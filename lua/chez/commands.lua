local M = {}

---@class chez.Subcommand
---@field desc string
---@field run fun(args: table)

---@type table<string, chez.Subcommand>
M.subcommands = {
  format = {
    desc = "Re-indent the buffer or [range]",
    run = function(args)
      local first, last
      if args.range > 0 then
        first, last = args.line1 - 1, args.line2
      end
      require("chez.format").format(0, first, last)
    end,
  },
  eval = {
    desc = "Evaluate [range], or the top-level form at the cursor",
    run = function(args)
      if args.range > 0 then
        local last = vim.fn.getline(args.line2)
        local buf = vim.api.nvim_get_current_buf()
        local text = vim.api.nvim_buf_get_lines(buf, args.line1 - 1, args.line2, false)
        require("chez.eval").eval_code(
          buf,
          table.concat(text, "\n"),
          { args.line1 - 1, 0, args.line2 - 1, #last },
          { label = "range" }
        )
      else
        require("chez.eval").root()
      end
    end,
  },
  load = { desc = "Load the current file", run = function() require("chez.eval").file() end },
  start = { desc = "Start the REPL", run = function() require("chez.repl").ensure(0) end },
  restart = { desc = "Restart the REPL", run = function() require("chez.repl").restart(0) end },
  stop = { desc = "Stop the REPL", run = function() require("chez.repl").stop(0) end },
  interrupt = { desc = "Interrupt evaluation", run = function() require("chez.repl").interrupt(0) end },
  repl = { desc = "Toggle the REPL window", run = function() require("chez.repl").toggle(0) end },
  clear = { desc = "Clear inline results", run = function() require("chez.repl.inline").clear(0) end },
  result = { desc = "Show the last result", run = function() require("chez.eval").show_result() end },
  backtrace = { desc = "Backtrace of the last error", run = function() require("chez.eval").backtrace() end },
  check = { desc = "Check the buffer (diagnostics)", run = function() require("chez.diagnostics").check(0) end },
  expand = { desc = "Expand the form at the cursor", run = function() require("chez.tools").expand(false) end },
  optimize = { desc = "expand/optimize the form at the cursor", run = function() require("chez.tools").expand(true) end },
  trace = { desc = "Toggle trace of the procedure at the cursor", run = function() require("chez.tools").trace() end },
}

function M.run(args)
  local name = args.fargs[1]
  local sub = M.subcommands[name]
  if not sub then
    vim.notify("Chez: unknown subcommand " .. tostring(name), vim.log.levels.ERROR)
    return
  end
  sub.run(args)
end

function M.complete(arglead, cmdline)
  if cmdline:match("^%S*%s+%S*$") then
    local names = vim.tbl_filter(function(n)
      return vim.startswith(n, arglead)
    end, vim.tbl_keys(M.subcommands))
    table.sort(names)
    return names
  end
  return {}
end

return M
