defmodule BeamLisp.ModelTest do
  use ExUnit.Case, async: false

  # `BeamLisp.Model` decides WHICH copy of the embedding weights answers, and
  # every way that decision can go wrong is invisible: semantic search degrades
  # to "the model weights are not on disk", which reads as a missing feature
  # rather than a resolution bug. So the rules are pinned here, against real
  # directories, with the marker the fetch actually writes.
  #
  # async: false because the pin is an environment variable (VM-global, one
  # table per node), and the name is unique per run so this can never collide
  # with a real model — the bundled copy lives in the checkout's `priv/embed/`,
  # which may well hold the real weights while these tests run.

  @name "model-test-#{System.unique_integer([:positive])}"

  setup do
    env = BeamLisp.Model.dir_env()
    saved = System.get_env(env)
    System.delete_env(env)

    bundled = BeamLisp.Model.bundled_dir(@name)
    ambient = BeamLisp.Model.ambient_dir(@name)

    on_exit(fn ->
      File.rm_rf(bundled)
      File.rm_rf(ambient)

      case saved do
        nil -> System.delete_env(env)
        dir -> System.put_env(env, dir)
      end
    end)

    {:ok, bundled: bundled, ambient: ambient}
  end

  test "an explicit pin is an ANSWER: present means it, and empty means absent", %{
    bundled: bundled,
    ambient: ambient
  } do
    # With a pin, the VALUE is the ROOT and the model is its `<name>`
    # subdirectory — `dir/1` is `root()/name` either way, so the pin has to be
    # written where a fetch would have written it.
    root = Path.join(ambient, "pinned-root")
    pinned = fetch!(Path.join(root, @name))
    System.put_env(BeamLisp.Model.dir_env(), root)

    assert BeamLisp.Model.tier(@name) == :env
    assert BeamLisp.Model.dir(@name) == pinned

    # The same pin with nothing in it is ABSENT — it does not fall through to a
    # bundled copy that is very likely sitting in this checkout, or a test that
    # forces absence on a machine that has the weights would be asserting
    # nothing. (Also: the bundle is not what answered above.)
    empty = Path.join(ambient, "empty")
    System.put_env(BeamLisp.Model.dir_env(), empty)

    assert BeamLisp.Model.tier(@name) == :absent
    assert BeamLisp.Model.dir(@name) == Path.join(empty, @name)
    refute BeamLisp.Model.dir(@name) == bundled
  end

  test "a bundled copy answers when nothing pins it", %{bundled: bundled} do
    fetch!(bundled)

    assert BeamLisp.Model.tier(@name) == :bundled
    assert BeamLisp.Model.dir(@name) == bundled
  end

  test "the ambient cache answers when the bundle has no copy", %{
    bundled: bundled,
    ambient: ambient
  } do
    File.rm_rf(bundled)
    fetch!(ambient)

    assert BeamLisp.Model.tier(@name) == :ambient
    assert BeamLisp.Model.dir(@name) == ambient
  end

  test "weights with no digest are not a copy", %{ambient: ambient} do
    partial = Path.join(ambient, "half-downloaded")
    File.mkdir_p!(partial)
    File.write!(Path.join(partial, "model.safetensors"), "weights")

    refute BeamLisp.Model.fetched?(partial)

    # …and nothing resolves to it: a partial download must not look like a model,
    # because the digest is what identifies the vector space every stored
    # embedding was made in.
    assert BeamLisp.Model.tier(@name) == :absent
  end

  test "a digest with no weights is not a copy either", %{ambient: ambient} do
    # The converse, and the reason `fetched?/1` asks for both halves: a DIGEST
    # alone is a CLAIM about weights that are not there. Reading it as complete
    # points every later caller at a directory that cannot be opened, and the
    # failure surfaces as a parse error instead of as "not on disk".
    claim = Path.join(ambient, "digest-only")
    File.mkdir_p!(claim)
    File.write!(Path.join(claim, "DIGEST"), "75cf7a6c2171b230ad19b1e7d8e0b1aee86da5a02af8e7cacedd9921d227623c")

    refute BeamLisp.Model.fetched?(claim)
    assert BeamLisp.Model.tier(@name) == :absent

    # And a copy missing ONE file is not a copy: the reader opens all three.
    almost = fetch!(Path.join(ambient, "almost"))
    File.rm!(Path.join(almost, "tokenizer.json"))

    refute BeamLisp.Model.fetched?(almost)
  end

  test "the shape of a model is declared once", %{ambient: ambient} do
    # `code.embed/present?` and the build's payload check ask this module what
    # files make a model, so the three lists that once existed here cannot drift
    # apart again.
    assert BeamLisp.Model.files() == ["config.json", "tokenizer.json", "model.safetensors"]

    complete = fetch!(Path.join(ambient, "complete"))
    assert BeamLisp.Model.fetched?(complete)
  end

  test "with nothing fetched, dir names where a fetch was expected", %{
    bundled: bundled,
    ambient: ambient
  } do
    assert BeamLisp.Model.tier(@name) == :absent

    # The absent case must point at a path a fetch would fill, so the message
    # that prints `dir` is a remedy and not a mystery.
    assert BeamLisp.Model.dir(@name) == ambient
    assert BeamLisp.Model.searched_dirs(@name) == [bundled, ambient]
  end

  # A fetch's completion record: DIGEST is written LAST, after every weight has
  # verified against its pinned sha256, which is why it — and not
  # `model.safetensors` — is what "this copy is complete" means.
  defp fetch!(dir) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "model.safetensors"), "weights")
    File.write!(Path.join(dir, "DIGEST"), "75cf7a6c2171b230ad19b1e7d8e0b1aee86da5a02af8e7cacedd9921d227623c")
    dir
  end
end
