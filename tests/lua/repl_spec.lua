local config = require("chez.config")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local function write(name, lines)
  local path = tmp .. "/" .. name
  vim.fn.writefile(lines, path)
  return path
end

local function wait_idle(s, ms)
  return vim.wait(ms or 5000, function()
    return s.ready and not s:busy()
  end, 10)
end

local function repl_lines(s)
  local buf = require("chez.repl.ui").buf(s)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function inline_texts(buf)
  local ns = vim.api.nvim_get_namespaces()["chez.inline.text"]
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    out[#out + 1] = { row = m[2], text = m[4].virt_text[1][1] }
  end
  table.sort(out, function(a, b)
    return a.row < b.row
  end)
  return out
end

describe("repl", function()
  local s, buf
  config.setup({ repl = { open_on_start = false } })
  vim.fn.writefile({}, tmp .. "/.chez-project")
  local repl = require("chez.repl")
  local eval = require("chez.eval")

  it("starts a session and evaluates the top-level form", function()
    local path = write("a.ss", {
      "(define (sq x)",
      "  (* x x))",
      "",
      "(list (sq 3) \"λ\")",
    })
    vim.cmd("edit " .. path)
    buf = vim.api.nvim_get_current_buf()
    assert.is_true(vim.b[buf].chez)
    vim.api.nvim_win_set_cursor(0, { 2, 4 })
    eval.root()
    s = repl.get(buf)
    assert.is_not_nil(s)
    assert.are.equal(vim.fs.normalize(tmp), s.root)
    assert.is_true(wait_idle(s))
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    eval.root()
    assert.is_true(wait_idle(s))
    local marks = inline_texts(buf)
    assert.are.same({ { row = 1, text = " ✓" }, { row = 3, text = ' => (9 "λ")' } }, marks)
    local lines = repl_lines(s)
    assert.is_truthy(vim.tbl_contains(lines, '(9 "λ")'))
  end)

  it("evaluates the innermost form and captures output", function()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '(begin (display "hello\\nworld") (sq 5))' })
    local n = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(0, { n, 0 })
    eval.form()
    assert.is_true(wait_idle(s))
    local lines = repl_lines(s)
    assert.is_truthy(vim.tbl_contains(lines, "; hello"))
    assert.is_truthy(vim.tbl_contains(lines, "; world"))
    assert.is_truthy(vim.tbl_contains(lines, "25"))
  end)

  it("reports errors with a diagnostic at the failing call", function()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
      "(define (boom y)",
      "  (+ 1 (car y)))",
      "(define (outer z)",
      "  (list (boom z)))",
      "(outer 5)",
    })
    local n = vim.api.nvim_buf_line_count(buf)
    vim.cmd("silent write")
    eval.buffer()
    assert.is_true(wait_idle(s))
    local ns = vim.api.nvim_get_namespaces()["chez.eval"]
    local diags = vim.diagnostic.get(buf, { namespace = ns })
    assert.are.equal(1, #diags)
    assert.are.equal(n - 2, diags[1].lnum) -- the (boom z) call in outer
    assert.is_truthy(diags[1].message:find("5 is not a pair", 1, true))
  end)

  it("locates syntax errors", function()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "(let ([x]) x)" })
    local n = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(0, { n, 3 })
    eval.root()
    assert.is_true(wait_idle(s))
    local ns = vim.api.nvim_get_namespaces()["chez.eval"]
    local diags = vim.diagnostic.get(buf, { namespace = ns })
    assert.are.equal(n - 1, diags[1].lnum)
    assert.is_truthy(diags[1].message:find("invalid syntax", 1, true))
  end)

  it("interrupts an infinite loop", function()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "(let loop () (loop))" })
    local n = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(0, { n, 0 })
    eval.root()
    vim.wait(300)
    assert.is_true(s:busy())
    repl.interrupt(buf)
    assert.is_true(wait_idle(s))
    local marks = inline_texts(buf)
    assert.are.equal(" ✗ interrupted", marks[#marks].text)
    -- the session is still usable
    local got
    s:request("eval", { code = "(+ 1 2)" }, function(r)
      got = r
    end)
    assert.is_true(wait_idle(s))
    assert.are.same({ "3" }, got.values)
  end)

  it("reads stdin through vim.ui.input", function()
    local orig = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("(a b)")
    end
    local got
    s:request("eval", { code = "(read)" }, function(r)
      got = r
    end)
    assert.is_true(wait_idle(s))
    vim.ui.input = orig
    assert.are.same({ "(a b)" }, got.values)
  end)

  it("evaluates and imports library forms", function()
    local path = write("lib.sls", {
      "(library (mylib)",
      "  (export twice)",
      "  (import (chezscheme))",
      "  ;; a comment",
      "  (define (twice x)",
      "    (* 2 x)))",
    })
    vim.cmd("edit " .. path)
    local lbuf = vim.api.nvim_get_current_buf()
    -- cursor inside a body form: only that form is evaluated
    vim.api.nvim_win_set_cursor(0, { 6, 4 })
    local node = require("chez.ts").root_form(lbuf, 5, 4)
    assert.are.equal(4, (node:range()))
    -- on the library line: the whole library, then auto-import
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    eval.root()
    assert.is_true(wait_idle(s))
    local got
    s:request("eval", { code = "(twice 21)" }, function(r)
      got = r
    end)
    assert.is_true(wait_idle(s))
    assert.are.same({ "42" }, got.values)
  end)

  it("accepts input typed in the REPL buffer", function()
    local ui = require("chez.repl.ui")
    ui.submit(s, "(define (f a)")
    ui.submit(s, "  (+ a 1))")
    assert.is_true(wait_idle(s))
    ui.submit(s, "(f 41)")
    assert.is_true(wait_idle(s))
    assert.is_truthy(vim.tbl_contains(repl_lines(s), "42"))
  end)

  it("clears earlier results of the buffer when the file is loaded", function()
    local path = write("load.ss", { "(define (h) 1)", "(car 5)" })
    vim.cmd("edit " .. path)
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eval.root()
    local sess = repl.get(b)
    assert.is_true(wait_idle(sess))
    assert.is_truthy(inline_texts(b)[1].text:find("✗", 1, true))
    -- fix the error elsewhere (in the REPL), then load the file
    vim.fn.writefile({ "(define (h) 1)", "(car '(5))" }, path)
    vim.cmd("edit!")
    eval.file()
    assert.is_true(wait_idle(sess))
    assert.are.same({}, inline_texts(b))
  end)

  it("restarts", function()
    local old_pid = s.pid
    repl.restart(buf)
    assert.is_true(vim.wait(5000, function()
      return s.pid ~= nil and s.pid ~= old_pid and s.ready
    end, 10))
    repl.stop_all()
  end)
end)
