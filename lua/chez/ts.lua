-- Tree-sitter helpers: pick the forms to evaluate.
local M = {}

-- reader prefixes that wrap the datum they quote
local PREFIX = {
  quote = true, quasiquote = true, unquote = true, unquote_splicing = true,
  syntax_quote = true, quasisyntax = true, unsyntax = true, unsyntax_splicing = true,
}
local COMPOUND = { list = true, vector = true, byte_vector = true }
local COMMENT = { comment = true, block_comment = true, sexp_comment = true }

function M.is_comment(node)
  return COMMENT[node:type()] == true
end

---@param buf integer
---@return TSNode? root
function M.root(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "scheme", { error = false })
  if not ok or not parser then
    return nil
  end
  local tree = parser:parse()[1]
  return tree and tree:root()
end

function M.available(buf)
  return M.root(buf) ~= nil
end

---Node at (row, col) — the smallest one that is not an anonymous token.
local function node_at(buf, row, col)
  local root = M.root(buf)
  if not root then
    return nil
  end
  return root:named_descendant_for_range(row, col, row, col)
end

local function with_prefix(node)
  local p = node:parent()
  while p and PREFIX[p:type()] do
    node, p = p, p:parent()
  end
  return node
end

local function head_text(list, buf)
  local first = list:named_child(0)
  if first and first:type() == "symbol" then
    return vim.treesitter.get_node_text(first, buf)
  end
end

---Innermost compound form at the cursor, or the atom under the cursor.
---@param buf integer
---@param row integer
---@param col integer
---@return TSNode?
function M.current_form(buf, row, col)
  local node = node_at(buf, row, col)
  if not node or node:type() == "program" then
    return nil
  end
  local n = node
  while n and not COMPOUND[n:type()] and n:type() ~= "program" do
    n = n:parent()
  end
  if n and COMPOUND[n:type()] then
    return with_prefix(n)
  end
  -- top-level atom
  if not M.is_comment(node) then
    return with_prefix(node)
  end
end

---Top-level form containing the cursor. Inside `(library ...)`, the body form
---containing the cursor is returned instead of the whole library; a datum
---comment `#;form` yields `form`.
---@param buf integer
---@param row integer
---@param col integer
---@return TSNode?
function M.root_form(buf, row, col)
  local node = node_at(buf, row, col)
  if not node or node:type() == "program" then
    return nil
  end
  local chain = {}
  local n = node
  while n:parent() and n:parent():type() ~= "program" do
    chain[#chain + 1] = n
    n = n:parent()
  end
  local top = n
  if top:type() == "sexp_comment" then
    return top:named_child(0)
  end
  if top:type() == "list" and head_text(top, buf) == "library" then
    local child = chain[#chain] -- direct child of the library form
    if child then
      local index, i = nil, 0
      for c in top:iter_children() do
        if c:named() and not M.is_comment(c) then
          if c:equal(child) then
            index = i
          end
          i = i + 1
        end
      end
      -- 0: `library`, 1: name, 2: export, 3: import
      if index and index >= 4 then
        return child
      end
    end
  end
  if M.is_comment(top) then
    return nil
  end
  return top
end

---Names of the libraries defined at the top level of `node` (or the buffer).
---@param buf integer
---@param node? TSNode a form; defaults to all top-level forms
---@return string[]
function M.library_names(buf, node)
  local forms = {}
  if node then
    forms = { node }
  else
    local root = M.root(buf)
    if not root then
      return {}
    end
    for child in root:iter_children() do
      forms[#forms + 1] = child
    end
  end
  local names = {}
  for _, f in ipairs(forms) do
    if f:type() == "list" and head_text(f, buf) == "library" then
      local name = f:named_child(1)
      if name and name:type() == "list" then
        names[#names + 1] = vim.treesitter.get_node_text(name, buf)
      end
    end
  end
  return names
end

return M
