# datom → DataFrame examples

`datom/q` answers a question and returns a **set of tuples** — the shape logic
wants. For the analytical majority (group, sum, percentile, join, plot) you want
**columns**, and a column engine (Polars, via Explorer) to run them fast.
`datom/q-df` and `datom/pull->df` are that bridge: the *same* datalog answers,
reshaped into an `Explorer.DataFrame`.

This is the last tenth of the datom→Polars story. PLAN-042 already made the
query engine column-native inside datom (a typed tag-free value slot + the
`datom_resolve` Rust NIF + a columnar engine); these functions only reshape the
*answer* into the DataFrame a downstream analytics layer consumes. `datom/q`
stays set-valued and untouched.

## The two surfaces

| function | in | out |
|---|---|---|
| `datom/q-df` | a query | a DataFrame, one column per `:find` element, in `:find` order |
| `datom/pull->df` | entity ids + attrs | a DataFrame, one row per entity, `db/id` + one column per attr |

Both raise a clear "add `:explorer`" error when Explorer is absent — it is an
**optional dependency**, and the whole datalog core never needs it.

## Run them

```sh
mix beam_lisp.run --path priv examples/datom/df/01-query-to-frame.bl
mix beam_lisp.run --path priv examples/datom/df/02-analytics.bl
mix beam_lisp.run --path priv examples/datom/df/03-pull-to-frame.bl
```

- **01-query-to-frame** — `q` vs `q-df` on the same query: column names (the `?`
  dropped), `:find` order preserved, and aggregates (`(count ?e)` → a `count_e`
  column).
- **02-analytics** — the payoff: a spend ledger pulled into one frame, then a
  full Polars pipeline — `group_by` + `summarise_with`, `sort_with`,
  `mutate_with` for a derived column, and `Series` reductions for scalars.
- **03-pull-to-frame** — `pull->df` over a heterogeneous entity set: entities
  with different attribute sets tabulate into one **rectangular** frame, a
  missing attribute becoming a null cell, then `mask`/`equal` to filter.

## beam-lisp ↔ Explorer gotchas (all shown in the examples)

- `Explorer.DataFrame.new` and the column-spec arguments (`group_by`, `select`)
  want **Erlang lists**, not beam-lisp `[…]` vectors (which are
  `%BeamLisp.Vector{}` and fail Explorer's `Table.Reader` protocol). Use
  `(list …)` or `(Enum/to_list …)`.
- `summarise_with` / `sort_with` / `mutate_with` take a function of the frame
  returning a **keyword list** — a list of `{name, Series}` tuples. Build a
  tuple with `(erlang/list_to_tuple (list :name series))`.
- Inside those functions, get a column's `Series` with
  `(Explorer.DataFrame/pull d "col")` — a DataFrame is a struct, not a
  beam-lisp map, so `Map/get` will not reach its columns.
