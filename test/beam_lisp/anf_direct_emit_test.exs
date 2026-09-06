defmodule BeamLisp.AnfDirectEmitTest do
  use ExUnit.Case, async: false

  # PLAN-086 E2 oracle: compiler2 emits bl-ANF DIRECTLY; before the cutover the
  # same forms compiled to Elixir-quoted trees that anf/normalise then read
  # back. The two routes over the toolchain corpus must produce the SAME ANF
  # nodes, modulo:
  #
  #   * fresh-name counters ("x_12" vs :x_2830 — generation order differs)
  #   * the transition def-clause encoding: compiler2 embeds the quoted
  #     entries list as one (a/lit entries) node, which normalise decomposed
  #     into cons/tuple nodes on the old path — so a new-side :lit carrying a
  #     quoted-tree value is compared against normalise(that value) instead.
  #
  # Retires in E5 together with the old `compiler` pipeline it compares against
  # (the fixtures under test/fixtures/anf_corpus/ remain the frozen record).

  @files [
    "priv/boot/core.bl",
    "priv/boot/sugar.bl",
    "priv/boot/compiler.bl",
    "priv/boot/reader.bl",
    "priv/std/multi.bl",
    "priv/std/optics.bl"
  ]

  defp bl(ns, name, args) do
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!(ns, name), args)
  end

  test "compiler2 direct emit ≡ normalise∘compile over the toolchain corpus" do
    BeamLisp.init()

    mismatches =
      for path <- @files, reduce: [] do
        acc ->
          forms = BeamLisp.Reader.read_all(File.read!(path)) |> Enum.to_list()
          env_old = Map.put(bl("compiler", "new-env", ["anfcensus"]), :ns, "anfcensus")
          env_new = Map.put(bl("compiler2", "new-env", ["anfcensus"]), :ns, "anfcensus")

          forms
          |> Enum.with_index()
          |> Enum.reduce(acc, fn {form, i}, acc ->
            old =
              try do
                {:ok, bl("anf", "normalise", [bl("compiler", "compile", [form, env_old])])}
              catch
                _, _ -> :skip
              end

            new =
              try do
                {:ok, bl("compiler2", "compile-node", [form, env_new])}
              catch
                _, _ -> :skip
              end

            case {old, new} do
              {:skip, _} ->
                acc

              {{:ok, o}, {:ok, n}} ->
                case equiv(o, n) do
                  :ok -> acc
                  {:diff, why} -> [{path, i, why} | acc]
                end
            end
          end)
      end

    assert mismatches == [],
           "#{length(mismatches)} corpus form(s) differ:\n" <>
             (mismatches
              |> Enum.take(5)
              |> Enum.map(fn {p, i, why} -> "  #{p} form #{i}: #{why}" end)
              |> Enum.join("\n"))
  end

  # Structural equality with the two normalisations above. Ground subtrees
  # (quote data) canonicalize to the VALUE they denote before the structural
  # walk: the old pipeline decomposed quoted data into :cons/:tuple/:struct
  # constructors, the direct emitter embeds it as one :lit. Canonicalization
  # runs at EVERY level (do_equiv is the recursion entry): a :lit of the
  # location list sits several levels under the defvar call.
  defp equiv(a, b), do: do_equiv(a, b)

  defp do_equiv(a, b) do
    na = norm(a) |> flatten_do()
    nb = norm(b) |> flatten_do()

    case {groundify(na), groundify(nb)} do
      {{:ground, x}, {:ground, y}} ->
        if ground_eq(x, y),
          do: :ok,
          else: {:diff, "ground #{inspect(x, limit: 8)} vs #{inspect(y, limit: 8)}"}

      {{:ground, _}, _} ->
        {:diff, "old side is ground, new is not: #{inspect(nb, limit: 8)}"}

      {_, {:ground, _}} ->
        {:diff, "new side is ground, old is not: #{inspect(na, limit: 8)}"}

      _ ->
        walk(na, nb)
    end
  end

  # :do associativity is semantics-preserving: the old pipeline right-nested
  # blocks (doo(s1, doo(s2, …)) from norm-block), the direct emitter keeps a
  # flat statement list. Flatten on both sides before comparing.
  defp flatten_do(%{op: :do, stmts: stmts} = node) do
    %{node | stmts: drop_noops(flatten_stmts(stmts))}
  end

  defp flatten_stmts(stmts) do
    Enum.flat_map(stmts, fn
      %{op: :do, stmts: inner} -> flatten_stmts(inner)
      s -> [s]
    end)
  end

  # The genesis ns/def assembly emitted empty __block__s for absent alias/refer
  # groups, which norm-block turned into pure-constant no-op statements
  # (:enil / lit nil) mid-sequence, and wrapped the ns :require loads in ONE
  # discarded cons-list expression. compiler2 omits the no-ops and emits each
  # load as its own statement. Both canonicalize away: drop pure-constant
  # NON-FINAL statements (the final one carries the value), and splice the
  # elements of a non-final cons-list stmt into individual statements
  # (evaluating them in order has the same effects; the list is discarded).
  defp drop_noops(stmts) do
    {init, last} = Enum.split(stmts, -1)

    init
    |> Enum.flat_map(fn
      %{op: :cons} = cons -> cons_chain(cons)
      s -> [s]
    end)
    |> Enum.reject(&noop_stmt?/1)
    |> Kernel.++(last)
  end

  defp cons_chain(%{op: :cons, head: h, tail: t}), do: [h | cons_chain(t)]
  defp cons_chain(%{op: :enil}), do: []
  defp cons_chain(other), do: [other]

  defp noop_stmt?(%{op: :enil}), do: true
  defp noop_stmt?(%{op: :lit, val: nil}), do: true
  defp noop_stmt?(_), do: false

  defp flatten_do(other), do: other

  # Reconstruct the DATA a ground subtree denotes: :lit of a ground term, or a
  # :cons/:tuple/:enil/:struct composition of ground subtrees.
  defp groundify(%{op: :lit, val: v}) do
    case ground_data(v) do
      {:ok, d} -> {:ground, d}
      :no -> :no
    end
  end

  defp groundify(%{op: :enil}), do: {:ground, []}

  defp groundify(%{op: :cons, head: h, tail: t}) do
    case {groundify(h), groundify(t)} do
      {{:ground, hv}, {:ground, tv}} -> {:ground, [hv | tv]}
      _ -> :no
    end
  end

  defp groundify(%{op: :tuple, elems: es}) do
    ground_list(to_enum(es), fn ds -> {:ground, List.to_tuple(ds)} end)
  end

  defp groundify(%{op: :struct, mod: mod, pairs: ps}) do
    ground_list(to_enum(ps), fn ds ->
      fields = Map.new(ds, fn [k, v] -> {k, v} end)
      {:ground, struct!(mod, fields)}
    end)
  end

  defp groundify(_), do: :no

  defp ground_list(xs, done) do
    case ground_all(xs, []) do
      {:ground, ds} -> done.(ds)
      :no -> :no
    end
  end

  defp ground_all([], acc), do: {:ground, Enum.reverse(acc)}

  defp ground_all([x | xs], acc) do
    case groundify(x) do
      {:ground, d} -> ground_all(xs, [d | acc])
      :no -> :no
    end
  end

  # bl lists arrive as proper Elixir lists; :tuple/:struct fields as tuples or
  # bl vectors — normalise all to plain lists for the walk.
  defp to_enum(%BeamLisp.Vector{items: t}), do: Tuple.to_list(t)
  defp to_enum(t) when is_tuple(t), do: Tuple.to_list(t)
  defp to_enum(l) when is_list(l), do: l

  # Ground DATA (not nodes): atoms, numbers, binaries, and proper lists /
  # tuples / bl vectors thereof.
  defp ground_data(v) when is_atom(v) or is_number(v) or is_binary(v), do: {:ok, v}

  defp ground_data(v) when is_list(v) do
    if proper_list?(v), do: ground_data_list(v, []), else: :no
  end

  defp ground_data(v) when is_tuple(v) do
    case ground_data_list(Tuple.to_list(v), []) do
      {:ok, ds} -> {:ok, List.to_tuple(ds)}
      :no -> :no
    end
  end

  defp ground_data(%BeamLisp.Vector{items: t}) do
    case ground_data_list(Tuple.to_list(t), []) do
      {:ok, ds} -> {:ok, %BeamLisp.Vector{items: List.to_tuple(ds)}}
      :no -> :no
    end
  end

  defp ground_data(_), do: :no

  defp proper_list?([]), do: true
  defp proper_list?([_ | t]), do: proper_list?(t)
  defp proper_list?(_), do: false

  defp ground_data_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp ground_data_list([h | t], acc) do
    case ground_data(h) do
      {:ok, d} -> ground_data_list(t, [d | acc])
      :no -> :no
    end
  end

  # Ground values compare with fresh-name normalisation applied to every atom
  # and binary leaf (gensym counters differ between the two pipelines), and
  # {:__aliases__, _, segs} tuples resolved to their module atom: the genesis
  # emitter resolved aliases at emit time, compiler2 keeps the alias tuple in
  # the transition entries, and normalise's alias->atom resolves both to the
  # same :remote — the data-level spellings differ, the compiled node does not.
  defp ground_eq(a, b), do: ground_norm(a) == ground_norm(b)

  # (atoms normalise to their fresh()-ed string spelling below, so the alias
  # resolves to the same string).
  defp ground_norm({:__aliases__, _meta, segs}) when is_list(segs),
    do: segs |> Enum.map(&Atom.to_string/1) |> Module.concat() |> Atom.to_string()

  defp ground_norm(a) when is_atom(a), do: fresh(Atom.to_string(a))
  defp ground_norm(s) when is_binary(s), do: fresh(s)
  defp ground_norm([h | t]), do: [ground_norm(h) | ground_norm_tail(t)]

  defp ground_norm(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.map(&ground_norm/1) |> List.to_tuple()

  defp ground_norm(%BeamLisp.Vector{items: t}),
    do: {:vector, t |> Tuple.to_list() |> Enum.map(&ground_norm/1)}

  defp ground_norm(other), do: other

  defp ground_norm_tail([]), do: []
  defp ground_norm_tail([h | t]), do: [ground_norm(h) | ground_norm_tail(t)]
  defp ground_norm_tail(improper), do: ground_norm(improper)

  # :lit carrying a quoted tree (transition encoding) → normalise it away.
  # Data that merely LOOKS quoted (a 3-tuple with an atom head and list meta
  # can occur in plain data) makes normalise throw — then it was data: keep
  # the node.
  defp norm(%{op: :lit, val: v} = node) do
    if quoted_tree?(v) do
      try do
        bl("anf", "normalise", [v])
      catch
        _, _ -> node
      end
    else
      node
    end
  end

  defp norm(other), do: other

  # A quoted AST tree: a list/tuple whose leaves include {atom, list, ctx}
  # var tuples or {:atom, meta, args} call nodes — plain data (keywords,
  # numbers, binaries) is not.
  defp quoted_tree?(v) when is_tuple(v) or is_list(v) do
    v |> :erts_debug.flat_size() |> Kernel.>(2) and has_meta_tuple?(v)
  end

  defp quoted_tree?(_), do: false

  defp has_meta_tuple?(t) when is_tuple(t) do
    (tuple_size(t) == 3 and is_atom(elem(t, 0)) and is_list(elem(t, 1))) or
      (t |> Tuple.to_list() |> Enum.any?(fn
         e when is_tuple(e) or is_list(e) -> has_meta_tuple?(e)
         _ -> false
       end))
  end

  defp has_meta_tuple?([h | t]), do: has_meta_tuple?(h) or has_meta_tuple?(t)
  defp has_meta_tuple?(_), do: false

  # bl vectors are %BeamLisp.Vector{} structs — compare by items tuple.
  defp walk(%BeamLisp.Vector{items: a}, %BeamLisp.Vector{items: b}),
    do: do_equiv(Tuple.to_list(a), Tuple.to_list(b))

  # The defvar transition entries: raw quoted data whose INTERNAL spelling
  # (alias tuples, cons markers) legitimately differs between genesis and
  # compiler2. The contract is the READBACK — normalise of each clause's
  # def-ast — so compare that, not the raw data.
  defp walk(%{op: :remote, mod: BeamLisp.Link, fun: :defvar, args: a},
            %{op: :remote, mod: BeamLisp.Link, fun: :defvar, args: b}) do
    with :ok <- do_equiv(Enum.at(a, 0), Enum.at(b, 0)),
         :ok <- do_equiv(Enum.at(a, 1), Enum.at(b, 1)),
         :ok <- entries_equiv(Enum.at(a, 2), Enum.at(b, 2)),
         :ok <- do_equiv(Enum.at(a, 3), Enum.at(b, 3)) do
      :ok
    else
      d -> d
    end
  end

  # entries on both sides, canonicalised to the raw data list of
  # {kind, arity, name, def-ast} tuples (old side: decomposed cons/tuple
  # nodes → groundify; new side: :lit of the raw list).
  defp entries_equiv(old_node, new_node) do
    with {:ground, es_old} <- groundify(old_node),
         {:ground, es_new} <- groundify(new_node),
         true <- length(es_old) == length(es_new) do
      Enum.zip(es_old, es_new)
      |> Enum.reduce_while(:ok, fn {e_old, e_new}, :ok ->
        {k1, n1, f1, ast1} = e_old
        {k2, n2, f2, ast2} = e_new

        if {k1, n1, f1} == {k2, n2, f2} do
          case def_ast_equiv(ast1, ast2) do
            :ok -> {:cont, :ok}
            {:diff, why} -> {:halt, {:diff, "def-ast readback: #{why}"}}
          end
        else
          {:halt, {:diff, "entry #{inspect({k1, n1, f1})} vs #{inspect({k2, n2, f2})}"}}
        end
      end)
    else
      false -> {:diff, "entries length"}
      :no -> {:diff, "entries not ground"}
    end
  end

  # A def-ast `{:def, _, [head, [do: body]]}`: head params compare as data
  # (fresh-normalised); the body compares through normalise — the readback
  # defs->module-anf performs.
  defp def_ast_equiv({:def, _, [head1, kw1]}, {:def, _, [head2, kw2]}) do
    {n1, _, params1} = head1
    {n2, _, params2} = head2

    cond do
      ground_norm(params1) != ground_norm(params2) ->
        {:diff, "def params #{inspect(params1, limit: 10)} vs #{inspect(params2, limit: 10)}"}

      Atom.to_string(n1) != Atom.to_string(n2) ->
        {:diff, "def name #{n1} vs #{n2}"}

      true ->
        do_equiv(
          bl("anf", "normalise", [Keyword.get(kw1, :do)]),
          bl("anf", "normalise", [Keyword.get(kw2, :do)])
        )
    end
  end

  defp def_ast_equiv(a, b),
    do: {:diff, "not def-asts: #{inspect(a, limit: 6)} vs #{inspect(b, limit: 6)}"}

  defp walk(a, b) when is_map(a) and is_map(b) do
    # :ann carries source positions (metadata, not semantics): the direct
    # emitter stamps it from reader meta; normalise of genesis's quoted
    # output has none. Positions are pinned by wave20, not by this oracle.
    ka = a |> Map.delete(:ann) |> Map.keys() |> Enum.sort()
    kb = b |> Map.delete(:ann) |> Map.keys() |> Enum.sort()

    if ka == kb do
      Enum.reduce_while(ka, :ok, fn k, :ok ->
        case do_equiv(a[k], b[k]) do
          :ok -> {:cont, :ok}
          {:diff, why} -> {:halt, {:diff, "#{k}: #{why}"}}
        end
      end)
    else
      {:diff, "keys #{inspect(ka)} vs #{inspect(kb)}"}
    end
  end

  defp walk(a, b) when is_tuple(a) and is_tuple(b) do
    do_equiv(Tuple.to_list(a), Tuple.to_list(b))
  end

  defp walk(a, b) when is_list(a) and is_list(b) do
    if length(a) == length(b) do
      Enum.zip(a, b)
      |> Enum.reduce_while(:ok, fn {x, y}, :ok ->
        case do_equiv(x, y) do
          :ok -> {:cont, :ok}
          d -> {:halt, d}
        end
      end)
    else
      {:diff, "list lengths #{length(a)} vs #{length(b)}"}
    end
  end

  defp walk(a, b) when is_binary(a) and is_binary(b) do
    if fresh(a) == fresh(b), do: :ok, else: {:diff, "#{inspect(a)} vs #{inspect(b)}"}
  end

  defp walk(a, b) when is_atom(a) and is_atom(b) do
    if fresh(Atom.to_string(a)) == fresh(Atom.to_string(b)),
      do: :ok,
      else: {:diff, "#{inspect(a)} vs #{inspect(b)}"}
  end

  defp walk(a, b) when is_number(a) or is_boolean(a) or is_nil(a) do
    if a == b, do: :ok, else: {:diff, "#{inspect(a)} vs #{inspect(b)}"}
  end

  defp walk(a, b), do: {:diff, "shape #{inspect(a, limit: 8)} vs #{inspect(b, limit: 8)}"}

  # Fresh-name counters are generation-order dependent: "x_12" ≡ :x_2830.
  defp fresh(s), do: String.replace(s, ~r/__?\d+/, "_N")
end
