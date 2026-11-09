local config = require("chez.config")
local doc = require("chez.doc")
local complete = require("chez.complete")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.fn.writefile({}, tmp .. "/.chez-project")

local function open(name, lines)
  local path = tmp .. "/" .. name
  vim.fn.writefile(lines, path)
  vim.cmd("edit " .. path)
  return vim.api.nvim_get_current_buf()
end

local function names(cands)
  local out = {}
  for _, c in ipairs(cands) do
    out[c.name] = c
  end
  return out
end

describe("doc", function()
  config.setup({ repl = { open_on_start = false } })

  it("formats arity masks", function()
    assert.are.equal("1", doc.arity_string(2))
    assert.are.equal("1, 2", doc.arity_string(6))
    assert.are.equal("2+", doc.arity_string(-4))
    assert.are.equal("0+", doc.arity_string(-1))
    assert.are.equal("1, 3+", doc.arity_string(-6))
  end)

  it("has builtin documentation", function()
    local md = table.concat(doc.builtin_markdown("list-head"), "\n")
    assert.is_truthy(md:find("(list-head list n)", 1, true))
    assert.is_truthy(md:find("csug/objects.html#", 1, true))
    md = table.concat(doc.builtin_markdown("vector-map"), "\n")
    assert.is_truthy(md:find("Revised", 1, true))
    assert.is_nil(doc.builtin_markdown("no-such-thing"))
  end)

  it("finds definitions in a buffer", function()
    local buf = open("defs.ss", {
      ";; Adds one.",
      "(define (inc x) (+ x 1))",
      "(define sq (lambda (x) (* x x)))",
      "(define-syntax swap! (syntax-rules () [(_ a b) (let ([t a]) (set! a b) (set! b t))]))",
      "(define-record-type point (fields x (mutable y)))",
      "(library (lib) (export) (import (chezscheme)) (define (inner a b) a))",
    })
    local defs = names(doc.definitions(buf))
    assert.are.equal("(inc x)", defs.inc.sig)
    assert.are.equal("procedure", defs.inc.kind)
    assert.are.equal("(sq x)", defs.sq.sig)
    assert.are.equal("syntax", defs["swap!"].kind)
    assert.are.equal("record", defs.point.kind)
    assert.are.equal("(make-point x y)", defs["make-point"].sig)
    assert.is_not_nil(defs["point?"])
    assert.is_not_nil(defs["point-x"])
    assert.is_not_nil(defs["point-y-set!"])
    assert.is_nil(defs["point-x-set!"])
    assert.are.equal("(inner a b)", defs.inner.sig)
    local md = table.concat(doc.definition_markdown(buf, defs.inc), "\n")
    assert.is_truthy(md:find("Adds one.", 1, true))
  end)
end)

describe("completion", function()
  it("computes Scheme identifier prefixes", function()
    assert.are.same({ "string->l", 1 }, { complete.prefix("(string->l", 10) })
    assert.are.same({ "x", 3 }, { complete.prefix("(f x", 4) })
    assert.are.same({ "foo", 4 }, { complete.prefix("`(,@foo", 7) })
    assert.are.same({ "", 3 }, { complete.prefix("(a ", 3) })
  end)

  it("collects local bindings in scope", function()
    local buf = open("locals.ss", {
      "(define (f alpha beta)",
      "  (let loop ([i 0] [acc '()])",
      "    (let-values ([(q r) (div-and-mod 7 2)])",
      "      (lambda (z . rest)",
      "        (+ X)))))",
      "(define (g other) other)",
    })
    local locals = complete.locals(buf, 4, 11)
    table.sort(locals)
    assert.are.same({ "acc", "alpha", "beta", "i", "loop", "q", "r", "rest", "z" }, locals)
    local cands = names(complete.candidates(buf, 4, 11))
    assert.are.equal("local", cands.alpha.source)
    assert.are.equal("buffer", cands.g.source)
    assert.are.equal("builtin", cands["list-head"].source)
    assert.is_nil(cands.other)
  end)

  it("provides blink items with a Scheme-aware text edit", function()
    package.loaded["blink.cmp.types"] = package.loaded["blink.cmp.types"]
      or { CompletionItemKind = { Function = 3, Keyword = 14, Snippet = 15, Struct = 22, Variable = 6 } }
    local buf = open("blink.ss", { "(string->l" })
    local src = require("chez.complete.blink").new()
    local result
    src:get_completions({ bufnr = buf, cursor = { 1, 10 }, line = "(string->l" }, function(r)
      result = r
    end)
    assert.is_not_nil(result)
    local by = {}
    for _, it in ipairs(result.items) do
      by[it.label] = it
    end
    assert.is_nil(by["car"]) -- filtered by the "string->" head
    local item = by["string->list"]
    assert.are.equal("list", item.filterText)
    assert.are.same({ start = { line = 0, character = 1 }, ["end"] = { line = 0, character = 10 } }, item.textEdit.range)
    local resolved
    src:resolve(item, function(i)
      resolved = i
    end)
    assert.is_truthy(resolved.documentation.value:find("string->list", 1, true))
  end)

  it("offers an #eval block snippet for #ev", function()
    package.loaded["blink.cmp.types"] = package.loaded["blink.cmp.types"]
      or { CompletionItemKind = { Function = 3, Keyword = 14, Snippet = 15, Struct = 22, Variable = 6 } }
    local buf = open("snippet.ss", { "#ev" })
    local src = require("chez.complete.blink").new()
    local result
    src:get_completions({ bufnr = buf, cursor = { 1, 3 }, line = "#ev" }, function(r)
      result = r
    end)
    local item
    for _, it in ipairs(result.items) do
      if it.label == "#eval" then
        item = it
      end
    end
    assert.is_not_nil(item)
    assert.are.equal("eval", item.filterText)
    assert.are.equal(vim.lsp.protocol.InsertTextFormat.Snippet, item.insertTextFormat)
    assert.are.equal("#|#eval\n$0\n|#", item.textEdit.newText)
    assert.are.same({ start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } }, item.textEdit.range)
  end)
end)

describe("tools", function()
  local repl = require("chez.repl")

  it("expands macros in a float", function()
    local buf = open("expand.ss", { "(when (> 1 0) 'yes)" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    require("chez.tools").expand(false)
    local s = repl.get(buf)
    assert.is_true(vim.wait(5000, function()
      return s.ready and not s:busy()
    end, 10))
    local found
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative ~= "" then
        local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
        found = text
        vim.api.nvim_win_close(win, true)
      end
    end
    assert.is_truthy(found and found:find("(if (> 1 0) 'yes (void))", 1, true))
  end)

  it("goes to definitions in the buffer and in other files", function()
    open("other.ss", { "(define (helper x)", "  x)" })
    local buf = open("main.ss", { "(define (local-one) 1)", "(helper (local-one))" })
    vim.api.nvim_win_set_cursor(0, { 2, 10 })
    require("chez.tools").definition()
    assert.are.same({ 1, 9 }, vim.api.nvim_win_get_cursor(0))
    vim.api.nvim_win_set_cursor(0, { 2, 2 })
    require("chez.tools").definition()
    assert.is_true(vim.wait(3000, function()
      return vim.api.nvim_buf_get_name(0):match("other%.ss$") ~= nil
    end, 10))
    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    assert.is_not_nil(buf)
    repl.stop_all()
  end)
end)

describe("diagnostics", function()
  it("reports syntax errors and unbound identifiers", function()
    local diagnostics = require("chez.diagnostics")
    local buf = open("check.ss", {
      "(define (f x)",
      "  (g x 'g))",
      "(define (h) (let ([y]) y))",
    })
    diagnostics.check(buf)
    local got
    assert.is_true(vim.wait(10000, function()
      got = vim.diagnostic.get(buf, { namespace = diagnostics.namespace })
      return #got > 0
    end, 20))
    table.sort(got, function(a, b)
      return a.lnum < b.lnum
    end)
    assert.are.equal(1, #got) -- the syntax error stops expansion
    assert.are.equal(2, got[1].lnum)
    assert.is_truthy(got[1].message:find("invalid syntax", 1, true))

    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "(define (h) (let ([y 1]) y))" })
    diagnostics.check(buf)
    assert.is_true(vim.wait(10000, function()
      got = vim.diagnostic.get(buf, { namespace = diagnostics.namespace })
      return #got > 0 and got[1].lnum ~= 2
    end, 20))
    assert.are.equal(1, #got) -- the quoted 'g is not reported
    assert.are.same({ 1, 3, 1, 4 }, { got[1].lnum, got[1].col, got[1].end_lnum, got[1].end_col })
    assert.are.equal("variable g is not bound", got[1].message)
  end)
end)

describe("paredit indentor", function()
  it("re-indents the enclosing form after a slurp", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].expandtab = true
    -- state after slurping (display y) into the let
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "(define (f x)",
      "  (let ([y x])",
      "  (display y))",
      "  (+ x y))",
    })
    vim.api.nvim_win_set_cursor(0, { 3, 3 })
    local root = vim.treesitter.get_parser(buf, "scheme"):parse()[1]:root()
    local let = root:named_descendant_for_range(1, 3, 1, 3)
    while let:type() ~= "list" do
      let = let:parent()
    end
    require("chez.paredit").indentor({ type = "slurp-forwards", parent = let }, { buf = buf })
    assert.are.same({
      "(define (f x)",
      "  (let ([y x])",
      "    (display y))",
      "  (+ x y))",
    }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.are.same({ 3, 5 }, vim.api.nvim_win_get_cursor(0))
  end)
end)
