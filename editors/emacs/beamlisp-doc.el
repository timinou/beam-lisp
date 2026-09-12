;;; beamlisp-doc.el --- literate beam-lisp documents (.bl.md / .bl.org) -*- lexical-binding: t; -*-

;; Author: beam-lisp project
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: languages, literate programming

;;; Commentary:

;; A .bl.md / .bl.org document is a PROGRAM with a narrative: prose sections
;; and `beam-lisp' code cells, run by `bl doc run', which writes each cell's
;; result back into the file as an owned span.  This library gives those
;; documents an editor surface:
;;
;;   - cell navigation     `beamlisp-doc-next-cell' / `beamlisp-doc-prev-cell'
;;   - cell evaluation     `beamlisp-doc-eval-cell' (see
;;                         `beamlisp-doc-eval-function' — the Doom module
;;                         overrides it to talk to a warm `bl repl')
;;   - the document loop   `beamlisp-doc-run' runs `bl doc run' async and
;;                         reverts the buffer on success, so fresh result
;;                         spans appear in place; with a prefix arg it runs
;;                         the --check drift gate instead
;;   - discovery           imenu over headings AND definition heads
;;
;; The machinery is host-agnostic: cells are found by their fence text
;; (```beam-lisp … ``` in markdown, #+begin_src beam-lisp … #+end_src in
;; org), so it works the same in a polymode buffer, a plain markdown-mode
;; buffer, or an org-mode buffer.

;;; Code:

(defgroup beamlisp-doc nil
  "Literate beam-lisp documents."
  :group 'languages)

(defvar beamlisp-doc-eval-function nil
  "Function called with a cell's source string to evaluate it.
When nil, `beamlisp-doc-eval-cell' falls back to `bl run -' on a
subprocess.  A host integration (the Doom module) sets this to a
function that sends the cell to a warm REPL instead.")

;;; Cell geometry

(defun beamlisp-doc--fences ()
  "The (BEGIN-RE . END-RE) cell fences for this buffer's document flavor."
  (if (and buffer-file-name (string-match-p "\\.org\\'" buffer-file-name))
      '("^[ \t]*#\\+begin_src[ \t]+beam-lisp\\b" . "^[ \t]*#\\+end_src")
    '("^```beam-lisp\\b" . "^```\\s-*$")))

(defun beamlisp-doc-cell-bounds ()
  "The (BEG . END) body bounds of the beam-lisp cell enclosing point.
Point on a fence line counts as inside that cell.  nil when no cell
encloses point."
  (save-excursion
    (pcase-let ((`(,beg-re . ,end-re) (beamlisp-doc--fences)))
      (let ((orig (point)))
        (beginning-of-line)
        (when (or (looking-at-p beg-re) (re-search-backward beg-re nil t))
          (let ((beg-fence (point)))
            (forward-line 1)
            (let ((body-beg (point)))
              (when (re-search-forward end-re nil t)
                ;; inside means: orig in [beg-fence, end of the end-fence line)
                (let ((cell-end (line-end-position)))
                  (when (and (<= beg-fence orig) (< orig cell-end))
                    (cons body-beg (line-beginning-position))))))))))))

;;; Navigation

(defun beamlisp-doc-next-cell ()
  "Move point to the next beam-lisp cell's begin fence."
  (interactive)
  (pcase-let ((`(,beg-re . ,end-re) (beamlisp-doc--fences)))
    ;; when inside a cell, first step past its end fence
    (when (beamlisp-doc-cell-bounds)
      (end-of-line)
      (re-search-forward end-re nil t))
    (if (re-search-forward beg-re nil t)
        (progn (beginning-of-line) (point))
      (user-error "No further beam-lisp cell"))))

(defun beamlisp-doc-prev-cell ()
  "Move point to the previous beam-lisp cell's begin fence."
  (interactive)
  (pcase-let ((`(,beg-re . ,_end-re) (beamlisp-doc--fences)))
    (when (beamlisp-doc-cell-bounds)
      (re-search-backward beg-re nil t))
    (if (re-search-backward beg-re nil t)
        (point)
      (user-error "No earlier beam-lisp cell"))))

;;; Evaluation

(defun beamlisp-doc--eval-with-cli (src)
  "Evaluate SRC with `bl run -' on a subprocess; return the printed output."
  (let ((work (generate-new-buffer " *bl cell*")))
    (unwind-protect
        (with-current-buffer work
          (insert src)
          (call-process-region (point-min) (point-max) "bl" t t nil "run" "-")
          (string-trim (buffer-string)))
      (kill-buffer work))))

(defun beamlisp-doc-eval-cell ()
  "Evaluate the beam-lisp cell at point.
Goes through `beamlisp-doc-eval-function' when set (the warm REPL),
else a fresh `bl run -'.  The result is echoed; the REPL buffer, when
there is one, shows the full transcript."
  (interactive)
  (let ((bounds (beamlisp-doc-cell-bounds)))
    (unless bounds (user-error "No beam-lisp cell at point"))
    (let* ((src (buffer-substring-no-properties (car bounds) (cdr bounds)))
           (f (or beamlisp-doc-eval-function #'beamlisp-doc--eval-with-cli))
           (result (funcall f src)))
      (when (stringp result)
        (message "%s" (string-trim result)))
      result)))

;;; The document loop: bl doc run, with in-place refresh

(defvar beamlisp-doc-command-function nil
  "Function returning the argv prefix that runs `bl' here, e.g. (\"bl\")
or (\"mix\" \"bl\") inside the beam-lisp checkout.  nil means (\"bl\").")

(defvar beamlisp-doc-directory-function nil
  "Function returning the directory `bl doc run' runs in.
nil means the buffer's `default-directory'.  A checkout integration sets
this to the checkout ROOT: `mix bl' must run where mix.exs lives.")

(defvar beamlisp-doc--run-buffer-name "*bl doc run*")

(defun beamlisp-doc-run (&optional check)
  "Run this document's cells with `bl doc run' and refresh the buffer.
Runs asynchronously; on success the buffer reverts (it was saved first,
and result spans are owned by the tool), so fresh results appear in
place.  With a prefix argument CHECK, runs the --check drift gate
instead: write nothing, fail when the stored results are stale.

The command is `bl' by default; a host integration may rebind
`beamlisp-doc-command-function' to answer (\"mix\" \"bl\") inside the
beam-lisp checkout."
  (interactive "P")
  (unless buffer-file-name (user-error "This buffer visits no file"))
  (save-buffer)
  (let* ((file buffer-file-name)
         (doc-buf (current-buffer))
         (default-directory (if beamlisp-doc-directory-function
                                (funcall beamlisp-doc-directory-function)
                              default-directory))
         (argv (append (if beamlisp-doc-command-function
                           (funcall beamlisp-doc-command-function)
                         '("bl"))
                       (list "doc" "run" file)
                       (and check '("--check"))))
         (out (get-buffer-create beamlisp-doc--run-buffer-name)))
    (with-current-buffer out (erase-buffer))
    (make-process
     :name "bl doc run"
     :buffer out
     :command argv
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (if (zerop (process-exit-status proc))
             (progn
               (when (buffer-live-p doc-buf)
                 (with-current-buffer doc-buf
                   (unless (buffer-modified-p)
                     (revert-buffer nil t t))))
               (message "bl doc run: %s ✓" (file-name-nondirectory file)))
           (message "bl doc run: %s failed — see %s"
                    (file-name-nondirectory file) beamlisp-doc--run-buffer-name)
           (display-buffer out)))))))

;;; Discovery: headings and definitions share one imenu

(defvar beamlisp-doc--def-imenu-regexp
  (concat "^\\s-*(\\(?:"
          (regexp-opt '("def" "defn" "defn-" "defmacro" "defonce" "defmulti"
                        "defmethod" "defprotocol" "defrecord" "deftype"
                        "defnative" "defserver" "ns"))
          "\\)\\s-+"
          "\\(?:\\^[^ \t\n]+\\s-+\\)*"
          "\\(?:\"[^\"\n]*\"\\s-+\\)?"
          "\\(\\(?:[^][(){}\" \t\n;]+\\)\\)")
  "Regexp matching the defined name (capture group 1) of a top-level form.")

(defun beamlisp-doc-imenu-setup ()
  "Install imenu entries for headings (markdown and org) and beam-lisp defs."
  (setq-local imenu-generic-expression
              `(("Section" "^\\(?:#+\\|\\*+\\)\\s-+\\(.*\\)$" 1)
                (nil ,beamlisp-doc--def-imenu-regexp 1))))

(provide 'beamlisp-doc)
;;; beamlisp-doc.el ends here
