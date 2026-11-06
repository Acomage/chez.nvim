#!chezscheme
;;; Static check of a Chez Scheme source file for chez.nvim diagnostics.
;;;
;;; The file is read with source annotations and expanded without running
;;; any top-level code:
;;;   - library forms are compiled (their bodies are not invoked) and import
;;;     forms are processed, so later forms can use them;
;;;   - all other top-level forms are expanded together inside one lambda body
;;;     (definitions first), so syntax errors are reported with positions;
;;;   - free variables of the expansion that are not bound in the environment
;;;     are reported as unbound.
;;;
;;; Output: one JSON object {"diagnostics": [...]}; each diagnostic has a
;;; message, a severity, and optionally pos (character offset of the form) or
;;; name (an unbound identifier).
(library (chez-nvim check)
  (export check-port)
  (import (chezscheme) (chez-nvim json))

  (define (condition->string c)
    (guard (e [#t (format "~s" c)])
      (if (condition? c)
          (call-with-string-output-port (lambda (p) (display-condition c p)))
          (format "non-condition object raised: ~s" c))))

  (define diagnostics '())

  (define (report! severity message . extra)
    (set! diagnostics
      (cons `((severity . ,severity) (message . ,message) ,@extra) diagnostics)))

  (define (form-pos x)
    (and (annotation? x)
         (source-object-bfp (annotation-source x))))

  ;; Run thunk; report errors (with the position of `form` as a fallback)
  ;; and warnings. Returns #t on success.
  (define (attempt form thunk)
    (call/cc
      (lambda (k)
        (with-exception-handler
          (lambda (c)
            (if (and (condition? c) (warning? c))
                (begin
                  (report! "warning" (condition->string c) `(pos . ,(or (form-pos form) 'null)))
                  (void))
                (begin
                  (report! "error" (condition->string c) `(pos . ,(or (form-pos form) 'null)))
                  (k #f))))
          (lambda () (thunk) #t)))))

  (define definers
    '(define define-syntax define-record-type define-values define-integrable
      define-inline trace-define trace-define-syntax define-structure
      define-enumeration define-condition-type define-ftype define-property
      define-record module meta alias))

  (define (head x)
    (let ([d (if (annotation? x) (annotation-stripped x) x)])
      (and (pair? d) (symbol? (car d)) (car d))))

  (define (definition? x)
    (let ([h (head x)])
      (and h (or (memq h definers)
                 (let ([s (symbol->string h)])
                   (and (>= (string-length s) 6) (string=? (substring s 0 6) "define")))))))

  (define (defined-name x)
    (let ([d (annotation-stripped x)])
      (and (pair? d) (pair? (cdr d))
           (let loop ([t (cadr d)])
             (cond
               [(symbol? t) t]
               [(pair? t) (loop (car t))]
               [else #f])))))

  ;; Free (non-gensym) variables in the output of `expand`.
  (define skip-heads
    '(foreign-procedure $foreign-procedure foreign-callable $foreign-callable
      $primitive quote profile $moi))

  (define (free-variables x)
    (let ([acc '()])
      (define (var! s)
        (unless (or (gensym? s) (memq s acc))
          (set! acc (cons s acc))))
      (define (walk-list xs)
        (when (pair? xs)
          (walk (car xs))
          (walk-list (cdr xs))))
      ;; (($primitive n $top-level-value) 'g): reference to a top-level
      ;; variable of a non-interaction environment ('g may be a gensym)
      (define (top-level-access? x)
        (and (pair? x) (pair? (car x)) (eq? (caar x) '$primitive)
             (memq (car (last-pair (car x))) '($top-level-value $set-top-level-value!))
             (pair? (cdr x)) (pair? (cadr x)) (eq? (caadr x) 'quote)
             (symbol? (cadadr x))))
      (define (walk x)
        (cond
          [(symbol? x) (var! x)]
          [(top-level-access? x)
           (let ([s (string->symbol (symbol->string (cadadr x)))])
             (unless (memq s acc) (set! acc (cons s acc))))
           (walk-list (cddr x))]
          [(pair? x)
           (let ([h (car x)])
             (cond
               [(and (symbol? h) (memq h skip-heads)) (void)]
               [(eq? h 'lambda) (walk-list (cddr x))]
               [(eq? h 'case-lambda)
                (for-each (lambda (cl) (when (pair? cl) (walk-list (cdr cl)))) (cdr x))]
               [(memq h '(let letrec letrec*))
                (for-each (lambda (b) (when (and (pair? b) (pair? (cdr b))) (walk (cadr b))))
                          (cadr x))
                (walk-list (cddr x))]
               [(memq h '(if begin pariah)) (walk-list (cdr x))]
               [(eq? h 'set!) (walk-list (cdr x))]
               [else (walk-list x)]))]
          [else (void)]))
      (walk x)
      (reverse acc)))

  (define (read-forms ip sfd)
    (let loop ([bfp 0] [acc '()])
      (let-values ([(x next) (get-datum/annotations ip sfd bfp)])
        (if (eof-object? x)
            (reverse acc)
            (loop next (cons x acc))))))

  (define (check-port name ip bytes)
    (let* ([env (copy-environment (interaction-environment) #t)]
           [sfd (make-source-file-descriptor name (open-bytevector-input-port bytes))]
           [forms '()])
      (when (attempt #f (lambda () (set! forms (read-forms ip sfd))))
        (let loop ([forms forms] [defs '()] [names '()] [exprs '()])
          (if (null? forms)
              (let ([body `(lambda () ,@(reverse defs) (begin ,@(reverse exprs) (void)))])
                (attempt #f
                  (lambda ()
                    (let ([expanded (expand body env)])
                      (for-each
                        (lambda (s)
                          (unless (top-level-bound? s env)
                            (report! "warning"
                                     (format "variable ~a is not bound" s)
                                     `(name . ,(symbol->string s)))))
                        (free-variables expanded))))))
              (let ([x (car forms)])
                (case (head x)
                  [(library import top-level-program)
                   (attempt x (lambda () (eval x env)))
                   (loop (cdr forms) defs names exprs)]
                  [else
                   (if (definition? x)
                       (let ([n (defined-name x)])
                         ;; drop redefinitions: duplicate internal definitions
                         ;; would be errors in the combined body
                         (if (and n (memq n names))
                             (loop (cdr forms) defs names exprs)
                             (loop (cdr forms) (cons x defs) (if n (cons n names) names) exprs)))
                       (loop (cdr forms) defs names (cons x exprs)))])))))
      `((diagnostics . ,(list->vector (reverse diagnostics)))))))
