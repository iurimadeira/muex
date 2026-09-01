defmodule Muex.CampaignPlanTest do
  use ExUnit.Case, async: true

  alias Muex.CampaignPlan
  alias Muex.Coverage

  @tag :tmp_dir
  test "balances atomic source files deterministically by estimated mutant work", %{tmp_dir: root} do
    write!(root, "lib/a.ex", "a")
    write!(root, "lib/b.ex", "b")
    write!(root, "lib/c.ex", "c")
    write!(root, "test/a_test.exs", "a test")
    write!(root, "test/b_test.exs", "b test")
    tests = ["test/a_test.exs", "test/b_test.exs"]

    coverage =
      Coverage.new()
      |> Coverage.put("lib/a.ex", 1, "test/a_test.exs")
      |> Coverage.put("lib/a.ex", 2, "test/b_test.exs")
      |> Coverage.put("lib/b.ex", 1, "test/a_test.exs")
      |> Coverage.put("lib/c.ex", 1, "test/a_test.exs")

    mutations = [
      mutation("a1", "lib/a.ex", 1),
      mutation("a2", "lib/a.ex", 2),
      mutation("b1", "lib/b.ex", 1),
      mutation("c1", "lib/c.ex", 1)
    ]

    opts = [
      shards: 2,
      config: %{preset: "none"},
      coverage_fingerprint: digest("coverage"),
      coverage_index_sha256: digest("index")
    ]

    assert {:ok, first} =
             CampaignPlan.build(
               root,
               mutations,
               ~w(lib/a.ex lib/b.ex lib/c.ex),
               tests,
               coverage,
               opts
             )

    assert {:ok, second} =
             CampaignPlan.build(
               root,
               Enum.reverse(mutations),
               ~w(lib/c.ex lib/a.ex lib/b.ex),
               Enum.reverse(tests),
               coverage,
               opts
             )

    assert first == second

    assert [
             %{"source_files" => ["lib/a.ex"], "estimated_work" => 2},
             %{"source_files" => ["lib/b.ex", "lib/c.ex"], "estimated_work" => 2}
           ] = first["shards"]
  end

  @tag :tmp_dir
  test "fingerprints invalidate changed content but ignore commit metadata", %{tmp_dir: root} do
    write!(root, "lib/a.ex", "same source")
    write!(root, "test/a_test.exs", "same test")
    coverage = Coverage.put(Coverage.new(), "lib/a.ex", 1, "test/a_test.exs")
    args = [root, [mutation("a1", "lib/a.ex", 1)], ["lib/a.ex"], ["test/a_test.exs"], coverage]

    opts = [
      shards: 1,
      config: %{preset: "none"},
      coverage_fingerprint: digest("coverage"),
      coverage_index_sha256: digest("index")
    ]

    assert {:ok, first} =
             apply(CampaignPlan, :build, args ++ [Keyword.put(opts, :commit_sha, "one")])

    assert {:ok, second} =
             apply(CampaignPlan, :build, args ++ [Keyword.put(opts, :commit_sha, "two")])

    assert first["global_fingerprint"] == second["global_fingerprint"]
    assert hd(first["files"])["fingerprint"] == hd(second["files"])["fingerprint"]
    assert :ok = CampaignPlan.validate(root, second, config: %{preset: "none"})

    assert {:error, :campaign_config_mismatch} =
             CampaignPlan.validate(root, second, config: %{preset: "phoenix"})

    write!(root, "test/a_test.exs", "changed test")

    assert {:error, {:stale_files, ["test/a_test.exs"]}} =
             CampaignPlan.validate(root, second, config: %{preset: "none"})
  end

  @tag :tmp_dir
  test "unknown coverage falls back only in the shard containing that file", %{tmp_dir: root} do
    for path <- ~w(lib/known.ex lib/unknown.ex test/known_test.exs test/other_test.exs),
        do: write!(root, path, path)

    coverage = Coverage.put(Coverage.new(), "lib/known.ex", 1, "test/known_test.exs")
    mutations = [mutation("known", "lib/known.ex", 1), mutation("unknown", "lib/unknown.ex", 9)]

    assert {:ok, plan} =
             CampaignPlan.build(
               root,
               mutations,
               ~w(lib/known.ex lib/unknown.ex),
               ~w(test/known_test.exs test/other_test.exs),
               coverage,
               shards: 2,
               config: %{},
               coverage_fingerprint: digest("coverage"),
               coverage_index_sha256: digest("index")
             )

    known = Enum.find(plan["shards"], &("lib/known.ex" in &1["source_files"]))
    unknown = Enum.find(plan["shards"], &("lib/unknown.ex" in &1["source_files"]))
    assert known["test_files"] == ["test/known_test.exs"]
    assert known["fallback_reasons"] == []
    assert unknown["test_files"] == ~w(test/known_test.exs test/other_test.exs)
    assert unknown["fallback_reasons"] == ["unknown_without_file_evidence"]

    assert Enum.find(plan["requirements"], &(&1["mutant_id"] == "unknown"))["test_files"] ==
             ~w(test/known_test.exs test/other_test.exs)
  end

  @tag :tmp_dir
  test "a shard accepts coverage bound to the global corpus without subset recomputation", %{
    tmp_dir: root
  } do
    for path <- ~w(lib/a.ex lib/b.ex test/a_test.exs test/b_test.exs),
        do: write!(root, path, path)

    coverage =
      Coverage.new()
      |> Coverage.put("lib/a.ex", 1, "test/a_test.exs")
      |> Coverage.put("lib/b.ex", 1, "test/b_test.exs")

    index_path = Path.join(root, "coverage.etf")
    Coverage.write_index!(coverage, index_path)

    fingerprint =
      Coverage.corpus_fingerprint(
        root,
        ~w(lib/a.ex lib/b.ex),
        ~w(test/a_test.exs test/b_test.exs)
      )

    index_sha256 = sha256_file(index_path)

    File.write!(
      index_path <> ".manifest.json",
      Jason.encode!(%{version: 1, corpus_fingerprint: fingerprint, index_sha256: index_sha256})
    )

    assert {:ok, plan} =
             CampaignPlan.build(
               root,
               [mutation("a", "lib/a.ex", 1), mutation("b", "lib/b.ex", 1)],
               ~w(lib/a.ex lib/b.ex),
               ~w(test/a_test.exs test/b_test.exs),
               coverage,
               shards: 2,
               config: %{},
               coverage_fingerprint: fingerprint,
               coverage_index_sha256: index_sha256
             )

    assert {:ok, slice} =
             CampaignPlan.execution_slice(root, plan, 1, index_path,
               config: %{},
               plan_artifact_sha256: digest("plan")
             )

    assert slice["coverage"]["status"] == "valid"
    assert is_binary(slice["slice_sha256"])
    assert length(slice["source_files"]) == 1
    assert length(slice["test_files"]) == 1
  end

  @tag :tmp_dir
  test "a stale global coverage artifact expands only the requested shard to the full corpus", %{
    tmp_dir: root
  } do
    for path <- ~w(lib/a.ex lib/b.ex test/a_test.exs test/b_test.exs),
        do: write!(root, path, path)

    coverage = Coverage.put(Coverage.new(), "lib/a.ex", 1, "test/a_test.exs")
    fingerprint = digest("global")

    assert {:ok, plan} =
             CampaignPlan.build(
               root,
               [mutation("a", "lib/a.ex", 1), mutation("b", "lib/b.ex", 1)],
               ~w(lib/a.ex lib/b.ex),
               ~w(test/a_test.exs test/b_test.exs),
               coverage,
               shards: 2,
               config: %{},
               coverage_fingerprint: fingerprint,
               coverage_index_sha256: digest("expected-index")
             )

    assert {:ok, slice} =
             CampaignPlan.execution_slice(root, plan, 1, Path.join(root, "missing.etf"),
               config: %{},
               plan_artifact_sha256: digest("plan")
             )

    assert slice["coverage"]["status"] == "stale"
    assert slice["test_files"] == ~w(test/a_test.exs test/b_test.exs)
    assert Enum.all?(slice["requirements"], &(&1["fallback_reason"] == "coverage_artifact_stale"))
  end

  @tag :tmp_dir
  test "continuation keeps stable ids, file atomicity, and each id's test requirements", %{
    tmp_dir: root
  } do
    for path <- ~w(lib/a.ex lib/b.ex test/a_test.exs test/b_test.exs),
        do: write!(root, path, path)

    coverage =
      Coverage.new()
      |> Coverage.put("lib/a.ex", 1, "test/a_test.exs")
      |> Coverage.put("lib/a.ex", 2, "test/b_test.exs")
      |> Coverage.put("lib/b.ex", 1, "test/b_test.exs")

    assert {:ok, plan} =
             CampaignPlan.build(
               root,
               [
                 mutation("a-one", "lib/a.ex", 1),
                 mutation("a-two", "lib/a.ex", 2),
                 mutation("b-one", "lib/b.ex", 1)
               ],
               ~w(lib/a.ex lib/b.ex),
               ~w(test/a_test.exs test/b_test.exs),
               coverage,
               shards: 2,
               config: %{},
               coverage_fingerprint: digest("coverage"),
               coverage_index_sha256: digest("index")
             )

    assert {:ok, continuation} = CampaignPlan.continuation(plan, ~w(a-two b-one), 2)
    assert continuation["parent_plan_sha256"] == plan["plan_sha256"]
    assert continuation["selected_ids"] == ~w(a-two b-one)

    a_slice = Enum.find(continuation["shards"], &("lib/a.ex" in &1["source_files"]))
    assert a_slice["mutant_ids"] == ["a-two"]
    assert a_slice["test_files"] == ["test/b_test.exs"]
    assert hd(a_slice["requirements"])["mutant_id"] == "a-two"
    assert hd(a_slice["requirements"])["test_files"] == ["test/b_test.exs"]
  end

  @tag :tmp_dir
  test "plan publication is exclusive and rejects tampering and symlink components", %{
    tmp_dir: root
  } do
    write!(root, "lib/a.ex", "a")
    write!(root, "test/a_test.exs", "test")

    assert {:ok, plan} =
             CampaignPlan.build(
               root,
               [mutation("a", "lib/a.ex", 1)],
               ["lib/a.ex"],
               ["test/a_test.exs"],
               nil,
               shards: 1,
               config: %{},
               coverage_fingerprint: digest("coverage")
             )

    path = Path.join(root, "campaign.json")
    assert :ok = CampaignPlan.write(plan, path)
    assert {:error, {:cannot_publish_artifact, :eexist}} = CampaignPlan.write(plan, path)

    tampered = Map.put(plan, "global_fingerprint", digest("forged"))
    File.write!(path, Jason.encode!(tampered))
    assert {:error, :campaign_plan_hash_mismatch} = CampaignPlan.read(path)

    real = Path.join(root, "real")
    linked = Path.join(root, "linked")
    File.mkdir_p!(real)
    File.ln_s!(real, linked)

    assert {:error, {:cannot_publish_artifact, :unsafe_artifact_directory}} =
             CampaignPlan.write(plan, Path.join(linked, "campaign.json"))
  end

  @tag :tmp_dir
  test "coverage can narrow only when its fingerprint and captured index digest are bound", %{
    tmp_dir: root
  } do
    write!(root, "lib/a.ex", "a")
    write!(root, "test/a_test.exs", "test")
    coverage = Coverage.put(Coverage.new(), "lib/a.ex", 1, "test/a_test.exs")
    args = [root, [mutation("a", "lib/a.ex", 1)], ["lib/a.ex"], ["test/a_test.exs"], coverage]

    assert {:error, :unbound_coverage_index} =
             apply(
               CampaignPlan,
               :build,
               args ++ [[shards: 1, config: %{}, coverage_fingerprint: digest("coverage")]]
             )

    assert {:error, :invalid_coverage_binding} =
             apply(
               CampaignPlan,
               :build,
               args ++
                 [
                   [
                     shards: 1,
                     config: %{},
                     coverage_fingerprint: "INVALID",
                     coverage_index_sha256: digest("index")
                   ]
                 ]
             )
  end

  @tag :tmp_dir
  test "rejects duplicate or empty stable mutation ids before sharding", %{tmp_dir: root} do
    write!(root, "lib/a.ex", "a")
    write!(root, "test/a_test.exs", "test")
    opts = [shards: 1, config: %{}, coverage_fingerprint: digest("coverage")]

    assert {:error, :duplicate_mutation_ids} =
             CampaignPlan.build(
               root,
               [mutation("same", "lib/a.ex", 1), mutation("same", "lib/a.ex", 2)],
               ["lib/a.ex"],
               ["test/a_test.exs"],
               nil,
               opts
             )

    assert {:error, :invalid_mutation_id} =
             CampaignPlan.build(
               root,
               [mutation("", "lib/a.ex", 1)],
               ["lib/a.ex"],
               ["test/a_test.exs"],
               nil,
               opts
             )
  end

  @tag :tmp_dir
  test "rejects source and test symlink components before fingerprint reads", %{tmp_dir: root} do
    external = Path.join(root, "external")
    File.mkdir_p!(external)
    File.write!(Path.join(external, "a.ex"), "external")
    File.ln_s!(external, Path.join(root, "linked"))
    write!(root, "test/a_test.exs", "test")

    assert {:error, {:unsafe_campaign_path, "linked/a.ex"}} =
             CampaignPlan.build(
               root,
               [mutation("a", "linked/a.ex", 1)],
               ["linked/a.ex"],
               ["test/a_test.exs"],
               nil,
               shards: 1,
               config: %{},
               coverage_fingerprint: digest("coverage")
             )
  end

  @tag :tmp_dir
  test "structural validation rejects internally resealed cross-field inconsistencies", %{
    tmp_dir: root
  } do
    write!(root, "lib/a.ex", "a")
    write!(root, "test/a_test.exs", "test")

    assert {:ok, plan} =
             CampaignPlan.build(
               root,
               [mutation("a", "lib/a.ex", 1)],
               ["lib/a.ex"],
               ["test/a_test.exs"],
               nil,
               shards: 1,
               config: %{},
               coverage_fingerprint: digest("coverage")
             )

    forged =
      plan
      |> put_in(["shards", Access.at(0), "mutant_ids"], [])
      |> reseal()

    assert {:error, :invalid_campaign_plan_structure} =
             CampaignPlan.validate(root, forged, config: %{})
  end

  defp mutation(id, file, line), do: %{id: id, location: %{file: file, line: line}}

  defp write!(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp digest(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
  defp sha256_file(path), do: path |> File.read!() |> digest()

  defp reseal(plan) do
    unsealed = Map.delete(plan, "plan_sha256")

    plan_sha256 =
      {"muex-campaign-plan-v1", unsealed}
      |> :erlang.term_to_binary()
      |> digest()

    Map.put(unsealed, "plan_sha256", plan_sha256)
  end
end
