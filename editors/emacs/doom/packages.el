;; -*- no-byte-compile: t; -*-
;;; lang/beamlisp/packages.el

;; The major mode, doc machinery and org-babel support are vendored next to
;; this file (installed by `bl install doom' from the beam-lisp checkout) —
;; no MELPA package needed for the language itself.

(when (modulep! +literate)
  ;; polymode: markdown host + tree-sitter beam-lisp cells in .bl.md
  (package! polymode))
