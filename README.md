# chez.nvim

English | [简体中文](README.zh-CN.md)

Chez Scheme support for Neovim: indentation, highlighting, a REPL with inline
results, completion, documentation, macro expansion and diagnostics.

- **Indentation** that works on incomplete code, with rules for Chez forms
  (`library`, `syntax-case`, `fluid-let`, `trace-lambda`, …) and a formatter
  (`:Chez format`, conform.nvim).
- **Highlighting**: tree-sitter query extensions for Chez syntax, all
  (chezscheme) procedures, `#!chezscheme`, `#%car`, `#;` datum comments.
- **REPL** per project: evaluate the form / top-level form / selection /
  buffer / file, results as virtual text, program output in a REPL window,
  `(read)` answered from Neovim, interrupt with SIGINT, backtraces to
  quickfix, diagnostics at the failing call, auto-import of evaluated
  libraries, a prompt buffer with history.
- **Completion**: blink.cmp source and `omnifunc` — locals in scope, buffer
  definitions (incl. record constructors/accessors), (chezscheme), REPL
  bindings.
- **Documentation**: `K` with signatures and text from the Chez Scheme
  User's Guide and the R6RS report for 1585 identifiers, buffer definitions
  with their comments, REPL bindings; signature help; links to the online
  guide.
- **Navigation**: `gd` via buffer, REPL source locations and ripgrep.
- **Macro expansion**: `expand` and `expand/optimize` (cp0) in a float.
- **Diagnostics**: a checker process expands (without running) the buffer —
  on open, on save and after edits — and reports syntax errors and unbound
  identifiers.
- **Brackets**: `(`/`)` pairing and skipping decided by the balance of the
  whole form, not the current line (fixes lost closers with autopair plugins).

## Requirements

- Neovim ≥ 0.11
- Chez Scheme (tested with 10.3.0)
- tree-sitter `scheme` parser (`:TSInstall scheme`)
- optional: blink.cmp, which-key.nvim, conform.nvim, ripgrep

## Installation (LazyVim / lazy.nvim)

`lua/plugins/chez.lua`:

```lua
return {
  {
    "Acomage/chez.nvim",
    ft = "scheme",
    opts = {},
  },

  -- completion
  {
    "saghen/blink.cmp",
    opts = {
      sources = {
        per_filetype = {
          scheme = { inherit_defaults = true, "chez" },
          chez_repl = { "chez", "buffer" },
        },
        providers = {
          chez = { name = "Chez", module = "chez.complete.blink" },
        },
      },
    },
  },

  -- structural editing, re-indenting with chez.nvim's rules
  {
    "julienvincent/nvim-paredit",
    ft = "scheme",
    opts = function()
      return { indent = { enabled = true, indentor = require("chez.paredit").indentor } }
    end,
  },

  -- <leader>cf formats with chez.nvim's indenter
  {
    "stevearc/conform.nvim",
    opts = function(_, opts)
      opts.formatters = opts.formatters or {}
      opts.formatters.chez_indent = require("chez.format").conform
      opts.formatters_by_ft = opts.formatters_by_ft or {}
      opts.formatters_by_ft.scheme = { "chez_indent" }
    end,
  },
}
```

Then `:TSInstall scheme` (once) and `:checkhealth chez`.

Keys are buffer-local under `<localleader>` (`\` in LazyVim): `e` evaluate,
`c` REPL, `m` macro expansion, `t` trace, `h` help; plus `K`, `gd` and `<C-k>`
in Insert mode. nvim-paredit adds its own keys (`>)`, `<(`, `>e`,
`<localleader>o`, `<localleader>r`, …).

See `:help chez.nvim` for configuration, keymaps and commands.

## Development

```sh
make test       # Scheme and Lua (plenary) tests
make generate   # data/builtins.json and queries/scheme/highlights.scm from the installed Chez
make docs CSUG=… CSUG_HTML=… R6RS=…   # data/docs.json, see scripts/gen-docs.lua
```

## Layout

```
after/ftplugin/scheme.lua   attaches to Chez buffers
ftdetect/chez.lua           *.sls / *.sps / *.sch
queries/scheme/             highlight extensions (generated)
lua/chez/                   Neovim side (indent, repl/, complete/, doc, tools, diagnostics)
scheme/chez-nvim/           Chez side: JSON, REPL server, checker
data/                       builtins.json, docs.json (generated)
```

## Data sources

`data/docs.json` is generated from the
[Chez Scheme Version 10 User's Guide](https://cisco.github.io/ChezScheme/csug/)
(Apache License 2.0, © Cisco Systems, Inc.) and the
[Revised⁶ Report on the Algorithmic Language Scheme](https://www.r6rs.org/)
(“we grant permission to copy it in whole or in part without fee”).
