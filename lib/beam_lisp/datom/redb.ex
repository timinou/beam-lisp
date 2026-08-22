defmodule BeamLisp.Datom.Redb do
  @moduledoc """
  The Rust NIF behind the datom layer's persistent storage backend.

  This module is *substrate*, in the doctrine's sense: it exists only
  because a BEAM process cannot open a file-backed B-tree by itself. It
  holds no database logic — the six operations here map one-to-one onto
  `datom.store/Store`, and every decision above them lives in
  `priv/datom/`.

  ## What it guarantees

  | operation | guarantee |
  |---|---|
  | `range/3` | ordered, bounds **inclusive** on both sides |
  | `commit/2` | **atomic** across the whole batch, applied in order |
  | `compare_and_swap/4` | read and write inside one transaction |
  | all writes | `Durability::Immediate` — committed means on disk |

  The middle two are the ones that cannot be built from the others. A
  `get` followed by a `put` is not a compare-and-swap, it is a race with
  a longer window; and a batch applied without atomicity can leave one
  datom in EAVT and missing from AEVT, which is a corrupt database
  rather than a slow one.

  ## Loading

  The NIF is optional. `available?/0` answers whether it loaded, and
  `datom.store-redb` checks that before offering itself, so a checkout
  without a Rust toolchain still runs the whole database on its
  in-memory stores. A persistent backend that fails to load should
  degrade to "not available", never to "silently not durable".
  """

  use Rustler, otp_app: :beam_lisp, crate: "datom_redb"

  @doc """
  Open (or create) a database at `path`. Returns an opaque handle.
  """
  @spec open(String.t()) :: reference()
  def open(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "The value at `key`, or `nil`."
  @spec get(reference(), binary()) :: binary() | nil
  def get(_handle, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Every `{key, value}` with `start <= key <= stop`, in key order.

  `nil` on either bound means unbounded on that side. Both bounds are
  INCLUSIVE — the same convention as `subseq` in beam-lisp core, so the
  two compose without an off-by-one at the seam.
  """
  @spec range(reference(), binary() | nil, binary() | nil) :: [{binary(), binary()}]
  def range(_handle, _start, _stop), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Store `value` at `key`."
  @spec put(reference(), binary(), binary()) :: :ok
  def put(_handle, _key, _value), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Remove `key`. Idempotent."
  @spec delete(reference(), binary()) :: :ok
  def delete(_handle, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Write `new` at `key` only if the current value is `expected`
  (or the key is absent, when `expected` is `nil`).

  Returns the value now at the key, so the caller can compare it against
  what they asked for to learn whether they won.
  """
  @spec compare_and_swap(reference(), binary(), binary() | nil, binary()) :: binary()
  def compare_and_swap(_handle, _key, _expected, _new), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Apply a batch of `{:put, key, value}` / `{:delete, key}` ops
  ATOMICALLY, in order.

  Order is correctness rather than an optimisation:
  `[{:delete, k}, {:put, k, v}]` is what a transaction emits when it
  retracts and re-asserts a datom, and a backend that grouped the puts
  ahead of the deletes would end with the key absent.
  """
  @spec commit(reference(), [{:put, binary(), binary()} | {:delete, binary()}]) :: :ok
  def commit(_handle, _ops), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Whether the NIF loaded.

  The database runs without it, on the in-memory stores, so this is a
  capability question rather than a health check.
  """
  @spec available?() :: boolean()
  def available? do
    _ = open(Path.join(System.tmp_dir!(), "beam_lisp_redb_probe.redb"))
    true
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
