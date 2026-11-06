local format = require("chez.format")
local indent = require("chez.indent")
local config = require("chez.config")

-- Each case is written correctly indented; the test strips all indentation
-- and checks that the formatter restores it.
local function check(src)
  local expected = vim.split(src, "\n", { plain = true })
  local flat = vim.tbl_map(function(l)
    return (l:gsub("^%s+", ""))
  end, expected)
  assert.are.same(expected, format.format_lines(flat))
end

describe("indent", function()
  before_each(function()
    config.setup({})
  end)

  it("indents define bodies and procedure calls", function()
    check([[
(define (f x)
  (g x
     (h x)))
(define y
  (foo
   bar
   baz))]])
  end)

  it("handles let, named let and let bindings", function()
    check([[
(let ([a 1]
      [b 2])
  (+ a b))
(let loop ([i 0])
  (when (< i 10)
    (loop (+ i 1))))
(let
    ([a 1])
  a)]])
  end)

  it("handles if/cond/case and brackets", function()
    check([[
(if (null? x)
    '()
    (cons 1 x))
(cond
 [(a) b]
 [else
  c])
(case x
  [(1) 'one]
  [else 'other])]])
  end)

  it("handles library, syntax-case and do", function()
    check([[
(library (foo bar)
  (export f)
  (import (chezscheme))
  (define-syntax m
    (lambda (x)
      (syntax-case x ()
        [(_ e)
         #'(begin e
             e)])))
  (do ([i 0 (+ i 1)])
      ((= i 3))
    (display i)))]])
  end)

  it("aligns quoted data and vectors with the first element", function()
    check([[
(define xs '(a b
             c (d e
                f)))
(define v #(1 2
            3))
(define bv #vu8(1 2
                3))
(define qq `(a ,(f x
                   y)
             b))]])
  end)

  it("ignores brackets in strings, chars and comments", function()
    check([[
(define (p)
  (display "(((")
  (display #\()
  (display #\))
  ; ((((
  #| ((( |#
  (display |a(b|)
  (list #\space
        #\x41))]])
  end)

  it("keeps lines that start inside strings or block comments", function()
    local lines = { "(define s", '  "abc', "     def", '  ghi")', "#|", "   keep", "|#" }
    local flat = { "(define s", '"abc', "     def", '  ghi")', "#|", "   keep", "|#" }
    assert.are.same(lines, format.format_lines(flat))
  end)

  it("skips datum comments when counting arguments", function()
    check([[
(foo #;skipped bar
               baz)
(let #;(x) ([a 1])
  a)]])
  end)

  it("measures display width of multibyte symbols", function()
    check([[
(λ (x)
  (f x))
(αβγ x
     y)]])
  end)

  it("honours user rules", function()
    config.setup({ indent = { rules = { ["my-when"] = 1, ["define-foo"] = false } } })
    check([[
(my-when x
  y)
(define-foo a
            b)]])
  end)

  it("uses the buffer cache consistently with the formatter", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local src = {}
    for i = 1, 40 do
      src[#src + 1] = "(define (f" .. i .. " x)"
      src[#src + 1] = "(let ([y x])"
      src[#src + 1] = "(+ x y)))"
    end
    local expected = format.format_lines(src)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, expected)
    indent.attach(buf)
    for lnum, line in ipairs(expected) do
      assert.are.equal(#line:match("^%s*"), indent.indentexpr(lnum))
    end
    -- edit near the top: cached states below must be invalidated
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "      (begin (list" })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local s = indent.new_state()
    for lnum, line in ipairs(lines) do
      assert.are.equal(indent.compute(s), indent.indentexpr(lnum), "line " .. lnum)
      indent.feed(s, line, lnum - 1)
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
