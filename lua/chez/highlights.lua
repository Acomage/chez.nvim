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
  ChezInlineOutput = { link = "Comment" },
  ChezEvalFlash = { link = "IncSearch" },
  ChezBracketUnmatched = { link = "Error" },
}

-- rainbow bracket colours (One Dark / One Light)
local rainbow = {
  dark = { "#e5c07b", "#c678dd", "#61afef", "#98c379", "#d19a66", "#56b6c2" },
  light = { "#c18401", "#a626a4", "#4078f2", "#50a14f", "#986801", "#0184bc" },
}
local rainbow_cterm = { 3, 5, 4, 2, 1, 6 }

---Colour `a` moved towards `b` by `t` (0..1); colours as 0xRRGGBB integers.
local function blend(a, b, t)
  local out = 0
  for shift = 16, 0, -8 do
    local x = math.floor(a / 2 ^ shift) % 256
    local y = math.floor(b / 2 ^ shift) % 256
    out = out + math.floor(x + (y - x) * t + 0.5) * 2 ^ shift
  end
  return out
end

local function color(name, attr)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl[attr] or nil
end

---Background for the current form: Normal's background tinted slightly
---towards a theme accent, so it differs from CursorLine.
local function current_form()
  local dark = vim.o.background == "dark"
  local bg = color("Normal", "bg") or (dark and 0x000000 or 0xffffff)
  local accent = color("DiagnosticInfo", "fg") or color("Function", "fg") or (dark and 0x61afef or 0x4078f2)
  return { bg = blend(bg, accent, dark and 0.12 or 0.10), ctermbg = dark and 236 or 254 }
end

function M.setup()
  local set = function(name, def)
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", def, { default = true }))
  end
  for name, def in pairs(M.groups) do
    set(name, def)
  end
  local colors = rainbow[vim.o.background] or rainbow.dark
  for i, fg in ipairs(colors) do
    set("ChezRainbow" .. i, { fg = fg, ctermfg = rainbow_cterm[i] })
  end
  set("ChezCurrentForm", current_form())
end

return M
