# chez.nvim — notes for coding agents

Chez Scheme support for Neovim (Lua) plus small Chez programs it runs (Scheme).
The owner rarely reads the code: keep it tidy, keep the docs current, and
leave the next agent a working tree with passing tests.

## Workflow

- `make test` runs everything (Scheme tests, then plenary specs in
  `tests/lua/`, sequentially). Always run it before committing; it takes about
  a minute and needs `chez`, the tree-sitter `scheme` parser
  (`~/.local/share/nvim/site`) and plenary.nvim (`~/.local/share/nvim/lazy`).
  Run specs through `make test`: running one file directly skips
  `tests/minimal_init.lua`, so `plugin/chez.lua` is not sourced and queries
  fail with "No handler for chez-eval-block?".
- Add a spec for every bug fix and feature. Specs that need Chez start real
  processes and wait with `vim.wait`.
- To check what is actually drawn (extmarks, colours, wrapping), run the TUI
  in a pty: `script -qc "nvim -u tests/minimal_init.lua -c 'luafile x.lua'" /dev/null`
  where `x.lua` writes `vim.fn.screenstring`/`screenattr` to a file and quits.
  `nvim --embed` UIs exit immediately in this environment.
- When behaviour or options change, update `doc/chez.txt` (`:help chez.nvim`,
  lines ≤ 78 columns, heading tags right-aligned to column 78), `README.md`
  and `README.zh-CN.md` (keep the two READMEs in sync), and the defaults in
  `lua/chez/config.lua` (documented in `doc/chez.txt`, section Configuration).
- Commit or push only when the owner asks. One commit per logical change.

## Layout

```
plugin/chez.lua         global setup: highlight groups, :Chez, tree-sitter
                        predicate/directive for #eval blocks
after/ftplugin/scheme.lua   attaches Chez buffers (chez.init.attach)
ftdetect/chez.lua       *.sls / *.sps / *.sch
queries/scheme/         highlights.scm (GENERATED), injections.scm
lua/chez/
  init.lua              setup(), attach(buf): wires every per-buffer feature
  config.lua            defaults; `require("chez.config").repl` etc.
  util.lua              buffers, positions, project libdirs, chez_script()
  detect.lua            is this scheme buffer Chez? project root
  reader.lua            incremental reader + per-buffer checkpoint cache
  indent.lua            indentation rules, compute(), 'indentexpr'
  format.lua            re-indent ranges (:Chez format, conform.nvim)
  paredit.lua           nvim-paredit indentor
  pairs.lua             smart ( [ ) ] in Insert mode
  brackets.lua          rainbow brackets, current form, % jumps
  ts.lua                tree-sitter: forms at the cursor, library names
  eval.lua              evaluate form/root/buffer/file in the REPL
  evalblock.lua         #| #eval ... |# blocks (separate runner process)
  diagnostics.lua       checker process -> vim.diagnostic
  repl/session.lua      one Chez process speaking the JSON protocol
  repl/init.lua         sessions per project root
  repl/ui.lua           REPL prompt buffer and window
  repl/inline.lua       results as virtual text (shared by eval/evalblock)
  complete/             candidates, omnifunc, blink.cmp source
  doc.lua tools.lua     K / signature help, macro expansion, gd, trace
  keymaps.lua commands.lua highlights.lua health.lua
scheme/
  server.ss + chez-nvim/server.sls       REPL bridge (long-lived)
  check.ss + chez-nvim/check.sls         checker (one shot, stdin source)
  evalblock.ss + chez-nvim/evalblock.sls #eval runner (one shot, JSON stdin)
  chez-nvim/json.sls, chez-nvim/common.sls   shared libraries
data/                   builtins.json, docs.json (GENERATED)
scripts/                generators for data/ and highlights.scm
```

## Key mechanisms

**Reader (`reader.lua`).** Line-based lexer with a stack of open lists. The
state at the start of each line is cached every 16 rows and invalidated by
`nvim_buf_attach` on edits; `reader.state_at(buf, row)` returns a copy that is
safe to `feed`. `feed(s, line, row, on_bracket)` reports every real bracket
(not in strings, comments, `#\(`). `form_start(buf, row)` gives a checkpoint
outside any form to scan from. Everything bracket-related (indent, pairs,
brackets, format, REPL prompt completeness) uses it — do not add another
paren scanner. The code of `#| #eval ... |#` blocks is read as code (fields
`evalb`/`evalp`), a plain `#| |#` comment as a comment.

**Processes.** All Chez programs are started with `util.chez_script(script,
args)` (adds `--libdirs <plugin>/scheme`) and get the project's library
directories from `util.project_libdirs(root)`. The REPL server talks
line-delimited JSON; messages from Chez start with U+001E so stray program
output on stdout can be told apart. The checker and the #eval runner are one
shot: killed and restarted per run, results ignored once superseded.

**#eval blocks.** `evalblock.find` (tree-sitter `block_comment` nodes +
`evalblock.parse`) → runner loads the whole buffer in a fresh process (library
forms are also flattened to top level so blocks see internal definitions) →
streams one message per result → `repl/inline` shows it. The checker gets the
buffer with the block delimiters blanked (same length, positions unchanged)
plus `--blocks=S:E,…` character ranges, and checks block forms in the same
scope.

**Inline results (`repl/inline.lua`).** A range extmark per evaluated region
plus a virtual-text extmark; editing the region removes the result.
`inline.position`: "inline" virtual text wraps with 'wrap', "eol" does not.

## Pitfalls (each of these was a real bug)

- **changedtick is not a text version.** Neovim increments it when a buffer
  that was just read is entered, without any change. To decide whether an
  async result is stale, use `util.same_text(buf, tick, lines)`, never a bare
  tick comparison (that silently dropped the on-open diagnostics check).
- **Positions.** Neovim: 0-based rows, byte columns. Chez reports character
  offsets into the text it was given: convert with `util.char_offset` and
  `util.offset_to_pos` on the same lines snapshot. Reader frames store
  *display* columns (`ocol`, for indentation); `on_bracket` gets byte columns.
- **Tree-sitter injections can recurse.** The injection in
  `queries/scheme/injections.scm` must only match complete #eval blocks
  (`#chez-eval-block?`); injecting a whole comment makes the child tree
  contain the same block again → stack overflow while typing.
- **Custom query predicates/directives** are registered in `plugin/chez.lua`.
  Queries using them fail entirely if that file was not sourced.
- **`queries/scheme/highlights.scm` is generated** by
  `scripts/gen-highlights.lua` (`make generate`): edit the script (it is a
  `string.format` template, so `%` is written `%%`) and regenerate.
- **Results must be cleared on re-runs**, not only where new results appear:
  e.g. an #eval run removes all marks of the previous run (`results[buf]`),
  loading a file clears the buffer's inline results, writing a file re-checks
  the project's other buffers.
- **undo_ftplugin** entries are joined with `|`; `:lua` would swallow the rest
  of the line, so wrap Lua in `exe "lua …"`.
- Buffer-local Insert mappings for brackets must win over autopair plugins
  (mini.pairs); `tests/lua/pairs_spec.lua` loads mini.pairs when installed.
