;;; chez.nvim file checker:
;;;   chez -q --libdirs <plugin>/scheme --script <plugin>/scheme/check.ss NAME [--blocks=S:E,...] [LIBDIR ...] < source
;;; Reads the source from stdin (NAME is used for source positions) and
;;; prints {"diagnostics": [...]} as JSON. --blocks gives the character ranges
;;; of the code of #eval blocks (with their delimiters blanked in the source).
(import (chezscheme) (chez-nvim json) (chez-nvim check))

(define (string-split s ch)
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(= i (string-length s)) (reverse (cons (substring s start i) acc))]
      [(char=? (string-ref s i) ch) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
      [else (loop (+ i 1) start acc)])))

(define (parse-blocks arg)
  ;; "--blocks=S:E,S:E" -> ((S . E) ...)
  (let ([spec (substring arg 9 (string-length arg))])
    (if (string=? spec "")
        '()
        (map (lambda (r)
               (let ([se (string-split r #\:)])
                 (cons (string->number (car se)) (string->number (cadr se)))))
             (string-split spec #\,)))))

(let* ([args (cdr (command-line))]
       [name (if (pair? args) (car args) "stdin")]
       [rest (if (pair? args) (cdr args) '())]
       [blocks? (and (pair? rest) (>= (string-length (car rest)) 9)
                     (string=? (substring (car rest) 0 9) "--blocks="))]
       [blocks (if blocks? (parse-blocks (car rest)) '())]
       [libdirs (if blocks? (cdr rest) rest)])
  (library-directories
    (append (map (lambda (d) (cons d d)) libdirs) (library-directories)))
  (let* ([bytes (get-bytevector-all (standard-input-port))]
         [bytes (if (eof-object? bytes) (bytevector) bytes)]
         [ip (open-string-input-port (utf8->string bytes))]
         ;; output of macros run at expansion time must not mix with the JSON
         [result (parameterize ([current-output-port (current-error-port)]
                                [console-output-port (current-error-port)])
                   (check-port name ip bytes blocks))]
         [out (transcoded-port (standard-output-port)
                (make-transcoder (utf-8-codec) (eol-style none) (error-handling-mode replace)))])
    (json-write result out)
    (newline out)
    (flush-output-port out)))
