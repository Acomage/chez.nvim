-- The REPL buffer: a prompt buffer showing output, results and errors of a
-- session, where expressions can also be typed directly.
local config = require("chez.config")
local util = require("chez.util")

local M = {}

local ns = vim.api.nvim_create_namespace("chez.repl")

---@class chez.ReplState
---@field buf? integer
---@field out_stream? string  stream of the unterminated output line
---@field out_text string     unterminated output
---@field input string        accumulated multi-line input
---@field history string[]
---@field hist_idx? integer

---@type table<chez.Session, chez.ReplState>
local states = setmetatable({}, { __mode = "k" })

local function state(s)
  local st = states[s]
  if not st then
    st = { out_text = "", input = "", history = {} }
    states[s] = st
  end
  return st
end

--------------------------------------------------------------------------------
-- buffer & window
--------------------------------------------------------------------------------

local function is_complete(code)
  local indent = require("chez.indent")
  local st = indent.new_state()
  for i, line in ipairs(vim.split(code, "\n", { plain = true })) do
    indent.feed(st, line, i - 1)
  end
  return #st.stack == 1 and not st.str and not st.bar and st.block == 0
end

local function set_prompt(buf, text)
  vim.fn.prompt_setprompt(buf, text)
  -- the prompt text on the current prompt line is only refreshed on the next
  -- prompt; update it right away when the prompt line is still empty
  local n = vim.api.nvim_buf_line_count(buf)
  local last = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ""
  local old_prompts = { config.repl.prompt, config.repl.continuation_prompt }
  for _, p in ipairs(old_prompts) do
    if last == p and p ~= text then
      vim.api.nvim_buf_set_lines(buf, n - 1, n, false, { text })
    end
  end
end

local function history_move(s, delta)
  local st = state(s)
  local h = st.history
  if #h == 0 then
    return
  end
  local idx = (st.hist_idx or (#h + 1)) + delta
  idx = math.max(1, math.min(#h + 1, idx))
  st.hist_idx = idx
  local text = h[idx] or ""
  local buf = st.buf
  local n = vim.api.nvim_buf_line_count(buf)
  local prompt = vim.fn.prompt_getprompt(buf)
  local first = vim.split(text, "\n", { plain = true })[1]
  vim.api.nvim_buf_set_lines(buf, n - 1, n, false, { prompt .. first })
  vim.api.nvim_win_set_cursor(0, { n, #prompt + #first })
end

---The REPL buffer of a session (created on demand).
---@param s chez.Session
---@return integer
function M.buf(s)
  local st = state(s)
  if st.buf and vim.api.nvim_buf_is_valid(st.buf) then
    return st.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  st.buf = buf
  local name = "chez://repl/" .. vim.fn.fnamemodify(s.root, ":t")
  if vim.fn.bufexists(name) == 1 then
    name = name .. "-" .. buf
  end
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "prompt"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "chez_repl"
  vim.b[buf].chez_root = s.root
  pcall(vim.treesitter.start, buf, "scheme")
  vim.fn.prompt_setprompt(buf, config.repl.prompt)
  vim.fn.prompt_setcallback(buf, function(text)
    M.submit(s, text)
  end)
  vim.fn.prompt_setinterrupt(buf, function()
    s:interrupt()
  end)
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc })
  end
  map("i", "<Up>", function()
    history_move(s, -1)
  end, "History back")
  map("i", "<Down>", function()
    history_move(s, 1)
  end, "History forward")
  map({ "n", "i" }, "<C-l>", function()
    M.clear(s)
  end, "Clear REPL buffer")
  map("n", "<C-c>", function()
    s:interrupt()
  end, "Interrupt evaluation")
  return buf
end

---Window showing the REPL buffer in the current tabpage.
---@param s chez.Session
---@return integer?
function M.win(s)
  local st = state(s)
  if not st.buf then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == st.buf then
      return win
    end
  end
end

local function scroll_to_end(win, buf)
  local n = vim.api.nvim_buf_line_count(buf)
  pcall(vim.api.nvim_win_set_cursor, win, { n, 0 })
end

---Open the REPL window.
---@param s chez.Session
---@param focus? boolean
function M.open(s, focus)
  local buf = M.buf(s)
  local win = M.win(s)
  local cfg = config.repl
  if not win then
    local pos = cfg.position
    local wincfg
    if pos == "float" then
      local w = math.floor(vim.o.columns * 0.7)
      local h = math.floor(vim.o.lines * 0.7)
      wincfg = {
        relative = "editor", width = w, height = h, border = "rounded",
        row = math.floor((vim.o.lines - h) / 2), col = math.floor((vim.o.columns - w) / 2),
        title = " Chez REPL ", title_pos = "center",
      }
    else
      wincfg = { split = pos, win = -1 }
      if pos == "left" or pos == "right" then
        wincfg.width = math.floor(vim.o.columns * cfg.size)
      else
        wincfg.height = math.floor(vim.o.lines * cfg.size)
      end
    end
    win = vim.api.nvim_open_win(buf, focus or false, wincfg)
    local wo = vim.wo[win]
    wo.number, wo.relativenumber, wo.signcolumn = false, false, "no"
    wo.foldcolumn, wo.spell, wo.wrap = "0", false, true
    wo.winfixwidth = pos == "left" or pos == "right"
    wo.winfixheight = pos == "top" or pos == "bottom"
  elseif focus then
    vim.api.nvim_set_current_win(win)
  end
  scroll_to_end(win, buf)
  if focus then
    vim.cmd("startinsert!")
  end
  return win
end

function M.close(s)
  local win = M.win(s)
  if win and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_close(win, false)
  end
end

function M.toggle(s)
  if M.win(s) then
    M.close(s)
  else
    M.open(s, false)
  end
end

function M.clear(s)
  local buf = M.buf(s)
  local n = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, 0, n - 1, false, {})
end

--------------------------------------------------------------------------------
-- appending
--------------------------------------------------------------------------------

---Append lines above the prompt. `hl` highlights the text after `prefix`.
---@param s chez.Session
---@param lines string[]
---@param hl? string
---@param prefix? string
function M.append(s, lines, hl, prefix)
  local buf = M.buf(s)
  prefix = prefix or ""
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = prefix .. l
  end
  -- windows whose cursor is on the prompt line follow the output
  local follow = {}
  local n = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local row = vim.api.nvim_win_get_cursor(win)[1]
    if row >= n or win ~= vim.api.nvim_get_current_win() then
      follow[#follow + 1] = win
    end
  end
  local at = n - 1
  vim.api.nvim_buf_set_lines(buf, at, at, false, out)
  for i, l in ipairs(out) do
    local row = at + i - 1
    if prefix ~= "" then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        end_col = #prefix, hl_group = "ChezReplPrefix", priority = 200,
      })
    end
    if hl and #l > #prefix then
      vim.api.nvim_buf_set_extmark(buf, ns, row, #prefix, {
        end_col = #l, hl_group = hl, priority = 200,
      })
    end
  end
  for _, win in ipairs(follow) do
    if win ~= vim.api.nvim_get_current_win() or vim.fn.mode() ~= "i" then
      scroll_to_end(win, buf)
    else
      -- keep the cursor on the prompt line while typing
      local c = vim.api.nvim_win_get_cursor(win)
      pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), c[2] })
    end
  end
end

local STREAM_HL = { out = "ChezReplOutput", err = "ChezReplError", raw = "ChezReplOutput" }

---Write the unterminated output line, if any.
function M.flush_output(s)
  local st = state(s)
  if st.out_text ~= "" then
    M.append(s, { st.out_text }, STREAM_HL[st.out_stream], "; ")
    st.out_text, st.out_stream = "", nil
  end
end

---Program output (stdout/stderr of user code).
---@param s chez.Session
---@param stream string "out" | "err" | "raw"
---@param text string
function M.output(s, stream, text)
  local st = state(s)
  if st.out_stream and st.out_stream ~= stream then
    M.flush_output(s)
  end
  st.out_stream = stream
  local lines = vim.split(st.out_text .. text, "\n", { plain = true })
  st.out_text = table.remove(lines)
  if #lines > 0 then
    M.append(s, lines, STREAM_HL[stream], "; ")
  end
  if st.out_text == "" then
    st.out_stream = nil
  end
end

---Echo code evaluated from a source buffer.
function M.echo(s, code, label)
  M.flush_output(s)
  local first = vim.trim(code):gsub("\n.*", " …")
  M.append(s, { (label and (label .. " ") or "") .. util.truncate(first, 70) }, "ChezReplInfo", "; ")
end

---Display an error response.
function M.error(s, err)
  M.flush_output(s)
  local lines = vim.split(err.message or "error", "\n", { plain = true })
  lines[1] = "✗ " .. lines[1]
  M.append(s, lines, err.kind == "interrupt" and "ChezReplWarning" or "ChezReplError", "; ")
  local frames = {}
  for _, f in ipairs(err.frames or {}) do
    local where = f.file and vim.fn.fnamemodify(f.file, ":~:.") or "?"
    if f.line then
      where = ("%s:%d:%d"):format(where, f.line, f.col or 0)
    elseif f.pos then
      where = ("%s@%d"):format(where, f.pos)
    end
    frames[#frames + 1] = ("  in %s  %s"):format(f.name or "<anonymous>", where)
  end
  if #frames > 0 then
    M.append(s, frames, "ChezReplInfo", "; ")
  end
end

---Display the response to an eval/load request.
function M.response(s, resp)
  M.flush_output(s)
  if not resp.ok then
    M.error(s, resp.error or {})
    return
  end
  local values = resp.values or {}
  local pretty = resp.pretty or {}
  for i, v in ipairs(values) do
    local text = pretty[i] or v
    M.append(s, vim.split(text, "\n", { plain = true }), nil)
  end
end

--------------------------------------------------------------------------------
-- input
--------------------------------------------------------------------------------

---Evaluate text typed at the prompt.
function M.submit(s, text)
  local st = state(s)
  st.input = st.input == "" and text or (st.input .. "\n" .. text)
  if not is_complete(st.input) then
    set_prompt(st.buf, config.repl.continuation_prompt)
    return
  end
  local code = st.input
  st.input = ""
  set_prompt(st.buf, config.repl.prompt)
  if vim.trim(code) == "" then
    return
  end
  local h = st.history
  if h[#h] ~= code then
    h[#h + 1] = code
    if #h > config.repl.history_size then
      table.remove(h, 1)
    end
  end
  st.hist_idx = nil
  if not s:alive() then
    local ok, err = require("chez.repl").start_session(s)
    if not ok then
      M.error(s, { message = err })
      return
    end
  end
  s:request("eval", { code = code }, function(resp)
    M.response(s, resp)
  end, { source = "prompt" })
end

---User code asked for input: read it with vim.ui.input.
function M.input(s)
  M.flush_output(s)
  vim.ui.input({ prompt = "chez stdin: " }, function(text)
    if text == nil then
      M.append(s, { "stdin: <eof>" }, "ChezReplInfo", "; ")
      s:send_input(nil)
    else
      M.append(s, { "stdin: " .. text }, "ChezReplInfo", "; ")
      s:send_input(text .. "\n")
    end
  end)
end

---Banner written when the process starts.
function M.banner(s)
  M.flush_output(s)
  M.append(s, { "Chez Scheme REPL in " .. vim.fn.fnamemodify(s.root, ":~") }, "ChezReplInfo", "; ")
end

---Register the session's event handlers.
---@param s chez.Session
function M.attach(s)
  s:on("out", function(stream, text)
    M.output(s, stream, text)
  end)
  s:on("raw", function(text)
    M.output(s, "raw", text)
  end)
  s:on("input", function()
    M.input(s)
  end)
  s:on("exit", function(code, signal)
    M.flush_output(s)
    local msg = ("process exited (code %s%s)"):format(code, (signal and signal ~= 0) and (", signal " .. signal) or "")
    M.append(s, { msg }, "ChezReplWarning", "; ")
  end)
end

return M
