;;; lang/beamlisp/doctor.el -*- lexical-binding: t; -*-

(unless (executable-find "bl")
  (warn! "Couldn't find `bl` on PATH."
         "Install the bl drop — or, inside the beam-lisp checkout, the module uses `mix bl` automatically."))

(unless (treesit-language-available-p 'beamlisp t)
  (explain! "The tree-sitter grammar `beamlisp' is not installed."
            "Run `bl install doom' — it compiles the grammar from the checkout."))

(when (modulep! +lsp)
  (unless (modulep! :tools lsp)
    (warn! "The +lsp flag needs Doom's :tools lsp module enabled.")))
