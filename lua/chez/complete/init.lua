-- Completion candidates: (chezscheme) builtins, definitions and local
-- bindings in the buffer, and top-level bindings of the running REPL.
local doc = require("chez.doc")

local M = {}

---@class chez.Candidate
---@field name string
---@field kind string   procedure | syntax | variable | record | local
---@field source string builtin | buffer | local | repl
---@field sig? string

local DELIM = "[%s%(%)%[%]\"';`,]"

---Scheme identifier prefix ending at byte column `col` (0-based, exclusive).
---@return string prefix, integer start_col
function M.prefix(line, col)
  local s = col
  while s > 0 and not line:sub(s, s):match(DELIM) do
    s = s - 1
  end
  local p = line:sub(s + 1, col)
  -- ,@id: the delimiter scan stops at "," and leaves "@"
  if p:sub(1, 1) == "@" then
    return p:sub(2), s + 1
  end
  return p, s
end

-- binding forms whose bindings are visible inside them
local LET = {
  ["let"] = true, ["let*"] = true, ["letrec"] = true, ["letrec*"] = true,
  ["let-values"] = true, ["let*-values"] = true, ["fluid-let"] = true,
  ["let-syntax"] = true, ["letrec-syntax"] = true,
  ["trace-let"] = true, ["do"] = true, ["with-syntax"] = true,
}

local function named(node)
  local out = {}
  for c in node:iter_children() do
    if c:named() and not require("chez.ts").is_comment(c) then
      out[#out + 1] = c
    end
  end
  return out
end

local function symbols_in(node, buf, acc)
  if node:type() == "symbol" then
    acc[#acc + 1] = vim.treesitter.get_node_text(node, buf)
  elseif node:type() == "list" then
    for _, c in ipairs(named(node)) do
      symbols_in(c, buf, acc)
    end
  end
  return acc
end

---Names bound by forms enclosing (row, col): lambda parameters, let/do
---bindings, named-let names, define parameters.
---@return string[]
function M.locals(buf, row, col)
  local ts = require("chez.ts")
  local root = ts.root(buf)
  if not root then
    return {}
  end
  local node = root:named_descendant_for_range(row, col, row, col)
  local names = {}
  while node do
    if node:type() == "list" then
      local kids = named(node)
      local head = kids[1] and kids[1]:type() == "symbol" and vim.treesitter.get_node_text(kids[1], buf)
      if head == "lambda" or head == "λ" or head == "trace-lambda" then
        local formals = head == "trace-lambda" and kids[3] or kids[2]
        if formals then
          symbols_in(formals, buf, names)
        end
      elseif head == "define" and kids[2] and kids[2]:type() == "list" then
        -- parameters only; the procedure name is a definition
        local formals = named(kids[2])
        for k = 2, #formals do
          symbols_in(formals[k], buf, names)
        end
      elseif head and LET[head] then
        local i = 2
        if kids[2] and kids[2]:type() == "symbol" then -- named let
          names[#names + 1] = vim.treesitter.get_node_text(kids[2], buf)
          i = 3
        end
        local bindings = kids[i]
        if bindings and bindings:type() == "list" then
          for _, b in ipairs(named(bindings)) do
            if b:type() == "list" then
              local first = named(b)[1]
              if first then
                symbols_in(first, buf, names)
              end
            end
          end
        end
      elseif head == nil and node:parent() and node:parent():type() == "list" then
        -- case-lambda clause: ((formals ...) body ...)
        local p = node:parent()
        local pk = named(p)
        local ph = pk[1] and pk[1]:type() == "symbol" and vim.treesitter.get_node_text(pk[1], buf)
        if ph == "case-lambda" and kids[1] then
          symbols_in(kids[1], buf, names)
        end
      end
    end
    node = node:parent()
  end
  return names
end

---All candidates for `buf` at (row, col); `repl_names` are names bound in the
---running REPL (may be nil).
---@return chez.Candidate[]
function M.candidates(buf, row, col, repl_names)
  local seen = {}
  local out = {}
  local function add(c)
    if not seen[c.name] then
      seen[c.name] = true
      out[#out + 1] = c
    end
  end
  for _, name in ipairs(M.locals(buf, row, col)) do
    add({ name = name, kind = "local", source = "local" })
  end
  for _, d in ipairs(doc.definitions(buf)) do
    add({ name = d.name, kind = d.kind, source = "buffer", sig = d.sig })
  end
  for _, b in ipairs(doc.builtin_list()) do
    add({ name = b.name, kind = b.kind, source = "builtin" })
  end
  for _, r in ipairs(repl_names or {}) do
    add({ name = r.name, kind = r.kind, source = "repl" })
  end
  return out
end

--------------------------------------------------------------------------------
-- REPL names (cached per session until the next evaluation)
--------------------------------------------------------------------------------

local repl_cache = setmetatable({}, { __mode = "k" })

---Names bound in the REPL that are not builtins. Calls `cb(names)`; uses the
---cache when it is fresh, otherwise asks the REPL (nil when not running).
function M.repl_names(buf, cb)
  local ok, repl = pcall(require, "chez.repl")
  local s = ok and repl.get(buf)
  if not s or not s:alive() then
    return cb(nil)
  end
  local c = repl_cache[s]
  if c and c.valid then
    return cb(c.names)
  end
  if not c then
    c = {}
    repl_cache[s] = c
    s:on("response", function(_, req)
      if req and (req.op == "eval" or req.op == "load") then
        c.valid = false
      end
    end)
  end
  s:request("complete", { prefix = "", limit = 100000 }, function(resp)
    local builtins = doc.builtins()
    local names = {}
    for _, cand in ipairs(resp.candidates or {}) do
      if not builtins[cand.name] then
        names[#names + 1] = cand
      end
    end
    c.names, c.valid = names, resp.ok
    cb(names)
  end)
end

--------------------------------------------------------------------------------
-- omnifunc
--------------------------------------------------------------------------------

local omni_start

---'omnifunc' implementation (synchronous; uses cached REPL names only).
function M.omnifunc(findstart, base)
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  if findstart == 1 then
    local _, start = M.prefix(vim.api.nvim_get_current_line(), pos[2])
    omni_start = start
    return start
  end
  local repl_names
  M.repl_names(buf, function(names)
    repl_names = names
  end)
  local items = {}
  for _, c in ipairs(M.candidates(buf, pos[1] - 1, omni_start or pos[2], repl_names)) do
    if vim.startswith(c.name, base) then
      items[#items + 1] = { word = c.name, kind = c.kind:sub(1, 1), menu = "[" .. c.source .. "]", info = c.sig or "" }
    end
  end
  table.sort(items, function(a, b)
    return a.word < b.word
  end)
  return items
end

return M
