defmodule BeamLisp.ImageTest do
  @moduledoc """
  The image-kind rule: `dev`, `release`, `drop`.

  This module is the ONE place the rule lives — `reload` (in bl) calls it to gate
  mutating reloads, and the application calls it to decide whether to start the
  dev server. Both used to ask whether `Mix` was loaded, which answers nothing
  once Mix is deleted, and answers it in the dangerous direction: a development
  image would look like production.

  Every case sets env vars and restores them, so a test cannot leak a kind into
  the next one.
  """
  use ExUnit.Case, async: false

  setup do
    saved = Enum.map(~w(BL_BIN BEAM_LISP_IMAGE BEAM_LISP_DEV BEAM_LISP_RELOAD), &{&1, System.get_env(&1)})
    Enum.each(~w(BL_BIN BEAM_LISP_IMAGE BEAM_LISP_DEV BEAM_LISP_RELOAD), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end

  test "a plain VM is development" do
    assert BeamLisp.Image.kind() == "dev"
    assert BeamLisp.Image.dev?()
    assert BeamLisp.Image.mutable?()
  end

  test "a release says so, and refuses to mutate itself" do
    System.put_env("BEAM_LISP_IMAGE", "release")
    assert BeamLisp.Image.kind() == "release"
    refute BeamLisp.Image.dev?()
    refute BeamLisp.Image.mutable?()
  end

  test "a drop is recognised by the launcher's BL_BIN" do
    # Measured: the Rust launcher sets BL_BIN to the compound it runs from, and it
    # is nil under `mix bl`.
    System.put_env("BL_BIN", "/somewhere/app")
    assert BeamLisp.Image.kind() == "drop"
    refute BeamLisp.Image.mutable?()
  end

  test "an operator can opt a packaged image into mutation" do
    System.put_env("BL_BIN", "/somewhere/app")
    System.put_env("BEAM_LISP_RELOAD", "1")
    assert BeamLisp.Image.mutable?()
    assert BeamLisp.Image.kind() == "drop", "opting in does not change what it IS"
  end

  test "a tree can declare itself development" do
    System.put_env("BL_BIN", "/somewhere/app")
    System.put_env("BEAM_LISP_DEV", "1")
    assert BeamLisp.Image.kind() == "dev"
    assert BeamLisp.Image.mutable?()
  end

  test "mix being loaded is not what makes an image development" do
    # This very test runs with Mix loaded. The answer must not consult it: that is
    # the whole point of the change, and it is what makes deleting Mix safe.
    assert Code.ensure_loaded?(Mix), "precondition: this suite runs under Mix today"
    System.put_env("BL_BIN", "/x")
    assert BeamLisp.Image.kind() == "drop"
    refute BeamLisp.Image.mutable?()
  end
end
