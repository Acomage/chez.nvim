-- A Chez Scheme process running the chez.nvim bridge (scheme/server.ss).
local config = require("chez.config")
local util = require("chez.util")

local RS = "\30" -- record separator: start of a protocol message

---@class chez.Request
---@field op string
---@field cb? fun(resp: table)
---@field ctx? table

---@class chez.Session
---@field root string
---@field proc? vim.SystemObj
---@field pid? integer
---@field ready boolean
---@field info? table           payload of the "ready" event
---@field pending table<integer, chez.Request>
---@field listeners table<string, function[]>
local Session = {}
Session.__index = Session

---@param root string
---@return chez.Session
function Session.new(root)
  local self = setmetatable({}, Session)
  self.root = root
  self.ready = false
  self.pending = {}
  self.listeners = {}
  self.next_id = 0
  self.partial = ""
  self.queue = {} -- requests sent before "ready" are buffered by the pipe anyway
  return self
end

---Subscribe to session events: "ready", "out" (stream, text, request?),
---"input" (request?), "exit" (code, signal), "raw" (text).
function Session:on(event, fn)
  self.listeners[event] = self.listeners[event] or {}
  table.insert(self.listeners[event], fn)
end

function Session:emit(event, ...)
  for _, fn in ipairs(self.listeners[event] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then
      util.notify("listener error (" .. event .. "): " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

function Session:alive()
  return self.proc ~= nil
end

function Session:busy()
  return next(self.pending) ~= nil
end

---@return boolean ok, string? err
function Session:start()
  if self.proc then
    return true
  end
  local cfg = config.repl
  local cmd = util.chez_script("server.ss")
  self.ready = false
  self.partial = ""
  local ok, proc = pcall(vim.system, cmd, {
    cwd = self.root,
    stdin = true,
    text = true,
    stdout = function(_, data)
      self:_on_stdout(data)
    end,
    stderr = function(_, data)
      if data then
        vim.schedule(function()
          self:emit("raw", data)
        end)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      self:_on_exit(obj.code, obj.signal)
    end)
  end)
  if not ok then
    return false, tostring(proc)
  end
  self.proc = proc
  self.pid = proc.pid
  -- configure the session before anything else
  self:request("set", {
    libdirs = util.project_libdirs(self.root),
    cwd = self.root,
    print_length = cfg.print_length,
    print_level = cfg.print_level,
  })
  return true
end

function Session:_on_stdout(data)
  if not data then
    return
  end
  local text = self.partial .. data
  local lines = vim.split(text, "\n", { plain = true })
  self.partial = table.remove(lines)
  if #lines == 0 then
    return
  end
  vim.schedule(function()
    for _, line in ipairs(lines) do
      self:_on_line(line)
    end
  end)
end

function Session:_on_line(line)
  local i = line:find(RS, 1, true)
  if not i then
    self:emit("raw", line .. "\n")
    return
  end
  if i > 1 then
    self:emit("raw", line:sub(1, i - 1))
  end
  local ok, msg = pcall(vim.json.decode, line:sub(i + 1), { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= "table" then
    self:emit("raw", line:sub(i + 1) .. "\n")
    return
  end
  self:_dispatch(msg)
end

function Session:_dispatch(msg)
  if msg.event == "ready" then
    self.ready = true
    self.info = msg
    self:emit("ready", msg)
  elseif msg.event == "out" then
    self:emit("out", msg.stream, msg.text or "", msg.id and self.pending[msg.id])
  elseif msg.event == "input" then
    self:emit("input", msg.id and self.pending[msg.id])
  elseif msg.event == "protocol-error" then
    util.notify("protocol error: " .. tostring(msg.message), vim.log.levels.ERROR)
  elseif msg.id then
    local req = self.pending[msg.id]
    self.pending[msg.id] = nil
    if req and req.cb then
      req.cb(msg, req)
    end
    self:emit("response", msg, req)
  end
end

function Session:_on_exit(code, signal)
  if not self.proc then
    return
  end
  self.proc = nil
  self.pid = nil
  self.ready = false
  local pending = self.pending
  self.pending = {}
  for _, req in pairs(pending) do
    if req.cb then
      req.cb({ ok = false, error = { message = "REPL process exited", kind = "exit" } }, req)
    end
  end
  self:emit("exit", code, signal)
end

---Send a request. `cb(resp, req)` runs on the main loop.
---@param op string
---@param params? table
---@param cb? fun(resp: table, req: chez.Request)
---@param ctx? table   arbitrary data attached to the request (see events)
---@return integer? id
function Session:request(op, params, cb, ctx)
  if not self.proc then
    if cb then
      cb({ ok = false, error = { message = "REPL is not running", kind = "client" } }, { op = op, ctx = ctx })
    end
    return nil
  end
  self.next_id = self.next_id + 1
  local id = self.next_id
  local msg = vim.tbl_extend("force", params or {}, { id = id, op = op })
  self.pending[id] = { op = op, cb = cb, ctx = ctx, id = id }
  self.proc:write(vim.json.encode(msg) .. "\n")
  return id
end

---Reply to an input request from user code; nil sends end-of-file.
---@param text? string
function Session:send_input(text)
  if not self.proc then
    return
  end
  local msg = text and { op = "input", text = text } or { op = "input", eof = true }
  self.proc:write(vim.json.encode(msg) .. "\n")
end

---Interrupt the running evaluation (SIGINT).
function Session:interrupt()
  if self.proc then
    self.proc:kill("sigint")
  end
end

---Stop the process. Closing stdin lets the server exit cleanly; it is
---killed if it is still running after a short delay (e.g. stuck in a loop).
function Session:stop()
  local proc = self.proc
  if not proc then
    return
  end
  pcall(proc.write, proc, nil)
  vim.defer_fn(function()
    if self.proc == proc then
      proc:kill("sigkill")
    end
  end, 500)
end

return Session
