#!chezscheme
;;; Minimal JSON reader/writer used by the chez.nvim bridge.
;;;
;;; Scheme <-> JSON mapping
;;;   object  <-> association list with symbol keys, e.g. ((id . 1) (op . "eval"))
;;;               (write `json-empty-object` for {})
;;;   array   <-> vector (lists that are not alists are also written as arrays)
;;;   string  <-> string     (symbols and chars are written as strings)
;;;   number  <-> number     (non-finite flonums are written as null)
;;;   true/false <-> #t / #f
;;;   null    <-> the symbol `null` (void is also written as null)
(library (chez-nvim json)
  (export json-write json->string json-read string->json json-empty-object)
  (import (chezscheme))

  (define json-empty-object (string->symbol "{}"))

  (define (alist? x)
    (and (pair? x)
         (let loop ([x x])
           (or (null? x)
               (and (pair? x) (pair? (car x)) (symbol? (caar x))
                    (loop (cdr x)))))))

  (define (write-string s p)
    (write-char #\" p)
    (string-for-each
      (lambda (c)
        (case c
          [(#\") (put-string p "\\\"")]
          [(#\\) (put-string p "\\\\")]
          [(#\newline) (put-string p "\\n")]
          [(#\return) (put-string p "\\r")]
          [(#\tab) (put-string p "\\t")]
          [else
           (let ([n (char->integer c)])
             (if (or (< n #x20) (= n #x7f) (= n #x2028) (= n #x2029))
                 (begin
                   (put-string p "\\u")
                   (let ([h (string-downcase (number->string n 16))])
                     (put-string p (make-string (- 4 (string-length h)) #\0))
                     (put-string p h)))
                 (write-char c p)))]))
      s)
    (write-char #\" p))

  (define (write-number x p)
    (cond
      [(and (exact? x) (integer? x)) (put-string p (number->string x))]
      [(not (real? x)) (put-string p "null")]
      [else
       (let ([x (inexact x)])
         (if (or (nan? x) (infinite? x))
             (put-string p "null")
             (let ([s (number->string x)])
               ;; Chez writes 1.0 as "1.0" and 1e21 as "1e21": both valid JSON,
               ;; but ".5"/"-.5" forms must be fixed up.
               (cond
                 [(and (> (string-length s) 0) (char=? (string-ref s 0) #\.))
                  (put-string p "0") (put-string p s)]
                 [(and (> (string-length s) 1) (char=? (string-ref s 0) #\-)
                       (char=? (string-ref s 1) #\.))
                  (put-string p "-0") (put-string p (substring s 1 (string-length s)))]
                 [else (put-string p s)]))))]))

  (define json-write
    (case-lambda
      [(x) (json-write x (current-output-port))]
      [(x p)
       (cond
         [(eq? x #t) (put-string p "true")]
         [(eq? x #f) (put-string p "false")]
         [(or (eq? x 'null) (eq? x (void))) (put-string p "null")]
         [(eq? x json-empty-object) (put-string p "{}")]
         [(string? x) (write-string x p)]
         [(symbol? x) (write-string (symbol->string x) p)]
         [(char? x) (write-string (string x) p)]
         [(number? x) (write-number x p)]
         [(alist? x)
          (write-char #\{ p)
          (let loop ([x x] [first #t])
            (unless (null? x)
              (unless first (write-char #\, p))
              (write-string (symbol->string (caar x)) p)
              (write-char #\: p)
              (json-write (cdar x) p)
              (loop (cdr x) #f)))
          (write-char #\} p)]
         [(or (null? x) (list? x))
          (write-char #\[ p)
          (let loop ([x x] [first #t])
            (unless (null? x)
              (unless first (write-char #\, p))
              (json-write (car x) p)
              (loop (cdr x) #f)))
          (write-char #\] p)]
         [(vector? x)
          (write-char #\[ p)
          (let ([n (vector-length x)])
            (do ([i 0 (fx+ i 1)]) ((fx= i n))
              (unless (fx= i 0) (write-char #\, p))
              (json-write (vector-ref x i) p)))
          (write-char #\] p)]
         [else
          ;; anything else: its printed representation
          (write-string (with-output-to-string (lambda () (write x))) p)])]))

  (define (json->string x)
    (call-with-string-output-port (lambda (p) (json-write x p))))

  ;; ---------------------------------------------------------------- reader

  (define (json-error msg . irritants)
    (apply error 'json-read msg irritants))

  (define (skip-ws p)
    (let ([c (peek-char p)])
      (when (and (char? c) (char-whitespace? c))
        (read-char p)
        (skip-ws p))))

  (define (expect p str)
    (string-for-each
      (lambda (ch)
        (unless (eqv? (read-char p) ch)
          (json-error "invalid literal, expected" str)))
      str))

  (define (read-hex4 p)
    (let ([s (get-string-n p 4)])
      (or (and (string? s) (= (string-length s) 4) (string->number s 16))
          (json-error "invalid \\u escape"))))

  (define (read-json-string p)
    (read-char p) ; opening quote
    (let ([out (open-output-string)])
      (let loop ()
        (let ([c (read-char p)])
          (cond
            [(eof-object? c) (json-error "unterminated string")]
            [(char=? c #\") (get-output-string out)]
            [(char=? c #\\)
             (let ([e (read-char p)])
               (case e
                 [(#\") (write-char #\" out)]
                 [(#\\) (write-char #\\ out)]
                 [(#\/) (write-char #\/ out)]
                 [(#\b) (write-char #\backspace out)]
                 [(#\f) (write-char #\page out)]
                 [(#\n) (write-char #\newline out)]
                 [(#\r) (write-char #\return out)]
                 [(#\t) (write-char #\tab out)]
                 [(#\u)
                  (let ([n (read-hex4 p)])
                    (if (and (>= n #xD800) (<= n #xDBFF))
                        ;; surrogate pair
                        (begin
                          (expect p "\\u")
                          (let ([m (read-hex4 p)])
                            (write-char
                              (integer->char
                                (+ #x10000 (* (- n #xD800) #x400) (- m #xDC00)))
                              out)))
                        (write-char (integer->char n) out)))]
                 [else (json-error "invalid escape" e)])
               (loop))]
            [else (write-char c out) (loop)])))))

  (define (read-json-number p)
    (let ([out (open-output-string)])
      (let loop ()
        (let ([c (peek-char p)])
          (when (and (char? c) (memv c '(#\- #\+ #\. #\e #\E #\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9)))
            (write-char (read-char p) out)
            (loop))))
      (let* ([s (get-output-string out)]
             [n (string->number s)])
        (or n (json-error "invalid number" s)))))

  (define (read-value p)
    (skip-ws p)
    (let ([c (peek-char p)])
      (cond
        [(eof-object? c) (json-error "unexpected end of input")]
        [(char=? c #\{)
         (read-char p)
         (skip-ws p)
         (if (eqv? (peek-char p) #\})
             (begin (read-char p) '())
             (let loop ([acc '()])
               (skip-ws p)
               (unless (eqv? (peek-char p) #\") (json-error "expected object key"))
               (let ([k (string->symbol (read-json-string p))])
                 (skip-ws p)
                 (unless (eqv? (read-char p) #\:) (json-error "expected :"))
                 (let* ([v (read-value p)]
                        [acc (cons (cons k v) acc)])
                   (skip-ws p)
                   (let ([d (read-char p)])
                     (cond
                       [(eqv? d #\,) (loop acc)]
                       [(eqv? d #\}) (reverse acc)]
                       [else (json-error "expected , or }")]))))))]
        [(char=? c #\[)
         (read-char p)
         (skip-ws p)
         (if (eqv? (peek-char p) #\])
             (begin (read-char p) '#())
             (let loop ([acc '()])
               (let ([acc (cons (read-value p) acc)])
                 (skip-ws p)
                 (let ([d (read-char p)])
                   (cond
                     [(eqv? d #\,) (loop acc)]
                     [(eqv? d #\]) (list->vector (reverse acc))]
                     [else (json-error "expected , or ]")])))))]
        [(char=? c #\") (read-json-string p)]
        [(char=? c #\t) (expect p "true") #t]
        [(char=? c #\f) (expect p "false") #f]
        [(char=? c #\n) (expect p "null") 'null]
        [else (read-json-number p)])))

  (define json-read
    (case-lambda
      [() (json-read (current-input-port))]
      [(p)
       (skip-ws p)
       (if (eof-object? (peek-char p))
           (peek-char p)
           (read-value p))]))

  (define (string->json s)
    (json-read (open-input-string s))))
