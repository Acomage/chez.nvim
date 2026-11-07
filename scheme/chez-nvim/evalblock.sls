#!chezscheme
;;; Evaluation of `#| #eval ... |#` blocks for chez.nvim.
;;;
;;; Runs in a fresh Chez process, so the file and every library it imports
;;; are loaded from scratch:
;;;   1. the file's top-level forms are evaluated in order. A library form is
;;;      defined (so later imports of it work) and then its imports and body
;;;      are also evaluated at top level, so blocks can use the library's
;;;      internal definitions; a top-level-program is evaluated as its imports
;;;      and body;
;;;   2. the expressions of each block are evaluated one by one.
;;;
;;; Results are reported as they are produced (see run-blocks). Output written
;;; by the code is captured per form; standard input is empty.
(library (chez-nvim evalblock)
  (export run-blocks)
  (import (chezscheme) (chez-nvim json) (chez-nvim common))

  (define (unwrap x)
    (if (annotation? x) (annotation-expression x) x))

  (define (head x)
    (let ([d (unwrap x)])
      (and (pair? d)
           (let ([h (unwrap (car d))])
             (and (symbol? h) h)))))

  ;; ((bfp . n) (efp . m)) of an annotated datum
  (define (span x)
    (if (annotation? x)
        (let ([s (annotation-source x)])
          `((bfp . ,(source-object-bfp s)) (efp . ,(source-object-efp s))))
        '()))

  ;; Run thunk with captured output and empty input.
  ;; Returns (values 'ok list-of-values output) | (values 'error condition output)
  (define (attempt thunk)
    (let* ([out (open-output-string)]
           [r (call/cc
                (lambda (k)
                  (with-exception-handler
                    (lambda (c)
                      (if (and (condition? c) (warning? c))
                          (begin
                            (display (condition->string c) out)
                            (newline out)
                            (void))
                          (k (cons 'error c))))
                    (lambda ()
                      (parameterize ([current-output-port out]
                                     [console-output-port out]
                                     [current-error-port out]
                                     [console-error-port out]
                                     [trace-output-port out]
                                     [current-input-port (open-input-string "")]
                                     [console-input-port (open-input-string "")])
                        (cons 'ok (call-with-values thunk list)))))))])
      (values (car r) (cdr r) (get-output-string out))))

  (define (read-annotated sfd str offset)
    (let ([ip (open-string-input-port str)])
      (let loop ([bfp offset] [acc '()])
        (let-values ([(x next) (get-datum/annotations ip sfd bfp)])
          (if (eof-object? x)
              (reverse acc)
              (loop next (cons x acc)))))))

  ;; Forms evaluated at top level after `x` itself was evaluated.
  (define (library-parts x)
    (let ([d (unwrap x)])
      (if (and (list? d) (>= (length d) 4) (eq? (head (cadddr d)) 'import))
          (cons (cadddr d) (cddddr d))
          '())))

  ;; Evaluate the blocks of a file.
  ;;   req: ((name . file) (code . text)
  ;;         (blocks . #(((offset . n) (code . text)) ...))
  ;;         (print_length . n) (print_level . n))
  ;;   emit: called with one alist per result:
  ;;     ((phase . "load") (ok . #f) (error ...) [bfp efp])  a top-level form failed
  ;;     ((phase . "eval") (block . i) (bfp . n) (efp . m) (ok . b)
  ;;      (values . #(...)) | (error ...) (output . s))     a block expression
  ;;     ((phase . "done"))
  ;; Positions are character offsets in `code`.
  (define (run-blocks req emit)
    (let* ([name (ref req 'name "buffer")]
           [code (ref req 'code "")]
           [blocks (vector->list (ref req 'blocks '#()))]
           [plen (ref req 'print_length 200)]
           [plev (ref req 'print_level 30)]
           [sfd (make-source-file-descriptor name
                  (open-bytevector-input-port (string->utf8 code)))]
           [env (interaction-environment)])
      (define (write-value v)
        (parameterize ([print-length plen] [print-level plev])
          (call-with-string-output-port (lambda (p) (write v p)))))
      (define (fields tag payload output)
        (if (eq? tag 'ok)
            `((ok . #t)
              (values . ,(list->vector
                           (map write-value
                                (filter (lambda (v) (not (eq? v (void)))) payload))))
              (output . ,output))
            `((ok . #f)
              (error . ((message . ,(condition->string payload))))
              (output . ,output))))
      (define (load-form x)
        (let-values ([(tag payload output) (attempt (lambda () (eval x env)))])
          (if (eq? tag 'ok)
              #t
              (begin
                (emit `((phase . "load") ,@(span x) ,@(fields tag payload output)))
                #f))))
      ;; 1. the file
      (let-values ([(tag payload output) (attempt (lambda () (read-annotated sfd code 0)))])
        (if (eq? tag 'ok)
            (for-each
              (lambda (x)
                (case (head x)
                  [(library)
                   (when (load-form x)
                     (for-each load-form (library-parts x)))]
                  [(top-level-program)
                   (for-each load-form (cdr (unwrap x)))]
                  [else (load-form x)]))
              (car payload))
            (emit `((phase . "load") ,@(fields tag payload output)))))
      ;; 2. the blocks
      (let loop ([bs blocks] [i 1])
        (unless (null? bs)
          (let ([offset (ref (car bs) 'offset 0)])
            (let-values ([(tag payload output)
                          (attempt (lambda () (read-annotated sfd (ref (car bs) 'code "") offset)))])
              (if (eq? tag 'ok)
                  (for-each
                    (lambda (x)
                      (let-values ([(tag payload output) (attempt (lambda () (eval x env)))])
                        (emit `((phase . "eval") (block . ,i) ,@(span x)
                                ,@(fields tag payload output)))))
                    (car payload))
                  (emit `((phase . "eval") (block . ,i) (bfp . ,offset) (efp . ,offset)
                          ,@(fields tag payload output))))))
          (loop (cdr bs) (+ i 1))))
      (emit '((phase . "done"))))))
