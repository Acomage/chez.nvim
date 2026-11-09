local config = require("chez.config")

local M = {}

-- name -> { modes, rhs, desc, opts? }
local function actions()
  local eval = function(fn)
    return function()
      require("chez.eval")[fn]()
    end
  end
  local repl = function(fn)
    return function()
      require("chez.repl")[fn](0)
    end
  end
  return {
    eval_form = { "n", eval("form"), "Eval form" },
    eval_root = { "n", eval("root"), "Eval top-level form" },
    eval_word = { "n", eval("word"), "Eval word" },
    eval_buffer = { "n", eval("buffer"), "Eval buffer" },
    eval_file = { "n", eval("file"), "Load file" },
    eval_selection = { "x", eval("selection"), "Eval selection" },
    eval_operator = {
      "n",
      function()
        return require("chez.eval").operator_expr()
      end,
      "Eval motion",
      { expr = true },
    },
    eval_blocks = { "n", function() require("chez.evalblock").run(0) end, "Eval #eval blocks" },
    eval_block_toggle = {
      "n",
      function()
        require("chez.evalblock").toggle(0)
      end,
      "Toggle #eval block",
    },
    show_result = { "n", eval("show_result"), "Show last result" },
    clear_results = {
      "n",
      function()
        require("chez.repl.inline").clear(0)
        vim.diagnostic.reset(vim.api.nvim_create_namespace("chez.eval"), 0)
      end,
      "Clear inline results",
    },
    backtrace = { "n", eval("backtrace"), "Backtrace to quickfix" },
    repl_start = { "n", repl("ensure"), "Start REPL" },
    repl_restart = { "n", repl("restart"), "Restart REPL" },
    repl_stop = { "n", repl("stop"), "Stop REPL" },
    repl_interrupt = { "n", repl("interrupt"), "Interrupt evaluation" },
    repl_toggle = { "n", repl("toggle"), "Toggle REPL window" },
    repl_focus = { "n", repl("focus"), "Focus REPL" },
    macro_expand = { "n", function() require("chez.tools").expand(false) end, "Expand macro" },
    macro_expand_optimize = {
      "n",
      function()
        require("chez.tools").expand(true)
      end,
      "Expand and optimize (cp0)",
    },
    trace = { "n", function() require("chez.tools").trace() end, "Toggle trace" },
    docs_online = { "n", function() require("chez.doc").open_docs() end, "Open online docs" },
    jump_pair = {
      { "n", "x", "o" },
      function()
        return require("chez.brackets").jump_expr()
      end,
      "Matching bracket",
      { expr = true },
    },
    hover = { "n", function() require("chez.doc").hover() end, "Documentation" },
    definition = { "n", function() require("chez.tools").definition() end, "Go to definition" },
    signature = { "i", function() require("chez.doc").signature_help() end, "Signature" },
  }
end

local groups = {
  { "<localleader>e", "eval" },
  { "<localleader>c", "repl" },
  { "<localleader>m", "macro" },
  { "<localleader>t", "trace" },
  { "<localleader>h", "help" },
}

---@param buf integer
function M.attach(buf)
  local maps = config.keymaps
  if not maps then
    return
  end
  for name, a in pairs(actions()) do
    local lhs = maps[name]
    if lhs then
      local opts = vim.tbl_extend("force", { buffer = buf, desc = a[3] }, a[4] or {})
      vim.keymap.set(a[1], lhs, a[2], opts)
    end
  end
  local ok, wk = pcall(require, "which-key")
  if ok and wk.add then
    local specs = {}
    for _, g in ipairs(groups) do
      specs[#specs + 1] = { g[1], group = g[2], buffer = buf }
    end
    pcall(wk.add, specs)
  end
end

return M
