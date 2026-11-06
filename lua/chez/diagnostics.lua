-- Diagnostics from scheme/check.ss: the buffer is read and expanded by a
-- separate Chez process (top-level code is not run).
local config = require("chez.config")
local util = require("chez.util")

local M = {}

local ns = vim.api.nvim_create_namespace("chez.check")
local running = {} ---@type table<integer, { proc: vim.SystemObj }>

local function clean_message(msg)
  msg = msg:gsub("^Exception in ([^:]+): ", "%1: "):gsub("^Exception: ", "")
  msg = msg:gsub(" at line %d+, char %d+ of .-$", ""):gsub(" at char %d+ of .-$", "")
  return msg
end

local function quoted(node)
  local p = node:parent()
  while p do
    local t = p:type()
    if t == "unquote" or t == "unquote_splicing" then
      return false
    end
    if t == "quote" or t == "quasiquote" or t == "syntax_quote" or t == "quasisyntax" then
      return true
    end
    p = p:parent()
  end
  return false
end

---Positions of the identifier `name` used as code in `buf`.
local function occurrences(buf, name)
  local root = require("chez.ts").root(buf)
  if not root then
    return {}
  end
  local q = vim.treesitter.query.parse("scheme", "((symbol) @s)")
  local out = {}
  for _, node in q:iter_captures(root, buf) do
    if vim.treesitter.get_node_text(node, buf) == name and not quoted(node) then
      local sr, sc, er, ec = node:range()
      out[#out + 1] = { sr, sc, er, ec }
    end
  end
  return out
end

---Convert the checker output into vim.diagnostic items.
---@param buf integer
---@param name string file name given to the checker
---@param result table
---@param lines string[] buffer lines the check ran on
function M.to_diagnostics(buf, name, result, lines)
  local items = {}
  for _, d in ipairs(result.diagnostics or {}) do
    local severity = d.severity == "error" and vim.diagnostic.severity.ERROR or vim.diagnostic.severity.WARN
    if d.name then
      for _, r in ipairs(occurrences(buf, d.name)) do
        items[#items + 1] = {
          lnum = r[1], col = r[2], end_lnum = r[3], end_col = r[4],
          severity = severity, source = "chez", message = clean_message(d.message),
        }
      end
    else
      local row, col = 0, 0
      local loc = util.location_from_message(d.message or "")
      if loc and (loc.file == name or vim.fs.normalize(loc.file) == name) then
        if loc.line then
          row = loc.line - 1
          local text = lines[loc.line] or ""
          col = vim.str_byteindex(text, "utf-32", math.min((loc.col or 1) - 1, util.strchars(text)), false)
        else
          row, col = util.offset_to_pos(lines, loc.pos)
        end
      elseif d.pos then
        row, col = util.offset_to_pos(lines, d.pos)
      end
      items[#items + 1] = {
        lnum = row, col = col, severity = severity, source = "chez", message = clean_message(d.message or "error"),
      }
    end
  end
  return items
end

---Check `buf` now.
---@param buf? integer
function M.check(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if running[buf] then
    pcall(running[buf].proc.kill, running[buf].proc, "sigkill")
  end
  local job = {}
  running[buf] = job
  local name = vim.api.nvim_buf_get_name(buf)
  name = name ~= "" and vim.fs.normalize(name) or ("buffer-" .. buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local root = require("chez.repl").root_for(buf)
  local scheme_dir = util.plugin_root .. "/scheme"
  local cmd = vim.deepcopy(config.repl.cmd)
  vim.list_extend(cmd, { "--libdirs", scheme_dir, "--script", scheme_dir .. "/check.ss", name })
  for _, d in ipairs(config.repl.libdirs) do
    local path = vim.fs.normalize(vim.fs.joinpath(root, d))
    if vim.fn.isdirectory(path) == 1 then
      cmd[#cmd + 1] = path
    end
  end
  local ok, proc = pcall(vim.system, cmd, {
    cwd = root,
    stdin = table.concat(lines, "\n") .. "\n",
    text = true,
    timeout = config.diagnostics.timeout,
  }, function(obj)
    vim.schedule(function()
      if running[buf] ~= job then
        return -- superseded by a newer check
      end
      running[buf] = nil
      if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
        return -- stale
      end
      local line = (obj.stdout or ""):match("[^\n]*{.*}")
      local okj, result = pcall(vim.json.decode, line or "", { luanil = { object = true, array = true } })
      if not okj or type(result) ~= "table" then
        if obj.code ~= 0 and obj.signal ~= 9 then
          util.notify("check failed: " .. vim.trim(obj.stderr or ""), vim.log.levels.DEBUG)
        end
        return
      end
      vim.diagnostic.set(ns, buf, M.to_diagnostics(buf, name, result, lines))
    end)
  end)
  if ok then
    job.proc = proc
  else
    running[buf] = nil
  end
end

---Enable automatic checks for `buf`.
---@param buf integer
function M.attach(buf)
  local cfg = config.diagnostics
  if not cfg.enabled then
    return
  end
  local group = vim.api.nvim_create_augroup("chez.diagnostics." .. buf, { clear = true })
  local timer = assert(vim.uv.new_timer())
  vim.api.nvim_create_autocmd(cfg.events, {
    group = group,
    buffer = buf,
    callback = function(ev)
      timer:stop()
      if ev.event == "BufWritePost" or (cfg.debounce or 0) <= 0 then
        M.check(buf)
        return
      end
      timer:start(cfg.debounce, 0, vim.schedule_wrap(function()
        -- wait until Insert mode is left
        if vim.api.nvim_buf_is_valid(buf) and vim.fn.mode():sub(1, 1) ~= "i" then
          M.check(buf)
        end
      end))
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      vim.diagnostic.reset(ns, buf)
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  if cfg.on_attach then
    M.check(buf)
  end
end

M.namespace = ns

return M
