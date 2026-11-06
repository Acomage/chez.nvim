-- Bracket insertion for Chez buffers.
--
-- Autopair plugins decide line by line whether to pair "(" or to jump over a
-- ")". In Lisp code a form usually spans many lines, so they get it wrong:
-- typing "(" on a line that holds only the closing ")" of a definition is not
-- paired (the line looks unbalanced), and the ")" typed next jumps over the
-- definition's closer, losing a bracket. Here the decision uses the reader
-- state of the whole top-level form instead (strings, comments and #\( are
-- understood).
local indent = require("chez.indent")

local M = {}

local CLOSE = { ["("] = ")", ["["] = "]" }

local function cursor()
  local pos = vim.api.nvim_win_get_cursor(0)
  return pos[1] - 1, pos[2]
end

---Reader state at (row, col) and the line text.
local function state_at(buf, row, col)
  local s = indent.state_at(buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  indent.feed(s, line:sub(1, col), row)
  return s, line
end

local function at_top(s)
  return #s.stack == 1 and not s.str and not s.bar and s.block == 0
end

---Is (row, col) inside a string, comment, |symbol| or after `#\`?
local function in_literal(s, line, col)
  if s.str or s.bar or s.block > 0 or s.comment then
    return true
  end
  return line:sub(1, col):match("#\\$") ~= nil
end

---Opening minus closing brackets of the top-level form around `row`
---(> 0: closers are missing; < 0: there are too many closers).
---@param buf integer
---@param row integer
---@return integer
function M.balance(buf, row)
  -- start at a cached checkpoint that is outside any form
  local CHECK = 16
  local start = row - row % CHECK
  local s = indent.state_at(buf, start)
  while start > 0 and not at_top(s) do
    start = start - CHECK
    s = indent.state_at(buf, start)
  end
  local extra0 = s.extra
  local lines = vim.api.nvim_buf_get_lines(buf, start, -1, false)
  for k, line in ipairs(lines) do
    local r = start + k - 1
    indent.feed(s, line, r)
    if r >= row and at_top(s) then
      break
    end
  end
  return (#s.stack - 1) - (s.extra - extra0)
end

---Keys for typing the opening bracket `o`.
function M.open(o)
  local buf = vim.api.nvim_get_current_buf()
  local row, col = cursor()
  local s, line = state_at(buf, row, col)
  if in_literal(s, line, col) then
    return o
  end
  local nxt = line:sub(col + 1, col + 1)
  -- pair only before whitespace, a closer or the end of the line
  if nxt == "" or nxt:match("[%s%)%]]") then
    return o .. CLOSE[o] .. "<C-g>U<Left>"
  end
  return o
end

---Keys for typing the closing bracket `c`: jump over the next character when
---it is `c` and the form has no missing closers, otherwise insert.
function M.close(c)
  local buf = vim.api.nvim_get_current_buf()
  local row, col = cursor()
  local s, line = state_at(buf, row, col)
  if in_literal(s, line, col) or line:sub(col + 1, col + 1) ~= c then
    return c
  end
  if M.balance(buf, row) > 0 then
    return c
  end
  return "<C-g>U<Right>"
end

---Map the bracket keys in `buf`.
---@param buf integer
function M.attach(buf)
  for o, c in pairs(CLOSE) do
    vim.keymap.set("i", o, function()
      return M.open(o)
    end, { buffer = buf, expr = true, desc = "Insert " .. o .. c })
    vim.keymap.set("i", c, function()
      return M.close(c)
    end, { buffer = buf, expr = true, desc = "Insert or skip " .. c })
  end
end

return M
