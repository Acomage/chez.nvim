-- Bracket features for Chez buffers:
--
-- * rainbow brackets: brackets coloured by nesting depth;
-- * current form: the innermost list around the cursor gets a background;
-- * jumping between matching brackets (`%`).
--
-- Brackets are found with chez.reader, so brackets in strings,
-- comments, |symbols| and character literals (#\( ) are ignored, and the
-- cached reader states make it cheap to start scanning anywhere.
local config = require("chez.config")
local reader = require("chez.reader")

local M = {}

local api = vim.api
local NCOLORS = 6
local CHUNK = 256

local rainbow_ns = api.nvim_create_namespace("chez.rainbow")
local form_ns = api.nvim_create_namespace("chez.current_form")

---@type table<integer, boolean>
local rainbow_bufs = {}

local at_top = reader.at_top

---@class chez.brackets.Pair
---@field [1] integer open row
---@field [2] integer open col (bytes)
---@field [3] integer close row
---@field [4] integer close col (bytes)

---@class chez.brackets.Scan
---@field tick integer
---@field first integer first scanned row
---@field last integer last scanned row
---@field pairs chez.brackets.Pair[]

---@type table<integer, chez.brackets.Scan>
local scans = {}

---Matched bracket pairs of the top-level form(s) around 0-based `row`.
---Scanning starts at a cached reader state outside any form and stops at the
---end of the top-level form containing `row` (or at the end of the buffer
---when that form is never closed).
---@param buf integer
---@param row integer
---@return chez.brackets.Scan
function M.scan(buf, row)
  local tick = api.nvim_buf_get_changedtick(buf)
  local c = scans[buf]
  if c and c.tick == tick and row >= c.first and row <= c.last then
    return c
  end
  local first, s = reader.form_start(buf, row)
  local result, stack = {}, {}
  local r = first
  local function on_bracket(col, open)
    if open then
      stack[#stack + 1] = { r, col }
    elseif #stack > 0 then
      local o = table.remove(stack)
      result[#result + 1] = { o[1], o[2], r, col }
    end
  end
  local nlines = api.nvim_buf_line_count(buf)
  local last = nlines - 1
  local done = false
  local from = first
  while not done and from < nlines do
    local lines = api.nvim_buf_get_lines(buf, from, from + CHUNK, false)
    for k, line in ipairs(lines) do
      r = from + k - 1
      reader.feed(s, line, r, on_bracket)
      if r >= row and at_top(s) then
        last, done = r, true
        break
      end
    end
    from = from + CHUNK
  end
  c = { tick = tick, first = first, last = math.max(last, row), pairs = result }
  scans[buf] = c
  return c
end

local function before_eq(r1, c1, r2, c2)
  return r1 < r2 or (r1 == r2 and c1 <= c2)
end

---Innermost list containing (row, col), both brackets included: the opening
---bracket found by scanning left from the cursor until one more `(` than `)`
---has been seen, and its closing bracket.
---@param buf integer
---@param row integer 0-based
---@param col integer 0-based byte column
---@return chez.brackets.Pair?
function M.enclosing(buf, row, col)
  local best
  for _, p in ipairs(M.scan(buf, row).pairs) do
    if before_eq(p[1], p[2], row, col) and before_eq(row, col, p[3], p[4]) then
      if not best or before_eq(best[1], best[2], p[1], p[2]) then
        best = p
      end
    end
  end
  return best
end

---Position of the bracket matching the one at (row, col). When (row, col) is
---not a bracket, the first bracket after it on the same line is used (like
---Vim's `%`).
---@param buf integer
---@param row integer
---@param col integer
---@return integer? row, integer? col
function M.match(buf, row, col)
  local nearest, ncol
  for _, p in ipairs(M.scan(buf, row).pairs) do
    if p[1] == row and p[2] == col then
      return p[3], p[4]
    elseif p[3] == row and p[4] == col then
      return p[1], p[2]
    end
    if p[1] == row and p[2] > col and (not ncol or p[2] < ncol) then
      nearest, ncol = { p[3], p[4] }, p[2]
    end
    if p[3] == row and p[4] > col and (not ncol or p[4] < ncol) then
      nearest, ncol = { p[1], p[2] }, p[4]
    end
  end
  if nearest then
    return nearest[1], nearest[2]
  end
end

---Jump to the matching bracket in the current window.
---@param add_jump? boolean add the old position to the jumplist
function M.jump(add_jump)
  local buf = api.nvim_get_current_buf()
  local pos = api.nvim_win_get_cursor(0)
  local row, col = M.match(buf, pos[1] - 1, pos[2])
  if not row then
    return
  end
  if add_jump then
    vim.cmd("normal! m'")
  end
  api.nvim_win_set_cursor(0, { row + 1, col })
end

---Keys for the `%` mapping (expr mapping in Normal, Visual and
---Operator-pending mode). A count keeps Vim's `N%` (go to N% of the file).
function M.jump_expr()
  if vim.v.count > 0 then
    return "%"
  end
  local mode = api.nvim_get_mode().mode
  if mode == "no" then
    -- make the motion inclusive, like `%`
    return "v<Cmd>lua require('chez.brackets').jump()<CR>"
  end
  local add = mode == "n" and "true" or "false"
  return "<Cmd>lua require('chez.brackets').jump(" .. add .. ")<CR>"
end

--------------------------------------------------------------------------------
-- Rainbow brackets
--------------------------------------------------------------------------------

---Brackets in rows [first, last] with their depth (0 = unmatched closer).
---@param buf integer
---@param first integer
---@param last integer
---@return { [1]: integer, [2]: integer, [3]: integer }[] row, col, depth
function M.brackets(buf, first, last)
  local s = reader.state_at(buf, first)
  local out = {}
  local lines = api.nvim_buf_get_lines(buf, first, last + 1, false)
  for k, line in ipairs(lines) do
    local r = first + k - 1
    reader.feed(s, line, r, function(col, _, depth)
      out[#out + 1] = { r, col, depth }
    end)
  end
  return out
end

---Highlight group for a bracket at `depth`.
function M.rainbow_group(depth)
  if depth <= 0 then
    return "ChezBracketUnmatched"
  end
  return "ChezRainbow" .. ((depth - 1) % NCOLORS + 1)
end

local provider_set = false
local function set_provider()
  if provider_set then
    return
  end
  provider_set = true
  api.nvim_set_decoration_provider(rainbow_ns, {
    on_win = function(_, _, buf, toprow, botrow)
      if not rainbow_bufs[buf] then
        return false
      end
      local ok, list = pcall(M.brackets, buf, toprow, botrow)
      if not ok then
        return false
      end
      for _, b in ipairs(list) do
        pcall(api.nvim_buf_set_extmark, buf, rainbow_ns, b[1], b[2], {
          end_col = b[2] + 1,
          hl_group = M.rainbow_group(b[3]),
          priority = 120, -- above tree-sitter (100)
          ephemeral = true,
        })
      end
      return false
    end,
  })
end

--------------------------------------------------------------------------------
-- Current form
--------------------------------------------------------------------------------

local function clear_form(buf)
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, form_ns, 0, -1)
  end
end

---Highlight the innermost list around the cursor of the current window.
---@param buf integer
function M.update_form(buf)
  if api.nvim_get_current_buf() ~= buf then
    return
  end
  local pos = api.nvim_win_get_cursor(0)
  local ok, p = pcall(M.enclosing, buf, pos[1] - 1, pos[2])
  clear_form(buf)
  if ok and p then
    api.nvim_buf_set_extmark(buf, form_ns, p[1], p[2], {
      end_row = p[3],
      end_col = p[4] + 1,
      hl_group = "ChezCurrentForm",
      priority = 90,
    })
  end
end

--------------------------------------------------------------------------------

---@param buf integer
function M.attach(buf)
  local opts = config.brackets
  if opts.rainbow then
    set_provider()
    rainbow_bufs[buf] = true
  end
  local group = api.nvim_create_augroup("chez.brackets." .. buf, { clear = true })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      rainbow_bufs[buf] = nil
      scans[buf] = nil
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })
  if opts.current_form then
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI", "BufEnter", "WinEnter" }, {
      group = group,
      buffer = buf,
      callback = function()
        M.update_form(buf)
      end,
    })
    -- extmarks belong to the buffer: hide the region in other windows
    api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
      group = group,
      buffer = buf,
      callback = function()
        clear_form(buf)
      end,
    })
    if api.nvim_get_current_buf() == buf then
      M.update_form(buf)
    end
  end
end

---@param buf integer
function M.detach(buf)
  rainbow_bufs[buf] = nil
  scans[buf] = nil
  pcall(api.nvim_del_augroup_by_name, "chez.brackets." .. buf)
  clear_form(buf)
end

return M
