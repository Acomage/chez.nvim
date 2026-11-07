-- Evaluate code from source buffers in the project's REPL.
local config = require("chez.config")
local util = require("chez.util")
local ts = require("chez.ts")
local repl = require("chez.repl")
local ui = require("chez.repl.ui")
local inline = require("chez.repl.inline")

local M = {}

local diag_ns = vim.api.nvim_create_namespace("chez.eval")

---Most recent response per buffer (for `show_result`), and the last error.
M.last = {}
M.last_error = nil

local function buf_file(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:match("^%a[%w+.-]*://") then
    return nil
  end
  return vim.fs.normalize(name)
end

---Put an evaluation error on the buffer as a diagnostic, when its location
---is known (reader/syntax errors carry a position; runtime errors a backtrace).
local function error_diagnostics(buf, resp, fallback_row)
  vim.diagnostic.reset(diag_ns, buf)
  if resp.ok then
    return
  end
  local err = resp.error or {}
  if err.kind == "interrupt" then
    return
  end
  local file = buf_file(buf)
  local loc = util.location_from_message(err.message or "")
  if not loc then
    for _, f in ipairs(err.frames or {}) do
      if f.file then
        loc = f
        break
      end
    end
  end
  local row, col = fallback_row, 0
  if loc then
    local r = util.resolve_location(loc)
    if r and file and r.file == file then
      row, col = r.row, r.col
    end
  end
  if not row then
    return
  end
  vim.diagnostic.set(diag_ns, buf, {
    {
      lnum = row,
      col = col,
      severity = vim.diagnostic.severity.ERROR,
      source = "chez",
      message = (err.message or "error"):gsub("^Exception[^:]*: ", "", 1),
    },
  })
end

---Evaluate `code` taken from `buf` at (sr, sc)-(er, ec).
---@param buf integer
---@param code string
---@param range? integer[] {sr, sc, er, ec}
---@param opts? { label?: string, libraries?: string[], on_done?: fun(resp: table) }
function M.eval_code(buf, code, range, opts)
  opts = opts or {}
  local s = repl.ensure(buf)
  if not s then
    return
  end
  local file = buf_file(buf)
  local params = { code = code }
  if file and range then
    params.file = file
    params.offset = util.char_offset(buf, range[1], range[2])
  end
  local handle = range and inline.start(buf, range[1], range[2], range[3], range[4])
  ui.echo(s, code, opts.label)
  s:request("eval", params, function(resp)
    ui.response(s, resp)
    if vim.api.nvim_buf_is_valid(buf) then
      inline.set(buf, handle, resp)
      error_diagnostics(buf, resp, range and range[1])
    end
    M.last[buf] = resp
    if not resp.ok then
      M.last_error = { resp = resp, buf = buf }
    elseif config.repl.auto_import and opts.libraries then
      for _, name in ipairs(opts.libraries) do
        s:request("eval", { code = "(import " .. name .. ")" }, function(r)
          if r.ok then
            ui.append(s, { "imported " .. name }, "ChezReplInfo", "; ")
          else
            ui.response(s, r)
          end
        end)
      end
    end
    if opts.on_done then
      opts.on_done(resp)
    end
  end, { buf = buf })
end

local function eval_node(buf, node, label)
  if not node then
    util.notify("no form at cursor", vim.log.levels.WARN)
    return
  end
  local sr, sc, er, ec = node:range()
  local code = vim.treesitter.get_node_text(node, buf)
  M.eval_code(buf, code, { sr, sc, er, ec }, { label = label, libraries = ts.library_names(buf, node) })
end

local function cursor()
  local pos = vim.api.nvim_win_get_cursor(0)
  return pos[1] - 1, pos[2]
end

local function need_ts(buf)
  if ts.available(buf) then
    return true
  end
  util.notify("tree-sitter parser for scheme is missing (:TSInstall scheme)", vim.log.levels.ERROR)
  return false
end

---Evaluate the innermost form at the cursor.
function M.form()
  local buf = vim.api.nvim_get_current_buf()
  if need_ts(buf) then
    eval_node(buf, ts.current_form(buf, cursor()), "form")
  end
end

---Evaluate the top-level form at the cursor (library body forms count as top level).
function M.root()
  local buf = vim.api.nvim_get_current_buf()
  if need_ts(buf) then
    eval_node(buf, ts.root_form(buf, cursor()), "root")
  end
end

---Evaluate the identifier under the cursor.
function M.word()
  local buf = vim.api.nvim_get_current_buf()
  local word = vim.fn.expand("<cword>")
  if word == "" then
    return
  end
  M.eval_code(buf, word, nil, { label = "word" })
end

---Evaluate the whole buffer (without saving it).
function M.buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local n = #lines
  M.eval_code(buf, table.concat(lines, "\n"), { 0, 0, n - 1, #(lines[n] or "") }, {
    label = "buffer",
    libraries = ts.available(buf) and ts.library_names(buf) or nil,
  })
end

---Load the buffer's file from disk with `load` (saving it first if modified).
function M.file()
  local buf = vim.api.nvim_get_current_buf()
  local file = buf_file(buf)
  if not file then
    util.notify("buffer has no file", vim.log.levels.WARN)
    return
  end
  if vim.bo[buf].modified then
    vim.cmd("silent update")
  end
  local s = repl.ensure(buf)
  if not s then
    return
  end
  -- the whole file is evaluated again: earlier results in it are outdated
  inline.clear(buf)
  ui.echo(s, '(load "' .. vim.fn.fnamemodify(file, ":~:.") .. '")', "file")
  local libraries = ts.available(buf) and ts.library_names(buf) or {}
  s:request("load", { file = file }, function(resp)
    ui.response(s, resp)
    error_diagnostics(buf, resp, nil)
    if resp.ok then
      util.notify("loaded " .. vim.fn.fnamemodify(file, ":t"))
      if config.repl.auto_import then
        for _, name in ipairs(libraries) do
          s:request("eval", { code = "(import " .. name .. ")" }, function(r)
            ui.append(s, { (r.ok and "imported " or "import failed: ") .. name }, "ChezReplInfo", "; ")
          end)
        end
      end
    else
      M.last_error = { resp = resp, buf = buf }
    end
  end, { buf = buf })
end

---Evaluate text from (srow, scol) to (erow, ecol) inclusive; rows are
---1-based, columns 0-based bytes.
local function eval_range(buf, srow, scol, erow, ecol, label)
  local last = vim.api.nvim_buf_get_lines(buf, erow - 1, erow, false)[1] or ""
  local stop = 0
  if #last > 0 and ecol >= 0 then
    ecol = math.min(ecol, #last - 1)
    -- end after the (possibly multibyte) character at ecol
    stop = vim.fn.byteidx(last, vim.fn.charidx(last, ecol) + 1)
    if stop < 0 then
      stop = #last
    end
  end
  local text = vim.api.nvim_buf_get_text(buf, srow - 1, scol, erow - 1, stop, {})
  M.eval_code(buf, table.concat(text, "\n"), { srow - 1, scol, erow - 1, stop }, { label = label })
end

---Evaluate the visual selection.
function M.selection()
  local buf = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local s, e
  if mode == "v" or mode == "V" or mode == "\22" then
    s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  else
    s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    mode = vim.fn.visualmode()
  end
  if s[2] > e[2] or (s[2] == e[2] and s[3] > e[3]) then
    s, e = e, s
  end
  local scol, ecol = s[3] - 1, e[3] - 1
  if mode == "V" then
    scol = 0
    ecol = #vim.fn.getline(e[2]) - 1
  end
  eval_range(buf, s[2], scol, e[2], ecol, "selection")
end

---'operatorfunc' for evaluating a motion.
function M.operator(kind)
  local buf = vim.api.nvim_get_current_buf()
  local s, e = vim.api.nvim_buf_get_mark(buf, "["), vim.api.nvim_buf_get_mark(buf, "]")
  if kind == "line" then
    s[2] = 0
    e[2] = #vim.fn.getline(e[1]) - 1
  end
  eval_range(buf, s[1], s[2], e[1], e[2], "motion")
end

function M.operator_expr()
  vim.o.operatorfunc = "v:lua.require'chez.eval'.operator"
  return "g@"
end

---Show the full result of the last evaluation from this buffer in a float.
function M.show_result()
  local buf = vim.api.nvim_get_current_buf()
  local resp = M.last[buf]
  if not resp then
    util.notify("no result yet", vim.log.levels.INFO)
    return
  end
  local lines
  if resp.ok then
    lines = {}
    for i, v in ipairs(resp.values or {}) do
      vim.list_extend(lines, vim.split((resp.pretty or {})[i] or v, "\n", { plain = true }))
    end
    if #lines == 0 then
      lines = { "; no values" }
    end
  else
    lines = vim.split("; " .. ((resp.error or {}).message or "error"), "\n", { plain = true })
  end
  local fbuf = vim.lsp.util.open_floating_preview(lines, "scheme", { border = "rounded", max_width = 100 })
  pcall(vim.treesitter.start, fbuf, "scheme")
end

---Fill the quickfix list with the backtrace of the last error.
function M.backtrace()
  local last = M.last_error
  if not last then
    util.notify("no error", vim.log.levels.INFO)
    return
  end
  local err = last.resp.error or {}
  local items = {}
  local loc = util.location_from_message(err.message or "")
  local first = vim.split(err.message or "", "\n")[1]
  if loc then
    local r = util.resolve_location(loc)
    if r then
      items[#items + 1] = { filename = r.file, lnum = r.row + 1, col = r.col + 1, text = first, type = "E" }
    end
  end
  for _, f in ipairs(err.frames or {}) do
    local r = util.resolve_location(f)
    if r then
      items[#items + 1] = {
        filename = r.file, lnum = r.row + 1, col = r.col + 1,
        text = (#items == 0 and (first .. " — ") or "") .. "in " .. (f.name or "<anonymous>"),
      }
    end
  end
  if #items == 0 then
    util.notify(first .. " (no source locations)", vim.log.levels.INFO)
    return
  end
  vim.fn.setqflist({}, " ", { title = "Chez backtrace", items = items })
  vim.cmd("copen")
end

return M
