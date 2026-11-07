local config = require("chez.config")
local evalblock = require("chez.evalblock")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.fn.writefile({}, tmp .. "/.chez-project")
vim.fn.writefile({
  "(library (util) (export double) (import (chezscheme))",
  "  (define (double x) (* 2 x)))",
}, tmp .. "/util.sls")

local function open(name, lines)
  local path = tmp .. "/" .. name
  vim.fn.writefile(lines, path)
  vim.cmd("edit! " .. path)
  return vim.api.nvim_get_current_buf()
end

---Virtual text per row: { [row] = "text" }
local function ghosts(buf)
  local ns = vim.api.nvim_get_namespaces()["chez.inline.text"]
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local text = {}
    for _, c in ipairs(m[4].virt_text or {}) do
      text[#text + 1] = c[1]
    end
    out[m[2]] = (out[m[2]] or "") .. table.concat(text)
  end
  return out
end

local function wait_done(buf)
  -- the pending marker on the #eval line disappears when the run is over
  return vim.wait(15000, function()
    for _, t in pairs(ghosts(buf)) do
      if t:find("…", 1, true) then
        return false
      end
    end
    return true
  end, 50)
end

describe("#eval blocks", function()
  config.setup({ diagnostics = { enabled = false }, repl = { open_on_start = false } })

  it("finds blocks whose first line is #eval", function()
    local buf = open("find.ss", {
      "#|#eval",
      "(+ 1 2)",
      "|#",
      "#| just a comment |#",
      "#|",
      "  #eval",
      "(f)|#",
      "#| #evaluate |#",
    })
    local blocks = evalblock.find(buf)
    assert.are.equal(2, #blocks)
    assert.are.same({ 0, 2 }, { blocks[1].trow, blocks[1].tcol })
    assert.are.equal("\n(+ 1 2)\n", blocks[1].code)
    assert.are.equal(7, blocks[1].offset)
    assert.are.same({ 5, 2 }, { blocks[2].trow, blocks[2].tcol })
    assert.are.equal("\n(f)", blocks[2].code)
  end)

  it("loads the file and its imports, shows results as virtual text", function()
    local buf = open("main.sls", {
      "(library (main) (export f) (import (chezscheme) (util))",
      "  (define (helper x) (+ x 1))",
      "  (define (f x) (double (helper x))))",
      "",
      "#|#eval",
      "(f 3)",
      "(helper 10) (define y 5)",
      '(begin (display "hi") (list y y))',
      "(car '())",
      "|#",
    })
    evalblock.run(buf)
    assert.is_true(wait_done(buf))
    local g = ghosts(buf)
    assert.are.equal(" => 8", g[5])
    assert.are.equal(" => 11 ✓", g[6])
    assert.are.equal(" ▷ hi => (5 5)", g[7])
    assert.is_truthy(g[8]:find("✗ Exception in car", 1, true))
    assert.is_nil(g[4])
  end)

  it("reports errors while loading the file at the failing form", function()
    local buf = open("bad.ss", {
      "(define (g) 1)",
      "(car 5)",
      "#|#eval",
      "(g)",
      "|#",
    })
    evalblock.run(buf)
    assert.is_true(wait_done(buf))
    local g = ghosts(buf)
    assert.is_truthy(g[1]:find("✗", 1, true))
    assert.are.equal(" => 1", g[3])
  end)

  it("reads the code of blocks as code: brackets, depth, indentation", function()
    local brackets = require("chez.brackets")
    local indent = require("chez.indent")
    local buf = open("reader.ss", {
      "#|#eval",
      "(f (g 1)",
      "   2)",
      "|#",
      "#|",
      "#eval",
      "(h [x])|#",
      "#| plain (a) |#",
      "(b)",
    })
    local list = brackets.brackets(buf, 0, 8)
    local rows = {}
    for _, b in ipairs(list) do
      rows[#rows + 1] = table.concat(b, ",")
    end
    assert.are.same({
      "1,0,1", "1,3,2", "1,7,2", "2,4,1",
      "6,0,1", "6,3,2", "6,5,2", "6,6,1",
      "8,0,1", "8,2,1",
    }, rows)
    assert.are.same({ 1, 3, 1, 7 }, brackets.enclosing(buf, 1, 5))
    -- line 3 continues (f ...: aligned with the first argument
    assert.are.equal(3, indent.indentexpr(3))
    -- an unclosed list in a block does not leak out of it
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "#|#eval (f", "|#", "(b)" })
    assert.are.same({ { 0, 8, 1 }, { 2, 0, 1 }, { 2, 2, 1 } }, brackets.brackets(buf, 0, 2))
  end)

  it("checks the code of blocks (diagnostics)", function()
    config.setup({ diagnostics = { enabled = true, on_attach = false }, repl = { open_on_start = false } })
    local buf = open("check.sls", {
      "(library (checked) (export f) (import (chezscheme))",
      "  (define (helper x) (+ x 1))",
      "  (define (f x) (helper x)))",
      "#|#eval",
      "(helper 1) (nope 2)",
      "|#",
    })
    local diag = require("chez.diagnostics")
    diag.check(buf)
    local ok = vim.wait(15000, function()
      return #vim.diagnostic.get(buf, { namespace = diag.namespace }) > 0
    end, 50)
    assert.is_true(ok)
    local ds = vim.diagnostic.get(buf, { namespace = diag.namespace })
    assert.are.equal(1, #ds)
    assert.are.same({ 4, 12, 16 }, { ds[1].lnum, ds[1].col, ds[1].end_col })
    assert.is_truthy(ds[1].message:find("nope", 1, true))
    config.setup({ diagnostics = { enabled = false }, repl = { open_on_start = false } })
  end)

  it("injects only complete blocks (an unterminated one would nest forever)", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local function depth(lines)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      local parser = vim.treesitter.get_parser(buf, "scheme")
      parser:parse(true)
      local n, t = 0, parser
      while next(t:children()) and n < 10 do
        n, t = n + 1, select(2, next(t:children()))
      end
      return n
    end
    assert.are.equal(1, depth({ "(a)", "#|#eval", "(b)", "|#" }))
    assert.are.equal(0, depth({ "(a)", "#|#eval", "(b)" }))
    -- typing into a block: complete -> unterminated -> complete
    assert.are.equal(1, depth({ "#|#eval (b) |#" }))
    assert.are.equal(0, depth({ "#|#eval (b) |" }))
    assert.are.equal(1, depth({ "#|#eval (b) |#" }))
  end)
end)
