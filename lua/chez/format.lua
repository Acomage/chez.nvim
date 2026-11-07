-- Re-indent Chez Scheme code with the same rules as 'indentexpr'.
local indent = require("chez.indent")
local reader = require("chez.reader")

local M = {}

local function indent_str(n, expandtab, ts)
  if expandtab or ts <= 0 then
    return string.rep(" ", n)
  end
  return string.rep("\t", math.floor(n / ts)) .. string.rep(" ", n % ts)
end

---Re-indent `lines`. `state` is the reader state at the first line (a fresh
---state by default). Lines starting inside strings or block comments are kept
---verbatim; trailing whitespace is removed from all other lines.
---@param lines string[]
---@param opts? { state?: chez.reader.State, row?: integer, expandtab?: boolean, tabstop?: integer }
---@return string[]
function M.format_lines(lines, opts)
  opts = opts or {}
  local s = opts.state or reader.new_state()
  local row = opts.row or 0
  local et = opts.expandtab ~= false
  local ts = opts.tabstop or 8
  local out = {}
  for k, line in ipairs(lines) do
    local n = indent.compute(s)
    if n >= 0 then
      local body = line:match("^%s*(.-)%s*$")
      line = body == "" and "" or indent_str(n, et, ts) .. body
    end
    out[k] = line
    reader.feed(s, line, row + k - 1)
  end
  return out
end

---Re-indent rows [first, last) (0-based, end-exclusive) of `buf`; defaults to
---the whole buffer. Only changed lines are written.
---@param buf? integer
---@param first? integer
---@param last? integer
function M.format(buf, first, last)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  first = first or 0
  last = last or vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
  local out = M.format_lines(lines, {
    state = reader.state_at(buf, first),
    row = first,
    expandtab = vim.bo[buf].expandtab,
    tabstop = vim.bo[buf].tabstop,
  })
  -- write back contiguous runs of changed lines to keep undo/marks tidy
  local k = 1
  while k <= #out do
    if out[k] ~= lines[k] then
      local j = k
      while j + 1 <= #out and out[j + 1] ~= lines[j + 1] do
        j = j + 1
      end
      vim.api.nvim_buf_set_lines(buf, first + k - 1, first + j, false, vim.list_slice(out, k, j))
      k = j + 1
    else
      k = k + 1
    end
  end
end

---Formatter definition for conform.nvim:
---  opts.formatters.chez_indent = require("chez.format").conform
---  opts.formatters_by_ft.scheme = { "chez_indent" }
M.conform = {
  meta = { description = "chez.nvim Lisp indentation" },
  format = function(_, ctx, lines, callback)
    local bo = vim.bo[ctx.buf]
    local ok, out = pcall(M.format_lines, lines, { expandtab = bo.expandtab, tabstop = bo.tabstop })
    if ok then
      callback(nil, out)
    else
      callback(tostring(out))
    end
  end,
}

return M
