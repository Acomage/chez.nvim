-- Chez Scheme file types. Neovim maps *.ss to scheme already; *.sls defaults to
-- SaltStack and *.sps/*.sch are unknown.
vim.filetype.add({
  extension = {
    sps = "scheme",
    sch = "scheme",
    sls = function(_, bufnr)
      -- SaltStack states are YAML (`#` comments); R6RS libraries start with a
      -- `;`/`#|`/`#;` comment, a `#!` directive or a parenthesis.
      for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, 50, false)) do
        if line:find("%S") then
          if line:match("^%s*[;(%[]") or line:match("^%s*#[!|;]") then
            return "scheme"
          end
          return "salt"
        end
      end
      return "scheme"
    end,
  },
})
