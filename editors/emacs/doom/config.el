;;; lang/beamlisp/config.el -*- lexical-binding: t; -*-

;; beam-lisp for Doom: the tree-sitter major mode, the language server, a
;; warm REPL, the codebase questions, and first-party literate documents
;; (.bl / .bl.md / .bl.org).
;;
;; Installed by `bl install doom'. The elisp next to this file is vendored
;; from the beam-lisp checkout (editors/emacs/); re-run the installer to
;; upgrade.

;;; 1. the major modes

;; Doom keeps module dirs off `load-path': `load!' loads the vendored files
;; relative to this module's own directory.
(load! "beamlisp-ts-mode")   ; .bl       — tree-sitter + eglot registration
(load! "beamlisp-doc")       ; .bl.md / .bl.org — cells, doc-run, imenu

;;; 2. the command: bl, or mix bl inside the beam-lisp checkout
;;
;; Every shell-out in this module resolves here once: a beam-lisp CHECKOUT
;; (a mix.exs that names the beam_lisp app) runs `mix bl`, everything else
;; runs the installed `bl' binary. Warm daemon or dev tree — same commands.

(defcustom beamlisp-command nil
  "The argv that runs bl, as a list: (\"bl\") or (\"mix\" \"bl\").
nil means auto-detect: `mix bl' inside the beam-lisp checkout, `bl' everywhere
else."
  :type '(choice (const nil) (repeat string))
  :group 'beamlisp-ts)

(defun beamlisp--checkout-root ()
  "The beam-lisp checkout root containing this buffer, or nil."
  (when-let* ((root (locate-dominating-file default-directory "mix.exs"))
              (mix (expand-file-name "mix.exs" root))
              ((with-temp-buffer
                 (insert-file-contents mix nil 0 4000)
                 (string-match-p "beam_lisp" (buffer-string)))))
    root))

;;;###autoload
(defun beamlisp--command ()
  "The argv prefix that runs bl here: (\"mix\" \"bl\") in the checkout."
  (or beamlisp-command
      (if (beamlisp--checkout-root) '("mix" "bl") '("bl"))))

(defun beamlisp--command-dir ()
  "The directory bl commands run in: the checkout ROOT (mix requires the
mix.exs directory itself, not a subdirectory of it), else the buffer's."
  (or (beamlisp--checkout-root) default-directory))

(defun beamlisp--call (args &optional input)
  "Run bl with ARGS synchronously; return (EXIT . OUTPUT). INPUT is stdin."
  (let ((cmd (beamlisp--command))
        (default-directory (beamlisp--command-dir)))
    (with-temp-buffer
      (when input (insert input))
      (let ((exit (apply #'call-process-region
                         (point-min) (point-max) (car cmd)
                         (if input t nil) t nil (cdr (append cmd args)))))
        (cons exit (string-trim (buffer-string)))))))

;; the literate layer resolves its commands through the same detector
(setq beamlisp-doc-command-function #'beamlisp--command)

;;; 3. the language server (+lsp)
;;
;; lsp-mode under Doom's default; the vendored major mode also registers
;; eglot, so `:tools (lsp +eglot)' setups work untouched. The server command
;; resolves per project, so a buffer inside the checkout talks to `mix bl
;; lsp serve' — the dev server — while your projects get the installed drop.

(when (modulep! +lsp)
  (after! lsp-mode
    (add-to-list 'lsp-language-id-configuration '(beamlisp-ts-mode . "beamlisp"))
    (lsp-register-client
     (make-lsp-client
      :new-connection (lsp-stdio-connection
                       (lambda () (append (beamlisp--command) '("lsp" "serve"))))
      :activation-fn (lsp-activate-on "beamlisp")
      :priority 1
      :server-id 'beamlisp-lsp
      :major-modes '(beamlisp-ts-mode))))
  (add-hook 'beamlisp-ts-mode-hook #'lsp! 'append))

;;; 4. the warm REPL
;;
;; `bl repl' is a persistent session; inside the checkout the daemon makes
;; each eval tens of milliseconds. Sending a form shows it in the REPL
;; buffer, so the transcript of your exploration is always there.

(defvar beamlisp-repl-buffer-name "*bl repl*")

(defun beamlisp--repl-buffer ()
  "The live REPL buffer, or nil."
  (when-let* ((buf (get-buffer beamlisp-repl-buffer-name))
              (proc (get-buffer-process buf))
              ((process-live-p proc)))
    buf))

;;;###autoload
(defun beamlisp-repl ()
  "Open the beam-lisp REPL, starting it against this project when needed."
  (interactive)
  (unless (beamlisp--repl-buffer)
    (let* ((cmd (append (beamlisp--command) '("repl")))
           (default-directory (beamlisp--command-dir))
           (buf (apply #'make-comint-in-buffer
                       "bl repl" beamlisp-repl-buffer-name (car cmd) nil (cdr cmd))))
      (with-current-buffer buf
        (setq-local comint-prompt-regexp "^[a-zA-Z0-9.-]*=> *"))))
  (pop-to-buffer beamlisp-repl-buffer-name))

(defun beamlisp--eval-string (src)
  "Send SRC to the warm REPL. Returns nil; the REPL buffer shows the value."
  (let ((buf (save-window-excursion (beamlisp-repl) (get-buffer beamlisp-repl-buffer-name))))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert (string-trim src))
      (comint-send-input))
    nil))

;; literate cells evaluate through the warm REPL, not a cold subprocess
(setq beamlisp-doc-eval-function #'beamlisp--eval-string)
(setq beamlisp-doc-directory-function #'beamlisp--command-dir)

(defun beamlisp-send-region (beg end)
  "Send the region to the REPL."
  (interactive "r")
  (beamlisp--eval-string (buffer-substring-no-properties beg end)))

(defun beamlisp-send-defun ()
  "Send the top-level form at point to the REPL."
  (interactive)
  (save-excursion
    (end-of-defun)
    (let ((end (point)))
      (beginning-of-defun)
      (beamlisp-send-region (point) end))))

(defun beamlisp-send-buffer ()
  "Send the whole buffer to the REPL."
  (interactive)
  (beamlisp-send-region (point-min) (point-max)))

;;; 5. run, check, ask
;;
;; The compiler's proofs one keystroke away: run the file, check it the way
;; the language server sees it, or ask the codebase questions (who calls
;; this? what breaks if it changes?) without leaving the buffer.

;;;###autoload
(defun beamlisp-run-file ()
  "Run this file with `bl run' in a compilation buffer."
  (interactive)
  (unless buffer-file-name (user-error "This buffer visits no file"))
  (save-buffer)
  (let ((default-directory (beamlisp--command-dir)))
    (compile (mapconcat #'shell-quote-argument
                        (append (beamlisp--command) (list "run" buffer-file-name))
                        " "))))

;;;###autoload
(defun beamlisp-check ()
  "Check this file the way an editor would: diagnostics + proven facts."
  (interactive)
  (unless buffer-file-name (user-error "This buffer visits no file"))
  (save-buffer)
  (pcase-let ((`(,exit . ,out)
               (beamlisp--call (list "lsp" "check" buffer-file-name))))
    (if (zerop exit)
        (message "%s" (car (last (split-string out "\n" t))))
      (with-help-window "*beamlisp check*" (princ out)))))

(defvar beamlisp-ask-questions
  '("impact" "callers" "reachable" "returns-type" "arity-mismatches"
    "unknown-callees" "dead-code" "symbols")
  "The named questions `bl ask' answers.")

;;;###autoload
(defun beamlisp-ask (question target)
  "Ask the codebase QUESTION about TARGET over this file's tree.
Rows are answers from the fact database, never file contents."
  (interactive
   (list (completing-read "Question: " beamlisp-ask-questions nil t)
         (let ((sym (thing-at-point 'symbol t)))
           (read-string (if sym (format "Target (%s): " sym) "Target: ")
                        nil nil sym))))
  (let ((args (append (list "ask" question)
                      (unless (string-empty-p target) (list target))
                      (list (or buffer-file-name default-directory)))))
    (pcase-let ((`(,exit . ,out) (beamlisp--call args)))
      (if (and (zerop exit) (not (string-empty-p out)))
          (with-help-window "*beamlisp ask*"
            (princ (concat "bl " (mapconcat #'identity args " ") "\n\n" out)))
        (message "bl ask: no rows")))))

;;;###autoload
(defun beamlisp-impact ()
  "What breaks if the symbol at point changes? (impact, one keystroke)."
  (interactive)
  (let ((sym (thing-at-point 'symbol t)))
    (unless sym (user-error "No symbol at point"))
    (beamlisp-ask "impact" sym)))

;;; 6. literate documents — .bl.md and .bl.org are first-party
;;
;; .bl.md: polymode (markdown host + tree-sitter beam-lisp cells), cell
;; navigation and warm-REPL cell eval, `bl doc run' with in-place refresh.
;;
;; .bl.org: org-mode IS the literate host. ob-beamlisp makes
;; #+begin_src beam-lisp blocks C-c C-c-evaluable in any org buffer, and
;; C-c ' edits a block in beamlisp-ts-mode (tree-sitter + LSP). No polymode
;; needed — org already knows cells.

(after! org
  (load! "ob-beamlisp"))

(defun +beamlisp-org-doc-h ()
  "In a .bl.org buffer, org gets the document loop too: imenu over sections
and defs, and the doc-run / cell keys under C-c C-v (babel's own prefix)."
  (when (and buffer-file-name
             (string-match-p "\\.bl\\.org\\'" buffer-file-name))
    (beamlisp-doc-imenu-setup)
    (local-set-key (kbd "C-c C-v r") #'beamlisp-doc-run)
    (local-set-key (kbd "C-c C-v ]") #'beamlisp-doc-next-cell)
    (local-set-key (kbd "C-c C-v [") #'beamlisp-doc-prev-cell)))

(add-hook 'org-mode-hook #'+beamlisp-org-doc-h)

(when (modulep! +literate)
  (use-package! polymode
    :defer t
    :init
    (add-to-list 'auto-mode-alist '("\\.bl\\.md\\'" . poly-beamlisp-md-mode))
    :config
    (define-innermode poly-beamlisp-innermode
      :mode 'beamlisp-ts-mode
      :head-matcher "^```beam-lisp\\b.*\n"
      :tail-matcher "^```\\s-*$"
      :head-mode 'host
      :tail-mode 'host)

    (define-hostmode poly-beamlisp-md-hostmode
      :mode (if (fboundp 'gfm-mode) 'gfm-mode 'markdown-mode))

    (define-polymode poly-beamlisp-md-mode
      :hostmode 'poly-beamlisp-md-hostmode
      :innermodes '(poly-beamlisp-innermode))

    (add-hook 'poly-beamlisp-md-mode-hook #'beamlisp-doc-imenu-setup)))

;;; 7. keys

(map! :map beamlisp-ts-mode-map
      :localleader
      "'" #'beamlisp-repl
      (:prefix ("e" . "eval")
       "e" #'beamlisp-send-defun
       "r" #'beamlisp-send-region
       "b" #'beamlisp-send-buffer)
      "r" #'beamlisp-run-file
      "c" #'beamlisp-check
      "i" #'beamlisp-impact
      "a" #'beamlisp-ask)

(when (modulep! +literate)
  (after! polymode
    (map! :map polymode-mode-map
          :localleader
          (:prefix ("e" . "eval")
           "e" #'beamlisp-doc-eval-cell)
          "r" #'beamlisp-doc-run
          "c" #'beamlisp-check
          "]" #'beamlisp-doc-next-cell
          "[" #'beamlisp-doc-prev-cell)))
