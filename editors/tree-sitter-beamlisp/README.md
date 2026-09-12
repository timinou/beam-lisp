# tree-sitter-beamlisp

Tree-sitter grammar for **Beam Lisp** (`.bl`), the Clojure-reader dialect on
the BEAM. Forked from [sogaiu/tree-sitter-clojure](https://github.com/sogaiu/tree-sitter-clojure)
(CC0), adapted to the reader contract in `priv/boot/reader.bl`.

## Deltas from tree-sitter-clojure

- Language name `beamlisp`, file type `.bl`.
- `:"string"` keyword literals (bl reader: `:` followed directly by `"`).
- Token charset matches bl's actual delimiter set — whitespace, comma,
  `()[]{}"`, `;` ONLY. Unlike Clojure, `@ ~ ^ \` # '` and digits are legal
  inside tokens (`:~similar`, `foo@bar`, `don't`, `123abc` all parse), and
  digits may head a symbol (the reader falls back to symbol when
  `whole-number` fails).
- Everything else kept as a tolerant superset (`#_`, `#?`, `#?@`, `#tag`,
  `#Record{}`, `#'`, `##`, `#=`, `^`, `#^`, regex `#"…"`, char literals).

Validated against every `.bl` file in the beam-lisp repo (822 files,
0 parse errors).

## Build / regenerate

```sh
cd editors/tree-sitter-beamlisp
npm install            # pulls tree-sitter-cli
npx tree-sitter generate
```

`src/parser.c` is pre-generated and committed, so consumers (Emacs, neovim,
helix) do **not** need the CLI — just a C compiler.

## Smoke-test a file

```sh
npx tree-sitter parse path/to/file.bl     # prints the tree
npx tree-sitter parse -q $(find ../.. -name '*.bl')   # errors only
```

## Node types cheat sheet (for highlight queries)

`list_lit` `vec_lit` `map_lit` `set_lit` `anon_fn_lit` `ns_map_lit` ·
`sym_lit` (`sym_name`, `sym_ns`) · `kwd_lit` (`kwd_name`, `kwd_ns`) ·
`str_lit` `num_lit` `char_lit` `nil_lit` `bool_lit` ·
`comment` `dis_expr` (`#_`) · reader macros: `quoting_lit` `syn_quoting_lit`
`unquoting_lit` `unquote_splicing_lit` `derefing_lit` `meta_lit`
`var_quoting_lit` `tagged_or_ctor_lit` (data readers `#d`, records)
`regex_lit` `read_cond_lit` `splicing_read_cond_lit` `sym_val_lit` `evaling_lit`.
