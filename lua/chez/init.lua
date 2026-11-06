local config = require("chez.config")

local M = {}

---@param opts? chez.Options
function M.setup(opts)
  config.setup(opts)
  require("chez.indent").reset()
  -- re-attach buffers that were opened before setup()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "scheme" then
      vim.b[buf].chez = nil
      if require("chez.detect").is_chez(buf) then
        M.attach(buf)
      end
    end
  end
end

local function append_undo(buf, cmd)
  local u = vim.b[buf].undo_ftplugin
  vim.b[buf].undo_ftplugin = (u and u ~= "") and (u .. " | " .. cmd) or cmd
end

---Set up a Chez Scheme buffer. Called from after/ftplugin/scheme.lua.
---@param buf integer
function M.attach(buf)
  local bo = vim.bo[buf]
  if config.indent.enabled then
    bo.lispoptions = "expr:1"
    bo.indentexpr = "v:lua.require'chez.indent'.indentexpr()"
    -- the runtime scheme ftplugin adds lisp-style reindent triggers already;
    -- reindent when typing a closing bracket on an otherwise empty line
    bo.indentkeys = "!^F,o,O,0),0]"
    require("chez.indent").attach(buf)
    append_undo(buf, "setl lispoptions< indentexpr< indentkeys<")
  end
  if config.editing.literal_quotes then
    for _, q in ipairs({ "'", "`" }) do
      vim.keymap.set("i", q, q, { buffer = buf, desc = "Insert " .. q })
    end
    append_undo(buf, "silent! iunmap <buffer> ' | silent! iunmap <buffer> `")
  end
  bo.omnifunc = "v:lua.require'chez.complete'.omnifunc"
  append_undo(buf, "setl omnifunc<")
  require("chez.keymaps").attach(buf)
  require("chez.diagnostics").attach(buf)
  vim.b[buf].chez_attached = true
end

---Statusline component, e.g. for lualine: `require("chez").status`.
function M.status()
  if not package.loaded["chez.repl"] then
    return ""
  end
  return require("chez.repl").status(0)
end

return M
