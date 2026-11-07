-- Lisp-style indentation for Chez Scheme ('indentexpr').
--
-- The reader state at the start of a line (chez.reader) holds the open lists
-- with their head symbol and element positions; `compute` turns it into the
-- line's indentation using the rules below.

local config = require("chez.config")
local reader = require("chez.reader")

local M = {}

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

---Indentation (display columns) of a line whose start state is `s`, or -1
---when the line starts inside a string, |symbol| or block comment.
---@param s chez.reader.State
---@return integer
function M.compute(s)
  if s.str or s.bar or s.block > 0 or s.evalp then
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

---'indentexpr' entry point.
---@param lnum? integer 1-based line, defaults to v:lnum
---@return integer
function M.indentexpr(lnum)
  lnum = lnum or vim.v.lnum
  local ok, res = pcall(function()
    return M.compute(reader.state_at(vim.api.nvim_get_current_buf(), lnum - 1))
  end)
  if not ok then
    return -1
  end
  return res
end

return M
