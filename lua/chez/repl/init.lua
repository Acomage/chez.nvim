-- REPL sessions: one Chez process per project root.
local config = require("chez.config")
local detect = require("chez.detect")
local util = require("chez.util")
local Session = require("chez.repl.session")
local ui = require("chez.repl.ui")

local M = {}

---@type table<string, chez.Session>
M.sessions = {}

---Project root used for `buf`.
---@param buf? integer
---@return string
function M.root_for(buf)
  buf = util.buf(buf)
  local root = vim.b[buf].chez_root
  if root then
    return root
  end
  local file = util.buf_file(buf)
  if file then
    root = detect.root(file) or vim.fs.dirname(file)
  end
  return root or vim.fn.getcwd()
end

---Existing session for `buf` (running or not).
---@param buf? integer
---@return chez.Session?
function M.get(buf)
  return M.sessions[M.root_for(buf)]
end

---Start `s` (if needed) and open its window per configuration.
---@param s chez.Session
---@return boolean ok, string? err
function M.start_session(s)
  if s:alive() then
    return true
  end
  local ok, err = s:start()
  if not ok then
    return false, "failed to start Chez Scheme (" .. table.concat(config.repl.cmd, " ") .. "): " .. tostring(err)
  end
  ui.banner(s)
  if config.repl.open_on_start then
    ui.open(s, false)
  end
  return true
end

---Running session for `buf`, starting one if necessary.
---@param buf? integer
---@return chez.Session?
function M.ensure(buf)
  local root = M.root_for(buf)
  local s = M.sessions[root]
  if not s then
    s = Session.new(root)
    M.sessions[root] = s
    ui.attach(s)
    s:on("exit", function()
      if s.restarting then
        s.restarting = false
        local ok, err = M.start_session(s)
        if not ok then
          util.notify(err, vim.log.levels.ERROR)
        end
      end
    end)
  end
  local ok, err = M.start_session(s)
  if not ok then
    util.notify(err, vim.log.levels.ERROR)
    return nil
  end
  return s
end

function M.restart(buf)
  local s = M.get(buf)
  if s and s:alive() then
    s.restarting = true
    s:stop()
  else
    M.ensure(buf)
  end
end

function M.stop(buf)
  local s = M.get(buf)
  if s and s:alive() then
    s:stop()
  end
end

function M.interrupt(buf)
  local s = M.get(buf)
  if s and s:alive() then
    s:interrupt()
  end
end

function M.toggle(buf)
  local s = M.get(buf) or M.ensure(buf)
  if s then
    ui.toggle(s)
  end
end

function M.focus(buf)
  local s = M.ensure(buf)
  if s then
    ui.open(s, true)
  end
end

function M.stop_all()
  for _, s in pairs(M.sessions) do
    if s.proc then
      pcall(s.proc.kill, s.proc, "sigkill")
    end
  end
end

---Short status string for statuslines: "" when no session for `buf`.
---@param buf? integer
function M.status(buf)
  local s = M.get(buf)
  if not s then
    return ""
  end
  if not s:alive() then
    return "chez ○"
  end
  return s:busy() and "chez ●" or "chez ◆"
end

return M
