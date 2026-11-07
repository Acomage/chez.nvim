local config = require("chez.config")
local util = require("chez.util")

local M = {}

---Root directory of the project containing `path`, or nil.
---@param path string
---@param markers? string[]
---@return string?
function M.root(path, markers)
  return vim.fs.root(path, markers or config.root_markers)
end

---Does the buffer text look like Chez Scheme (`#!chezscheme` near the top)?
---@param buf integer
local function has_chez_directive(buf)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, 30, false)) do
    if line:find("#!chezscheme", 1, true) then
      return true
    end
  end
  return false
end

---Is `buf` a Chez Scheme buffer? Result is cached in `b:chez`; set `b:chez`
---yourself (e.g. via an autocmd) to override detection.
---@param buf? integer
---@return boolean
function M.is_chez(buf)
  buf = util.buf(buf)
  local cached = vim.b[buf].chez
  if cached ~= nil then
    return cached == true or cached == 1
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local ext = name:match("%.([^./]+)$")
  local opts = config.detect
  local result = false
  if ext and vim.list_contains(opts.extensions, ext) then
    result = true
  elseif has_chez_directive(buf) then
    result = true
  elseif ext == "scm" then
    result = opts.scm or (name ~= "" and M.root(name, opts.markers) ~= nil)
  end
  vim.b[buf].chez = result
  return result
end

return M
