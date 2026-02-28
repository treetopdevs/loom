defmodule LoomTest do
  use ExUnit.Case, async: true

  test "version is defined" do
    assert Loom.version() != nil
  end
end
