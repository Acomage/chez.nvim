;;; Entry point of the chez.nvim REPL bridge:
;;;   chez -q --libdirs <plugin>/scheme --script <plugin>/scheme/server.ss
(import (chezscheme) (chez-nvim server))
(serve)
