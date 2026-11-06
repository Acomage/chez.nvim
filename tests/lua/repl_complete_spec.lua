local config = require("chez.config")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.fn.writefile({}, tmp .. "/.chez-project")

describe("REPL completion", function()
  config.setup({ repl = { open_on_start = false }, diagnostics = { enabled = false } })
  local repl = require("chez.repl")
  local ui = require("chez.repl.ui")
  local complete = require("chez.complete")
  local s, rbuf

  local function idle()
    return vim.wait(5000, function()
      return s.ready and not s:busy()
    end, 10)
  end

  it("offers REPL bindings and unevaluated project definitions", function()
    vim.fn.writefile({ "(define (proj-helper a b)", "  (+ a b))" }, tmp .. "/lib.ss")
    vim.cmd("edit " .. tmp .. "/lib.ss")
    s = repl.ensure(0)
    assert.is_true(idle())
    s:request("eval", { code = "(define (my-fun x) x) (define my-var 1)" })
    assert.is_true(idle())
    -- names are refreshed in the background after the evaluation
    assert.is_true(vim.wait(3000, function()
      local names = complete.repl_names_now(0) or {}
      return #names >= 2
    end, 10))

    rbuf = ui.buf(s)
    vim.api.nvim_set_current_buf(rbuf)
    local n = vim.api.nvim_buf_line_count(rbuf)
    vim.api.nvim_buf_set_lines(rbuf, n - 1, n, false, { "λ> (my-" })
    vim.api.nvim_win_set_cursor(0, { n, #"λ> (my-" })
    local start = complete.omnifunc(1, "")
    assert.are.equal(#"λ> (", start)
    local items = complete.omnifunc(0, "my-")
    local by = {}
    for _, it in ipairs(items) do
      by[it.word] = it
    end
    assert.are.equal("[repl]", by["my-fun"].menu)
    assert.are.equal("[repl]", by["my-var"].menu)

    local proj = complete.omnifunc(0, "proj-")
    assert.are.equal("proj-helper", proj[1].word)
    assert.are.equal("[project]", proj[1].menu)
    assert.are.equal("(proj-helper a b)", proj[1].info)

    local lh = complete.omnifunc(0, "list-he")
    assert.are.equal("(list-head list n)", lh[1].info)
  end)

  it("completes with <Tab> at the prompt", function()
    vim.api.nvim_set_current_buf(rbuf)
    vim.o.autocomplete = false -- deterministic: only <Tab> opens the menu
    vim.opt_local.autocomplete = false
    local n = vim.api.nvim_buf_line_count(rbuf)
    -- (typed text is set directly: with feedkeys typeahead an <expr> mapping
    -- would not see the characters typed just before it)
    vim.api.nvim_buf_set_lines(rbuf, n - 1, n, false, { "λ> (my-f" })
    vim.api.nvim_feedkeys(vim.keycode("A<Tab><Tab><C-y><Esc>"), "xt", false)
    assert.are.equal("λ> (my-fun", vim.api.nvim_buf_get_lines(rbuf, n - 1, n, false)[1])
    repl.stop_all()
  end)
end)
