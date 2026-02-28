defmodule Loom.ConfigTest do
  use ExUnit.Case, async: false

  @test_dir System.tmp_dir!()
            |> Path.join("loom_config_test_#{System.unique_integer([:positive])}")

  setup do
    # Config GenServer is already running via the application
    # Reset to defaults before each test
    Loom.Config.load(@test_dir)
    :ok
  end

  describe "defaults" do
    test "get/1 returns default model config" do
      model = Loom.Config.get(:model)
      assert model.default == "anthropic:claude-sonnet-4-6"
      assert model.weak == "anthropic:claude-haiku-4-5"
    end

    test "get/2 returns nested values" do
      assert Loom.Config.get(:model, :default) == "anthropic:claude-sonnet-4-6"
      assert Loom.Config.get(:model, :weak) == "anthropic:claude-haiku-4-5"
    end

    test "get/1 returns default permissions" do
      perms = Loom.Config.get(:permissions)
      assert "file_read" in perms.auto_approve
      assert "content_search" in perms.auto_approve
    end

    test "get/1 returns default context config" do
      ctx = Loom.Config.get(:context)
      assert ctx.max_repo_map_tokens == 2048
      assert ctx.reserved_output_tokens == 4096
    end

    test "get/1 returns default decisions config" do
      decisions = Loom.Config.get(:decisions)
      assert decisions.enabled == true
      assert decisions.enforce_pre_edit == false
    end

    test "get/1 returns nil for unknown keys" do
      assert Loom.Config.get(:nonexistent) == nil
    end

    test "get/2 returns nil for unknown subkeys" do
      assert Loom.Config.get(:model, :nonexistent) == nil
    end
  end

  describe "load/1" do
    test "loads from .loom.toml and merges with defaults" do
      File.mkdir_p!(@test_dir)

      toml_content = """
      [model]
      default = "openai:gpt-4o"

      [permissions]
      auto_approve = ["file_read", "shell"]
      """

      File.write!(Path.join(@test_dir, ".loom.toml"), toml_content)

      Loom.Config.load(@test_dir)

      # Overridden values
      assert Loom.Config.get(:model, :default) == "openai:gpt-4o"
      assert "shell" in Loom.Config.get(:permissions, :auto_approve)

      # Preserved defaults (deep merge keeps non-overridden keys)
      assert Loom.Config.get(:model, :weak) == "anthropic:claude-haiku-4-5"
      assert Loom.Config.get(:context, :max_repo_map_tokens) == 2048
    after
      File.rm_rf!(@test_dir)
    end

    test "unknown TOML sections do not prevent known keys from atomizing" do
      File.mkdir_p!(@test_dir)

      toml_content = """
      [model]
      default = "openai:gpt-4o"

      [my_custom_thing]
      foo = "bar"
      """

      File.write!(Path.join(@test_dir, ".loom.toml"), toml_content)

      Loom.Config.load(@test_dir)

      # Known keys should still be atomized and accessible
      assert Loom.Config.get(:model, :default) == "openai:gpt-4o"
      # Defaults preserved via deep merge
      assert Loom.Config.get(:model, :weak) == "anthropic:claude-haiku-4-5"
    after
      File.rm_rf!(@test_dir)
    end

    test "uses defaults when .loom.toml doesn't exist" do
      Loom.Config.load("/tmp/nonexistent_loom_path")

      defaults = Loom.Config.defaults()
      assert Loom.Config.get(:model) == defaults.model
      assert Loom.Config.get(:permissions) == defaults.permissions
    end
  end

  describe "put/2" do
    test "overrides a config value for the session" do
      Loom.Config.put(:model, %{default: "custom:model", weak: "custom:weak"})

      assert Loom.Config.get(:model, :default) == "custom:model"
      assert Loom.Config.get(:model, :weak) == "custom:weak"
    end
  end

  describe "all/0" do
    test "returns the full config map" do
      config = Loom.Config.all()
      assert is_map(config)
      assert Map.has_key?(config, :model)
      assert Map.has_key?(config, :permissions)
      assert Map.has_key?(config, :context)
      assert Map.has_key?(config, :decisions)
    end
  end
end
