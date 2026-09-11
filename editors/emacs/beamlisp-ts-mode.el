;;; beamlisp-ts-mode.el --- tree-sitter mode for Beam Lisp (.bl) -*- lexical-binding: t; -*-

;; Author: beam-lisp project
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, lisp, beam, tree-sitter

;;; Commentary:

;; Major mode for Beam Lisp (.bl), the Clojure-reader dialect on the
;; BEAM, powered by the tree-sitter-beamlisp grammar
;; (editors/tree-sitter-beamlisp in the beam-lisp repo).
;;
;; Requires Emacs 29+ built with tree-sitter support and the
;; `beamlisp' grammar installed.  Check: (treesit-language-available-p 'beamlisp)
;;
;; Install the grammar (no tree-sitter CLI needed, parser.c is
;; pre-generated in the repo):
;;
;;   cc -shared -fPIC -O2 -I src \
;;      ~/code/undefine/beam-lisp/editors/tree-sitter-beamlisp/src/parser.c \
;;      -o ~/.emacs.d/tree-sitter/libtree-sitter-beamlisp.so
;;
;; Doom: put this file's directory on load-path in config.el:
;;
;;   (add-to-list 'load-path "~/code/undefine/beam-lisp/editors/emacs")
;;   (require 'beamlisp-ts-mode)
;;
;; `.bl' files open in this mode automatically via `auto-mode-alist'.

;;; Code:

(require 'treesit)
(require 'lisp-mode)                    ; lisp-indent-line, syntax table base

(defgroup beamlisp-ts nil
  "Tree-sitter support for Beam Lisp."
  :group 'languages)

(defvar beamlisp-ts-mode--syntax-table
  (let ((st (make-syntax-table lisp-mode-syntax-table)))
    ;; bl delimiters are ws/comma/()[]{}"/; ONLY — everything else,
    ;; including @ ~ ^ ` # ' and digits, is symbol-constituent.
    (modify-syntax-entry ?' "_ p" st)
    (modify-syntax-entry ?` "_ p" st)
    (modify-syntax-entry ?@ "_" st)
    (modify-syntax-entry ?# "_" st)
    (modify-syntax-entry ?~ "_" st)
    (modify-syntax-entry ?^ "_" st)
    (modify-syntax-entry ?, " " st)     ; comma is whitespace in bl
    (modify-syntax-entry ?\\ "\\" st)   ; \a character literals
    st)
  "Syntax table for `beamlisp-ts-mode'.")

(defvar beamlisp-ts-mode--def-heads
  '("def" "defn" "defn-" "defmacro" "defonce" "defmulti" "defmethod"
    "defprotocol" "defrecord" "deftype" "defnative" "defserver"
    "defnav" "defrichnav" "defrelation" "definterface" "ns" "in-ns")
  "Head symbols treated as definition forms for highlighting and imenu.")

(defvar beamlisp-ts-mode--font-lock-settings
  (treesit-font-lock-rules
   :language 'beamlisp
   :feature 'comment
   '((comment) @font-lock-comment-face)

   :language 'beamlisp
   :feature 'string
   '((str_lit) @font-lock-string-face
     (regex_lit) @font-lock-regexp-face
     (char_lit) @font-lock-string-face)

   :language 'beamlisp
   :feature 'keyword
   '((kwd_lit (kwd_name) @font-lock-constant-face)
     (kwd_lit (kwd_ns) @font-lock-constant-face))

   :language 'beamlisp
   :feature 'number
   '((num_lit) @font-lock-number-face
     (nil_lit) @font-lock-constant-face
     (bool_lit) @font-lock-constant-face)

   :language 'beamlisp
   :feature 'definition
   `((list_lit
      value: (sym_lit name: (sym_name) @font-lock-keyword-face)
      (:match ,(concat "\\`\\(?:" (regexp-opt beamlisp-ts-mode--def-heads) "\\)\\'")
              @font-lock-keyword-face))
     (list_lit
      value: (sym_lit name: (sym_name) @_head)
      (:match ,(concat "\\`\\(?:" (regexp-opt beamlisp-ts-mode--def-heads) "\\)\\'")
              @_head)
      value: (sym_lit name: (sym_name) @font-lock-function-name-face)))

   :language 'beamlisp
   :feature 'call
   '((list_lit
      value: (sym_lit name: (sym_name) @font-lock-function-call-face)))

   :language 'beamlisp
   :feature 'reader-macro
   '((dis_expr marker: _ @font-lock-preprocessor-face)
     (quoting_lit marker: _ @font-lock-preprocessor-face)
     (syn_quoting_lit marker: _ @font-lock-preprocessor-face)
     (unquoting_lit marker: _ @font-lock-preprocessor-face)
     (unquote_splicing_lit marker: _ @font-lock-preprocessor-face)
     (derefing_lit marker: _ @font-lock-preprocessor-face)
     (meta_lit marker: _ @font-lock-preprocessor-face)
     (tagged_or_ctor_lit tag: (sym_lit name: (sym_name) @font-lock-type-face)))

   :language 'beamlisp
   :feature 'bracket
   '((["(" ")" "[" "]" "{" "}"]) @font-lock-bracket-face))
  "Font-lock settings for `beamlisp-ts-mode'.")

(defvar beamlisp-ts-mode--imenu-regexp
  (concat "^\\s-*(\\(?:" (regexp-opt beamlisp-ts-mode--def-heads) "\\)"
          "\\s-+"                            ; head
          "\\(?:\\^[^ \t\n]+\\s-+\\)*"      ; leading ^metadata
          "\\(?:\"[^\"\n]*\"\\s-+\\)?"      ; optional docstring
          "\\(\\(?:[^][(){}\" \t\n;]+\\)\\)")
  "Regexp matching the defined name (capture group 1) of a top-level form.")

;;;###autoload
(define-derived-mode beamlisp-ts-mode prog-mode "BeamLisp"
  "Major mode for Beam Lisp (.bl) sources, powered by tree-sitter."
  :syntax-table beamlisp-ts-mode--syntax-table
  (unless (treesit-ready-p 'beamlisp)
    (error "tree-sitter grammar `beamlisp' not available; see beamlisp-ts-mode.el commentary"))
  (treesit-parser-create 'beamlisp)
  ;; comments: `;' to end of line
  (setq-local comment-start ";")
  (setq-local comment-end "")
  (setq-local comment-start-skip ";+\\s-*")
  ;; without these, indenting a single-`;` comment line loops:
  ;; lisp-indent-line -> comment-indent -> indent-according-to-mode -> …
  ;; (lisp-mode escapes via comment-add=1; also never let the indent fn
  ;; return nil, which is what re-enters indent-according-to-mode)
  (setq-local comment-add 1)
  (setq-local comment-indent-function
              (lambda () (or (lisp-comment-indent) comment-column)))
  ;; font-lock
  (setq-local treesit-font-lock-settings beamlisp-ts-mode--font-lock-settings)
  (setq-local treesit-font-lock-feature-list
              '((comment string)
                (keyword number call)
                (definition reader-macro)
                (bracket)))
  ;; indentation: plain sexp-aware lisp indentation; tree-sitter is not
  ;; needed for it and lisp-mode's handles bl's forms fine
  (setq-local indent-line-function #'lisp-indent-line)
  (setq-local lisp-indent-offset 2)
  ;; navigation / discovery
  (setq-local imenu-generic-expression
              `((nil ,beamlisp-ts-mode--imenu-regexp 1)))
  (treesit-major-mode-setup))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.bl\\'" . beamlisp-ts-mode))

;;; LSP

;; Eglot drives `bl lsp serve`, the stdio language server: diagnostics, hover
;; (with the compiler's proof card), go-to-definition, references, document
;; symbols, completion, inlay hints, code actions. Registering the command here
;; means `M-x eglot` in a BeamLisp buffer starts it with no init.el change.
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(beamlisp-ts-mode . ("bl" "lsp" "serve"))))

(provide 'beamlisp-ts-mode)
;;; beamlisp-ts-mode.el ends here
