-- Incremental reader for Chez Scheme source.
--
-- Scans the buffer line by line and keeps a stack of open lists, so the state
-- at the start of any line is known even in incomplete or unbalanced code
-- (unlike a tree-sitter tree). Strings, |symbols|, `;` and `#| |#` comments,
-- `#;` datum comments and character literals such as `#\(` are understood;
-- the code inside `#| #eval ... |#` blocks is read as code.
--
-- Users: indentation (chez.indent), smart brackets (chez.pairs), rainbow
-- brackets / current form / `%` (chez.brackets), formatting (chez.format) and
-- the REPL prompt (chez.repl.ui). States are cached per buffer at checkpoint
-- rows and invalidated through `nvim_buf_attach`.

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

--------------------------------------------------------------------------------
-- Reader state
--------------------------------------------------------------------------------

---@class chez.reader.Frame
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

---@class chez.reader.State
---@field stack chez.reader.Frame[]
---@field str boolean     inside a string literal
---@field bar boolean     inside a |symbol|
---@field block integer   nesting depth of #| |# comments
---@field extra integer   closing brackets without an opening one
---@field comment boolean the fed text ended inside a ; comment
---@field evalb? integer  inside a `#| #eval ... |#` block (read as code):
---                       stack depth at its start
---@field evalp? boolean  after a `#|` that ended its line: an #eval block if
---                       the next non-blank line starts with `#eval`

local function new_frame(ocol, orow, data)
  return { ocol = ocol, orow = orow, data = data, n = 0, skip = 0 }
end

---@return chez.reader.State
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
  return {
    stack = stack, str = s.str, bar = s.bar, block = s.block, extra = s.extra, comment = false,
    evalb = s.evalb, evalp = s.evalp,
  }
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

---Byte index after an `#eval` tag that starts (after blanks) at byte `i`
---of `line`, or nil.
local function eval_tag(line, i)
  local _, e = line:find("^%s*#eval", i)
  if e and (e == #line or is_ws(byte(line, e + 1))) then
    return e + 1
  end
end

---Feed one line (0-based `row`) into the state.
---`on_bracket(col, open, depth)` is called for every bracket outside strings,
---comments and character literals: `col` is the 0-based byte column, `depth`
---the nesting level of the list (1 = top-level form, 0 = unmatched closer).
---@param s chez.reader.State
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
  if s.evalp then
    local tag = eval_tag(line, 1)
    if tag then
      s.evalp, s.evalb, i = nil, #stack, tag
    elseif line:find("%S") then
      s.evalp, s.block = nil, 1 -- an ordinary block comment
    else
      return
    end
  end
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
        local base = s.evalb or 1
        if on_bracket then
          on_bracket(i - 1, false, #stack > base and #stack - 1 or 0)
        end
        if #stack > base then
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
          local tag = not s.evalb and eval_tag(line, i + 2)
          if tag then
            -- #| #eval ... |#: the content is read as code
            s.evalb, i = #stack, tag
          elseif not s.evalb and not line:find("%S", i + 2) then
            s.evalp, i = true, len + 1
          else
            s.block, i = s.block + 1, i + 2
          end
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
      elseif c == B.bar and s.evalb and byte(line, i + 1) == B.hash then
        -- end of an #eval block: drop lists left open inside it
        for k = #stack, s.evalb + 1, -1 do
          stack[k] = nil
        end
        s.evalb, i = nil, i + 2
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

---Is the reader outside any list, string, |symbol| and block comment?
---@param s chez.reader.State
function M.at_top(s)
  return #s.stack == 1 and not s.str and not s.bar and s.block == 0
end

--------------------------------------------------------------------------------
-- Buffer integration: checkpoint cache
--------------------------------------------------------------------------------

local CHECKPOINT = 16

---@type table<integer, { states: table<integer, chez.reader.State> }>
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
---@return chez.reader.State
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

---Start of the top-level form(s) around 0-based `row`: a cached checkpoint
---row at or before `row` where the reader is outside any form, and the
---state there (a copy, safe to feed).
---@param buf integer
---@param row integer
---@return integer start, chez.reader.State state
function M.form_start(buf, row)
  local start = row - row % CHECKPOINT
  local s = M.state_at(buf, start)
  while start > 0 and not M.at_top(s) do
    start = start - CHECKPOINT
    s = M.state_at(buf, start)
  end
  return start, s
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
