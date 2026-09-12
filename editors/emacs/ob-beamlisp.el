;;; ob-beamlisp.el --- org-babel functions for beam-lisp evaluation -*- lexical-binding: t; -*-

;; Author: beam-lisp project
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Org-babel support for beam-lisp: `#+begin_src beam-lisp' blocks evaluate
;; with C-c C-c — in any org document, and first-party in `.bl.org'
;; livebooks, where the same blocks are what `bl doc run' executes.
;;
;; Evaluation runs the block as a program (`bl run -': the block's printed
;; output and last value come back as the result).  Inside a beam-lisp
;; checkout, `beamlisp--command' (the Doom module) makes the same block run
;; through `mix bl' instead — one command resolution, everywhere.
;;
;; C-c ' in a beam-lisp src block opens it in `beamlisp-ts-mode' — full
;; tree-sitter highlighting and LSP while editing the cell.

;;; Code:

(require 'ob)

(defcustom org-babel-beamlisp-command nil
  "The argv that runs bl, as a list: (\"bl\") or (\"mix\" \"bl\").
When nil, resolved per invocation: `beamlisp--command' when the
beam-lisp major-mode package is loaded, else (\"bl\")."
  :type '(choice (const nil) (repeat string))
  :group 'org-babel)

(defun org-babel-beamlisp--command ()
  "Resolve the argv prefix that runs bl for this evaluation."
  (or org-babel-beamlisp-command
      (if (fboundp 'beamlisp--command) (funcall 'beamlisp--command) '("bl"))))

(defun org-babel-beamlisp--command-dir ()
  "The directory the block runs in: the checkout root when the major-mode
package knows one (mix must run where mix.exs lives, not in a subdirectory
of the checkout), else the buffer's `default-directory'."
  (if (fboundp 'beamlisp--command-dir)
      (funcall 'beamlisp--command-dir)
    default-directory))

(defun org-babel-execute:beamlisp (body params)
  "Execute a beam-lisp block with `bl run -'.
The block's standard output and final value are the result.  A non-zero
exit surfaces the program's stderr via `user-error', so a failing cell
in a .bl.org document reads like a failing babel block anywhere else."
  (let* ((cmd (org-babel-beamlisp--command))
         (default-directory (org-babel-beamlisp--command-dir))
         (err-file (make-temp-file "ob-bl-err"))
         (work (generate-new-buffer " *ob-bl*")))
    (unwind-protect
        (let ((exit (with-current-buffer work
                      (insert body)
                      ;; DELETE=t: the region is replaced by the stdout it
                      ;; produced — `work' now holds exactly the output
                      (apply #'call-process-region (point-min) (point-max)
                             (car cmd) t (list t err-file) nil
                             (append (cdr cmd) '("run" "-"))))))
          (if (and (integerp exit) (zerop exit))
              (with-current-buffer work (string-trim (buffer-string)))
            (user-error "bl run: %s"
                        (string-trim (with-temp-buffer
                                       (insert-file-contents err-file)
                                       (buffer-string))))))
      (kill-buffer work)
      (delete-file err-file))))

;; C-c ' edits a beam-lisp block in the tree-sitter major mode.
(with-eval-after-load 'org-src
  (add-to-list 'org-src-lang-modes '("beam-lisp" . beamlisp-ts)))

(provide 'ob-beamlisp)
;;; ob-beamlisp.el ends here
