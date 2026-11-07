---@class chez.Config
local M = {}

---@class chez.Options
local defaults = {
  -- How to recognise a Chez Scheme buffer among `scheme` buffers.
  detect = {
    -- Treat every *.scm file as Chez Scheme. When false, a .scm file is Chez
    -- only if it contains `#!chezscheme` near the top or the project root
    -- contains one of `markers`.
    scm = false,
    -- Extensions that are always Chez Scheme.
    extensions = { "ss", "sls", "sps", "sch" },
    -- Files/dirs marking a Chez project root (also used for .scm detection).
    markers = { ".chez-project" },
  },
  -- Project root detection (library-directories, REPL working directory).
  root_markers = { ".chez-project", ".git", "Akku.manifest" },
  indent = {
    enabled = true,
    -- Extra/overriding indentation rules: symbol -> number of distinguished
    -- arguments (body is indented by 2 after them), or `false` to indent the
    -- form like an ordinary procedure call.
    rules = {},
    -- Symbols starting with "def" are treated as having 0 distinguished args.
    def_prefix = true,
  },
  editing = {
    -- Insert ' and ` literally (prevents autopair plugins pairing them).
    literal_quotes = true,
    -- Handle ( [ ) ] using the bracket balance of the whole top-level form
    -- instead of the current line (overrides autopair plugins for these keys).
    smart_brackets = true,
  },
  brackets = {
    -- Colour brackets by nesting depth.
    rainbow = true,
    -- Give the innermost list around the cursor a background (ChezCurrentForm).
    current_form = true,
  },
  repl = {
    -- Chez executable and extra arguments; chez.nvim appends
    -- `--libdirs <plugin>/scheme --script <plugin>/scheme/server.ss`.
    cmd = { "chez", "-q" },
    -- Library directories relative to the project root, added when they exist.
    libdirs = { ".", "src", "lib" },
    -- print-length / print-level used when printing results.
    print_length = 200,
    print_level = 30,
    -- REPL window: "right" | "left" | "bottom" | "top" | "float"
    position = "right",
    -- Width (right/left) or height (bottom/top) as a fraction of the editor.
    size = 0.4,
    -- Open the REPL window (without focusing it) when a REPL starts.
    open_on_start = true,
    prompt = "λ> ",
    continuation_prompt = ".. ",
    -- After evaluating a `(library (name) ...)` form, import it into the REPL.
    auto_import = true,
    history_size = 500,
    -- Show the completion menu while typing in the REPL window (Neovim 0.12
    -- 'autocomplete'); <Tab> completes either way.
    autocomplete = true,
  },
  diagnostics = {
    -- Check buffers with a separate Chez process (reads and expands the code,
    -- does not run it): syntax errors, unbound identifiers.
    enabled = true,
    -- InsertLeave/TextChanged check unsaved changes (debounced)
    events = { "BufWritePost", "InsertLeave", "TextChanged" },
    debounce = 500,
    -- also check when a buffer is opened
    on_attach = true,
    timeout = 10000,
  },
  -- `#| #eval ... |#` blocks: evaluated by a fresh Chez process that loads
  -- the whole file (and the libraries it imports) first.
  eval_blocks = {
    -- evaluate the blocks whenever the buffer is written
    on_save = false,
    -- kill the process after this many milliseconds
    timeout = 10000,
  },
  inline = {
    -- Show evaluation results as virtual text after the evaluated form.
    enabled = true,
    max_width = 80,
    -- Briefly highlight the evaluated region.
    flash = true,
  },
  -- Buffer-local keymaps under <localleader>; set to false to disable all,
  -- or set individual entries to false.
  keymaps = {
    eval_form = "<localleader>ee",
    eval_root = "<localleader>er",
    eval_word = "<localleader>ew",
    eval_buffer = "<localleader>eb",
    eval_file = "<localleader>ef",
    eval_selection = "<localleader>E",
    eval_operator = "<localleader>E",
    eval_blocks = "<localleader>ei",
    show_result = "<localleader>ev",
    clear_results = "<localleader>ec",
    backtrace = "<localleader>eq",
    repl_start = "<localleader>cs",
    repl_restart = "<localleader>cr",
    repl_stop = "<localleader>cq",
    repl_interrupt = "<localleader>ci",
    repl_toggle = "<localleader>ct",
    repl_focus = "<localleader>cf",
    macro_expand = "<localleader>mx",
    macro_expand_optimize = "<localleader>mo",
    trace = "<localleader>tt",
    docs_online = "<localleader>hd",
    -- jump to the matching bracket (Normal, Visual, Operator-pending);
    -- ignores brackets in strings/comments/#\(, `N%` still works
    jump_pair = "%",
    -- global-style keys, mapped buffer-locally in Chez buffers
    hover = "K",
    definition = "gd",
    signature = "<C-k>",
  },
}

---@type chez.Options
M.options = vim.deepcopy(defaults)

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

return setmetatable(M, {
  __index = function(_, k)
    return M.options[k]
  end,
})
