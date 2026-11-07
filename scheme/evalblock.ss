;;; chez.nvim #eval block runner:
;;;   chez -q --libdirs <plugin>/scheme --script <plugin>/scheme/evalblock.ss [LIBDIR ...] < request
;;; Reads one JSON request from stdin (see run-blocks in chez-nvim/evalblock)
;;; and prints one JSON object per line, each preceded by U+001E.
(import (chezscheme) (chez-nvim json) (chez-nvim evalblock))

(let ([tx (make-transcoder (utf-8-codec) (eol-style none) (error-handling-mode replace))])
  (library-directories
    (append (map (lambda (d) (cons d d)) (cdr (command-line))) (library-directories)))
  (let ([req (json-read (transcoded-port (standard-input-port) tx))]
        [out (transcoded-port (standard-output-port (buffer-mode block)) tx)])
    (run-blocks req
      (lambda (msg)
        (put-char out #\x1e)
        (json-write msg out)
        (newline out)
        (flush-output-port out)))))
