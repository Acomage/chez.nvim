#!chezscheme
;;; chez.nvim REPL bridge.
;;;
;;; Neovim talks to this server over stdin/stdout. Every message is one line of
;;; JSON. Messages from the server start with the record separator character
;;; U+001E so that stray output written straight to the process's stdout (FFI,
;;; standard-output-port, ...) can be told apart from protocol traffic.
;;;
;;; Requests  (nvim -> chez): {"id": n, "op": "<op>", ...}
;;; Responses (chez -> nvim): {"id": n, "ok": true, ...}
;;;                           {"id": n, "ok": false, "error": {...}}
;;; Events    (chez -> nvim): {"event": "ready" | "out" | "input", ...}
;;; Input     (nvim -> chez): {"op": "input", "text": "..."} | {"op": "input", "eof": true}
(library (chez-nvim server)
  (export serve)
  (import (chezscheme) (chez-nvim json) (chez-nvim common))

  ;; ------------------------------------------------------------ transport

  (define proto-in #f)
  (define proto-out #f)
  (define queued '())          ; requests read while user code awaited input
  (define current-id #f)       ; id of the request being evaluated
  (define abort-k #f)          ; escape continuation of the running evaluation
  (define result-print-length 200)
  (define result-print-level 30)

  (define (send msg)
    (put-char proto-out #\x1e)
    (json-write msg proto-out)
    (newline proto-out)
    (flush-output-port proto-out))

  (define (read-message)
    (let ([line (get-line proto-in)])
      (cond
        [(eof-object? line) line]
        [(string=? line "") (read-message)]
        [else
         (guard (c [#t (send `((event . "protocol-error")
                               (message . ,(condition->string c))
                               (line . ,line)))
                       (read-message)])
           (string->json line))])))

  (define (next-request)
    (if (null? queued)
        (read-message)
        (let ([r (car queued)])
          (set! queued (cdr queued))
          r)))

  ;; ------------------------------------------------------------ user ports

  (define (make-forward-port stream)
    (make-custom-textual-output-port stream
      (lambda (s start n)
        (send `((event . "out")
                (id . ,(or current-id 'null))
                (stream . ,stream)
                (text . ,(substring s start (+ start n)))))
        n)
      #f #f #f))

  (define user-out (make-forward-port "out"))
  (define user-err (make-forward-port "err"))

  (define (flush-user-ports)
    (flush-output-port user-out)
    (flush-output-port user-err))

  ;; Input requested by user code is fetched from nvim; other requests that
  ;; arrive in the meantime are queued.
  (define input-buffer "")
  (define input-eof #f)

  (define (fill-input!)
    (flush-user-ports)
    (send `((event . "input") (id . ,(or current-id 'null))))
    (let loop ()
      (let ([msg (read-message)])
        (cond
          [(eof-object? msg) (exit 0)]
          [(equal? (ref msg 'op) "input")
           (if (ref msg 'eof)
               (set! input-eof #t)
               (set! input-buffer (ref msg 'text "")))]
          [else (set! queued (append queued (list msg))) (loop)]))))

  (define user-in
    (make-custom-textual-input-port "nvim"
      (lambda (s start n)
        (when (and (string=? input-buffer "") (not input-eof))
          (fill-input!))
        (if (string=? input-buffer "")
            (begin (set! input-eof #f) 0)
            (let* ([len (string-length input-buffer)]
                   [k (min n len)])
              (string-copy! input-buffer 0 s start k)
              (set! input-buffer (substring input-buffer k len))
              k)))
      #f #f #f))

  ;; ------------------------------------------------------------ errors

  (define (source-path->json path-values)
    ;; inspector source-path: () | (path char) | (path line char)
    (cond
      [(and (= (length path-values) 3) (string? (car path-values)))
       `((file . ,(car path-values)) (line . ,(cadr path-values)) (col . ,(caddr path-values)))]
      [(and (= (length path-values) 2) (string? (car path-values)))
       `((file . ,(car path-values)) (pos . ,(cadr path-values)))]
      [else #f]))

  (define (string-suffix? suf s)
    (let ([n (string-length suf)] [m (string-length s)])
      (and (<= n m) (string=? suf (substring s (- m n) m)))))

  (define (server-file? path)
    (string-suffix? "chez-nvim/server.sls" path))

  (define (backtrace c)
    (guard (e [#t '()])
      (if (and (continuation-condition? c))
          (let loop ([k (inspect/object (condition-continuation c))] [n 0] [acc '()])
            (if (or (>= n 40) (not (eq? (k 'type) 'continuation)))
                (reverse acc)
                (let* ([code (k 'code)]
                       [name (and code (code 'name))]
                       [path (call-with-values (lambda () (k 'source-path)) list)])
                  ;; frames below the evaluation belong to this server
                  (if (and (pair? path) (string? (car path)) (server-file? (car path)))
                      (reverse acc)
                      (let ([src (source-path->json path)])
                        (loop (k 'link) (+ n 1)
                              (if src
                                  (cons `((name . ,(or name 'null)) ,@src) acc)
                                  acc)))))))
          '())))

  (define (condition-kind c)
    (cond
      [(not (condition? c)) "raise"]
      [(syntax-violation? c) "syntax"]
      [(undefined-violation? c) "undefined"]
      [(assertion-violation? c) "assertion"]
      [(i/o-error? c) "io"]
      [(lexical-violation? c) "lexical"]
      [(violation? c) "violation"]
      [(error? c) "error"]
      [(warning? c) "warning"]
      [else "condition"]))

  (define (error-info c)
    (guard (e [#t `((message . ,(condition->string c)) (kind . "error"))])
      `((message . ,(condition->string c))
        (kind . ,(condition-kind c))
        ,@(if (and (condition? c) (who-condition? c))
              `((who . ,(format "~a" (condition-who c))))
              '())
        (frames . ,(backtrace c)))))

  ;; ------------------------------------------------------------ evaluation

  ;; Run thunk with user ports and error handling. Returns
  ;; (ok . value) | (error . info) | (interrupted)
  (define (with-eval-context id thunk)
    (set! current-id id)
    (let ([result
           (call/cc
             (lambda (k)
               (dynamic-wind
                 (lambda () (set! abort-k k))
                 (lambda ()
                   (parameterize ([current-output-port user-out]
                                  [current-error-port user-err]
                                  [console-output-port user-out]
                                  [console-error-port user-err]
                                  [trace-output-port user-out]
                                  [current-input-port user-in]
                                  [console-input-port user-in])
                     (with-exception-handler
                       (lambda (c)
                         (if (and (condition? c) (warning? c))
                             (begin
                               (display (condition->string c) user-err)
                               (newline user-err)
                               (void))
                             (k (cons 'error (error-info c)))))
                       (lambda () (cons 'ok (thunk))))))
                 (lambda ()
                   (set! abort-k #f)
                   (guard (e [#t #f]) (flush-user-ports))))))])
      (set! current-id #f)
      (set! input-buffer "")
      (set! input-eof #f)
      result))

  (define (respond id result fields)
    (case (car result)
      [(ok) (send `((id . ,id) (ok . #t) ,@(fields (cdr result))))]
      [(error) (send `((id . ,id) (ok . #f) (error . ,(cdr result))))]
      [(interrupted)
       (send `((id . ,id) (ok . #f)
               (error . ((message . "interrupted") (kind . "interrupt")))))]
      [else (send `((id . ,id) (ok . #f)
                    (error . ((message . ,(format "~s" result)) (kind . "error")))))]))

  (define pretty-threshold 80)

  (define (pretty-value v)
    (parameterize ([print-length result-print-length]
                   [print-level result-print-level]
                   [pretty-line-length 80])
      (let ([s (call-with-string-output-port (lambda (p) (pretty-print v p)))])
        ;; drop pretty-print's trailing newline
        (if (and (> (string-length s) 0)
                 (char=? (string-ref s (- (string-length s) 1)) #\newline))
            (substring s 0 (- (string-length s) 1))
            s))))

  (define (write-value v)
    (parameterize ([print-length result-print-length]
                   [print-level result-print-level])
      (call-with-string-output-port (lambda (p) (write v p)))))

  ;; Read all data from `code`; with a file name, the data carry source
  ;; annotations whose positions are character offsets from `offset`.
  (define (read-all code file offset)
    (let ([ip (open-input-string code)])
      (if file
          (let ([sfd (make-source-file-descriptor file
                       (open-bytevector-input-port (string->utf8 code)))])
            (let loop ([bfp offset] [acc '()])
              (let-values ([(x next) (get-datum/annotations ip sfd bfp)])
                (if (eof-object? x)
                    (reverse acc)
                    (loop next (cons x acc))))))
          (let loop ([acc '()])
            (let ([x (get-datum ip)])
              (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))

  (define (eval-all code file offset)
    (let loop ([forms (read-all code file offset)] [vals '()])
      (if (null? forms)
          vals
          (loop (cdr forms)
                (call-with-values
                  (lambda () (eval (car forms) (interaction-environment)))
                  list)))))

  (define (op-eval id msg)
    (respond id
      (with-eval-context id
        (lambda ()
          (eval-all (ref msg 'code "") (ref msg 'file) (ref msg 'offset 0))))
      (lambda (vals)
        (let* ([vals (filter (lambda (v) (not (eq? v (void)))) vals)]
               [strs (map write-value vals)])
          `((values . ,(list->vector strs))
            ;; multi-line rendering of long values (null when short)
            (pretty . ,(list->vector
                         (map (lambda (v s)
                                (if (> (string-length s) pretty-threshold)
                                    (pretty-value v)
                                    'null))
                              vals strs))))))))

  (define (op-load id msg)
    (respond id
      (with-eval-context id (lambda () (load (ref msg 'file)) (void)))
      (lambda (_) `((values . #())))))

  ;; ($primitive 3 car) / ($primitive car) -> car, for readable expansions
  (define (strip-primitives x)
    (cond
      [(and (pair? x) (eq? (car x) '$primitive) (list? x) (<= 2 (length x) 3))
       (car (last-pair x))]
      [(pair? x) (cons (strip-primitives (car x)) (strip-primitives (cdr x)))]
      [(vector? x) (vector-map strip-primitives x)]
      [else x]))

  (define (op-expand id msg)
    (let ([optimize (ref msg 'optimize #f)])
      (respond id
        (with-eval-context id
          (lambda ()
            (map (lambda (form)
                   (let ([x (if optimize
                                (expand/optimize form (interaction-environment))
                                (expand form (interaction-environment)))])
                     (parameterize ([print-gensym #f])
                       (call-with-string-output-port
                         (lambda (p) (pretty-print (strip-primitives x) p))))))
                 (read-all (ref msg 'code "") #f 0))))
        (lambda (strs) `((expansions . ,(list->vector strs)))))))

  ;; ------------------------------------------------------------ introspection

  (define (binding-kind sym)
    (guard (c [#t "syntax"])
      (let ([v (interpret sym (interaction-environment))])
        (if (procedure? v) "procedure" "variable"))))

  (define (string-prefix? pre s)
    (let ([n (string-length pre)])
      (and (<= n (string-length s))
           (string=? pre (substring s 0 n)))))

  (define (op-complete id msg)
    (let* ([prefix (ref msg 'prefix "")]
           [limit (ref msg 'limit 500)]
           [syms (environment-symbols (interaction-environment))]
           [matches (filter (lambda (s) (string-prefix? prefix (symbol->string s))) syms)]
           [matches (list-head matches (min limit (length matches)))])
      (send `((id . ,id) (ok . #t)
              (candidates . ,(list->vector
                               (map (lambda (s)
                                      `((name . ,(symbol->string s))
                                        (kind . ,(binding-kind s))))
                                    matches)))))))

  (define (procedure-location v)
    (guard (c [#t #f])
      (let ([code ((inspect/object v) 'code)])
        (source-path->json (call-with-values (lambda () (code 'source-path)) list)))))

  (define (op-describe id msg)
    (let* ([name (ref msg 'name "")]
           [sym (string->symbol name)]
           [env (interaction-environment)])
      (if (not (memq sym (environment-symbols env)))
          (send `((id . ,id) (ok . #t) (bound . #f)))
          (let ([kind (binding-kind sym)])
            (if (string=? kind "syntax")
                (send `((id . ,id) (ok . #t) (bound . #t) (kind . ,kind)))
                (let ([v (interpret sym env)])
                  (send `((id . ,id) (ok . #t) (bound . #t) (kind . ,kind)
                          ,@(if (procedure? v)
                                `((arity . ,(procedure-arity-mask v))
                                  (location . ,(or (procedure-location v) 'null)))
                                `((value . ,(write-value v))))))))))))

  (define (op-set id msg)
    (let ([dirs (ref msg 'libdirs)]
          [cwd (ref msg 'cwd)])
      (when cwd (current-directory cwd))
      (when (vector? dirs)
        (library-directories
          (append (map (lambda (d) (cons d d)) (vector->list dirs))
                  (library-directories))))
      (let ([pl (ref msg 'print_length)] [pv (ref msg 'print_level)])
        (when (number? pl) (set! result-print-length pl))
        (when (number? pv) (set! result-print-level pv)))
      (send `((id . ,id) (ok . #t)))))

  (define ops
    `(("eval" . ,op-eval)
      ("load" . ,op-load)
      ("expand" . ,op-expand)
      ("complete" . ,op-complete)
      ("describe" . ,op-describe)
      ("set" . ,op-set)
      ("ping" . ,(lambda (id msg) (send `((id . ,id) (ok . #t)))))))

  (define (dispatch msg)
    (let* ([id (ref msg 'id 'null)]
           [op (ref msg 'op)]
           [handler (and (string? op) (assoc op ops))])
      (cond
        [handler
         (guard (c [#t (send `((id . ,id) (ok . #f)
                               (error . ((message . ,(condition->string c))
                                         (kind . "internal")))))])
           ((cdr handler) id msg))]
        [(equal? op "input") (void)] ; stray input reply
        [else
         (send `((id . ,id) (ok . #f)
                 (error . ((message . ,(format "unknown op ~s" op)) (kind . "internal")))))])))

  (define (serve)
    (let ([tx (make-transcoder (utf-8-codec) (eol-style none) (error-handling-mode replace))])
      (set! proto-in (transcoded-port (standard-input-port) tx))
      (set! proto-out (transcoded-port (standard-output-port (buffer-mode block)) tx)))
    (keyboard-interrupt-handler
      (lambda () (when abort-k (abort-k '(interrupted)))))
    (reset-handler
      (lambda () (if abort-k (abort-k '(interrupted)) (exit 0))))
    (send `((event . "ready")
            (version . ,(scheme-version))
            (machine . ,(symbol->string (machine-type)))
            (pid . ,(guard (c [#t 'null])
                      ((foreign-procedure "getpid" () int))))))
    (let loop ()
      (let ([msg (next-request)])
        (unless (eof-object? msg)
          (dispatch msg)
          (loop))))
    (exit 0)))
