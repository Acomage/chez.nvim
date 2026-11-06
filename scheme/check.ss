;;; chez.nvim file checker:
;;;   chez -q --libdirs <plugin>/scheme --script <plugin>/scheme/check.ss NAME [LIBDIR ...] < source
;;; Reads the source from stdin (NAME is used for source positions) and
;;; prints {"diagnostics": [...]} as JSON.
(import (chezscheme) (chez-nvim json) (chez-nvim check))

(let* ([args (cdr (command-line))]
       [name (if (pair? args) (car args) "stdin")]
       [libdirs (if (pair? args) (cdr args) '())])
  (library-directories
    (append (map (lambda (d) (cons d d)) libdirs) (library-directories)))
  (let* ([bytes (get-bytevector-all (standard-input-port))]
         [bytes (if (eof-object? bytes) (bytevector) bytes)]
         [ip (open-string-input-port (utf8->string bytes))]
         ;; output of macros run at expansion time must not mix with the JSON
         [result (parameterize ([current-output-port (current-error-port)]
                                [console-output-port (current-error-port)])
                   (check-port name ip bytes))]
         [out (transcoded-port (standard-output-port)
                (make-transcoder (utf-8-codec) (eol-style none) (error-handling-mode replace)))])
    (json-write result out)
    (newline out)
    (flush-output-port out)))
