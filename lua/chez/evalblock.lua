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

local function buf_name(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:match("^%a[%w+.-]*://") then
    return "buffer-" .. buf
  end
  return vim.fs.normalize(name)
end

---Command line of the runner process, with the project's library directories.
local function command(root)
  local scheme_dir = util.plugin_root .. "/scheme"
  local cmd = vim.deepcopy(config.repl.cmd)
  vim.list_extend(cmd, { "--libdirs", scheme_dir, "--script", scheme_dir .. "/evalblock.ss" })
  for _, d in ipairs(config.repl.libdirs) do
    local path = vim.fs.normalize(vim.fs.joinpath(root, d))
    if vim.fn.isdirectory(path) == 1 then
      cmd[#cmd + 1] = path
    end
  end
  return cmd
end

---Show `resp` as a result for the text between character offsets bfp and efp.
local function show(buf, lines, bfp, efp, resp)
  local sr, sc = util.offset_to_pos(lines, bfp)
  local er, ec = util.offset_to_pos(lines, efp or bfp)
  local h = inline.start(buf, sr, sc, er, ec, { flash = false, force = true })
  inline.set(buf, h, resp)
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
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if not require("chez.ts").available(buf) then
    if not opts.silent then
      util.notify("tree-sitter parser for scheme is missing (:TSInstall scheme)", vim.log.levels.ERROR)
    end
    return
  end
  local blocks = M.find(buf)
  if #blocks == 0 then
    if not opts.silent then
      util.notify("no #eval blocks in this buffer", vim.log.levels.INFO)
    end
    return
  end
  M.stop(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local job = { blocks = blocks, done = false }
  running[buf] = job
  local req = { name = buf_name(buf), code = table.concat(lines, "\n"), blocks = {} }
  req.print_length = config.repl.print_length
  req.print_level = config.repl.print_level
  for i, b in ipairs(blocks) do
    inline.clear_range(buf, b.srow, b.erow)
    b.handle = inline.start(buf, b.trow, b.tcol, b.trow, b.tcol + 5, { flash = false, force = true })
    req.blocks[i] = { offset = b.offset, code = b.code }
  end

  local function current()
    return running[buf] == job and vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_buf_get_changedtick(buf) == tick
  end

  local function handle(msg)
    if msg.phase == "done" then
      job.done = true
    elseif msg.phase == "eval" then
      show(buf, lines, msg.bfp, msg.efp, msg)
    elseif msg.phase == "load" then
      if msg.bfp then
        show(buf, lines, msg.bfp, msg.efp, msg)
      else
        -- no position (e.g. the file cannot be read): report on the tags
        for _, b in ipairs(blocks) do
          inline.set(buf, b.handle, msg)
          b.handle = nil
        end
      end
    end
  end

  local partial = ""
  local function on_stdout(data)
    if not current() then
      return
    end
    partial = partial .. data
    while true do
      local nl = partial:find("\n", 1, true)
      if not nl then
        break
      end
      local line = partial:sub(1, nl - 1)
      partial = partial:sub(nl + 1)
      local start = line:find(RS, 1, true)
      if start then
        local ok, msg = pcall(vim.json.decode, line:sub(start + 1), { luanil = { object = true, array = true } })
        if ok and type(msg) == "table" then
          handle(msg)
        end
      end
    end
  end

  local function on_exit(obj)
    if not current() then
      return
    end
    running[buf] = nil
    local err
    if not job.done then
      if obj.code == 124 then
        err = ("timed out after %d ms"):format(config.eval_blocks.timeout)
      else
        local stderr = vim.trim(obj.stderr or "")
        err = stderr ~= "" and stderr or ("Chez exited (code " .. tostring(obj.code) .. ")")
      end
    end
    for _, b in ipairs(blocks) do
      if b.handle then
        if err then
          inline.set(buf, b.handle, { ok = false, error = { message = err } })
        else
          inline.remove(buf, b.handle)
        end
      end
    end
  end

  local root = require("chez.repl").root_for(buf)
  local ok, proc = pcall(vim.system, command(root), {
    cwd = root,
    stdin = vim.json.encode(req),
    text = true,
    timeout = config.eval_blocks.timeout,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          on_stdout(data)
        end)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      on_exit(obj)
    end)
  end)
  if ok then
    job.proc = proc
  else
    running[buf] = nil
    for _, b in ipairs(blocks) do
      inline.set(buf, b.handle, { ok = false, error = { message = "failed to start Chez: " .. tostring(proc) } })
    end
  end
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
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

return M
