#!chezscheme
;;; Helpers shared by the chez.nvim Scheme programs (REPL server, checker,
;;; #eval block runner).
(library (chez-nvim common)
  (export condition->string ref)
  (import (chezscheme))

  ;; Message of a raised object as display-condition writes it.
  (define (condition->string c)
    (guard (e [#t (format "~s" c)])
      (if (condition? c)
          (call-with-string-output-port (lambda (p) (display-condition c p)))
          (format "non-condition object raised: ~s" c))))

  ;; Value of `key` in a JSON object (alist), or the optional default (#f)
  ;; when it is missing or null.
  (define (ref msg key . default)
    (let ([p (and (list? msg) (assq key msg))])
      (cond
        [(and p (not (eq? (cdr p) 'null))) (cdr p)]
        [(pair? default) (car default)]
        [else #f]))))
