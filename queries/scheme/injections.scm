; extends
; chez.nvim: the code in #| #eval ... |# blocks is parsed as Scheme
((block_comment) @injection.content
  (#lua-match? @injection.content "^#|%s*#eval%s")
  (#chez-eval-block! @injection.content)
  (#set! injection.language "scheme"))
