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
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
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

local function text_opts(chunks)
  return { virt_text = chunks, virt_text_pos = "eol", hl_mode = "combine", priority = 300 }
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
  local text_id = vim.api.nvim_buf_set_extmark(buf, ns_text, er, 0, text_opts({ { " …", "ChezInlinePending" } }))
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
  local max = config.inline.max_width
  local chunks = {}
  local output = resp.output and vim.trim(resp.output) or ""
  if output ~= "" then
    -- output written by the code (only for #eval blocks; REPL output goes to the REPL window)
    chunks[1] = { " ▷ " .. util.truncate(output:gsub("\n", "⏎"), max), "ChezInlineOutput" }
  end
  local chunk
  if resp.ok then
    local values = resp.values or {}
    if #values == 0 then
      chunk = { " ✓", "ChezInlineOk" }
    else
      chunk = { " => " .. util.truncate(table.concat(values, " "):gsub("\n", " "), max), "ChezInlineResult" }
    end
  else
    local err = resp.error or {}
    local msg = (err.message or "error"):gsub("\n.*", "")
    local hl = err.kind == "interrupt" and "ChezInlineWarning" or "ChezInlineError"
    chunk = { " ✗ " .. util.truncate(msg, max), hl }
  end
  pcall(vim.api.nvim_buf_del_extmark, buf, ns_text, m[handle])
  chunks[#chunks + 1] = chunk
  local opts = text_opts(chunks)
  m[handle] = vim.api.nvim_buf_set_extmark(buf, ns_text, row, 0, opts)
end

return M
