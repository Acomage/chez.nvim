-- Evaluation results shown as virtual text after the evaluated form.
local config = require("chez.config")
local util = require("chez.util")

local M = {}

local ns_range = vim.api.nvim_create_namespace("chez.inline.range")
local ns_text = vim.api.nvim_create_namespace("chez.inline.text")
local ns_flash = vim.api.nvim_create_namespace("chez.inline.flash")

---@type table<integer, table<integer, integer>> buf -> range mark -> text mark
local marks = {}
local attached = {}

local function attach(buf)
  if attached[buf] then
    return
  end
  attached[buf] = true
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, _, first, last_old, last_new)
      local m = marks[buf]
      if not m or next(m) == nil then
        return
      end
      -- editing a form hides its result
      local last = math.max(last_old, last_new)
      local hits = vim.api.nvim_buf_get_extmarks(buf, ns_range, { first, 0 }, { last, 0 }, { overlap = true })
      if #hits > 0 then
        vim.schedule(function()
          for _, h in ipairs(hits) do
            M.remove(buf, h[1])
          end
        end)
      end
    end,
    on_detach = function()
      attached[buf] = nil
      marks[buf] = nil
    end,
  })
end

function M.remove(buf, range_id)
  local m = marks[buf]
  if not m or not m[range_id] then
    return
  end
  pcall(vim.api.nvim_buf_del_extmark, buf, ns_text, m[range_id])
  pcall(vim.api.nvim_buf_del_extmark, buf, ns_range, range_id)
  m[range_id] = nil
end

---Remove all results in `buf`.
function M.clear(buf)
  buf = util.buf(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns_range, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_text, 0, -1)
  marks[buf] = {}
end

---Remove all results whose region touches rows [sr, er].
function M.clear_range(buf, sr, er)
  for _, h in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns_range, { sr, 0 }, { er, 2147483647 }, { overlap = true })) do
    M.remove(buf, h[1])
  end
end

---Show results as inline virtual text (wraps with 'wrap') rather than "eol"?
local function use_inline(buf)
  local pos = config.inline.position
  if pos == "inline" or pos == "eol" then
    return pos == "inline"
  end
  local win = vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_current_win() or vim.fn.bufwinid(buf)
  if win == -1 then
    return vim.go.wrap
  end
  return vim.wo[win].wrap
end

---Put virtual text `chunks` at the end of `row`.
local function set_text(buf, row, chunks)
  local opts = { virt_text = chunks, hl_mode = "combine", priority = 300 }
  local col = 0
  if use_inline(buf) then
    opts.virt_text_pos = "inline"
    col = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
  else
    opts.virt_text_pos = "eol"
  end
  return vim.api.nvim_buf_set_extmark(buf, ns_text, row, col, opts)
end

---`s` on one line, truncated for display.
local function fit(s, inline)
  s = s:gsub("\n", inline and " ⏎ " or "⏎")
  if inline then
    local max = config.inline.max_length
    if vim.fn.strchars(s) > max then
      return vim.fn.strcharpart(s, 0, max - 1) .. "…"
    end
    return s
  end
  return util.truncate(s, config.inline.max_width)
end

---Mark a region as being evaluated. Returns a handle for `M.set`.
---@param opts? { flash?: boolean, force?: boolean } force: even when inline results are disabled
---@return integer? handle
function M.start(buf, sr, sc, er, ec, opts)
  opts = opts or {}
  local flash = opts.flash
  if flash == nil then
    flash = config.inline.flash
  end
  if flash then
    pcall(vim.hl.range, buf, ns_flash, "ChezEvalFlash", { sr, sc }, { er, ec }, { timeout = 200 })
  end
  if not config.inline.enabled and not opts.force then
    return nil
  end
  attach(buf)
  marks[buf] = marks[buf] or {}
  -- replace results that overlap the region
  for _, h in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns_range, { sr, sc }, { er, ec }, { overlap = true })) do
    M.remove(buf, h[1])
  end
  local range_id = vim.api.nvim_buf_set_extmark(buf, ns_range, sr, sc, {
    end_row = er, end_col = ec, right_gravity = false, end_right_gravity = true,
  })
  local text_id = set_text(buf, er, { { " …", "ChezInlinePending" } })
  marks[buf][range_id] = text_id
  return range_id
end

---Display the response for a region started with `M.start`.
function M.set(buf, handle, resp)
  if not handle or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local m = marks[buf]
  if not m or not m[handle] then
    return
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns_range, handle, { details = true })
  if not pos or not pos[1] then
    return
  end
  local row = pos[3] and pos[3].end_row or pos[1]
  local inline = use_inline(buf)
  local chunks = {}
  local output = resp.output and vim.trim(resp.output) or ""
  if output ~= "" then
    -- output written by the code (only for #eval blocks; REPL output goes to the REPL window)
    chunks[1] = { " ▷ " .. fit(output, inline), "ChezInlineOutput" }
  end
  local chunk
  if resp.ok then
    local values = resp.values or {}
    if #values == 0 then
      chunk = { " ✓", "ChezInlineOk" }
    else
      chunk = { " => " .. fit(table.concat(values, " "):gsub("\n", " "), inline), "ChezInlineResult" }
    end
  else
    local err = resp.error or {}
    local msg = vim.trim(err.message or "error")
    if not inline then
      msg = msg:gsub("\n.*", "")
    end
    local hl = err.kind == "interrupt" and "ChezInlineWarning" or "ChezInlineError"
    chunk = { " ✗ " .. fit(msg, inline), hl }
  end
  pcall(vim.api.nvim_buf_del_extmark, buf, ns_text, m[handle])
  chunks[#chunks + 1] = chunk
  m[handle] = set_text(buf, row, chunks)
end

return M
