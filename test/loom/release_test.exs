defmodule Loom.ReleaseTest do
  use ExUnit.Case, async: true

  describe "db_path/0" do
    test "returns a path string" do
      path = Loom.Release.db_path()
      assert is_binary(path)
      assert String.ends_with?(path, ".db")
    end
  end

  describe "create_db/0" do
    test "ensures directory exists" do
      assert :ok = Loom.Release.create_db()
      db_dir = Path.dirname(Loom.Release.db_path())
      assert File.dir?(db_dir)
    end
  end

  describe "release config" do
    test "mix.exs defines loom release" do
      releases = Loom.MixProject.project()[:releases]
      assert releases != nil
      assert Keyword.has_key?(releases, :loom)

      loom_release = releases[:loom]
      assert :assemble in loom_release[:steps]
    end
  end
end
