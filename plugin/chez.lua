if vim.g.loaded_chez then
  return
end
vim.g.loaded_chez = true

-- queries/scheme/{highlights,injections}.scm: `#chez-eval-block?` matches a
-- complete `#| #eval ... |#` block comment, `#chez-eval-block!` narrows the
-- capture to the code inside it. Only complete blocks may be injected: an
-- unterminated one would be injected as a whole, contain itself and nest
-- without end.
local function capture_node(match, id)
  local node = match[id]
  if type(node) == "table" then
    node = node[#node]
  end
  return node
end

vim.treesitter.query.add_predicate("chez-eval-block?", function(match, _, source, pred)
  local node = capture_node(match, pred[2])
  return node ~= nil and require("chez.evalblock").code_range(node, source) ~= nil
end, { force = true })

vim.treesitter.query.add_directive("chez-eval-block!", function(match, _, source, pred, metadata)
  local id = pred[2]
  local node = capture_node(match, id)
  if not node then
    return
  end
  local range = require("chez.evalblock").code_range(node, source)
  if range then
    metadata[id] = metadata[id] or {}
    metadata[id].range = range
  end
end, { force = true })

require("chez.highlights").setup()

local group = vim.api.nvim_create_augroup("chez.nvim", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = function()
    require("chez.highlights").setup()
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    if package.loaded["chez.repl"] then
      require("chez.repl").stop_all()
    end
  end,
})

vim.api.nvim_create_user_command("Chez", function(args)
  require("chez.commands").run(args)
end, {
  nargs = "+",
  range = true,
  desc = "chez.nvim",
  complete = function(arglead, cmdline)
    return require("chez.commands").complete(arglead, cmdline)
  end,
})
