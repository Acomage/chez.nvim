-- Runs after Neovim's runtime ftplugin/scheme.vim.
local buf = vim.api.nvim_get_current_buf()
if not require("chez.detect").is_chez(buf) then
  return
end
require("chez").attach(buf)
