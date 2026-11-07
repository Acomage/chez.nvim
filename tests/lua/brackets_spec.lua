local brackets = require("chez.brackets")

local function setup(lines, row, col)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "scheme"
  vim.b[buf].chez = true
  require("chez").attach(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { row or 1, col or 0 })
  return buf
end

local function cursor()
  local p = vim.api.nvim_win_get_cursor(0)
  return { p[1], p[2] }
end

local function type_keys(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

describe("brackets", function()
  require("chez.config").setup({ diagnostics = { enabled = false } })

  it("reports brackets with their depth, ignoring literals", function()
    local buf = setup({ '(a "(" #\\( ; )', "  [b #(c) #vu8(1)]) )" })
    assert.are.same({
      { 0, 0, 1 },
      { 1, 2, 2 },
      { 1, 6, 3 },
      { 1, 8, 3 },
      { 1, 14, 3 },
      { 1, 16, 3 },
      { 1, 17, 2 },
      { 1, 18, 1 },
      { 1, 20, 0 },
    }, brackets.brackets(buf, 0, 1))
    assert.are.equal("ChezRainbow1", brackets.rainbow_group(1))
    assert.are.equal("ChezRainbow1", brackets.rainbow_group(7))
    assert.are.equal("ChezBracketUnmatched", brackets.rainbow_group(0))
  end)

  it("starts the depth at the visible row from the reader state", function()
    local buf = setup({ "(define (f x)", "  (g (h x)))" })
    assert.are.same({ { 1, 2, 2 }, { 1, 5, 3 }, { 1, 9, 3 }, { 1, 10, 2 }, { 1, 11, 1 } }, brackets.brackets(buf, 1, 1))
  end)

  it("finds the innermost enclosing list", function()
    local buf = setup({ "(define (f x)", '  (g ")" (h x)))', "(other)" })
    -- inside (h x)
    assert.are.same({ 1, 9, 1, 13 }, brackets.enclosing(buf, 1, 11))
    -- on the ")" inside the string: (g ...)
    assert.are.same({ 1, 2, 1, 14 }, brackets.enclosing(buf, 1, 6))
    -- on an opening / closing bracket: that list
    assert.are.same({ 1, 9, 1, 13 }, brackets.enclosing(buf, 1, 9))
    assert.are.same({ 1, 9, 1, 13 }, brackets.enclosing(buf, 1, 13))
    assert.are.same({ 0, 0, 1, 15 }, brackets.enclosing(buf, 0, 3))
    assert.are.same({ 2, 0, 2, 6 }, brackets.enclosing(buf, 2, 3))
  end)

  it("finds nothing between top-level forms or in unclosed forms", function()
    local buf = setup({ "(a)  (b)", "(c (d)" })
    assert.is_nil(brackets.enclosing(buf, 0, 4))
    assert.is_nil(brackets.enclosing(buf, 1, 1))
    assert.are.same({ 1, 3, 1, 5 }, brackets.enclosing(buf, 1, 4))
  end)

  it("highlights the current form", function()
    local buf = setup({ "(a (b c) d)" }, 1, 5)
    brackets.update_form(buf)
    local ns = vim.api.nvim_get_namespaces()["chez.current_form"]
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert.are.equal(1, #marks)
    assert.are.same({ 0, 3 }, { marks[1][2], marks[1][3] })
    assert.are.same({ 0, 8 }, { marks[1][4].end_row, marks[1][4].end_col })
  end)

  it("jumps between matching brackets with %", function()
    setup({ "(define (f x)", '  (g "(" x))' }, 1, 0)
    type_keys("%")
    assert.are.same({ 2, 11 }, cursor())
    type_keys("%")
    assert.are.same({ 1, 0 }, cursor())
    -- not on a bracket: the next bracket on the line
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    type_keys("%")
    assert.are.same({ 1, 12 }, cursor())
  end)

  it("works as an inclusive motion", function()
    local buf = setup({ "(a (b c) d)" }, 1, 3)
    type_keys("d%")
    assert.are.same({ "(a  d)" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)
end)
