defmodule Muex.CampaignSeamTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Muex, as: MuexTask
  alias Mix.Tasks.Muex.Campaign
  alias Muex.CampaignPlan

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  @config %{
    "preset" => "none",
    "optimize" => true,
    "optimize_level" => "balanced",
    "max_mutations" => 0
  }

  test "an external wrapper chains audit-only, campaign build and slice", %{tmp_dir: root} do
    write_project!(root)

    File.cd!(root, fn ->
      Mix.Task.reenable("muex")

      assert capture_io(fn ->
               assert :ok =
                        MuexTask.run([
                          "--project-root",
                          ".",
                          "--files",
                          "lib",
                          "--test-paths",
                          "test",
                          "--mutators",
                          "return_value",
                          "--min-complexity",
                          "0",
                          "--no-filter",
                          "--audit-only",
                          "--audit-plan",
                          "inventory.json"
                        ])
             end) =~ "Audit inventory published"

      Mix.Task.reenable("muex.campaign")

      assert :ok =
               Campaign.run([
                 "build",
                 "--project-root",
                 ".",
                 "--audit-plan",
                 "inventory.json",
                 "--source-files",
                 "sources.txt",
                 "--test-files",
                 "tests.txt",
                 "--config-file",
                 "config.json",
                 "--shards",
                 "1",
                 "--commit-sha",
                 "seam",
                 "--output",
                 "campaign.json"
               ])

      assert {:ok, plan} = CampaignPlan.read("campaign.json")
      assert plan["metadata"]["commit_sha"] == "seam"
      assert [_ | _] = plan["requirements"]

      Mix.Task.reenable("muex.campaign")

      assert :ok =
               Campaign.run([
                 "slice",
                 "--project-root",
                 ".",
                 "--plan",
                 "campaign.json",
                 "--plan-sha256",
                 sha256_file("campaign.json"),
                 "--config-file",
                 "config.json",
                 "--shard",
                 "1",
                 "--output",
                 "slice-1.json"
               ])

      assert {:ok, slice} =
               CampaignPlan.read_execution_slice("slice-1.json", sha256_file("slice-1.json"))

      assert slice["source_files"] == ["lib/example.ex"]
      assert slice["test_files"] == ["test/example_test.exs"]
      assert length(slice["mutant_ids"]) == length(plan["requirements"])
    end)
  end

  defp write_project!(root) do
    write!(root, "mix.exs", """
    defmodule SeamFixture.MixProject do
      use Mix.Project
      def project, do: [app: :seam_fixture, version: "0.1.0"]
    end
    """)

    # Deliberately not written in its rendered form: a comment plus a keyword-form
    # body, which is what the audit inventory has to stay verifiable against.
    write!(root, "lib/example.ex", """
    defmodule SeamFixture.Example do
      # keyword form plus a comment
      def value, do: :original
    end
    """)

    write!(root, "test/test_helper.exs", "ExUnit.start()\n")

    write!(root, "test/example_test.exs", """
    defmodule SeamFixture.ExampleTest do
      use ExUnit.Case
      test "value", do: assert(SeamFixture.Example.value() == :original)
    end
    """)

    write!(root, "sources.txt", "lib/example.ex\n")
    write!(root, "tests.txt", "test/example_test.exs\n")
    write!(root, "config.json", Jason.encode!(@config))
  end

  defp write!(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp sha256_file(path) do
    :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
  end
end
