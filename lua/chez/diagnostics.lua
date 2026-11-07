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

local DELIM = "[%s()%[%]\"';`,]"

---Positions of the identifier `name` in the code of #eval blocks (which the
---tree-sitter tree only knows as comments).
---@param lines string[]
---@param blocks chez.EvalBlock[]
local function block_occurrences(lines, blocks, name)
  local out = {}
  for _, b in ipairs(blocks) do
    for row = b.trow, b.erow do
      local line = lines[row + 1] or ""
      local first = row == b.trow and b.tcol + 5 or 0
      local last = row == b.erow and b.ecol - 2 or #line
      local init = first + 1
      while true do
        local s, e = line:find(name, init, true)
        if not s or e > last then
          break
        end
        local before, after = line:sub(s - 1, s - 1), line:sub(e + 1, e + 1)
        local comment = line:sub(first + 1, s - 1):find(";", 1, true)
        if not comment and (before == "" or before:match(DELIM)) and (after == "" or after:match(DELIM)) then
          out[#out + 1] = { row, s - 1, row, e }
        end
        init = e + 1
      end
    end
  end
  return out
end

---Convert the checker output into vim.diagnostic items.
---@param buf integer
---@param name string file name given to the checker
---@param result table
---@param lines string[] buffer lines the check ran on
---@param blocks? chez.EvalBlock[] #eval blocks sent to the checker
function M.to_diagnostics(buf, name, result, lines, blocks)
  local items = {}
  local seen = {}
  local function add(item)
    local key = table.concat({ item.lnum, item.col, item.message }, ":")
    if not seen[key] then
      seen[key] = true
      items[#items + 1] = item
    end
  end
  for _, d in ipairs(result.diagnostics or {}) do
    local severity = d.severity == "error" and vim.diagnostic.severity.ERROR or vim.diagnostic.severity.WARN
    if d.name then
      local where = d.block and block_occurrences(lines, blocks or {}, d.name) or occurrences(buf, d.name)
      for _, r in ipairs(where) do
        add({
          lnum = r[1], col = r[2], end_lnum = r[3], end_col = r[4],
          severity = severity, source = "chez", message = clean_message(d.message),
        })
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
      add({
        lnum = row, col = col, severity = severity, source = "chez", message = clean_message(d.message or "error"),
      })
    end
  end
  return items
end

---Check `buf` now.
---@param buf? integer
function M.check(buf)
  buf = util.buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if running[buf] then
    pcall(running[buf].proc.kill, running[buf].proc, "sigkill")
  end
  local job = {}
  running[buf] = job
  local name = util.buf_file(buf) or ("buffer-" .. buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local root = require("chez.repl").root_for(buf)
  -- #eval blocks are checked as code: their delimiters are blanked (same
  -- length, so positions do not change) and their ranges passed along
  local source = lines
  local ok_b, blocks = pcall(require("chez.evalblock").find, buf)
  blocks = ok_b and blocks or {}
  local ranges = {}
  if #blocks > 0 then
    source = vim.deepcopy(lines)
    local function blank(row, col, n)
      local l = source[row + 1]
      source[row + 1] = l:sub(1, col) .. string.rep(" ", n) .. l:sub(col + n + 1)
    end
    for _, b in ipairs(blocks) do
      blank(b.srow, b.scol, 2)
      blank(b.trow, b.tcol, 5)
      blank(b.erow, b.ecol - 2, 2)
      ranges[#ranges + 1] = b.offset .. ":" .. b.end_offset
    end
  end
  local args = { name }
  if #ranges > 0 then
    args[#args + 1] = "--blocks=" .. table.concat(ranges, ",")
  end
  local cmd = util.chez_script("check.ss", vim.list_extend(args, util.project_libdirs(root)))
  local ok, proc = pcall(vim.system, cmd, {
    cwd = root,
    stdin = table.concat(source, "\n") .. "\n",
    text = true,
    timeout = config.diagnostics.timeout,
  }, function(obj)
    vim.schedule(function()
      if running[buf] ~= job then
        return -- superseded by a newer check
      end
      running[buf] = nil
      if not vim.api.nvim_buf_is_valid(buf) or not util.same_text(buf, tick, lines) then
        return -- stale: the next edit starts a new check
      end
      local line = (obj.stdout or ""):match("[^\n]*{.*}")
      local okj, result = pcall(vim.json.decode, line or "", { luanil = { object = true, array = true } })
      if not okj or type(result) ~= "table" then
        if obj.code ~= 0 and obj.signal ~= 9 then
          util.notify("check failed: " .. vim.trim(obj.stderr or ""), vim.log.levels.DEBUG)
        end
        return
      end
      vim.diagnostic.set(ns, buf, M.to_diagnostics(buf, name, result, lines, blocks))
    end)
  end)
  if ok then
    job.proc = proc
  else
    running[buf] = nil
  end
end

---Check the other loaded Chez buffers of `buf`'s project: after `buf` was
---written, libraries they import may have changed.
---@param buf integer
function M.check_dependents(buf)
  local repl = require("chez.repl")
  local root = repl.root_for(buf)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= buf and vim.api.nvim_buf_is_loaded(b) and vim.b[b].chez_attached and repl.root_for(b) == root then
      M.check(b)
    end
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
        if ev.event == "BufWritePost" then
          M.check_dependents(buf)
        end
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
