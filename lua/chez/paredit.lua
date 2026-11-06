-- Integration with nvim-paredit: re-indent after slurp/barf with chez.nvim's
-- indentation rules.
--
--   require("nvim-paredit").setup({
--     indent = { enabled = true, indentor = require("chez.paredit").indentor },
--   })
local M = {}

---nvim-paredit indentor: re-indents the form enclosing the edited one.
---@param event { type: string, parent: TSNode }
---@param opts? { buf?: integer }
function M.indentor(event, opts)
  local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
  local node = event and event.parent
  if not node then
    return
  end
  -- barfed elements move into the enclosing form, so re-indent that one
  local outer = node:parent()
  if not outer or outer:type() == "program" then
    outer = node
  end
  local sr, _, er = outer:range()

  -- keep the cursor on the same character when its line is re-indented
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_buf(win) == buf and vim.api.nvim_win_get_cursor(win)
  local before = cursor and vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1]

  require("chez.format").format(buf, sr, er + 1)

  if cursor and before then
    local after = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1] or ""
    local delta = #after:match("^%s*") - #before:match("^%s*")
    if delta ~= 0 then
      pcall(vim.api.nvim_win_set_cursor, win, { cursor[1], math.max(cursor[2] + delta, 0) })
    end
  end
end

return M
