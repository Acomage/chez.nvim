-- blink.cmp source for Chez Scheme.
--
--   sources.providers.chez = { name = "Chez", module = "chez.complete.blink" }
--   sources.per_filetype.scheme = { inherit_defaults = true, "chez" }
local complete = require("chez.complete")
local doc = require("chez.doc")

local source = {}

function source.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = source })
end

function source:enabled()
  local ft = vim.bo.filetype
  if ft == "chez_repl" then
    return true
  end
  return ft == "scheme" and require("chez.detect").is_chez(0)
end

local kinds
local function kind_of(c)
  kinds = kinds or require("blink.cmp.types").CompletionItemKind
  if c.kind == "procedure" then
    return kinds.Function
  elseif c.kind == "syntax" then
    return kinds.Keyword
  elseif c.kind == "record" then
    return kinds.Struct
  end
  return kinds.Variable
end

local BOOST = { ["local"] = 4, buffer = 3, repl = 2, builtin = 0 }

function source:get_completions(ctx, callback)
  local buf = ctx.bufnr or vim.api.nvim_get_current_buf()
  local row, col = ctx.cursor[1] - 1, ctx.cursor[2]
  local line = ctx.line
  local prefix, start = complete.prefix(line, col)
  -- blink's own keyword is the trailing run of letters, digits, _ and -;
  -- the part of the Scheme identifier before it is matched literally here
  local keyword = prefix:match("[%w_\128-\255][%w_%-\128-\255]*$") or ""
  local head = prefix:sub(1, #prefix - #keyword)

  complete.repl_names(buf, function(repl_names)
    local items = {}
    for _, c in ipairs(complete.candidates(buf, row, col, repl_names)) do
      if head == "" or (vim.startswith(c.name, head) and #c.name > #head) then
        items[#items + 1] = {
          label = c.name,
          kind = kind_of(c),
          filterText = c.name:sub(#head + 1),
          score_offset = BOOST[c.source] or 0,
          labelDetails = { description = c.source ~= "builtin" and c.source or nil },
          textEdit = {
            newText = c.name,
            range = {
              start = { line = row, character = start },
              ["end"] = { line = row, character = col },
            },
          },
          data = { chez = c },
        }
      end
    end
    callback({ items = items, is_incomplete_forward = head ~= "", is_incomplete_backward = true })
  end)
  return function() end
end

function source:resolve(item, callback)
  local c = item.data and item.data.chez
  if not c then
    return callback(item)
  end
  item = vim.deepcopy(item)
  local lines
  if c.source == "builtin" then
    lines = doc.builtin_markdown(c.name)
  elseif c.sig then
    lines = { "```scheme", c.sig, "```", "*" .. c.kind .. "* · " .. c.source }
  else
    lines = { "*" .. c.kind .. "* · " .. c.source }
  end
  if lines then
    item.documentation = { kind = "markdown", value = table.concat(lines, "\n") }
  end
  callback(item)
end

return source
