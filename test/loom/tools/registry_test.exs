defmodule Loom.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias Loom.Tools.Registry

  test "all/0 returns a list of tool modules" do
    tools = Registry.all()
    assert is_list(tools)
    assert length(tools) >= 6
    assert Loom.Tools.FileRead in tools
    assert Loom.Tools.FileWrite in tools
    assert Loom.Tools.FileEdit in tools
    assert Loom.Tools.FileSearch in tools
    assert Loom.Tools.ContentSearch in tools
    assert Loom.Tools.DirectoryList in tools
  end

  test "definitions/0 returns tool definitions" do
    defs = Registry.definitions()
    assert is_list(defs)
    names = Enum.map(defs, fn d -> d.name end)
    assert "file_read" in names
    assert "file_write" in names
    assert "file_edit" in names
    assert "file_search" in names
    assert "content_search" in names
    assert "directory_list" in names
  end

  test "find/1 returns tool module by name" do
    assert {:ok, Loom.Tools.FileRead} = Registry.find("file_read")
    assert {:ok, Loom.Tools.FileWrite} = Registry.find("file_write")
  end

  test "find/1 returns error for unknown tool" do
    assert {:error, msg} = Registry.find("nonexistent_tool")
    assert msg =~ "Unknown tool"
  end

  @tag :tmp_dir
  test "execute/3 runs a tool by name", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "exec_test.txt")
    File.write!(file, "test content\n")

    assert {:ok, %{result: result}} =
             Registry.execute("file_read", %{"file_path" => "exec_test.txt"}, %{
               project_path: tmp_dir
             })

    assert result =~ "test content"
  end

  @tag :tmp_dir
  test "execute/3 returns error for unknown tool", %{tmp_dir: tmp_dir} do
    assert {:error, msg} = Registry.execute("bad_tool", %{}, %{project_path: tmp_dir})
    assert msg =~ "Unknown tool"
  end
end
