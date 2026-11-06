-- Macro expansion, go to definition and tracing.
local util = require("chez.util")
local ts = require("chez.ts")
local doc = require("chez.doc")

local M = {}

--------------------------------------------------------------------------------
-- macro expansion
--------------------------------------------------------------------------------

---Expand the form at the cursor and show the result in a float.
---@param optimize? boolean use expand/optimize (shows the cp0 output)
function M.expand(optimize)
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local node = ts.current_form(buf, pos[1] - 1, pos[2])
  if not node then
    util.notify("no form at cursor", vim.log.levels.WARN)
    return
  end
  local code = vim.treesitter.get_node_text(node, buf)
  local s = require("chez.repl").ensure(buf)
  if not s then
    return
  end
  s:request("expand", { code = code, optimize = optimize or false }, function(resp)
    local lines
    if resp.ok then
      lines = {}
      for _, e in ipairs(resp.expansions or {}) do
        vim.list_extend(lines, vim.split(vim.trim(e), "\n", { plain = true }))
      end
    else
      lines = vim.split("; " .. ((resp.error or {}).message or "error"), "\n", { plain = true })
    end
    local title = optimize and " expand/optimize " or " expand "
    local fbuf, fwin = vim.lsp.util.open_floating_preview(lines, "scheme", {
      border = "rounded", max_width = 100, max_height = 40, focus_id = "chez-expand", title = title,
    })
    pcall(vim.treesitter.start, fbuf, "scheme")
    vim.wo[fwin].wrap = false
  end)
end

--------------------------------------------------------------------------------
-- go to definition
--------------------------------------------------------------------------------

local function jump(file, row, col)
  vim.cmd("normal! m'")
  local cur = vim.fs.normalize(vim.api.nvim_buf_get_name(0))
  if file and vim.fs.normalize(file) ~= cur then
    vim.cmd.edit(vim.fn.fnameescape(file))
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, col })
  vim.cmd("normal! zv")
end

local function rg_escape(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?{}|\\]", "\\%0"))
end

---Search the project for definitions of `name` with ripgrep.
local function project_search(buf, name)
  if vim.fn.executable("rg") == 0 then
    return {}
  end
  local root = require("chez.repl").root_for(buf)
  local pat = "\\((define[a-z\\-]*|trace-define|define-record-type)\\s+[\\(\\[]?\\s*" .. rg_escape(name) .. "([\\s\\)\\]]|$)"
  local res = vim.system({
    "rg", "--vimgrep", "--no-messages", "-g", "*.{ss,sls,sps,scm,sch,sld}", "-e", pat, root,
  }, { text = true }):wait()
  local items = {}
  for _, l in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
    local file, lnum, col, text = l:match("^(.-):(%d+):(%d+):(.*)$")
    if file then
      items[#items + 1] = { filename = file, lnum = tonumber(lnum), col = tonumber(col), text = vim.trim(text) }
    end
  end
  return items
end

---Go to the definition of the identifier under the cursor: buffer
---definitions, then the REPL (source location of procedures), then a
---project-wide search.
function M.definition()
  local buf = vim.api.nvim_get_current_buf()
  local name = doc.symbol_at_cursor()
  if not name then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local def = doc.find_definition(buf, name, row)
  if def then
    jump(nil, def.row, def.col)
    return
  end
  local function fallback()
    local items = project_search(buf, name)
    if #items == 1 then
      jump(items[1].filename, items[1].lnum - 1, items[1].col - 1)
    elseif #items > 1 then
      vim.fn.setqflist({}, " ", { title = "definitions of " .. name, items = items })
      vim.cmd("copen")
    elseif doc.builtins()[name] then
      util.notify(name .. " is a Chez Scheme builtin (" .. (doc.signature(buf, name) or name) .. ")")
    else
      util.notify("no definition found for " .. name, vim.log.levels.WARN)
    end
  end
  local s = require("chez.repl").get(buf)
  if s and s:alive() and not doc.builtins()[name] then
    s:request("describe", { name = name }, function(resp)
      local loc = resp.ok and resp.location and util.resolve_location(resp.location)
      if loc and vim.uv.fs_stat(loc.file) then
        jump(loc.file, loc.row, loc.col)
      else
        fallback()
      end
    end)
  else
    fallback()
  end
end

--------------------------------------------------------------------------------
-- tracing
--------------------------------------------------------------------------------

local traced = setmetatable({}, { __mode = "k" })

---Toggle `trace` for the procedure under the cursor.
function M.trace()
  local buf = vim.api.nvim_get_current_buf()
  local name = doc.symbol_at_cursor()
  if not name then
    return
  end
  local s = require("chez.repl").ensure(buf)
  if not s then
    return
  end
  if not traced[s] then
    traced[s] = {}
    s:on("exit", function()
      traced[s] = {}
    end)
  end
  local on = not traced[s][name]
  local code = ("(%s %s)"):format(on and "trace" or "untrace", name)
  s:request("eval", { code = code }, function(resp)
    if resp.ok then
      traced[s][name] = on or nil
      util.notify((on and "tracing " or "untraced ") .. name)
    else
      util.notify(((resp.error or {}).message or "error"), vim.log.levels.ERROR)
    end
  end)
end

return M
