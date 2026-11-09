-- `#eval` blocks: block comments whose first line is `#eval`, e.g.
--
--   #|#eval
--   (fact 5)
--   (map square '(1 2 3))
--   |#
--
-- are evaluated by a fresh Chez process (scheme/evalblock.ss) that first
-- loads the whole buffer, and with it every library it imports, from
-- scratch. The result of each expression is shown as virtual text after it.
local config = require("chez.config")
local util = require("chez.util")
local inline = require("chez.repl.inline")

local M = {}

local RS = "\30"

---@type table<integer, table> buf -> running job
local running = {}

---@type table<integer, integer[]> buf -> inline marks of the last run
local results = {}

---@class chez.EvalBlock
---@field srow integer  range of the whole comment (0-based, end exclusive col)
---@field scol integer
---@field erow integer
---@field ecol integer
---@field trow integer  position of the `#eval` tag
---@field tcol integer
---@field offset integer  character offset of the code after `#eval`
---@field end_offset integer  character offset of the closing `|#`
---@field code string
---@field handle? integer  inline mark shown on the tag while running

---Parse the text of a block comment starting at (sr, sc). Returns nil when
---it is not an `#eval` block, otherwise the position of the `#eval` tag, the
---code after it and the end of the code (before `|#`).
---@param text string
---@param sr integer
---@param sc integer
---@return { trow: integer, tcol: integer, code: string, crow: integer, ccol: integer, erow: integer, ecol: integer }?
function M.parse(text, sr, sc)
  if text:sub(1, 2) ~= "#|" or text:sub(-2) ~= "|#" or #text < 4 then
    return nil
  end
  local inner = text:sub(3, -3)
  local pos = inner:find("#eval", 1, true)
  if not pos or not inner:sub(1, pos - 1):match("^%s*$") then
    return nil
  end
  local after = inner:sub(pos + 5, pos + 5)
  if after ~= "" and not after:match("%s") then
    return nil
  end
  -- 0-based (row, col) of byte index i (1-based) of `text`
  local function at(i)
    local before = text:sub(1, i - 1)
    local _, nl = before:gsub("\n", "")
    if nl == 0 then
      return sr, sc + #before
    end
    return sr + nl, #before:match("[^\n]*$")
  end
  local trow, tcol = at(pos + 2)
  local erow, ecol = at(#text - 1)
  return {
    trow = trow, tcol = tcol, crow = trow, ccol = tcol + 5, erow = erow, ecol = ecol,
    code = inner:sub(pos + 5),
  }
end

---Range of the code in an `#eval` block comment node (for tree-sitter
---injections and highlights), or nil.
---@param node TSNode
---@param source integer|string
---@return integer[]? { start_row, start_col, end_row, end_col }
function M.code_range(node, source)
  local sr, sc = node:range()
  local p = M.parse(vim.treesitter.get_node_text(node, source), sr, sc)
  if p then
    return { p.crow, p.ccol, p.erow, p.ecol }
  end
end

---`#eval` blocks of `buf`, in buffer order.
---@param buf integer
---@return chez.EvalBlock[]
function M.find(buf)
  local root = require("chez.ts").root(buf)
  if not root then
    return {}
  end
  local q = vim.treesitter.query.parse("scheme", "((block_comment) @c)")
  local out = {}
  for _, node in q:iter_captures(root, buf) do
    local sr, sc, er, ec = node:range()
    local p = M.parse(vim.treesitter.get_node_text(node, buf), sr, sc)
    if p then
      out[#out + 1] = {
        srow = sr, scol = sc, erow = er, ecol = ec, trow = p.trow, tcol = p.tcol,
        offset = util.char_offset(buf, p.crow, p.ccol),
        end_offset = util.char_offset(buf, p.erow, p.ecol),
        code = p.code,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.srow < b.srow or (a.srow == b.srow and a.scol < b.scol)
  end)
  return out
end

--------------------------------------------------------------------------------
-- Results
--------------------------------------------------------------------------------

---Show `resp` as a result for the text between character offsets bfp and efp
---of `lines` (the buffer text the run started with).
local function show(buf, lines, bfp, efp, resp)
  local sr, sc = util.offset_to_pos(lines, bfp)
  local er, ec = util.offset_to_pos(lines, efp or bfp)
  local h = inline.start(buf, sr, sc, er, ec, { flash = false, force = true })
  inline.set(buf, h, resp)
  if h then
    results[buf] = results[buf] or {}
    table.insert(results[buf], h)
  end
end

---Remove the results of the previous run, also those outside the blocks
---(errors of top-level forms of the file).
local function clear_results(buf)
  for _, h in ipairs(results[buf] or {}) do
    inline.remove(buf, h)
  end
  results[buf] = {}
end

--------------------------------------------------------------------------------
-- A run: one runner process for all blocks of a buffer
--------------------------------------------------------------------------------

---@class chez.evalblock.Job
---@field buf integer
---@field blocks chez.EvalBlock[]
---@field lines string[]  buffer text sent to the runner
---@field tick integer
---@field done boolean  the runner reported the end of the run
---@field proc? vim.SystemObj

---Is `job` still the run of its buffer, on unchanged text?
local function current(job)
  local buf = job.buf
  return running[buf] == job and vim.api.nvim_buf_is_valid(buf) and util.same_text(buf, job.tick, job.lines)
end

---Request for scheme/evalblock.ss (see run-blocks in chez-nvim/evalblock.sls).
local function request(job)
  local req = {
    name = util.buf_file(job.buf) or ("buffer-" .. job.buf),
    code = table.concat(job.lines, "\n"),
    blocks = {},
    print_length = config.repl.print_length,
    print_level = config.repl.print_level,
  }
  for i, b in ipairs(job.blocks) do
    req.blocks[i] = { offset = b.offset, code = b.code }
  end
  return vim.json.encode(req)
end

---Handle one message of the runner.
local function on_message(job, msg)
  if msg.phase == "done" then
    job.done = true
  elseif msg.phase == "eval" or (msg.phase == "load" and msg.bfp) then
    show(job.buf, job.lines, msg.bfp, msg.efp, msg)
  elseif msg.phase == "load" then
    -- no position (e.g. the file cannot be read): report on the tags
    for _, b in ipairs(job.blocks) do
      inline.set(job.buf, b.handle, msg)
      b.handle = nil
    end
  end
end

---Stdout handler: splits the output into lines and passes the messages
---(lines with a leading U+001E) to `on_msg`.
local function message_reader(on_msg)
  local partial = ""
  return function(data)
    partial = partial .. data
    while true do
      local nl = partial:find("\n", 1, true)
      if not nl then
        return
      end
      local line = partial:sub(1, nl - 1)
      partial = partial:sub(nl + 1)
      local start = line:find(RS, 1, true)
      if start then
        local ok, msg = pcall(vim.json.decode, line:sub(start + 1), { luanil = { object = true, array = true } })
        if ok and type(msg) == "table" then
          on_msg(msg)
        end
      end
    end
  end
end

---Replace the pending markers on the `#eval` tags: removed after a complete
---run, an error otherwise (`err`).
local function finish_tags(job, err)
  for _, b in ipairs(job.blocks) do
    if b.handle then
      if err then
        inline.set(job.buf, b.handle, { ok = false, error = { message = err } })
      else
        inline.remove(job.buf, b.handle)
      end
      b.handle = nil
    end
  end
end

---The runner exited.
local function on_exit(job, obj)
  running[job.buf] = nil
  local err
  if not job.done then
    if obj.code == 124 then
      err = ("timed out after %d ms"):format(config.eval_blocks.timeout)
    else
      local stderr = vim.trim(obj.stderr or "")
      err = stderr ~= "" and stderr or ("Chez exited (code " .. tostring(obj.code) .. ")")
    end
  end
  finish_tags(job, err)
end

---Start the runner process of `job`.
local function spawn(job)
  local root = require("chez.repl").root_for(job.buf)
  local read = message_reader(function(msg)
    on_message(job, msg)
  end)
  local ok, proc = pcall(vim.system, util.chez_script("evalblock.ss", util.project_libdirs(root)), {
    cwd = root,
    stdin = request(job),
    text = true,
    timeout = config.eval_blocks.timeout,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          if current(job) then
            read(data)
          end
        end)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      if current(job) then
        on_exit(job, obj)
      end
    end)
  end)
  if ok then
    job.proc = proc
  else
    running[job.buf] = nil
    finish_tags(job, "failed to start Chez: " .. tostring(proc))
  end
end

---Stop the running evaluation of `buf`, if any.
function M.stop(buf)
  local job = running[buf]
  if job then
    running[buf] = nil
    if job.proc then
      pcall(job.proc.kill, job.proc, "sigkill")
    end
    for _, b in ipairs(job.blocks) do
      inline.remove(buf, b.handle)
    end
  end
end

---Evaluate the `#eval` blocks of `buf`.
---@param buf? integer
---@param opts? { silent?: boolean } silent: no message when there are no blocks
function M.run(buf, opts)
  opts = opts or {}
  buf = util.buf(buf)
  local function notify(msg, level)
    if not opts.silent then
      util.notify(msg, level)
    end
  end
  if not require("chez.ts").available(buf) then
    notify("tree-sitter parser for scheme is missing (:TSInstall scheme)", vim.log.levels.ERROR)
    return
  end
  local blocks = M.find(buf)
  if #blocks == 0 then
    notify("no #eval blocks in this buffer", vim.log.levels.INFO)
    return
  end
  M.stop(buf)
  clear_results(buf)
  ---@type chez.evalblock.Job
  local job = {
    buf = buf,
    blocks = blocks,
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    tick = vim.api.nvim_buf_get_changedtick(buf),
    done = false,
  }
  running[buf] = job
  for _, b in ipairs(blocks) do
    inline.clear_range(buf, b.srow, b.erow)
    -- pending marker on the tag until the run is over
    b.handle = inline.start(buf, b.trow, b.tcol, b.trow, b.tcol + 5, { flash = false, force = true })
  end
  spawn(job)
end

--------------------------------------------------------------------------------
-- Wrapping forms in blocks
--------------------------------------------------------------------------------

---The `#eval` block containing (row, col), if any.
---@return chez.EvalBlock?
function M.block_at(buf, row, col)
  for _, b in ipairs(M.find(buf)) do
    local after_start = row > b.srow or (row == b.srow and col >= b.scol)
    local before_end = row < b.erow or (row == b.erow and col < b.ecol)
    if after_start and before_end then
      return b
    end
  end
end

local function line(buf, row)
  return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

---Remove the delimiters of block `b`: the lines of `#|#eval` and `|#` when
---nothing else is on them, otherwise just the delimiters (and the blanks
---between them and the code).
local function unwrap(buf, b)
  -- closing `|#` first: the opening positions stay valid
  local close = line(buf, b.erow)
  local cs = b.ecol - 2
  if close:sub(1, cs):match("^%s*$") and close:sub(b.ecol + 1):match("^%s*$") then
    vim.api.nvim_buf_set_lines(buf, b.erow, b.erow + 1, false, {})
  else
    local before = close:sub(1, cs)
    local trimmed = before:match("^(.-)%s*$")
    vim.api.nvim_buf_set_text(buf, b.erow, #trimmed, b.erow, b.ecol, {})
  end
  local tag_end = b.tcol + 5
  local first, last = line(buf, b.srow), line(buf, b.trow)
  if first:sub(1, b.scol):match("^%s*$") and last:sub(tag_end + 1):match("^%s*$") then
    vim.api.nvim_buf_set_lines(buf, b.srow, b.trow + 1, false, {})
  else
    local blanks = #(last:sub(tag_end + 1):match("^[ \t]*"))
    vim.api.nvim_buf_set_text(buf, b.srow, b.scol, b.trow, tag_end + blanks, {})
  end
end

---Put `node` into an `#eval` block: on lines of their own when the form
---fills its lines, otherwise `#|#eval form |#` on the same line.
local function wrap(buf, node)
  local sr, sc, er, ec = node:range()
  local first, last = line(buf, sr), line(buf, er)
  local indent = first:sub(1, sc)
  if indent:match("^%s*$") and last:sub(ec + 1):match("^%s*$") then
    vim.api.nvim_buf_set_lines(buf, er + 1, er + 1, false, { indent .. "|#" })
    vim.api.nvim_buf_set_lines(buf, sr, sr, false, { indent .. "#|#eval" })
  else
    vim.api.nvim_buf_set_text(buf, er, ec, er, ec, { " |#" })
    vim.api.nvim_buf_set_text(buf, sr, sc, sr, sc, { "#|#eval " })
  end
end

---Toggle an `#eval` block at (row, col): remove the delimiters of the block
---containing it, or put the top-level form there into a new block.
---@param buf? integer
---@param row? integer 0-based; defaults to the cursor
---@param col? integer
function M.toggle(buf, row, col)
  buf = util.buf(buf)
  if not row then
    local c = vim.api.nvim_win_get_cursor(0)
    row, col = c[1] - 1, c[2]
  end
  local ts = require("chez.ts")
  if not ts.available(buf) then
    util.notify("tree-sitter parser for scheme is missing (:TSInstall scheme)", vim.log.levels.ERROR)
    return
  end
  local b = M.block_at(buf, row, col)
  if b then
    return unwrap(buf, b)
  end
  local node = ts.root_form(buf, row, col)
  if not node then
    util.notify("no top-level form at the cursor", vim.log.levels.INFO)
    return
  end
  wrap(buf, node)
end

---Run the blocks on save when `eval_blocks.on_save` is set.
---@param buf integer
function M.attach(buf)
  if not config.eval_blocks.on_save then
    return
  end
  local group = vim.api.nvim_create_augroup("chez.evalblock." .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = buf,
    callback = function()
      M.run(buf, { silent = true })
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      M.stop(buf)
      results[buf] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

return M
