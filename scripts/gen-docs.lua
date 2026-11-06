-- Build data/docs.json: signatures and short documentation for the
-- identifiers exported by (chezscheme).
--
--   nvim -l scripts/gen-docs.lua CSUG_DIR CSUG_HTML_DIR R6RS_DOC_DIR
--
--   CSUG_DIR       csug/ directory of https://github.com/cisco/ChezScheme
--                  (Chez Scheme Version 10 User's Guide, Apache-2.0)
--   CSUG_HTML_DIR  the corresponding pages of https://cisco.github.io/ChezScheme/csug/
--                  (only used to find per-entry anchors; may be empty)
--   R6RS_DOC_DIR   r6rs/document/ of https://www.r6rs.org/final/r6rs.tar.gz
--                  ("we grant permission to copy it in whole or in part
--                  without fee")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local csug_dir, html_dir, r6rs_dir = arg[1], arg[2], arg[3]
assert(csug_dir and r6rs_dir, "usage: nvim -l scripts/gen-docs.lua CSUG_DIR CSUG_HTML_DIR R6RS_DOC_DIR")

local CSUG_URL = "https://cisco.github.io/ChezScheme/csug/"
local MAX_DOC = 2500

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

--------------------------------------------------------------------------------
-- A small LaTeX -> Markdown converter (enough for CSUG and the R6RS report)
--------------------------------------------------------------------------------

-- read a balanced {...} group starting at s[i] == "{"; returns content, next index
local function group(s, i)
  local depth, j = 0, i
  while j <= #s do
    local c = s:sub(j, j)
    if c == "\\" then
      j = j + 1
    elseif c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then
        return s:sub(i + 1, j - 1), j + 1
      end
    end
    j = j + 1
  end
  return s:sub(i + 1), #s + 1
end

local function arg_at(s, i)
  while s:sub(i, i):match("[ \t]") do
    i = i + 1
  end
  if s:sub(i, i) == "{" then
    return group(s, i)
  end
  return s:sub(i, i), i + 1
end

local convert

local simple = {
  ev = " ⟹ ", lev = " ⟹ ", xev = " ⟹ error", schtrue = "#t", schfalse = "#f",
  unspecified = "unspecified", isunspecified = "is unspecified",
  dotsfoo = "...", ldots = "...", dots = "...", cdots = "...", sharpsign = "#",
  leq = "≤", geq = "≥", neq = "≠", pi = "π", log = "log", times = "×", infty = "∞",
  syntax = "\n\n**Syntax:** ", semantics = "\n\n**Semantics:** ",
  implresp = "\n\n*Implementation responsibilities:* ", item = "\n- ",
  exprtype = "syntax", vest = "", noindent = "", medskip = "", smallskip = "",
  bigskip = "", par = "\n\n", newline = "\n", listlibraries = "", endentryheader = "", ["break"] = "",
  entryheader = "", hfill = "", nobreak = "", label = "", ["/"] = "",
  lambdaexp = "lambda expression", categoryprocedure = "procedure",
  categorysyntax = "syntax", categorythreadparameter = "thread parameter",
  categoryglobalparameter = "global parameter", categorymodule = "module",
}
-- macros whose (single) argument is dropped
local drop1 = {
  index = true, mainindex = true, schindex = true, label = true, ref = true,
  pageref = true, cite = true, todo = true, hyphenation = true, protect = true,
  bibitem = true, foot = false,
}
local italic = { var = true, emph = true, em = true, textit = true, it = true, meta = false }

---@param s string
---@param code boolean inside code (no markdown markup)
function convert(s, code)
  local out = {}
  local i = 1
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "%" then
      local j = s:find("\n", i, true) or n + 1
      i = j + 1
    elseif c == "~" then
      out[#out + 1] = " "
      i = i + 1
    elseif c == "$" then
      local j = s:find("%$", i + 1) or n + 1
      out[#out + 1] = convert(s:sub(i + 1, j - 1), code)
      i = j + 1
    elseif c == "{" then
      local inner, j = group(s, i)
      -- font switches: {\cf ...} {\it ...} {\tt ...} {\em ...}
      local sw, rest = inner:match("^\\(%a+)%s*(.*)$")
      if sw == "cf" or sw == "tt" then
        local t = convert(rest, true)
        out[#out + 1] = code and t or ("`" .. t .. "`")
      elseif sw == "it" or sw == "em" or sw == "sl" then
        local t = convert(rest, code)
        out[#out + 1] = code and t or ("*" .. t .. "*")
      elseif sw == "rm" or sw == "bf" then
        out[#out + 1] = convert(rest, code)
      else
        out[#out + 1] = convert(inner, code)
      end
      i = j
    elseif c == "}" then
      i = i + 1
    elseif c == "\\" then
      local name = s:match("^%a+", i + 1)
      if not name then
        local ch = s:sub(i + 1, i + 1)
        if ch == "\\" then
          out[#out + 1] = "\n"
        elseif ch == " " then
          out[#out + 1] = " "
        elseif ch ~= "" and ch ~= "/" and ch ~= "," and ch ~= ";" and ch ~= "!" then
          out[#out + 1] = ch -- \# \& \% \_ \{ \} \$ \'
        end
        i = i + 2
      else
        i = i + 1 + #name
        if name == "begin" or name == "end" then
          local env
          env, i = arg_at(s, i)
          if env == "scheme" or env == "schemedisplay" then
            out[#out + 1] = name == "begin" and "\n```scheme\n" or "\n```\n"
          elseif env == "note" and name == "begin" then
            out[#out + 1] = "\n\n*Note:* "
          elseif env == "entry" and name == "begin" then
            -- header handled by the caller
            local _
            _, i = arg_at(s, i)
          end
        elseif name == "schemedisplay" then
          out[#out + 1] = "\n```scheme\n"
        elseif name == "endschemedisplay" then
          out[#out + 1] = "\n```\n"
        elseif simple[name] then
          out[#out + 1] = simple[name]
        elseif drop1[name] then
          local _
          _, i = arg_at(s, i)
        elseif name == "extref" then
          local _, t
          _, i = arg_at(s, i)
          t, i = arg_at(s, i)
          out[#out + 1] = convert(t, code)
        elseif name == "frac" then
          local a, b
          a, i = arg_at(s, i)
          b, i = arg_at(s, i)
          out[#out + 1] = convert(a, code) .. "/" .. convert(b, code)
        elseif name == "scheme" or name == "texttt" or name == "ide" or name == "cf" then
          local t
          t, i = arg_at(s, i)
          t = convert(t, true)
          out[#out + 1] = code and t or ("`" .. t .. "`")
        elseif italic[name] then
          local t
          t, i = arg_at(s, i)
          t = convert(t, code)
          out[#out + 1] = code and t or ("*" .. t .. "*")
        elseif name:match("^vari+$") or name == "varn" then
          local t
          t, i = arg_at(s, i)
          local sub = name == "varn" and "n" or tostring(#name - 3)
          t = convert(t, code) .. sub
          out[#out + 1] = code and t or ("*" .. t .. "*")
        elseif name == "hyper" or name == "meta" or name:match("^hyperi+$") then
          local t
          t, i = arg_at(s, i)
          local sub = name:match("^hyper(i+)$")
          out[#out + 1] = "<" .. convert(t, true) .. (sub and tostring(#sub) or "") .. ">"
        elseif name == "returns" then
          out[#out + 1] = "**Returns:** "
        elseif s:sub(i, i) == "{" then
          -- unknown macro with an argument: keep the argument
          local t
          t, i = group(s, i)
          out[#out + 1] = convert(t, code)
        end
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

-- Normalise whitespace outside code blocks and trim to a reasonable size.
local function tidy(md)
  local parts = {}
  local pos = 1
  while true do
    local a, b = md:find("\n```scheme\n.-\n```\n", pos)
    local text = md:sub(pos, (a or #md + 1) - 1)
    -- paragraphs: blank lines separate; single newlines are spaces
    text = text:gsub("[ \t]*\n[ \t]*\n%s*", "\0"):gsub("\n%- ", "\1"):gsub("%s+", " ")
    text = text:gsub("%z", "\n\n"):gsub("\1", "\n- ")
    parts[#parts + 1] = text
    if not a then
      break
    end
    local block = md:sub(a, b):gsub("^\n```scheme\n\n*", "```scheme\n"):gsub("\n*```\n$", "\n```")
    parts[#parts + 1] = "\n\n" .. block .. "\n\n"
    pos = b + 1
  end
  local out = table.concat(parts):gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
  if #out > MAX_DOC then
    -- cut at a paragraph boundary outside code blocks
    local cut = 0
    local inside = false
    local idx = 1
    for para in (out .. "\n\n"):gmatch("(.-)\n\n") do
      local fences = select(2, para:gsub("```", ""))
      if idx + #para > MAX_DOC and not inside and cut > 0 then
        break
      end
      if fences % 2 == 1 then
        inside = not inside
      end
      idx = idx + #para + 2
      if not inside then
        cut = idx - 3
      end
    end
    out = out:sub(1, math.max(cut, 1)):gsub("%s+$", "") .. "\n\n…"
  end
  return out
end

--------------------------------------------------------------------------------
-- CSUG
--------------------------------------------------------------------------------

local function html_anchors(chapter)
  local anchors = {}
  if not html_dir then
    return anchors
  end
  local ok, html = pcall(read, html_dir .. "/" .. chapter .. ".html")
  if not ok then
    return anchors
  end
  for anchor, body in html:gmatch('<a name="([^"]+)"></a><span class=formdef>(.-)</span>') do
    local tt = body:match("<tt>(.-)</tt>") or ""
    tt = tt:gsub("<[^>]+>", ""):gsub("&nbsp;", " "):gsub("&gt;", ">"):gsub("&lt;", "<"):gsub("&amp;", "&")
    local name = tt:match("^%(?([^%s()]+)")
    if name and not anchors[name] then
      anchors[name] = anchor
    end
  end
  return anchors
end

local docs = {}

local function add(name, entry)
  if not docs[name] then
    docs[name] = entry
  end
end

local function parse_csug(file)
  local chapter = vim.fn.fnamemodify(file, ":t:r")
  local anchors = html_anchors(chapter)
  local src = read(file)
  local pos = 1
  local count = 0
  while true do
    -- \entryheader or \noskipentryheader (but not \endentryheader)
    local a, b, prefix = src:find("\\(%a*)entryheader", pos)
    while a and prefix == "end" do
      a, b, prefix = src:find("\\(%a*)entryheader", b + 1)
    end
    if not a then
      break
    end
    local c, d = src:find("\\endentryheader", b, true)
    if not c then
      break
    end
    local header = src:sub(b + 1, c - 1)
    -- body: until the next separator / entry / section
    local stop = #src + 1
    for _, pat in ipairs({ "\n%%%-%-%-%-", "\\entryheader", "\\noskipentryheader", "\n\\x?section", "\n\\chapter" }) do
      local e = src:find(pat, d)
      if e and e < stop then
        stop = e
      end
    end
    local body = src:sub(d + 1, stop - 1)
    pos = d + 1
    local forms = {}
    local hpos = 1
    while true do
      local fa, fb = header:find("\\formdef", hpos, true)
      if not fa then
        break
      end
      local name, cat, sig
      local i = fb + 1
      name, i = arg_at(header, i)
      cat, i = arg_at(header, i)
      sig, i = arg_at(header, i)
      forms[#forms + 1] = { name = convert(name, true), kind = convert(cat, true), sig = vim.trim(convert(sig, true)) }
      hpos = i
    end
    local returns = header:match("\\returns%s+(.-)\n")
    local doc = tidy(convert(body, false))
    for _, f in ipairs(forms) do
      local sigs, kinds = {}, {}
      for _, g in ipairs(forms) do
        if g.name == f.name then
          sigs[#sigs + 1] = g.sig
          kinds[g.kind] = true
        end
      end
      local anchor = anchors[f.name]
      add(f.name, {
        kind = f.kind,
        sigs = sigs,
        returns = returns and vim.trim(convert(returns, false)) or nil,
        doc = doc,
        source = "CSUG",
        url = CSUG_URL .. chapter .. ".html" .. (anchor and ("#" .. anchor) or ""),
      })
      count = count + 1
    end
  end
  return count
end

--------------------------------------------------------------------------------
-- R6RS
--------------------------------------------------------------------------------

local function parse_r6rs(file)
  local src = read(file)
  local pos = 1
  local count = 0
  while true do
    local a, b = src:find("\\begin{entry}", pos, true)
    if not a then
      break
    end
    local header, i = group(src, b + 1)
    -- the body ends at \end{entry} or, as the report is not always
    -- balanced, at the next \begin{entry}
    local e = src:find("\\end{entry}", i, true) or #src
    local nb = src:find("\\begin{entry}", i, true)
    if nb and nb < e then
      e = nb
    end
    local body = src:sub(i, e - 1)
    pos = e
    local forms = {}
    local h = 1
    while true do
      local pa, pb, kind = header:find("\\(r?p?proto)", h)
      if not pa then
        break
      end
      local j = pb + 1
      if kind == "proto" or kind == "rproto" then
        local name, args, cat
        name, j = arg_at(header, j)
        args, j = arg_at(header, j)
        cat, j = arg_at(header, j)
        name = convert(name, true)
        forms[#forms + 1] = {
          name = name,
          sig = "(" .. name .. vim.trim(convert(args, true)):gsub("^(.)", " %1") .. ")",
          kind = convert(cat, true),
        }
      else -- pproto{(sig ...)}{cat}
        local sig, cat
        sig, j = arg_at(header, j)
        cat, j = arg_at(header, j)
        sig = vim.trim(convert(sig, true))
        local name = sig:match("^%(([^%s()]+)") or sig
        forms[#forms + 1] = { name = name, sig = sig, kind = convert(cat, true) }
      end
      h = j
    end
    local doc = tidy(convert(body, false))
    for _, f in ipairs(forms) do
      if not docs[f.name] then
        local sigs, seen = {}, {}
        for _, g in ipairs(forms) do
          if g.name == f.name and not seen[g.sig] then
            sigs[#sigs + 1] = g.sig
            seen[g.sig] = true
          end
        end
        add(f.name, { kind = f.kind, sigs = sigs, doc = doc, source = "R6RS" })
        count = count + 1
      end
    end
  end
  return count
end

--------------------------------------------------------------------------------

local csug_count = 0
for _, file in ipairs(vim.fn.glob(csug_dir .. "/*.stex", false, true)) do
  csug_count = csug_count + parse_csug(file)
end
local r6rs_count = 0
for _, file in ipairs(vim.fn.glob(r6rs_dir .. "/*.tex", false, true)) do
  r6rs_count = r6rs_count + parse_r6rs(file)
end

-- signatures the sources split in unusual ways
local fixes = {
  ["syntax-case"] = { "(syntax-case <expression> (<literal> ...) <syntax-case clause> ...)" },
}
for name, sigs in pairs(fixes) do
  if docs[name] then
    docs[name].sigs = sigs
  end
end
docs["do"] = docs["do"] or {
  kind = "syntax",
  sigs = { "(do ((<variable1> <init1> <step1>) ...) (<test> <expression> ...) <command> ...)" },
  doc = "The `do` expression is an iteration construct. It specifies a set of variables to be "
    .. "bound, how they are to be initialized at the start, and how they are to be updated on "
    .. "each iteration.\n\n```scheme\n(do ((vec (make-vector 5))\n     (i 0 (+ i 1)))\n    "
    .. "((= i 5) vec)\n  (vector-set! vec i i))  ⟹  #(0 1 2 3 4)\n```",
  source = "R6RS",
}
-- caar ... cddddr share one entry in the report
if docs.caar then
  for _, a in ipairs({ "a", "d" }) do
    for _, b in ipairs({ "a", "d" }) do
      for _, mid in ipairs({ "", "a", "d", "aa", "ad", "da", "dd" }) do
        local name = "c" .. a .. b .. mid .. "r"
        if not docs[name] then
          docs[name] = vim.deepcopy(docs.caar)
          docs[name].sigs = { "(" .. name .. " pair)" }
        end
      end
    end
  end
end

-- keep only identifiers that (chezscheme) actually exports
local builtins = vim.json.decode(read(root .. "/data/builtins.json"))
local out, missing = {}, 0
for _, s in ipairs(builtins.symbols) do
  if docs[s.name] then
    out[s.name] = docs[s.name]
  else
    missing = missing + 1
  end
end

local names = vim.tbl_keys(out)
table.sort(names)
local lines = { "{" }
for k, name in ipairs(names) do
  lines[#lines + 1] = vim.json.encode(name) .. ":" .. vim.json.encode(out[name]) .. (k < #names and "," or "")
end
lines[#lines + 1] = "}"
vim.fn.writefile(lines, root .. "/data/docs.json")
print(("CSUG entries: %d, R6RS entries: %d, documented: %d, undocumented: %d"):format(
  csug_count, r6rs_count, #names, missing))
