# beamlisp-ts-mode — Emacs tree-sitter mode for Beam Lisp

`beamlisp-ts-mode.el` gives `.bl` files: tree-sitter highlighting
(def/heads, calls, keywords incl. `:~similar` and `:"str"` forms, strings,
numbers, reader-macro markers, brackets), `;` comments, sexp-aware lisp
indentation, and imenu for top-level `def*` forms.

Requires Emacs 29+ with tree-sitter (`M-: (treesit-available-p)` → t).

## 1. Install the grammar (once)

No tree-sitter CLI needed — `parser.c` is pre-generated:

```sh
mkdir -p ~/.emacs.d/tree-sitter
cc -shared -fPIC -O2 -I ~/code/undefine/beam-lisp/editors/tree-sitter-beamlisp/src \
   ~/code/undefine/beam-lisp/editors/tree-sitter-beamlisp/src/parser.c \
   -o ~/.emacs.d/tree-sitter/libtree-sitter-beamlisp.so
```

Verify: `M-: (treesit-language-available-p 'beamlisp)` → t.

(Alternative: `M-x treesit-install-language-grammar` with a recipe entry in
`treesit-language-source-alist` pointing at the grammar dir.)

## 2. Doom Emacs setup

In `~/.doom.d/config.el`:

```elisp
(add-to-list 'load-path "~/code/undefine/beam-lisp/editors/emacs")
(require 'beamlisp-ts-mode)
```

`.bl` files now open in `beamlisp-ts-mode` automatically
(`auto-mode-alist` is set by the file). `doom sync` not needed — no package,
just load-path.

## 3. Vanilla Emacs

Same two lines in `init.el`, or:

```elisp
(load "~/code/undefine/beam-lisp/editors/emacs/beamlisp-ts-mode.el")
```

## Highlight levels

Faces come in tree-sitter "levels" (default max is 3). Level 4 adds bracket
coloring: `(setq treesit-font-lock-level 4)` if you want it.

## Recommended companions (Doom)

- `paredit` / Doom's `:editor lispy` module — structural editing on sexps;
  works fine here since bl is plain sexprs.
- `aggressive-indent-mode` or just `indent-region` (`gr` / `=` in Doom) —
  indentation is `lisp-indent-line`, so standard 2-space lisp style.
