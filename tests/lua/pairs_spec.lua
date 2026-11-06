local pairs_mod = require("chez.pairs")

-- mini.pairs (as used by LazyVim) when available: the buffer-local mappings
-- must take precedence over its global ones
local mini = vim.fn.stdpath("data") .. "/lazy/mini.pairs"
if vim.uv.fs_stat(mini) then
  vim.opt.rtp:append(mini)
  require("mini.pairs").setup({})
end

local function setup(lines, row, col)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "scheme"
  vim.b[buf].chez = true
  require("chez").attach(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { row, col })
  return buf
end

local function type_keys(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("smart brackets", function()
  require("chez.config").setup({ diagnostics = { enabled = false } })

  it("does not lose the definition's closer on a line holding only ')'", function()
    local buf = setup({ "(define (f x)", ")" }, 2, 0)
    type_keys("i()<Left>display x<Esc>")
    assert.are.same({ "(define (f x)", "(display x))" }, lines(buf))
  end)

  it("pairs and jumps over closers of balanced forms", function()
    local buf = setup({ "" }, 1, 0)
    type_keys("i(define (f x) (g x))<Esc>")
    assert.are.same({ "(define (f x) (g x))" }, lines(buf))
  end)

  it("inserts a closer when the form is missing one", function()
    local buf = setup({ "(define (f x)", "  (g x)" }, 2, 6)
    -- cursor before the last ")": typing ")" must insert, the form needs it
    type_keys("i)<Esc>")
    assert.are.same({ "(define (f x)", "  (g x))" }, lines(buf))
  end)

  it("jumps over a closer on another construct across lines", function()
    local buf = setup({ "(let ([a 1]", "      [b 2])", "  (+ a b))" }, 3, 8)
    type_keys("a)<Esc>")
    assert.are.same({ "(let ([a 1]", "      [b 2])", "  (+ a b))" }, lines(buf))
  end)

  it("inserts brackets literally in strings, comments and characters", function()
    local buf = setup({ '(display "")', "; ", "(list #\\)" }, 1, 10)
    type_keys("i(<Esc>")
    vim.api.nvim_win_set_cursor(0, { 2, 1 })
    type_keys("a(<Esc>")
    vim.api.nvim_win_set_cursor(0, { 3, 7 })
    type_keys("a(<Esc>")
    assert.are.same({ '(display "(")', "; (", "(list #\\()" }, lines(buf))
  end)

  it("does not pair before a word (wrapping)", function()
    local buf = setup({ "foo" }, 1, 0)
    type_keys("i(<Esc>")
    assert.are.same({ "(foo" }, lines(buf))
  end)

  it("computes the balance of the surrounding top-level form", function()
    local buf = setup({ "(a)", "(define (f)", "  (g", "(b)" }, 3, 0)
    assert.are.equal(2, pairs_mod.balance(buf, 2))
    assert.are.equal(0, pairs_mod.balance(buf, 0))
  end)
end)
