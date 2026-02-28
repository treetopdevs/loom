defmodule Loom.Tools.ShellTest do
  use ExUnit.Case, async: true

  alias Loom.Tools.Shell

  @tag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    %{project_path: tmp_dir}
  end

  test "definition returns valid tool definition" do
    defn = Shell.definition()
    assert defn.name == "shell"
    assert "command" in defn.parameters.required
  end

  @tag :tmp_dir
  test "runs a simple command", %{project_path: proj} do
    params = %{"command" => "echo hello"}
    assert {:ok, result} = Shell.run(params, %{project_path: proj})
    assert result =~ "Exit code: 0"
    assert result =~ "hello"
  end

  @tag :tmp_dir
  test "captures stderr in output", %{project_path: proj} do
    params = %{"command" => "echo error >&2"}
    assert {:ok, result} = Shell.run(params, %{project_path: proj})
    assert result =~ "error"
  end

  @tag :tmp_dir
  test "returns error for non-zero exit code", %{project_path: proj} do
    params = %{"command" => "exit 1"}
    assert {:error, result} = Shell.run(params, %{project_path: proj})
    assert result =~ "Exit code: 1"
  end

  @tag :tmp_dir
  test "runs command in project directory", %{project_path: proj} do
    File.write!(Path.join(proj, "marker.txt"), "found")
    params = %{"command" => "cat marker.txt"}
    assert {:ok, result} = Shell.run(params, %{project_path: proj})
    assert result =~ "found"
  end

  @tag :tmp_dir
  test "times out long-running commands", %{project_path: proj} do
    params = %{"command" => "sleep 60", "timeout" => 100}
    assert {:error, result} = Shell.run(params, %{project_path: proj})
    assert result =~ "timed out"
  end

  @tag :tmp_dir
  test "truncates large output", %{project_path: proj} do
    # Generate output larger than 10K chars
    params = %{"command" => "yes | head -5000"}
    assert {:ok, result} = Shell.run(params, %{project_path: proj})
    assert result =~ "truncated"
  end
end
