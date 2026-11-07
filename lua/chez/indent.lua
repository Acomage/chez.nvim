-- Lisp-style indentation for Chez Scheme.
--
-- A small incremental reader scans the buffer line by line and keeps a stack
-- of open lists. The state at the start of a line is enough to compute that
-- line's indentation, so the scanner works on incomplete or unbalanced code
-- (unlike a tree-sitter based approach). States are cached per buffer at
-- checkpoint rows and invalidated through `nvim_buf_attach`.

local config = require("chez.config")

local M = {}

local byte = string.byte
local B = {
  lparen = byte("("), rparen = byte(")"), lbrack = byte("["), rbrack = byte("]"),
  dquote = byte('"'), semi = byte(";"), hash = byte("#"), bslash = byte("\\"),
  bar = byte("|"), quote = byte("'"), bquote = byte("`"), comma = byte(","),
  at = byte("@"), space = byte(" "), tab = byte("\t"), cr = byte("\r"),
  ff = byte("\f"), bang = byte("!"),
}

local function is_ws(c)
  return c == B.space or c == B.tab or c == B.cr or c == B.ff
end

local function is_delim(c)
  return c == nil or is_ws(c) or c == B.lparen or c == B.rparen or c == B.lbrack
    or c == B.rbrack or c == B.dquote or c == B.semi
end

-- Number of distinguished arguments. The body after them is indented by 2;
-- distinguished arguments on their own line are indented by 4.
M.default_rules = {
  -- binding / body forms
  ["lambda"] = 1, ["λ"] = 1, ["case-lambda"] = 0, ["trace-lambda"] = 2,
  ["trace-case-lambda"] = 1, ["let"] = 1, ["let*"] = 1, ["letrec"] = 1,
  ["letrec*"] = 1, ["let-values"] = 1, ["let*-values"] = 1, ["let-syntax"] = 1,
  ["letrec-syntax"] = 1, ["fluid-let"] = 1, ["fluid-let-syntax"] = 1,
  ["trace-let"] = 2, ["rec"] = 1, ["parameterize"] = 1, ["with-syntax"] = 1,
  ["with-implicit"] = 1, ["receive"] = 2, ["do"] = 2, ["trace-do"] = 2,
  ["begin"] = 0, ["when"] = 1, ["unless"] = 1, ["case"] = 1, ["guard"] = 1,
  ["syntax-case"] = 2, ["syntax-rules"] = 1, ["identifier-syntax"] = 0,
  ["delay"] = 0, ["delay-force"] = 0, ["make-promise"] = 0,
  -- libraries and modules
  ["library"] = 1, ["module"] = 2, ["top-level-program"] = 0, ["meta"] = 0,
  ["eval-when"] = 1, ["meta-cond"] = 0, ["exclusive-cond"] = 0,
  -- Chez specific
  ["with-mutex"] = 1, ["critical-section"] = 0, ["with-interrupts-disabled"] = 0,
  ["with-continuation-mark"] = 2, ["record-case"] = 1, ["time"] = 0,
  ["extend-syntax"] = 1, ["dynamic-wind"] = 0,
  ["with-exception-handler"] = 1, ["call-with-current-continuation"] = 0,
  ["call/cc"] = 0, ["call-with-values"] = 1,
  ["call-with-input-file"] = 1, ["call-with-output-file"] = 1,
  ["with-input-from-file"] = 1, ["with-output-to-file"] = 1,
  ["call-with-port"] = 1, ["call-with-string-output-port"] = 0,
  ["call-with-bytevector-output-port"] = 0, ["with-output-to-string"] = 0,
  ["with-input-from-string"] = 1, ["fork-thread"] = 0,
}

---Indentation rule for a head symbol: number of distinguished arguments, or
---nil for procedure-call style.
---@param sym string
---@return integer?
function M.rule(sym)
  local user = config.indent.rules[sym]
  if user ~= nil then
    return user or nil
  end
  local r = M.default_rules[sym]
  if r ~= nil then
    return r
  end
  if config.indent.def_prefix and sym:sub(1, 3) == "def" then
    return 0
  end
  return nil
end

--------------------------------------------------------------------------------
-- Reader state
--------------------------------------------------------------------------------

---@class chez.indent.Frame
---@field ocol integer   display column of the opening bracket
---@field orow integer
---@field data boolean   quoted list / vector: align elements with the first
---@field n integer      number of elements started so far
---@field hcol? integer  column/row/text/kind of the first element
---@field hrow? integer
---@field head? string   symbol text when the first element is a plain symbol
---@field acol? integer  column/row/kind of the second element
---@field arow? integer
---@field asym? boolean
---@field pending? boolean  a prefix (' ` , #' …) awaits its datum
---@field pq? boolean       pending prefix is a quote (' or `)
---@field skip integer      datums still to be skipped because of #;

---@class chez.indent.State
---@field stack chez.indent.Frame[]
---@field str boolean     inside a string literal
---@field bar boolean     inside a |symbol|
---@field block integer   nesting depth of #| |# comments
---@field extra integer   closing brackets without an opening one
---@field comment boolean the fed text ended inside a ; comment

local function new_frame(ocol, orow, data)
  return { ocol = ocol, orow = orow, data = data, n = 0, skip = 0 }
end

---@return chez.indent.State
function M.new_state()
  return { stack = { new_frame(-1, -1, false) }, str = false, bar = false, block = 0, extra = 0, comment = false }
end

local function copy_state(s)
  local stack = {}
  for i, f in ipairs(s.stack) do
    stack[i] = {
      ocol = f.ocol, orow = f.orow, data = f.data, n = f.n, hcol = f.hcol,
      hrow = f.hrow, head = f.head, acol = f.acol, arow = f.arow, asym = f.asym,
      pending = f.pending, pq = f.pq, skip = f.skip,
    }
  end
  return { stack = stack, str = s.str, bar = s.bar, block = s.block, extra = s.extra, comment = false }
end
M.copy_state = copy_state

---Register the start of a datum (or a prefix) in frame `f`.
---Returns false when the datum is skipped by a `#;` comment.
local function elem(f, col, row, text, is_prefix, quoting)
  if f.pending then
    -- datum following a prefix: belongs to the already counted element
    f.pending = is_prefix or nil
    return true
  end
  if f.skip > 0 then
    f.skip = f.skip - 1
    if is_prefix then
      f.pending, f.pq = true, quoting
    end
    return false
  end
  f.n = f.n + 1
  if f.n == 1 then
    f.hcol, f.hrow = col, row
    f.head = (not is_prefix) and text or nil
  elseif f.n == 2 then
    f.acol, f.arow = col, row
    f.asym = text ~= nil and not is_prefix
  end
  if is_prefix then
    f.pending, f.pq = true, quoting
  end
  return true
end

---Feed one line (0-based `row`) into the state.
---`on_bracket(col, open, depth)` is called for every bracket outside strings,
---comments and character literals: `col` is the 0-based byte column, `depth`
---the nesting level of the list (1 = top-level form, 0 = unmatched closer).
---@param s chez.indent.State
---@param line string
---@param row integer
---@param on_bracket? fun(col: integer, open: boolean, depth: integer)
function M.feed(s, line, row, on_bracket)
  local len = #line
  local simple = not line:find("[\t\128-\255]")
  local function vcol(i) -- display column of byte index i (1-based)
    if simple then
      return i - 1
    end
    return vim.fn.strdisplaywidth(line:sub(1, i - 1))
  end
  local stack = s.stack
  s.comment = false
  local i = 1
  while i <= len do
    local c = byte(line, i)
    if s.block > 0 then
      -- inside #| ... |# (nests)
      if c == B.bar and byte(line, i + 1) == B.hash then
        s.block, i = s.block - 1, i + 2
      elseif c == B.hash and byte(line, i + 1) == B.bar then
        s.block, i = s.block + 1, i + 2
      else
        i = i + 1
      end
    elseif s.str then
      if c == B.bslash then
        i = i + 2
      else
        if c == B.dquote then
          s.str = false
        end
        i = i + 1
      end
    elseif s.bar then
      if c == B.bslash then
        i = i + 2
      else
        if c == B.bar then
          s.bar = false
        end
        i = i + 1
      end
    elseif is_ws(c) then
      i = i + 1
    elseif c == B.semi then
      s.comment = true
      break
    else
      local f = stack[#stack]
      local col = vcol(i)
      if c == B.lparen or c == B.lbrack then
        -- quoted data stays data; an unquote (,) switches back to code
        local quoted
        if f.pending then
          quoted = f.pq and true or false
        else
          quoted = f.data
        end
        elem(f, col, row, nil, false)
        stack[#stack + 1] = new_frame(col, row, quoted)
        if on_bracket then
          on_bracket(i - 1, true, #stack - 1)
        end
        i = i + 1
      elseif c == B.rparen or c == B.rbrack then
        if on_bracket then
          on_bracket(i - 1, false, #stack - 1)
        end
        if #stack > 1 then
          stack[#stack] = nil
        else
          s.extra = s.extra + 1
        end
        i = i + 1
      elseif c == B.dquote then
        elem(f, col, row, nil, false)
        s.str = true
        i = i + 1
      elseif c == B.quote or c == B.bquote then
        elem(f, col, row, nil, true, true)
        i = i + 1
      elseif c == B.comma then
        elem(f, col, row, nil, true, false)
        i = i + ((byte(line, i + 1) == B.at) and 2 or 1)
      elseif c == B.hash then
        local d = byte(line, i + 1)
        if d == B.bar then
          s.block, i = s.block + 1, i + 2
        elseif d == B.semi then
          f.skip, i = f.skip + 1, i + 2
        elseif d == B.lparen or d == B.lbrack then
          -- vector / record literal
          elem(f, col, row, nil, false)
          stack[#stack + 1] = new_frame(col, row, true)
          if on_bracket then
            on_bracket(i, true, #stack - 1)
          end
          i = i + 2
        elseif d == B.quote or d == B.bquote then
          elem(f, col, row, nil, true, false) -- syntax templates are code
          i = i + 2
        elseif d == B.comma then
          elem(f, col, row, nil, true, false)
          i = i + ((byte(line, i + 2) == B.at) and 3 or 2)
        elseif d == B.bslash then
          -- character literal: #\x, #\(, #\space, #\x41, #\λ
          local j = i + 2
          local ch = byte(line, j)
          if ch then
            j = j + 1
            if ch >= 0xC0 then -- skip UTF-8 continuation bytes
              while (byte(line, j) or 0) >= 0x80 and (byte(line, j) or 0) < 0xC0 do
                j = j + 1
              end
            end
            while j <= len and not is_delim(byte(line, j)) do
              j = j + 1
            end
          end
          elem(f, col, row, nil, false)
          i = j
        else
          -- other # syntax: #t #f #x1F #!eof #%car #0= #0# #vu8( #vfx(
          local j = i + 1
          while j <= len and not is_delim(byte(line, j)) do
            j = j + 1
          end
          local tok = line:sub(i, j - 1)
          local nxt = byte(line, j)
          if (nxt == B.lparen) and tok:match("^#v%a*%d*$") then
            elem(f, col, row, nil, false)
            stack[#stack + 1] = new_frame(col, row, true)
            if on_bracket then
              on_bracket(j - 1, true, #stack - 1)
            end
            i = j + 1
          elseif tok:match("^#%d+=$") then
            elem(f, col, row, nil, true, false)
            i = j
          else
            elem(f, col, row, tok, false)
            i = j
          end
        end
      else
        -- symbol / number; may contain |...| segments
        local j = i
        while j <= len do
          local e = byte(line, j)
          if e == B.bar then
            local k = j + 1
            while k <= len and byte(line, k) ~= B.bar do
              k = k + (byte(line, k) == B.bslash and 2 or 1)
            end
            if k > len then
              s.bar = true
              j = len + 1
              break
            end
            j = k + 1
          elseif e == B.bslash then
            j = j + 2
          elseif is_delim(e) then
            break
          else
            j = j + 1
          end
        end
        elem(f, col, row, line:sub(i, j - 1), false)
        i = j
      end
    end
  end
end

---Indentation (display columns) of a line whose start state is `s`, or -1
---when the line starts inside a string, |symbol| or block comment.
---@param s chez.indent.State
---@return integer
function M.compute(s)
  if s.str or s.bar or s.block > 0 then
    return -1
  end
  local stack = s.stack
  if #stack == 1 then
    return 0
  end
  local f = stack[#stack]
  if f.n == 0 then
    return f.ocol + 1
  end
  if f.data or not f.head then
    return f.hcol
  end
  local head = f.head
  local rule = M.rule(head)
  if rule then
    if (head == "let" or head == "trace-let") and f.asym then
      rule = rule + 1 -- named let
    end
    local args = f.n - 1
    if args < rule then
      if f.acol and f.arow == f.hrow then
        return f.acol
      end
      return f.ocol + 4
    end
    return f.ocol + 2
  end
  if f.acol and f.arow == f.hrow then
    return f.acol
  end
  return f.hcol
end

--------------------------------------------------------------------------------
-- Buffer integration (indentexpr) with a checkpoint cache
--------------------------------------------------------------------------------

local CHECKPOINT = 16

---@type table<integer, { states: table<integer, chez.indent.State> }>
local caches = {}

local function cache_for(buf)
  local c = caches[buf]
  if c then
    return c
  end
  c = { states = { [0] = M.new_state() } }
  caches[buf] = c
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, _, first)
      if caches[buf] ~= c then
        return true
      end
      -- the state at the start of row r depends on rows < r only
      for r in pairs(c.states) do
        if r > first then
          c.states[r] = nil
        end
      end
    end,
    on_reload = function()
      c.states = { [0] = M.new_state() }
    end,
    on_detach = function()
      if caches[buf] == c then
        caches[buf] = nil
      end
    end,
  })
  return c
end

---Reader state at the start of 0-based `row` in `buf`.
---@param buf integer
---@param row integer
---@return chez.indent.State
function M.state_at(buf, row)
  local c = cache_for(buf)
  local base = row - row % CHECKPOINT
  while not c.states[base] do
    base = base - CHECKPOINT
  end
  local s = copy_state(c.states[base])
  if base == row then
    return s
  end
  local lines = vim.api.nvim_buf_get_lines(buf, base, row, false)
  for k, line in ipairs(lines) do
    local r = base + k - 1
    M.feed(s, line, r)
    if (r + 1) % CHECKPOINT == 0 and not c.states[r + 1] then
      c.states[r + 1] = copy_state(s)
    end
  end
  return s
end

---'indentexpr' entry point.
---@param lnum? integer 1-based line, defaults to v:lnum
---@return integer
function M.indentexpr(lnum)
  lnum = lnum or vim.v.lnum
  local ok, res = pcall(function()
    return M.compute(M.state_at(vim.api.nvim_get_current_buf(), lnum - 1))
  end)
  if not ok then
    return -1
  end
  return res
end

---Start tracking `buf` (call from the ftplugin).
---@param buf integer
function M.attach(buf)
  cache_for(buf)
end

---Drop cached reader states (e.g. after changing rules).
function M.reset(buf)
  if buf then
    caches[buf] = nil
  else
    caches = {}
  end
end

return M
