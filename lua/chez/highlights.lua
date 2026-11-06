local M = {}

M.groups = {
  ChezReplPrefix = { link = "NonText" },
  ChezReplOutput = { link = "Normal" },
  ChezReplError = { link = "DiagnosticError" },
  ChezReplWarning = { link = "DiagnosticWarn" },
  ChezReplInfo = { link = "Comment" },
  ChezInlineResult = { link = "DiagnosticVirtualTextHint" },
  ChezInlineOk = { link = "DiagnosticVirtualTextOk" },
  ChezInlineError = { link = "DiagnosticVirtualTextError" },
  ChezInlineWarning = { link = "DiagnosticVirtualTextWarn" },
  ChezInlinePending = { link = "Comment" },
  ChezEvalFlash = { link = "IncSearch" },
}

function M.setup()
  for name, def in pairs(M.groups) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", def, { default = true }))
  end
end

return M
