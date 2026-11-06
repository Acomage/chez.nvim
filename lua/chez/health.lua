local M = {}

function M.check()
  local h = vim.health
  local config = require("chez.config")
  local util = require("chez.util")

  h.start("chez.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.11 or newer is required")
  end

  local exe = config.repl.cmd[1]
  if vim.fn.executable(exe) == 1 then
    local res = vim.system({ exe, "--version" }, { text = true }):wait()
    local version = vim.trim((res.stdout or "") .. (res.stderr or ""))
    h.ok(("Chez Scheme: %s (%s)"):format(version, vim.fn.exepath(exe)))
    -- the bridge must load
    local probe = vim.system(
      vim.list_extend(vim.deepcopy(config.repl.cmd), {
        "--libdirs", util.plugin_root .. "/scheme", "--script", util.plugin_root .. "/scheme/server.ss",
      }),
      { stdin = "", text = true, timeout = 10000 }
    ):wait()
    if (probe.stdout or ""):find('"event":"ready"', 1, true) then
      h.ok("REPL bridge starts")
    else
      h.error("REPL bridge failed to start: " .. vim.trim((probe.stderr or "") .. (probe.stdout or "")))
    end
  else
    h.error(("`%s` not found; set `repl.cmd` (e.g. { \"scheme\", \"-q\" })"):format(exe))
  end

  local ok_parser = pcall(vim.treesitter.language.inspect, "scheme")
  if ok_parser then
    h.ok("tree-sitter parser: scheme")
  else
    h.error("tree-sitter parser for scheme is missing", { "Run :TSInstall scheme" })
  end

  for _, f in ipairs({ "builtins.json", "docs.json" }) do
    if vim.uv.fs_stat(util.plugin_root .. "/data/" .. f) then
      h.ok("data/" .. f)
    else
      h.warn("data/" .. f .. " is missing (run `make generate`)")
    end
  end

  if pcall(require, "blink.cmp") then
    h.ok("blink.cmp found: add the `chez.complete.blink` provider (see :h chez-completion)")
  else
    h.info("blink.cmp not found: completion is available through 'omnifunc'")
  end
  if vim.fn.executable("rg") == 1 then
    h.ok("ripgrep found (project-wide go to definition)")
  else
    h.warn("ripgrep not found: go to definition only searches buffers and the REPL")
  end

  local repl = package.loaded["chez.repl"]
  if repl then
    for root, s in pairs(repl.sessions) do
      h.info(("REPL %s: %s"):format(vim.fn.fnamemodify(root, ":~"), s:alive() and ("running, pid " .. tostring(s.pid)) or "stopped"))
    end
  end
end

return M
