local M = {}

---Absolute path of the plugin's root directory.
M.plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

---Number of characters (code points) in `s`.
---@param s string
function M.strchars(s)
  local ok, n = pcall(vim.str_utfindex, s, "utf-32")
  if ok then
    return n
  end
  return vim.fn.strchars(s)
end

---Character offset (as counted by Chez) of byte position (row, col) in buf.
---@param buf integer
---@param row integer 0-based
---@param col integer 0-based byte column
---@return integer
function M.char_offset(buf, row, col)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, row, false)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local before = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
  return M.strchars(before) + M.strchars(line:sub(1, col))
end

---Convert a 0-based character offset into a 0-based (row, byte col).
---@param lines string[]
---@param off integer
---@return integer row, integer col
function M.offset_to_pos(lines, off)
  for i, line in ipairs(lines) do
    local n = M.strchars(line)
    if off <= n then
      return i - 1, vim.str_byteindex(line, "utf-32", off, false)
    end
    off = off - n - 1
  end
  local last = #lines
  return math.max(last - 1, 0), #(lines[last] or "")
end

---Lines of `file`: from a loaded buffer when there is one, else from disk.
---@param file string
---@return string[]?, integer? buf
function M.file_lines(file)
  local buf = vim.fn.bufnr(file)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false), buf
  end
  if vim.uv.fs_stat(file) then
    return vim.fn.readfile(file)
  end
end

---Resolve a source location reported by Chez into a 0-based (row, col).
---Accepts { file, pos } (character offset) or { file, line, col } (1-based).
---@param loc { file: string, pos?: integer, line?: integer, col?: integer }
---@return { file: string, row: integer, col: integer, buf?: integer }?
function M.resolve_location(loc)
  if not loc or not loc.file then
    return nil
  end
  local file = vim.fs.normalize(vim.fn.fnamemodify(loc.file, ":p"))
  local lines, buf = M.file_lines(file)
  if loc.line then
    local row = loc.line - 1
    local col = 0
    local text = lines and lines[loc.line]
    if text and loc.col then
      col = vim.str_byteindex(text, "utf-32", math.min(loc.col - 1, M.strchars(text)), false)
    end
    return { file = file, row = row, col = col, buf = buf }
  end
  if loc.pos and lines then
    local row, col = M.offset_to_pos(lines, loc.pos)
    return { file = file, row = row, col = col, buf = buf }
  end
  return { file = file, row = 0, col = 0, buf = buf }
end

---Extract "at char N of FILE" / "at line L, char C of FILE" from a Chez
---condition message.
---@param msg string
---@return { file: string, pos?: integer, line?: integer, col?: integer }?
function M.location_from_message(msg)
  local line, col, file = msg:match("at line (%d+), char (%d+) of (.-)%s*$")
  if line then
    return { file = file, line = tonumber(line), col = tonumber(col) }
  end
  local pos
  pos, file = msg:match("at char (%d+) of (.-)%s*$")
  if pos and not file:match("^#<") then
    return { file = file, pos = tonumber(pos) }
  end
end

---Does `buf` still hold `lines`, a snapshot taken at changedtick `tick`?
---The changedtick also moves without text changes (Neovim increments it
---when a buffer that was just read is entered), so the text is compared then.
---@param buf integer
---@param tick integer
---@param lines string[]
---@return boolean
function M.same_text(buf, tick, lines)
  if vim.api.nvim_buf_get_changedtick(buf) == tick then
    return true
  end
  local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #cur ~= #lines then
    return false
  end
  for i = 1, #cur do
    if cur[i] ~= lines[i] then
      return false
    end
  end
  return true
end

---Truncate `s` to at most `n` display cells, appending "…".
function M.truncate(s, n)
  if vim.fn.strdisplaywidth(s) <= n then
    return s
  end
  return vim.fn.strcharpart(s, 0, math.max(n - 1, 0)) .. "…"
end

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "chez.nvim" })
end

return M
