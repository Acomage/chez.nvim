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
end)
