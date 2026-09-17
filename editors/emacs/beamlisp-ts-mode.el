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
;; The grammar is one install step, not a precondition: without it the mode
;; still opens `.bl' files — comments, indentation, imenu and the language
;; server need no grammar — and says once what is missing.
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
(require 'seq)                          ; seq-some, for the search-rule table below

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
  "Major mode for Beam Lisp (.bl) sources, powered by tree-sitter.

The tree-sitter half needs the `beamlisp' grammar, which is a separate
install; without it the mode keeps the half that needs no grammar —
comments, indentation, imenu, and the language server — and says so once."
  :syntax-table beamlisp-ts-mode--syntax-table
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
  ;; indentation: plain sexp-aware lisp indentation; tree-sitter is not
  ;; needed for it and lisp-mode's handles bl's forms fine
  (setq-local indent-line-function #'lisp-indent-line)
  (setq-local lisp-indent-offset 2)
  ;; navigation / discovery
  (setq-local imenu-generic-expression
              `((nil ,beamlisp-ts-mode--imenu-regexp 1)))
  ;; tree-sitter is one half of the mode, and its grammar is a separate
  ;; install: when it is missing, keep the other half rather than error out of
  ;; the mode. A mode that errors leaves the buffer in `fundamental-mode', and
  ;; no major-mode hook runs from there — so the LSP never attaches and every
  ;; lookup falls through to a plain search tool that knows nothing of `.bl'.
  (if (treesit-ready-p 'beamlisp t)
      (progn
        (treesit-parser-create 'beamlisp)
        (setq-local treesit-font-lock-settings
                    beamlisp-ts-mode--font-lock-settings)
        (setq-local treesit-font-lock-feature-list
                    '((comment string)
                      (keyword number call)
                      (definition reader-macro)
                      (bracket)))
        (treesit-major-mode-setup))
    (beamlisp-ts-mode--missing-grammar)))

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

;;; When the grammar is not installed

(defvar beamlisp-ts-mode--missing-grammar-said nil
  "Whether the missing-grammar warning has been shown this session.")

(defun beamlisp-ts-mode--missing-grammar ()
  "Warn once that the `beamlisp' grammar is absent, and how to install it."
  (unless beamlisp-ts-mode--missing-grammar-said
    (setq beamlisp-ts-mode--missing-grammar-said t)
    (display-warning
     'beamlisp-ts
     (concat "tree-sitter grammar `beamlisp' is not installed: `.bl' buffers get"
             " no tree-sitter font-lock, and stay in the plain-lisp half of this"
             " mode. Comments, indentation, imenu and the language server need no"
             " grammar and work as usual.\n"
             "Install it with `bl install doom' — or compile the pre-generated"
             " parser.c by hand; the `cc' line is in the commentary at the top of"
             " beamlisp-ts-mode.el.")
     :warning)))

;;; Search: `.bl' is Clojure's reader, so Clojure's rules answer

;; A lookup in a `.bl' buffer that no language server answers goes to whatever
;; regex-search tool the editor wired into `xref' (dumb-jump, in Doom). That
;; tool keys its rules off a file-extension table, and `.bl' is not in it — so
;; instead of searching it answers "Could not find rules for '.bl file'." bl
;; defines with the `def' family, which is exactly what the clojure rules
;; match, so the extension is the only thing missing.
(defvar dumb-jump-language-file-exts)   ; dumb-jump: the table extended below
(with-eval-after-load 'dumb-jump
  (dolist (ext '("bl" "bl.md"))
    (unless (seq-some (lambda (rule)
                        (and (equal (plist-get rule :language) "clojure")
                             (equal (plist-get rule :ext) ext)))
                      dumb-jump-language-file-exts)
      (set-default 'dumb-jump-language-file-exts
                   (cons (list :language "clojure" :ext ext
                               :agtype "clojure" :rgtype "clojure")
                         dumb-jump-language-file-exts)))))

(provide 'beamlisp-ts-mode)
;;; beamlisp-ts-mode.el ends here
