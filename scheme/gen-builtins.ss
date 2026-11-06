;;; Generate data/builtins.json: every identifier exported by (chezscheme)
;;; with its kind and, for procedures, its arity mask.
;;;
;;;   chez --libdirs scheme --script scheme/gen-builtins.ss > data/builtins.json
(import (chezscheme) (chez-nvim json))

(define env (scheme-environment))
(define rnrs (environment '(rnrs) '(rnrs eval) '(rnrs mutable-pairs)
                          '(rnrs mutable-strings) '(rnrs r5rs)))
(define rnrs-syms
  (let ([ht (make-eq-hashtable)])
    (for-each (lambda (s) (hashtable-set! ht s #t)) (environment-symbols rnrs))
    ht))

(define (entry s)
  (let ([v (guard (c [#t c]) (eval s env))])
    `((name . ,(symbol->string s))
      (kind . ,(cond [(condition? v) "syntax"]
                     [(procedure? v) "procedure"]
                     [else "variable"]))
      ,@(if (procedure? v) `((arity . ,(procedure-arity-mask v))) '())
      (rnrs . ,(hashtable-contains? rnrs-syms s)))))

(define syms
  (sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
        (environment-symbols env)))

(json-write
  `((version . ,(scheme-version))
    (symbols . ,(list->vector (map entry syms)))))
(newline)
