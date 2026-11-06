-- Minimal init for headless tests: nvim --headless -u tests/minimal_init.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(root .. "/after")
local site = vim.fn.stdpath("data") .. "/site"
vim.opt.rtp:append(site) -- tree-sitter parsers installed by nvim-treesitter
local plenary = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.uv.fs_stat(plenary) then
  vim.opt.rtp:append(plenary)
end
vim.opt.swapfile = false
vim.cmd("filetype plugin indent on")
vim.cmd("runtime! plugin/chez.lua plugin/plenary.vim")
