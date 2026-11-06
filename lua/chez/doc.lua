-- Documentation and signatures: static data for (chezscheme) generated from
-- the Chez Scheme User's Guide and the R6RS report (data/*.json), live
-- information from the REPL, and definitions found in the buffer.
local util = require("chez.util")

local M = {}

local cache = {}

local function load_json(name)
  if cache[name] == nil then
    local path = util.plugin_root .. "/data/" .. name
    local ok, data = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    cache[name] = ok and data or false
  end
  return cache[name] or nil
end

---@class chez.Builtin
---@field name string
---@field kind "procedure"|"syntax"|"variable"
---@field arity? integer
---@field rnrs boolean

---Identifiers exported by (chezscheme), by name.
---@return table<string, chez.Builtin>
function M.builtins()
  if not cache.builtins_by_name then
    local data = load_json("builtins.json")
    local by_name = {}
    for _, s in ipairs(data and data.symbols or {}) do
      by_name[s.name] = s
    end
    cache.builtins_by_name = by_name
    cache.builtins_list = data and data.symbols or {}
  end
  return cache.builtins_by_name
end

---@return chez.Builtin[]
function M.builtin_list()
  M.builtins()
  return cache.builtins_list
end

---@class chez.DocEntry
---@field kind string
---@field sigs string[]
---@field returns? string
---@field doc string
---@field source "CSUG"|"R6RS"
---@field url? string

---@param name string
---@return chez.DocEntry?
function M.entry(name)
  local docs = load_json("docs.json")
  return docs and docs[name]
end

---Human readable arity from a Chez procedure-arity-mask.
---@param mask integer
---@return string
function M.arity_string(mask)
  if not mask then
    return "?"
  end
  -- bit k set: accepts k arguments; a negative mask has all high bits set
  local counts = {}
  for k = 0, 31 do
    if mask < 0 and bit.arshift(mask, k) == -1 then
      counts[#counts + 1] = k .. "+"
      break
    end
    if bit.band(bit.rshift(mask, k), 1) == 1 then
      counts[#counts + 1] = tostring(k)
    end
  end
  if #counts == 0 then
    return "none"
  end
  return table.concat(counts, ", ")
end

--------------------------------------------------------------------------------
-- definitions in a buffer
--------------------------------------------------------------------------------

local DEFINERS = {
  ["define"] = true, ["define-syntax"] = true, ["define-record-type"] = true,
  ["define-values"] = true, ["define-integrable"] = true, ["define-inline"] = true,
  ["trace-define"] = true, ["trace-define-syntax"] = true, ["define-structure"] = true,
  ["define-enumeration"] = true, ["define-condition-type"] = true, ["define-ftype"] = true,
  ["define-property"] = true, ["define-top-level-syntax"] = true, ["define-record"] = true,
}

---@class chez.Definition
---@field name string
---@field kind string   "procedure" | "syntax" | "variable" | "record" | ...
---@field node TSNode   the defining form
---@field sig? string   e.g. "(f x y)" for procedures
---@field row integer
---@field col integer

local function text(node, buf)
  return vim.treesitter.get_node_text(node, buf)
end

local function children(node)
  local out = {}
  for c in node:iter_children() do
    if c:named() and not require("chez.ts").is_comment(c) then
      out[#out + 1] = c
    end
  end
  return out
end

local function record_names(buf, form, kids, defs)
  local spec = kids[2]
  local tname, cname, pname
  if spec:type() == "symbol" then
    tname = text(spec, buf)
    cname, pname = "make-" .. tname, tname .. "?"
  elseif spec:type() == "list" then
    local sk = children(spec)
    tname = sk[1] and text(sk[1], buf)
    cname = sk[2] and text(sk[2], buf)
    pname = sk[3] and text(sk[3], buf)
  end
  if not tname then
    return
  end
  local r, c = spec:range()
  defs[#defs + 1] = { name = tname, kind = "record", node = form, row = r, col = c }
  local fields = {}
  for i = 3, #kids do
    local clause = kids[i]
    local ck = clause:type() == "list" and children(clause) or {}
    if ck[1] and text(ck[1], buf) == "fields" then
      for j = 2, #ck do
        local f = ck[j]
        if f:type() == "symbol" then
          fields[#fields + 1] = { name = text(f, buf), mutable = false }
        elseif f:type() == "list" then
          local fk = children(f)
          local mode = fk[1] and text(fk[1], buf)
          local fname = fk[2] and text(fk[2], buf)
          if fname then
            fields[#fields + 1] = {
              name = fname,
              mutable = mode == "mutable",
              accessor = fk[3] and text(fk[3], buf),
              mutator = fk[4] and text(fk[4], buf),
            }
          end
        end
      end
    end
  end
  if cname then
    local args = vim.tbl_map(function(f)
      return f.name
    end, fields)
    defs[#defs + 1] = {
      name = cname, kind = "procedure", node = form, row = r, col = c,
      sig = "(" .. cname .. (#args > 0 and (" " .. table.concat(args, " ")) or "") .. ")",
    }
  end
  if pname then
    defs[#defs + 1] = { name = pname, kind = "procedure", node = form, row = r, col = c, sig = "(" .. pname .. " obj)" }
  end
  for _, f in ipairs(fields) do
    local acc = f.accessor or (tname .. "-" .. f.name)
    defs[#defs + 1] = { name = acc, kind = "procedure", node = form, row = r, col = c, sig = "(" .. acc .. " " .. tname .. ")" }
    if f.mutable then
      local mut = f.mutator or (tname .. "-" .. f.name .. "-set!")
      defs[#defs + 1] = {
        name = mut, kind = "procedure", node = form, row = r, col = c,
        sig = "(" .. mut .. " " .. tname .. " " .. f.name .. ")",
      }
    end
  end
end

---All definitions in `buf` (at any depth).
---@param buf integer
---@return chez.Definition[]
function M.definitions(buf)
  local ts = require("chez.ts")
  local root = ts.root(buf)
  if not root then
    return {}
  end
  local defs = {}
  local function visit(node)
    if node:type() == "list" then
      local kids = children(node)
      local head = kids[1]
      local h = head and head:type() == "symbol" and text(head, buf)
      if h and DEFINERS[h] and kids[2] then
        local target = kids[2]
        if h == "define-record-type" then
          record_names(buf, node, kids, defs)
        elseif target:type() == "symbol" then
          local r, c = target:range()
          local kind = h:find("syntax") and "syntax" or "variable"
          local sig
          -- (define f (lambda (x y) ...)) / (case-lambda ...)
          local val = kids[3]
          if kind == "variable" and val and val:type() == "list" then
            local vk = children(val)
            local vh = vk[1] and vk[1]:type() == "symbol" and text(vk[1], buf)
            if (vh == "lambda" or vh == "λ") and vk[2] then
              kind = "procedure"
              local formals = text(vk[2], buf)
              if vk[2]:type() == "list" then
                formals = formals:sub(2, -2)
              else
                formals = ". " .. formals
              end
              sig = "(" .. text(target, buf) .. (formals ~= "" and (" " .. formals) or "") .. ")"
            elseif vh == "case-lambda" then
              kind = "procedure"
            end
          end
          defs[#defs + 1] = { name = text(target, buf), kind = kind, node = node, row = r, col = c, sig = sig }
        elseif target:type() == "list" then
          -- (define (f . args) ...), curried (define ((f a) b) ...)
          local inner = target
          while inner:type() == "list" and children(inner)[1] and children(inner)[1]:type() == "list" do
            inner = children(inner)[1]
          end
          local name = children(inner)[1]
          if name and name:type() == "symbol" then
            local r, c = name:range()
            local sig = text(target, buf):gsub("%s+", " ")
            defs[#defs + 1] = { name = text(name, buf), kind = "procedure", node = node, row = r, col = c, sig = sig }
          end
          if h == "define-values" then
            for _, k in ipairs(children(target)) do
              if k:type() == "symbol" then
                local r, c = k:range()
                defs[#defs + 1] = { name = text(k, buf), kind = "variable", node = node, row = r, col = c }
              end
            end
          end
        end
      end
    end
    for child in node:iter_children() do
      if child:named() then
        visit(child)
      end
    end
  end
  visit(root)
  return defs
end

---Comment lines directly above `row` (;; doc comments).
local function leading_comment(buf, row)
  local lines = {}
  local r = row - 1
  while r >= 0 do
    local l = vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1]
    local c = l and l:match("^%s*;+%s?(.*)$")
    if not c then
      break
    end
    table.insert(lines, 1, c)
    r = r - 1
  end
  return lines
end

--------------------------------------------------------------------------------
-- markdown rendering
--------------------------------------------------------------------------------

---Markdown lines for a static (chezscheme) identifier.
---@param name string
---@return string[]?
function M.builtin_markdown(name)
  local b = M.builtins()[name]
  local e = M.entry(name)
  if not b and not e then
    return nil
  end
  local lines = {}
  local sigs = e and e.sigs or {}
  if #sigs == 0 then
    sigs = { name }
  end
  lines[#lines + 1] = "```scheme"
  vim.list_extend(lines, sigs)
  lines[#lines + 1] = "```"
  local meta = {}
  meta[#meta + 1] = "*" .. ((e and e.kind) or (b and b.kind) or "?") .. "*"
  if b and b.arity then
    meta[#meta + 1] = "arity " .. M.arity_string(b.arity)
  end
  meta[#meta + 1] = (b and b.rnrs) and "R6RS" or "Chez Scheme"
  lines[#lines + 1] = table.concat(meta, " · ")
  if e and e.returns then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "**Returns:** " .. e.returns
  end
  if e and e.doc and e.doc ~= "" then
    lines[#lines + 1] = ""
    vim.list_extend(lines, vim.split(e.doc, "\n", { plain = true }))
  end
  if e then
    lines[#lines + 1] = ""
    if e.url then
      lines[#lines + 1] = ("[Chez Scheme User's Guide](%s)"):format(e.url)
    else
      lines[#lines + 1] = "*Source: Revised⁶ Report on Scheme*"
    end
  end
  return lines
end

---Markdown lines for a definition found in a buffer.
---@param buf integer
---@param def chez.Definition
function M.definition_markdown(buf, def)
  local lines = { "```scheme", def.sig or def.name, "```" }
  local where = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
  lines[#lines + 1] = ("*%s* · %s:%d"):format(def.kind, where ~= "" and where or "[buffer]", def.row + 1)
  local comment = leading_comment(buf, def.node:range())
  if #comment > 0 then
    lines[#lines + 1] = ""
    vim.list_extend(lines, comment)
  end
  return lines
end

---Find a definition of `name` in `buf`, preferring the one nearest above `row`.
---@return chez.Definition?
function M.find_definition(buf, name, row)
  local best
  for _, d in ipairs(M.definitions(buf)) do
    if d.name == name then
      if not best or (row and d.row <= row and (best.row > row or d.row > best.row)) then
        best = d
      end
    end
  end
  return best
end

--------------------------------------------------------------------------------
-- hover / signature
--------------------------------------------------------------------------------

---Identifier at the cursor (Scheme identifier characters).
---@return string?
function M.symbol_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local delim = "[%s%(%)%[%]\"';`,]"
  if col > #line or line:sub(col, col):match(delim) then
    return nil
  end
  local s, e = col, col
  while s > 1 and not line:sub(s - 1, s - 1):match(delim) do
    s = s - 1
  end
  while e < #line and not line:sub(e + 1, e + 1):match(delim) do
    e = e + 1
  end
  local sym = line:sub(s, e):gsub("^#", "")
  return sym ~= "" and sym or nil
end

local function float(lines)
  if not lines or #lines == 0 then
    return
  end
  vim.lsp.util.open_floating_preview(lines, "markdown", {
    border = "rounded", max_width = 90, max_height = 30, focus_id = "chez-doc",
  })
end

local function repl_markdown(name, info)
  local lines = { "```scheme", name, "```" }
  local meta = { "*" .. (info.kind or "?") .. "*" }
  if info.arity then
    meta[#meta + 1] = "arity " .. M.arity_string(info.arity)
  end
  meta[#meta + 1] = "REPL"
  lines[#lines + 1] = table.concat(meta, " · ")
  if info.value then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "```scheme"
    vim.list_extend(lines, vim.split(util.truncate(info.value, 400), "\n", { plain = true }))
    lines[#lines + 1] = "```"
  end
  local loc = info.location and util.resolve_location(info.location)
  if loc then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("defined at %s:%d"):format(vim.fn.fnamemodify(loc.file, ":~:."), loc.row + 1)
  end
  return lines
end

---Show documentation for the identifier under the cursor.
function M.hover()
  local buf = vim.api.nvim_get_current_buf()
  local name = M.symbol_at_cursor()
  if not name then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  -- buffer definitions shadow builtins
  local def = M.find_definition(buf, name, row)
  if def then
    float(M.definition_markdown(buf, def))
    return
  end
  local md = M.builtin_markdown(name)
  if md then
    float(md)
    return
  end
  local s = require("chez.repl").get(buf)
  if s and s:alive() then
    s:request("describe", { name = name }, function(resp)
      if resp.ok and resp.bound then
        float(repl_markdown(name, resp))
      else
        util.notify("no documentation for " .. name)
      end
    end)
    return
  end
  util.notify("no documentation for " .. name)
end

---Signature line for `name`, if known.
---@return string?
function M.signature(buf, name, row)
  local def = M.find_definition(buf, name, row)
  if def then
    return def.sig or def.name
  end
  local e = M.entry(name)
  if e and e.sigs and #e.sigs > 0 then
    return table.concat(e.sigs, "  |  ")
  end
  local b = M.builtins()[name]
  if b and b.arity then
    return ("(%s …)  arity %s"):format(name, M.arity_string(b.arity))
  end
end

---Show the signature of the procedure call surrounding the cursor.
function M.signature_help()
  local buf = vim.api.nvim_get_current_buf()
  local ts = require("chez.ts")
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  if col > 0 then
    col = col - 1
  end
  local form = ts.current_form(buf, row, col)
  while form and form:type() ~= "list" do
    form = form:parent()
  end
  local head = form and form:named_child(0)
  if not head or head:type() ~= "symbol" then
    return
  end
  local name = vim.treesitter.get_node_text(head, buf)
  local sig = M.signature(buf, name, row)
  if sig then
    vim.lsp.util.open_floating_preview({ "```scheme", sig, "```" }, "markdown", {
      border = "rounded", focus = false, focus_id = "chez-signature", close_events = { "CursorMoved", "InsertLeave", "BufLeave" },
    })
  end
end

---Open the online documentation of the identifier under the cursor.
function M.open_docs()
  local name = M.symbol_at_cursor()
  local e = name and M.entry(name)
  if e and e.url then
    vim.ui.open(e.url)
  elseif e then
    vim.ui.open("https://www.r6rs.org/final/html/r6rs/r6rs.html")
  else
    util.notify("no online documentation for " .. tostring(name))
  end
end

return M
