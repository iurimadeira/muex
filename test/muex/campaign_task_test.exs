defmodule Muex.CampaignTaskTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Muex.Campaign
  alias Muex.CampaignPlan
  alias Muex.Coverage

  @tag :tmp_dir
  test "builds one immutable plan and materializes an exact shard slice", %{tmp_dir: root} do
    write!(root, "lib/a.ex", "a")
    write!(root, "lib/b.ex", "b")
    write!(root, "test/a_test.exs", "a test")
    write!(root, "bin/runtime-value", "available")
    source_list = Path.join(root, "sources.txt")
    test_list = Path.join(root, "tests.txt")
    auxiliary_list = Path.join(root, "auxiliary.txt")
    audit_plan = Path.join(root, "audit-plan.json")
    config_file = Path.join(root, "config.json")
    plan_path = Path.join(root, "campaign.json")
    slice_path = Path.join(root, "slice.json")
    File.write!(source_list, "lib/a.ex\nlib/b.ex\n")
    File.write!(test_list, "test/a_test.exs\n")
    File.write!(auxiliary_list, "bin\n")

    config = %{
      preset: "none",
      optimize: true,
      optimize_level: "balanced",
      max_mutations: 0
    }

    File.write!(config_file, Jason.encode!(config))

    File.write!(
      audit_plan,
      Jason.encode!(audit_plan(%{"lib/a.ex" => "a", "lib/b.ex" => "b"}, config))
    )

    coverage_fingerprint =
      Coverage.corpus_fingerprint(
        root,
        ["lib/a.ex", "lib/b.ex"],
        ["test/a_test.exs"],
        nil,
        ["bin"]
      )

    coverage_index = Path.join(root, "coverage.etf")
    Coverage.write_index!(Coverage.new(), coverage_index)

    File.write!(
      coverage_index <> ".manifest.json",
      Jason.encode!(%{
        version: 1,
        corpus_fingerprint: coverage_fingerprint,
        index_sha256: sha256_file(coverage_index)
      })
    )

    Mix.Task.reenable("muex.campaign")

    assert :ok =
             Campaign.run([
               "build",
               "--project-root",
               root,
               "--audit-plan",
               audit_plan,
               "--source-files",
               source_list,
               "--test-files",
               test_list,
               "--auxiliary-paths-file",
               auxiliary_list,
               "--coverage-index",
               coverage_index,
               "--config-file",
               config_file,
               "--shards",
               "2",
               "--commit-sha",
               "metadata-only",
               "--output",
               plan_path
             ])

    assert {:ok, plan} = CampaignPlan.read(plan_path)
    assert plan["metadata"]["commit_sha"] == "metadata-only"
    assert plan["metadata"]["audit_plan_sha256"] == sha256_file(audit_plan)
    assert plan["metadata"]["audit_optimizer"]["enabled"] == true
    assert plan["coverage"]["corpus_fingerprint"] == coverage_fingerprint
    assert plan["coverage"]["index_sha256"] == sha256_file(coverage_index)
    assert length(plan["requirements"]) == 2
    plan_artifact_sha256 = sha256_file(plan_path)

    Mix.Task.reenable("muex.campaign")

    assert :ok =
             Campaign.run([
               "slice",
               "--project-root",
               root,
               "--plan",
               plan_path,
               "--plan-sha256",
               plan_artifact_sha256,
               "--config-file",
               config_file,
               "--coverage-index",
               coverage_index,
               "--shard",
               "1",
               "--output",
               slice_path
             ])

    slice_artifact_sha256 = sha256_file(slice_path)
    assert {:ok, slice} = CampaignPlan.read_execution_slice(slice_path, slice_artifact_sha256)
    assert slice["coverage"]["status"] == "valid"
    assert slice["plan_artifact_sha256"] == plan_artifact_sha256
    assert is_binary(slice["slice_sha256"])
    assert length(slice["source_files"]) == 1
    assert length(slice["mutant_ids"]) == 1
    assert slice["test_files"] == ["test/a_test.exs"]
    assert hd(slice["requirements"])["mutant_id"] == hd(slice["mutant_ids"])

    forged_slice_path = Path.join(root, "resealed-slice.json")
    forged_slice = slice |> Map.put("mutant_ids", []) |> reseal_slice()
    File.write!(forged_slice_path, Jason.encode!(forged_slice))

    assert {:error, :invalid_campaign_slice_structure} =
             CampaignPlan.read_execution_slice(
               forged_slice_path,
               sha256_file(forged_slice_path)
             )

    Mix.Task.reenable("muex.campaign")

    assert_raise Mix.Error, ~r/campaign slice failed.*campaign_plan_artifact_hash_mismatch/, fn ->
      Campaign.run([
        "slice",
        "--project-root",
        root,
        "--plan",
        plan_path,
        "--plan-sha256",
        String.duplicate("0", 64),
        "--config-file",
        config_file,
        "--shard",
        "1",
        "--output",
        Path.join(root, "forged-slice.json")
      ])
    end

    write!(root, "lib/a.ex", "changed")
    Mix.Task.reenable("muex.campaign")

    assert_raise Mix.Error, ~r/campaign planning failed.*invalid_campaign_inventory/, fn ->
      Campaign.run([
        "build",
        "--project-root",
        root,
        "--audit-plan",
        audit_plan,
        "--source-files",
        source_list,
        "--test-files",
        test_list,
        "--config-file",
        config_file,
        "--shards",
        "2",
        "--output",
        Path.join(root, "stale-campaign.json")
      ])
    end
  end

  defp audit_plan(sources, config) do
    mutants = Enum.map(sources, fn {path, source} -> audit_mutant(path, source) end)

    %{
      version: 1,
      optimizer: %{
        enabled: config.optimize,
        level: config.optimize_level,
        heuristic_equivalence: false,
        tce: false,
        max_mutations: config.max_mutations
      },
      exhaustive: true,
      source_file_count: map_size(sources),
      selected_source_file_count: map_size(sources),
      source_files:
        sources
        |> Map.keys()
        |> Enum.sort()
        |> Enum.map(&%{path: &1, selected: true, selection_reason: "selected_all"}),
      candidate_count: length(mutants),
      selected_count: length(mutants),
      mutants: mutants
    }
  end

  defp audit_mutant(path, source) do
    mutator = "Muex.TestMutator"
    description = "replace source"
    patch = %{before: source, after: String.upcase(source)}
    id = Muex.mutation_id(mutator, description, path, 1, patch, 0)

    %{
      id: id,
      selected: true,
      selection_reason: "selected_all",
      mutator: mutator,
      description: description,
      location: %{file: path, line: 1},
      target_ordinal: 0,
      patch: patch,
      original_source: source,
      original_sha256: sha256(source),
      mutated_source: String.upcase(source),
      mutated_sha256: sha256(String.upcase(source))
    }
  end

  defp write!(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp sha256_file(path) do
    :sha256
    |> :crypto.hash(File.read!(path))
    |> Base.encode16(case: :lower)
  end

  defp sha256(contents) do
    :sha256
    |> :crypto.hash(contents)
    |> Base.encode16(case: :lower)
  end

  defp reseal_slice(slice) do
    unsealed = Map.delete(slice, "slice_sha256")
    Map.put(unsealed, "slice_sha256", digest_term({"muex-campaign-slice-v1", unsealed}))
  end

  defp digest_term(term), do: term |> :erlang.term_to_binary() |> sha256()
end
