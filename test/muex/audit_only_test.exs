defmodule Muex.AuditOnlyTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Muex, as: MuexTask
  alias Muex.Audit.Validator

  import ExUnit.CaptureIO

  @tag :tmp_dir
  test "mix muex publishes complete optimized inventory without executing tests", %{tmp_dir: root} do
    marker = Path.join(root, "test-executed")
    plan_path = Path.join(root, "inventory.json")
    write_project!(root, marker)

    args = [
      "--project-root",
      root,
      "--files",
      Path.join(root, "lib"),
      "--test-paths",
      Path.join(root, "test"),
      "--mutators",
      "return_value",
      "--min-complexity",
      "0",
      "--no-filter",
      "--audit-only",
      "--audit-plan",
      plan_path
    ]

    Mix.Task.reenable("muex")

    assert capture_io(fn -> assert :ok = MuexTask.run(args) end) =~
             "Audit inventory published"

    refute File.exists?(marker)

    assert {:ok, %{plan: plan, selected_ids: [_ | _] = selected_ids}} =
             Validator.validate_plan_file(plan_path)

    assert plan["selected_count"] == length(selected_ids)
    assert plan["candidate_count"] == length(plan["mutants"])
    assert plan["optimizer"]["enabled"]
  end

  @tag :tmp_dir
  test "audit-only returns publication failure and never runs tests", %{tmp_dir: root} do
    marker = Path.join(root, "test-executed")
    plan_path = Path.join(root, "inventory.json")
    write_project!(root, marker)
    File.write!(plan_path, "occupied")

    config =
      config!(root,
        audit_only: true,
        audit_plan: plan_path,
        mutators: "return_value",
        min_complexity: 0
      )

    assert {:error, {:cannot_publish_artifact, :eexist}} = Muex.run(config)
    assert File.read!(plan_path) == "occupied"
    refute File.exists?(marker)

    Mix.Task.reenable("muex")

    assert_raise Mix.Error, ~r/cannot_publish_artifact.*eexist/, fn ->
      MuexTask.run([
        "--project-root",
        root,
        "--files",
        Path.join(root, "lib"),
        "--test-paths",
        Path.join(root, "test"),
        "--mutators",
        "return_value",
        "--min-complexity",
        "0",
        "--no-filter",
        "--audit-only",
        "--audit-plan",
        plan_path
      ])
    end
  end

  defp config!(root, overrides) do
    {:ok, config} =
      Muex.Config.from_opts(
        [
          project_root: root,
          files: Path.join(root, "lib"),
          test_paths: Path.join(root, "test"),
          no_filter: true
        ] ++ overrides
      )

    config
  end

  defp write_project!(root, marker) do
    write!(root, "mix.exs", """
    defmodule AuditOnlyFixture.MixProject do
      use Mix.Project
      def project, do: [app: :audit_only_fixture, version: "0.1.0"]
    end
    """)

    write!(root, "lib/example.ex", """
    defmodule AuditOnlyFixture.Example do
      def value do
        :original
      end
    end
    """)

    write!(root, "test/test_helper.exs", "ExUnit.start()\n")

    write!(root, "test/example_test.exs", """
    File.write!(#{inspect(marker)}, "executed")
    defmodule AuditOnlyFixture.ExampleTest do
      use ExUnit.Case
      test "value", do: assert(AuditOnlyFixture.Example.value() == :original)
    end
    """)
  end

  defp write!(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
