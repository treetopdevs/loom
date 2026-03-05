%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      checks: %{
        disabled: [
          # Pre-existing widespread pattern — not enforced
          {Credo.Check.Design.AliasUsage, false}
        ]
      }
    }
  ]
}
