defmodule Muex.HardeningTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Muex.Audit
  alias Muex.Checkpoint
  alias Muex.Compiler
  alias Muex.Config
  alias Muex.Continuation
  alias Muex.Continuation.Artifact
  alias Muex.Coverage
  alias Muex.ExUnitFormatter
  alias Muex.InventoryCache
  alias Muex.Language.Elixir, as: ElixirLanguage
  alias Muex.MutantOptimizer
  alias Muex.Mutator.Comparison
  alias Muex.Mutator.Literal
  alias Muex.Runner
  alias Muex.Sandbox
  alias Muex.TestRunner.Port, as: PortRunner

  setup context do
    if tmp_dir = context[:tmp_dir] do
      File.rm_rf!(tmp_dir)
      File.mkdir_p!(tmp_dir)
    end

    :ok
  end

  defmodule GenerationErrorLanguage do
    @moduledoc false
    @behaviour Muex.Language

    alias ElixirLanguage, as: DelegateLanguage

    @impl true
    defdelegate parse(source), to: DelegateLanguage

    @impl true
    def unparse(_ast) do
      {:error,
       %FunctionClauseError{
         module: Code.Normalizer,
         function: :normalize_kw_args,
         arity: 3
       }}
    end

    @impl true
    defdelegate compile(source, module_name), to: DelegateLanguage

    @impl true
    defdelegate file_extensions(), to: DelegateLanguage

    @impl true
    defdelegate test_file_pattern(), to: DelegateLanguage
  end

  defmodule InventoryProbeMutator do
    @moduledoc false
    @behaviour Muex.Mutator

    @impl true
    def mutate(_ast, _context) do
      if pid = Process.whereis(:muex_inventory_probe), do: send(pid, :inventory_walk)
      []
    end

    @impl true
    def name, do: "Inventory probe"

    @impl true
    def description, do: "Observes inventory generation"

    @impl true
    def supported_languages, do: [ElixirLanguage]
  end

  @tag :tmp_dir
  test "coverage exports are isolated from the project and retained for audit", %{
    tmp_dir: tmp_dir
  } do
    project = coverage_fixture!(tmp_dir)
    source = Path.join(project, "lib/example.ex")
    test_file = Path.join(project, "test/example_test.exs")
    output = Path.join(tmp_dir, "audit/coverage")
    File.rm_rf!(output)

    index =
      Coverage.collect(
        [test_file],
        %{source => MuexCoverageFixture.Example},
        cd: project,
        output: output
      )

    assert {:covered, [^test_file]} = Coverage.tests_for(index, source, 2)
    assert [_coverdata] = Path.wildcard(Path.join(output, "*.coverdata"))
    assert [log] = Path.wildcard(Path.join(output, "*.log"))
    assert File.read!(log) =~ "Result: 1 passed"
    refute File.exists?(Path.join(project, "compile-probe"))
    refute File.exists?(Path.join(project, "cover"))
    refute File.exists?(Path.join(project, "tmp"))
  end

  @tag :tmp_dir
  test "coverage collection materializes explicit auxiliary project paths", %{tmp_dir: tmp_dir} do
    project = coverage_fixture!(tmp_dir)
    source = Path.join(project, "lib/example.ex")
    test_file = Path.join(project, "test/auxiliary_test.exs")
    File.mkdir_p!(Path.join(project, "bin"))
    File.write!(Path.join(project, "bin/runtime-value"), "available")

    File.write!(
      test_file,
      """
      defmodule MuexCoverageFixture.AuxiliaryTest do
        use ExUnit.Case

        test "auxiliary path" do
          assert File.read!("bin/runtime-value") == "available"
          assert MuexCoverageFixture.Example.value() == 1
        end
      end
      """
    )

    index =
      Coverage.collect(
        [test_file],
        %{source => MuexCoverageFixture.Example},
        cd: project,
        auxiliary_paths: ["bin"],
        output: Path.join(tmp_dir, "audit/coverage")
      )

    assert {:covered, [^test_file]} = Coverage.tests_for(index, source, 2)
  end

  @tag :tmp_dir
  test "coverage batches a partition and conservatively attributes its covered lines", %{
    tmp_dir: tmp_dir
  } do
    project = coverage_fixture!(tmp_dir)
    source = Path.join(project, "lib/example.ex")
    first_test = Path.join(project, "test/example_test.exs")
    second_test = Path.join(project, "test/other_test.exs")
    output = Path.join(tmp_dir, "audit/coverage")

    index =
      Coverage.collect(
        [first_test, second_test],
        %{source => MuexCoverageFixture.Example},
        cd: project,
        output: output
      )

    expected_tests = Enum.sort([first_test, second_test])
    assert {:covered, ^expected_tests} = Coverage.tests_for(index, source, 2)
    assert {:covered, ^expected_tests} = Coverage.tests_for(index, source, 3)
    assert [_coverdata] = Path.wildcard(Path.join(output, "*.coverdata"))
    assert [log] = Path.wildcard(Path.join(output, "*.log"))
    assert File.read!(log) =~ "Result: 2 passed"
  end

  @tag :tmp_dir
  test "coverage export audits conservative batch membership and evidence", %{tmp_dir: tmp_dir} do
    project = coverage_fixture!(tmp_dir)
    source_files = Path.join(tmp_dir, "source-files.txt")
    test_files = Path.join(tmp_dir, "test-files.txt")
    auxiliary_paths = Path.join(tmp_dir, "auxiliary-paths.txt")
    index_path = Path.join(tmp_dir, "partition-1.etf")
    audit_dir = Path.join(tmp_dir, "partition-1-audit")
    File.mkdir_p!(Path.join(project, "bin"))
    File.write!(Path.join(project, "bin/runtime-value"), "available")
    File.write!(source_files, "lib/example.ex\n")
    File.write!(test_files, "test/example_test.exs\ntest/other_test.exs\n")
    File.write!(auxiliary_paths, "bin\n")
    Mix.Task.reenable("muex.coverage")

    assert :ok =
             Mix.Tasks.Muex.Coverage.run([
               "export",
               "--project-root",
               project,
               "--source-files",
               source_files,
               "--test-files",
               test_files,
               "--corpus-test-files",
               test_files,
               "--auxiliary-paths-file",
               auxiliary_paths,
               "--index",
               index_path,
               "--audit-dir",
               audit_dir,
               "--partition",
               "1"
             ])

    manifest = Jason.decode!(File.read!(index_path <> ".manifest.json"))
    assert manifest["batch"]["mode"] == "conservative_partition"
    assert manifest["batch"]["tests"] == ["test/example_test.exs", "test/other_test.exs"]
    assert manifest["batch"]["test_count"] == 2
    assert Enum.sort(manifest["batch"]["evidence"]) == Enum.sort(manifest["evidence"])
    assert Enum.all?(manifest["batch"]["evidence"], &File.regular?(&1["path"]))

    assert manifest["corpus_fingerprint"] ==
             Coverage.corpus_fingerprint(
               project,
               ["lib/example.ex"],
               ["test/example_test.exs", "test/other_test.exs"],
               nil,
               ["bin"]
             )
  end

  @tag :tmp_dir
  test "coverage partitions bind to one global corpus fingerprint before merge", %{
    tmp_dir: tmp_dir
  } do
    project = coverage_fixture!(tmp_dir)
    source_files = Path.join(tmp_dir, "source-files.txt")
    first_tests = Path.join(tmp_dir, "first-tests.txt")
    second_tests = Path.join(tmp_dir, "second-tests.txt")
    corpus_tests = Path.join(tmp_dir, "corpus-tests.txt")
    File.write!(source_files, "lib/example.ex\n")
    File.write!(first_tests, "test/example_test.exs\n")
    File.write!(second_tests, "test/other_test.exs\n")
    File.write!(corpus_tests, "test/example_test.exs\ntest/other_test.exs\n")

    manifests =
      for {partition, tests} <- [{1, first_tests}, {2, second_tests}] do
        index = Path.join(tmp_dir, "partition-#{partition}.etf")
        Mix.Task.reenable("muex.coverage")

        assert :ok =
                 Mix.Tasks.Muex.Coverage.run([
                   "export",
                   "--project-root",
                   project,
                   "--source-files",
                   source_files,
                   "--test-files",
                   tests,
                   "--corpus-test-files",
                   corpus_tests,
                   "--index",
                   index,
                   "--audit-dir",
                   Path.join(tmp_dir, "audit-#{partition}"),
                   "--partition",
                   Integer.to_string(partition)
                 ])

        Jason.decode!(File.read!(index <> ".manifest.json"))
      end

    assert [fingerprint] = manifests |> Enum.map(& &1["corpus_fingerprint"]) |> Enum.uniq()

    assert fingerprint ==
             Coverage.corpus_fingerprint(
               project,
               ["lib/example.ex"],
               ["test/example_test.exs", "test/other_test.exs"],
               System.get_env("MUEX_COVERAGE_MODULES_FILE")
             )
  end

  @tag :tmp_dir
  test "coverage collection fails closed when the verified build is missing a selected beam", %{
    tmp_dir: tmp_dir
  } do
    project = coverage_fixture!(tmp_dir)
    source = Path.join(project, "lib/example.ex")
    test_file = Path.join(project, "test/example_test.exs")
    output = Path.join(tmp_dir, "audit/coverage")
    File.rm_rf!(output)

    beam =
      Path.join(
        project,
        "_build/test/lib/muex_coverage_fixture/ebin/Elixir.MuexCoverageFixture.Example.beam"
      )

    File.rm!(beam)

    assert_raise RuntimeError, ~r/coverage collection failed.*example_test[.]exs/, fn ->
      Coverage.collect(
        [test_file],
        %{source => MuexCoverageFixture.Example},
        cd: project,
        output: output
      )
    end

    refute File.exists?(Path.join(project, "compile-probe"))
  end

  @tag :tmp_dir
  test "coverage collection failures retain output and abort", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "project")
    test_file = Path.join(project, "test/example_test.exs")
    output = Path.join(tmp_dir, "audit/coverage")
    File.mkdir_p!(Path.dirname(test_file))
    File.write!(test_file, "")

    with_fake_mix(tmp_dir, "printf 'COVERAGE_FAILURE_SENTINEL\\n'\nexit 23\n", fn ->
      assert_raise RuntimeError, ~r/coverage collection failed.*example_test[.]exs/, fn ->
        Coverage.collect([test_file], %{}, cd: project, output: output)
      end
    end)

    assert [log] = Path.wildcard(Path.join(output, "*.log"))
    assert File.read!(log) =~ "COVERAGE_FAILURE_SENTINEL"
  end

  test "coverage returns the sorted union of tests that execute a source file" do
    index =
      Coverage.new()
      |> Coverage.put("lib/example.ex", 2, "test/b_test.exs")
      |> Coverage.put("lib/example.ex", 3, "test/a_test.exs")
      |> Coverage.put("lib/example.ex", 4, "test/b_test.exs")
      |> Coverage.put_executable("lib/uncovered.ex", 1)

    assert Coverage.tests_for_file(index, "lib/example.ex") == [
             "test/a_test.exs",
             "test/b_test.exs"
           ]

    assert Coverage.tests_for_file(index, "lib/uncovered.ex") == []
    assert Coverage.tests_for_file(index, "lib/missing.ex") == []
  end

  @tag :tmp_dir
  test "coverage indexes round-trip and reject malformed artifacts", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "coverage/index.etf")

    index = Coverage.put(Coverage.new(), "lib/example.ex", 2, "test/example_test.exs")

    assert :ok = Coverage.write_index!(index, path)
    assert Coverage.read_index!(path) == index

    malformed = Path.join(tmp_dir, "malformed.etf")
    File.write!(malformed, :erlang.term_to_binary(%{version: 99, index: index}))

    assert_raise ArgumentError, ~r/invalid coverage index/, fn ->
      Coverage.read_index!(malformed)
    end
  end

  @tag :tmp_dir
  test "coverage task merges disjoint exhaustive partitions into one index", %{tmp_dir: tmp_dir} do
    first = Path.join(tmp_dir, "partition-1.etf")
    second = Path.join(tmp_dir, "partition-2.etf")
    parts = Path.join(tmp_dir, "parts.txt")
    expected = Path.join(tmp_dir, "expected-tests.txt")
    output = Path.join(tmp_dir, "index.etf")
    manifest = Path.join(tmp_dir, "index.json")
    first_evidence = Path.join(tmp_dir, "first.coverdata")
    second_evidence = Path.join(tmp_dir, "second.coverdata")
    File.write!(first_evidence, "first coverage")
    File.write!(second_evidence, "second coverage")

    Coverage.write_index!(
      Coverage.put(Coverage.new(), "lib/example.ex", 2, "test/a_test.exs"),
      first
    )

    Coverage.write_index!(
      Coverage.put(Coverage.new(), "lib/example.ex", 3, "test/b_test.exs"),
      second
    )

    File.write!(
      first <> ".manifest.json",
      Jason.encode!(
        coverage_partition_manifest(
          first,
          ["test/a_test.exs"],
          first_evidence,
          ["test/a_test.exs", "test/b_test.exs"]
        )
      )
    )

    File.write!(
      second <> ".manifest.json",
      Jason.encode!(
        coverage_partition_manifest(
          second,
          ["test/b_test.exs"],
          second_evidence,
          ["test/a_test.exs", "test/b_test.exs"]
        )
      )
    )

    File.write!(parts, Enum.join([first, second], "\n") <> "\n")
    File.write!(expected, "test/a_test.exs\ntest/b_test.exs\n")

    Mix.Task.reenable("muex.coverage")

    assert :ok =
             Mix.Tasks.Muex.Coverage.run([
               "merge",
               "--parts-file",
               parts,
               "--expected-tests-file",
               expected,
               "--index",
               output,
               "--manifest",
               manifest
             ])

    merged = Coverage.read_index!(output)
    assert {:covered, ["test/a_test.exs"]} = Coverage.tests_for(merged, "lib/example.ex", 2)
    assert {:covered, ["test/b_test.exs"]} = Coverage.tests_for(merged, "lib/example.ex", 3)
    assert Jason.decode!(File.read!(manifest))["test_count"] == 2
  end

  @tag :tmp_dir
  test "coverage merge rejects a batch whose audit membership diverges", %{tmp_dir: tmp_dir} do
    part = Path.join(tmp_dir, "partition.etf")
    parts = Path.join(tmp_dir, "parts.txt")
    expected = Path.join(tmp_dir, "expected-tests.txt")
    output = Path.join(tmp_dir, "index.etf")
    manifest = Path.join(tmp_dir, "index.json")
    coverdata = Path.join(tmp_dir, "batch.coverdata")
    File.write!(coverdata, "coverage")
    Coverage.write_index!(Coverage.new(), part)

    invalid =
      part
      |> coverage_partition_manifest(["test/a_test.exs"], coverdata, ["test/a_test.exs"])
      |> put_in([:batch, :tests], ["test/b_test.exs"])

    File.write!(part <> ".manifest.json", Jason.encode!(invalid))
    File.write!(parts, part <> "\n")
    File.write!(expected, "test/a_test.exs\n")
    Mix.Task.reenable("muex.coverage")

    assert_raise Mix.Error, ~r/invalid coverage partition/, fn ->
      Mix.Tasks.Muex.Coverage.run([
        "merge",
        "--parts-file",
        parts,
        "--expected-tests-file",
        expected,
        "--index",
        output,
        "--manifest",
        manifest
      ])
    end
  end

  @tag :tmp_dir
  test "loader fails when any selected source cannot be parsed", %{tmp_dir: tmp_dir} do
    valid = Path.join(tmp_dir, "valid.ex")
    invalid = Path.join(tmp_dir, "invalid.ex")
    File.write!(valid, "defmodule Valid do\nend\n")
    File.write!(invalid, "defmodule Invalid do\n")

    assert {:error, {:source_load_failed, ^invalid, _reason}} =
             Muex.Loader.load_all([valid, invalid], ElixirLanguage)
  end

  test "compiler applies a mutation to exactly one repeated AST occurrence" do
    source = "defmodule Example do\n  def values, do: {1, 1}\nend\n"
    {:ok, ast} = Code.string_to_quoted(source)
    entry = %{path: "lib/example.ex", ast: ast, module_name: Example}

    mutation = %{
      ast: 2,
      original_ast: 1,
      target_ordinal: 1,
      mutator: Literal,
      description: "replace second literal",
      location: %{file: "lib/example.ex", line: 2}
    }

    assert {:ok, mutated} = Compiler.compile_to_source(mutation, entry, ElixirLanguage)
    assert mutated =~ "{1, 2}"
    refute mutated =~ "{2, 2}"
  end

  @tag :tmp_dir
  test "fork configuration and balanced optimizer preserve the trustworthy contract", %{
    tmp_dir: tmp_dir
  } do
    assert {:error, "--concurrency must be a positive integer"} =
             Muex.Config.from_args(["--concurrency", "0"])

    report_file = Path.join(tmp_dir, "report.json")
    audit_dir = Path.join(tmp_dir, "audit")
    campaign_fingerprint = String.duplicate("f", 64)

    assert {:ok, config} =
             Muex.Config.from_args([
               "--files",
               "lib",
               "--report-file",
               report_file,
               "--audit-dir",
               audit_dir,
               "--baseline-timeout",
               "60000",
               "--mutant-id",
               "abc123",
               "--campaign-fingerprint",
               campaign_fingerprint
             ])

    assert config.report_file == report_file
    assert config.audit_dir == audit_dir
    assert config.baseline_timeout_ms == 60_000
    assert config.mutant_id == "abc123"
    assert config.campaign_fingerprint == campaign_fingerprint

    assert {:error, "--tce is disabled because compiler-equivalence detection is not sound"} =
             Muex.Config.from_args(["--tce"])

    assert {:error, "--coverage-index-file requires --coverage-guided"} =
             Muex.Config.from_args(["--coverage-index-file", "coverage.etf"])

    assert {:ok, coverage_config} =
             Muex.Config.from_args([
               "--coverage-guided",
               "--coverage-index-file",
               "coverage.etf"
             ])

    assert coverage_config.internal.coverage_index_file == "coverage.etf"

    global_coverage_fingerprint = String.duplicate("b", 64)

    assert {:ok, shard_coverage_config} =
             Muex.Config.from_args([
               "--coverage-guided",
               "--coverage-index-file",
               "coverage.etf",
               "--coverage-corpus-fingerprint",
               global_coverage_fingerprint
             ])

    assert shard_coverage_config.internal.coverage_corpus_fingerprint ==
             global_coverage_fingerprint

    assert {:error, "--coverage-corpus-fingerprint requires --coverage-index-file"} =
             Muex.Config.from_args([
               "--coverage-guided",
               "--coverage-corpus-fingerprint",
               global_coverage_fingerprint
             ])

    assert {:error, "--inventory-cache-file and --inventory-cache-key must be provided together"} =
             Muex.Config.from_args(["--inventory-cache-file", "inventory.etf"])

    assert {:error, "--inventory-cache-file requires --audit-dir"} =
             Muex.Config.from_args([
               "--inventory-cache-file",
               "inventory.etf",
               "--inventory-cache-key",
               String.duplicate("a", 64)
             ])

    assert {:error, "--inventory-cache-key must be a lowercase SHA-256 digest"} =
             Muex.Config.from_args([
               "--inventory-cache-file",
               "inventory.etf",
               "--inventory-cache-key",
               "invalid",
               "--audit-dir",
               audit_dir
             ])

    mutation = %{
      id: "commutative-swap",
      ast: {:+, [], [1, 2]},
      original_ast: {:+, [], [2, 1]},
      mutator: Muex.Mutator.FunctionCall,
      description: "swap arguments in +()",
      location: %{file: "lib/example.ex", line: 1, function: {:value, 0}}
    }

    assert Muex.Mutator.equivalent?(mutation)

    assert %{prioritized: [%{id: "commutative-swap"}]} =
             mutation
             |> List.wrap()
             |> Muex.MutantOptimizer.optimization_stages(
               enabled: true,
               min_complexity: 0,
               max_mutations_per_function: 20
             )
  end

  @tag :tmp_dir
  test "validated inventory cache skips mutation generation and reuses its audited plan", %{
    tmp_dir: tmp_dir
  } do
    source = Path.join(tmp_dir, "lib/example.ex")
    cache = Path.join(tmp_dir, "cache/shard-1.etf")
    cache_key = String.duplicate("a", 64)
    first_audit = Path.join(tmp_dir, "first-audit")
    second_audit = Path.join(tmp_dir, "second-audit")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "defmodule Example do\n  def value, do: 1\nend\n")
    Process.register(self(), :muex_inventory_probe)

    config = fn audit ->
      {:ok, config} =
        Muex.Config.from_opts(
          files: source,
          project_root: tmp_dir,
          test_paths: "test",
          no_filter: true,
          audit_dir: audit,
          inventory_cache_file: cache,
          inventory_cache_key: cache_key
        )

      %{config | mutators: [InventoryProbeMutator]}
    end

    assert {:ok, %{results: []}} = Muex.run(config.(first_audit))
    assert_received :inventory_walk
    drain_messages(:inventory_walk)

    assert %{"status" => "miss", "cache_key" => ^cache_key, "selected_count" => 0} =
             first_audit
             |> Path.join("inventory-cache.json")
             |> File.read!()
             |> Jason.decode!()

    assert {:ok, %{results: []}} = Muex.run(config.(second_audit))
    refute_received :inventory_walk

    assert %{"status" => "hit", "cache_key" => ^cache_key, "selected_count" => 0} =
             second_audit
             |> Path.join("inventory-cache.json")
             |> File.read!()
             |> Jason.decode!()

    first_plan = Path.join(first_audit, "plan.json")
    second_plan = Path.join(second_audit, "plan.json")
    assert File.read!(second_plan) == File.read!(first_plan)

    assert File.stat!(second_plan).inode ==
             File.stat!(Path.rootname(cache, ".etf") <> ".plan.json").inode

    File.write!(source, "defmodule Example do\n  def value, do: 2\nend\n")
    assert {:error, reason} = Muex.run(config.(Path.join(tmp_dir, "changed-audit")))
    assert reason =~ "input fingerprint mismatch"

    File.write!(cache, "not an ETF")
    assert {:error, corrupt_reason} = Muex.run(config.(Path.join(tmp_dir, "corrupt-audit")))
    assert corrupt_reason =~ "invalid mutation inventory cache"
  end

  @tag :tmp_dir
  test "inventory cache round-trips selected mutation terms", %{tmp_dir: tmp_dir} do
    cache = Path.join(tmp_dir, "cache/shard-1.etf")
    plan = Path.join(tmp_dir, "first-audit/plan.json")
    audit = Path.join(tmp_dir, "second-audit")
    key = String.duplicate("c", 64)

    mutation = %{
      id: String.duplicate("d", 64),
      ast: {:>, [], [1, 2]},
      original_ast: {:>=, [], [1, 2]},
      mutator: Comparison,
      description: "replace >= with >",
      location: %{file: "lib/example.ex", line: 2},
      target_ordinal: 0
    }

    File.mkdir_p!(Path.dirname(plan))
    File.write!(plan, ~s({"selected_count":1}))

    assert {:ok, %{status: "miss", selected_count: 1}} =
             InventoryCache.publish(cache, key, "input", [mutation], plan)

    assert {:ok, [^mutation], %{status: "hit", selected_count: 1}} =
             InventoryCache.load(cache, key, "input", audit)
  end

  @tag :tmp_dir
  test "inventory cache round-trips optimizer-scored mutations", %{tmp_dir: tmp_dir} do
    cache = Path.join(tmp_dir, "cache/shard-1.etf")
    plan = Path.join(tmp_dir, "audit/plan.json")
    audit = Path.join(tmp_dir, "second-audit")
    key = String.duplicate("c", 64)

    [mutation] =
      [Map.put(mutation(), :id, String.duplicate("d", 64))]
      |> MutantOptimizer.score_by_impact()

    assert Map.has_key?(mutation, :impact_score)

    File.mkdir_p!(Path.dirname(plan))
    File.write!(plan, ~s({"selected_count":1}))

    assert {:ok, %{status: "miss"}} =
             InventoryCache.publish(cache, key, "input", [mutation], plan)

    assert {:ok, [^mutation], %{status: "hit"}} =
             InventoryCache.load(cache, key, "input", audit)
  end

  @tag :tmp_dir
  test "inventory cache ships the atom names its payload needs", %{tmp_dir: tmp_dir} do
    cache = Path.join(tmp_dir, "cache/shard-1.etf")
    plan = Path.join(tmp_dir, "audit/plan.json")
    key = String.duplicate("c", 64)

    mutation =
      mutation()
      |> Map.put(:id, String.duplicate("d", 64))
      |> Map.put(:ast, {:__block__, [], [[key: :cached_atom_in_list], %{cached_atom_key: 1}]})

    File.mkdir_p!(Path.dirname(plan))
    File.write!(plan, ~s({"selected_count":1}))

    assert {:ok, _metadata} = InventoryCache.publish(cache, key, "input", [mutation], plan)

    assert {names, payload} = :erlang.binary_to_term(File.read!(cache), [:safe])
    assert is_binary(payload)
    assert Enum.all?(names, &is_binary/1)

    for name <- ~w(__block__ key cached_atom_in_list cached_atom_key location file),
        do: assert(name in names)
  end

  test "audit rendering resolves a language adapter per source extension" do
    assert {:ok, Muex.Language.Elixir} = Config.language_for_path("lib/a.ex")
    assert {:ok, Muex.Language.Erlang} = Config.language_for_path("src/a.erl")
    assert {:error, _reason} = Config.language_for_path("README.md")
  end

  @tag :tmp_dir
  test "inventory cache imports an exact subset with a rewritten audited plan", %{
    tmp_dir: tmp_dir
  } do
    parent = Path.join(tmp_dir, "parent/shard-5.etf")
    child = Path.join(tmp_dir, "child/shard-1.etf")
    parent_plan = Path.join(tmp_dir, "parent-audit/plan.json")
    child_audit = Path.join(tmp_dir, "child-audit")
    key = String.duplicate("a", 64)

    ids =
      Map.new(
        ~w(first second third),
        &{&1, :sha256 |> :crypto.hash(&1) |> Base.encode16(case: :lower)}
      )

    mutations = Enum.map(~w(first second third), &Map.put(mutation(), :id, ids[&1]))

    plan = %{
      version: 1,
      exhaustive: false,
      source_file_count: 1,
      selected_source_file_count: 1,
      source_files: [
        %{
          path: "lib/example.ex",
          selected: true,
          selection_reason: "selected_without_file_filter"
        }
      ],
      candidate_count: 3,
      selected_count: 3,
      optimizer: %{},
      mutants:
        Enum.map(mutations, fn item ->
          %{id: item.id, selected: true, selection_reason: "selected_by_optimizer"}
        end)
    }

    File.mkdir_p!(Path.dirname(parent_plan))
    File.write!(parent_plan, Jason.encode!(plan))

    assert {:ok, _metadata} =
             InventoryCache.publish(parent, key, "parent-input", mutations, parent_plan)

    assert {:ok, provenance} =
             InventoryCache.import_subset(parent, child, [ids["third"], ids["first"]])

    assert provenance.status == "imported_subset"
    assert provenance.parent_cache_sha256 == sha256_file!(parent)

    assert provenance.parent_plan_sha256 ==
             sha256_file!(Path.rootname(parent, ".etf") <> ".plan.json")

    assert {:ok, imported, %{status: "hit"}} =
             InventoryCache.load(child, key, "parent-input", child_audit)

    assert Enum.map(imported, & &1.id) == [ids["first"], ids["third"]]
    rewritten = child_audit |> Path.join("plan.json") |> File.read!() |> Jason.decode!()
    assert rewritten["selected_count"] == 2

    assert Enum.map(rewritten["mutants"], &{&1["id"], &1["selected"], &1["selection_reason"]}) ==
             [
               {ids["first"], true, "selected_by_continuation"},
               {ids["third"], true, "selected_by_continuation"}
             ]

    assert {:error, "unknown subset mutant ids: missing"} =
             InventoryCache.import_subset(parent, Path.join(tmp_dir, "missing.etf"), ["missing"])
  end

  @tag :tmp_dir
  test "all eight continuation assignments load their imported cache through the worker seam", %{
    tmp_dir: tmp_dir
  } do
    key = String.duplicate("e", 64)

    mutations =
      Enum.map(1..8, fn shard ->
        Map.put(
          mutation(),
          :id,
          :sha256 |> :crypto.hash("assignment-#{shard}") |> Base.encode16(case: :lower)
        )
      end)

    parents = [
      {Path.join(tmp_dir, "parent/shard-5.etf"), String.duplicate("f", 64),
       Enum.take(mutations, 7)},
      {Path.join(tmp_dir, "parent/shard-8.etf"), String.duplicate("d", 64),
       [List.last(mutations)]}
    ]

    for {parent, input_fingerprint, parent_mutations} <- parents do
      parent_plan = Path.rootname(parent, ".etf") <> ".source-plan.json"

      plan = %{
        version: 1,
        exhaustive: true,
        source_file_count: 1,
        selected_source_file_count: 1,
        source_files: [%{path: "lib/example.ex", selected: true}],
        candidate_count: length(parent_mutations),
        selected_count: length(parent_mutations),
        optimizer: %{},
        mutants: Enum.map(parent_mutations, &%{id: &1.id, selected: true})
      }

      File.mkdir_p!(Path.dirname(parent_plan))
      File.write!(parent_plan, Jason.encode!(plan))

      assert {:ok, _metadata} =
               InventoryCache.publish(
                 parent,
                 key,
                 input_fingerprint,
                 parent_mutations,
                 parent_plan
               )
    end

    for {mutation, shard} <- Enum.with_index(mutations, 1) do
      {parent, input_fingerprint, _mutations} =
        if shard == 8, do: List.last(parents), else: hd(parents)

      child = Path.join(tmp_dir, "child/shard-#{shard}.etf")
      audit = Path.join(tmp_dir, "worker-#{shard}-audit")

      assert {:ok, _provenance} = InventoryCache.import_subset(parent, child, [mutation.id])

      assert {:ok, [loaded], %{status: "hit", selected_count: 1}} =
               InventoryCache.load(child, key, input_fingerprint, audit)

      assert loaded.id == mutation.id

      assert %{"selected_count" => 1, "mutants" => [%{"id" => loaded_id}]} =
               audit |> Path.join("plan.json") |> File.read!() |> Jason.decode!()

      assert loaded_id == mutation.id
    end
  end

  test "optimizer preserves every boundary mutant through destructive stages" do
    boundary_mutations = [
      "greater-or-equal-to-greater"
      |> optimizer_mutation({:>, [], [1, 2]}, Comparison)
      |> Map.put(:original_ast, {:>=, [], [1, 2]}),
      "less-or-equal-to-less"
      |> optimizer_mutation({:<, [], [1, 2]}, Comparison)
      |> Map.put(:original_ast, {:<=, [], [1, 2]})
    ]

    regular_mutation =
      optimizer_mutation(
        "conditional",
        {:if, [], [true, [do: 1, else: 2]]},
        Muex.Mutator.Conditional
      )

    stages =
      Muex.MutantOptimizer.optimization_stages(boundary_mutations ++ [regular_mutation],
        min_complexity: 2,
        max_mutations_per_function: 1,
        keep_boundary_mutations: true
      )

    for stage <- [:complexity, :clustered, :limited, :prioritized] do
      ids = stages |> Map.fetch!(stage) |> MapSet.new(& &1.id)

      assert MapSet.subset?(
               MapSet.new(~w(greater-or-equal-to-greater less-or-equal-to-less)),
               ids
             )
    end

    assert Enum.map(stages.prioritized, & &1.id) ==
             ~w(greater-or-equal-to-greater less-or-equal-to-less conditional)
  end

  test "clustering compatibility stage conserves mutants for every threshold" do
    mutations =
      for index <- 1..6 do
        optimizer_mutation("literal-#{index}", index, Literal)
      end

    scored = Muex.MutantOptimizer.score_by_impact(mutations)

    for threshold <- [0.0, 0.8, 1.0] do
      assert Enum.map(Muex.MutantOptimizer.cluster_and_sample(scored, threshold), & &1.id) ==
               Enum.map(scored, & &1.id)
    end
  end

  test "unlocatable generated mutants remain auditable with an exact exclusion reason" do
    assert {:ok, config} = Muex.Config.from_args(["--files", "lib"])
    mutation = Map.put(mutation(), :location, %{file: "lib/example.ex", line: 0})
    id = mutation.id

    assert {[], %{^id => "excluded_unlocatable"}} =
             Muex.preselect_mutations([mutation], nil, config)
  end

  @tag :tmp_dir
  test "continuation selects the exact declared mutant id set", %{tmp_dir: tmp_dir} do
    ids_file = Path.join(tmp_dir, "mutant-ids.txt")
    File.write!(ids_file, "second\nfirst\n")

    assert {:ok, config} = Muex.Config.from_args(["--mutant-ids-file", ids_file])
    assert config.mutant_ids_file == ids_file

    mutations = Enum.map(~w(first second third), &Map.put(mutation(), :id, &1))

    assert {:ok, [%{id: "first"}, %{id: "second"}], reasons} =
             Muex.select_mutations_by_ids(mutations, ids_file)

    assert reasons == %{
             "first" => "selected_by_mutant_ids_file",
             "second" => "selected_by_mutant_ids_file",
             "third" => "not_selected_by_mutant_ids_file"
           }

    File.write!(ids_file, "first\nfirst\n")

    assert {:error, "mutant ids file contains duplicate ids"} =
             Muex.select_mutations_by_ids(mutations, ids_file)

    File.write!(ids_file, "missing\n")

    assert {:error, "unknown mutant ids: missing"} =
             Muex.select_mutations_by_ids(mutations, ids_file)
  end

  test "continuation proves imported, blocked, and pending partition the parent plan" do
    shards = continuation_shards()

    assert {:ok, plan} = Continuation.plan(shards, ["e"], 2)
    assert plan.imported_finalized_ids == MapSet.new(~w(a d))
    assert plan.infra_blocked_ids == MapSet.new(~w(e))
    assert plan.pending_ids == MapSet.new(~w(b c))
    assert plan.assignments == %{1 => ["b"], 2 => ["c"]}

    assert {:error, :infra_blocked_without_parent_infrastructure_error} =
             Continuation.plan(shards, ["c"], 2)

    cache_shards = [
      %{shard: 5, selected_ids: ~w(a b c d e), result_ids: ~w(a), infrastructure_error_ids: []},
      %{shard: 8, selected_ids: ~w(f g h), result_ids: ~w(f), infrastructure_error_ids: ~w(g)}
    ]

    assert {:ok, cache_plan} = Continuation.cache_compatible_plan(cache_shards, ["g"], 4)

    assert Enum.count(cache_plan.assignments, fn {_child, assignment} ->
             assignment.parent_shard == 5
           end) == 3

    assert Enum.count(cache_plan.assignments, fn {_child, assignment} ->
             assignment.parent_shard == 8
           end) == 1

    assert cache_plan.assignments[4] == %{parent_shard: 8, ids: ["h"]}

    assert cache_plan.assignments |> Map.values() |> Enum.flat_map(& &1.ids) |> MapSet.new() ==
             MapSet.new(~w(b c d e h))
  end

  @tag :tmp_dir
  test "continuation source paths are normalized and contained in the canonical snapshot", %{
    tmp_dir: tmp_dir
  } do
    snapshot = Path.join(tmp_dir, "snapshot")
    source = Path.join(snapshot, "lib/example.ex")
    outside = Path.join(tmp_dir, "outside.ex")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "source")
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(snapshot, "linked.ex"))

    assert {:ok, ^source} = Artifact.validate_snapshot_path(snapshot, "lib/example.ex")

    for unsafe <- [outside, "../outside.ex", "lib/../lib/example.ex", "linked.ex"] do
      assert {:error, :unsafe_source_file_list} =
               Artifact.validate_snapshot_path(snapshot, unsafe)
    end
  end

  @tag :tmp_dir
  test "source generation errors are excluded with deterministic JSON evidence", %{
    tmp_dir: tmp_dir
  } do
    source = Path.join(tmp_dir, "lib/example.ex")
    checkpoint = Path.join(tmp_dir, "checkpoint.jsonl")
    report = Path.join(tmp_dir, "report.json")
    audit = Path.join(tmp_dir, "audit")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "defmodule Example do\n  def value, do: 1\nend\n")

    assert {:ok, base_config} =
             Muex.Config.from_opts(
               files: source,
               project_root: tmp_dir,
               test_paths: "test",
               no_filter: true,
               checkpoint: checkpoint,
               report_file: report,
               audit_dir: audit,
               format: "json",
               campaign_fingerprint: "campaign"
             )

    config = %{base_config | language: GenerationErrorLanguage, mutators: [Literal]}

    assert {:ok, %{results: []}} = Muex.run(config)
    first_plan = File.read!(Path.join(audit, "plan.json"))

    assert %{
             "candidate_count" => 2,
             "selected_count" => 0,
             "exhaustive" => false,
             "mutants" => [first, second]
           } = Jason.decode!(first_plan)

    for mutant <- [first, second] do
      assert %{
               "selected" => false,
               "selection_reason" => "excluded_generation_error",
               "mutator" => "Muex.Mutator.Literal",
               "location" => %{"file" => "lib/example.ex", "line" => 2},
               "generation_error" => %{
                 "tag" => "error",
                 "reason" => "mutation_source_generation_failed",
                 "type" => "FunctionClauseError",
                 "message" => message,
                 "inspect" => inspected
               }
             } = mutant

      assert message =~ "Code.Normalizer.normalize_kw_args/3"
      assert inspected =~ "{:error, %FunctionClauseError{"
      assert inspected =~ "module: Code.Normalizer"
      assert String.length(inspected) <= 1_000
      refute Map.has_key?(mutant, "mutated_source")
      refute Map.has_key?(mutant, "mutated_sha256")
    end

    assert [header] = checkpoint |> File.stream!() |> Enum.map(&Jason.decode!/1)
    assert header["total"] == 0

    assert {:ok, %{results: []}} = Muex.run(config)
    assert File.read!(Path.join(audit, "plan.json")) == first_plan
  end

  @tag :tmp_dir
  test "a non-test process failure is reported as infrastructure failure", %{tmp_dir: tmp_dir} do
    with_fake_mix(tmp_dir, "printf 'MUEX_INFRA_SENTINEL\\n'\nexit 23\n", fn ->
      assert {:error, {:test_process_failed, 23, output}} =
               PortRunner.run_tests([], timeout_ms: 1_000, cd: tmp_dir)

      assert output =~ "MUEX_INFRA_SENTINEL"
    end)
  end

  @tag :tmp_dir
  test "test processes use sandbox-local temp directories only when cd is provided", %{
    tmp_dir: tmp_dir
  } do
    sandbox = Path.join(tmp_dir, "sandbox")
    environment_log = Path.join(tmp_dir, "temp-environment")
    File.mkdir!(sandbox)
    File.mkdir!(Path.join(sandbox, "tmp"))

    body = """
    printf '%s|%s|%s|%s\n' "$PWD" "$TMPDIR" "$TMP" "$TEMP" >> '#{environment_log}'
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    """

    inherited = %{
      "TMPDIR" => Path.join(tmp_dir, "outer-tmpdir"),
      "TMP" => Path.join(tmp_dir, "outer-tmp"),
      "TEMP" => Path.join(tmp_dir, "outer-temp")
    }

    with_system_env(inherited, fn ->
      with_fake_mix(tmp_dir, body, fn ->
        assert {:ok, _result} = PortRunner.run_tests([], timeout_ms: 1_000, cd: sandbox)
        assert {:ok, _result} = PortRunner.run_tests([], timeout_ms: 1_000)
      end)
    end)

    sandbox_tmp = Path.join(sandbox, "tmp")

    assert [sandbox_line, inherited_line] =
             environment_log |> File.read!() |> String.split("\n", trim: true)

    assert sandbox_line == Enum.join([sandbox, sandbox_tmp, sandbox_tmp, sandbox_tmp], "|")

    assert inherited_line ==
             Enum.join(
               [File.cwd!(), inherited["TMPDIR"], inherited["TMP"], inherited["TEMP"]],
               "|"
             )
  end

  @tag :tmp_dir
  test "test processes reject a sandbox temp symlink without changing its external target", %{
    tmp_dir: tmp_dir
  } do
    sandbox = Path.join(tmp_dir, "sandbox")
    external = Path.join(tmp_dir, "external")
    sentinel = Path.join(external, "sentinel")
    File.mkdir!(sandbox)
    File.mkdir!(external)
    File.write!(sentinel, "keep")
    File.ln_s!(external, Path.join(sandbox, "tmp"))

    body = """
    printf 'changed' > "$TMPDIR/sentinel"
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    """

    with_fake_mix(tmp_dir, body, fn ->
      assert_raise ArgumentError, ~r/unsafe Muex sandbox temp directory/, fn ->
        PortRunner.run_tests([], timeout_ms: 1_000, cd: sandbox)
      end
    end)

    assert File.read!(sentinel) == "keep"
  end

  @tag :tmp_dir
  test "test processes reject symlinked and non-canonical working directories", %{
    tmp_dir: tmp_dir
  } do
    sandbox = Path.join(tmp_dir, "sandbox")
    sandbox_link = Path.join(tmp_dir, "sandbox-link")
    File.mkdir!(sandbox)
    File.ln_s!(sandbox, sandbox_link)

    body =
      ~s(printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"\n)

    with_fake_mix(tmp_dir, body, fn ->
      for unsafe_cd <- [sandbox_link, sandbox <> "/../sandbox"] do
        assert_raise ArgumentError, ~r/unsafe Muex sandbox temp directory/, fn ->
          PortRunner.run_tests([], timeout_ms: 1_000, cd: unsafe_cd)
        end
      end
    end)

    refute File.exists?(Path.join(sandbox, "tmp"))
  end

  @tag :tmp_dir
  test "nonzero exit with a zero-failure-looking line remains infrastructure failure", %{
    tmp_dir: tmp_dir
  } do
    with_fake_mix(tmp_dir, "printf '0 failures\nBROKEN_INFRA\n'\nexit 23\n", fn ->
      assert {:error, {:test_process_failed, 23, output}} =
               PortRunner.run_tests([], timeout_ms: 1_000, cd: tmp_dir)

      assert output =~ "BROKEN_INFRA"
    end)
  end

  @tag :tmp_dir
  test "current ExUnit failure summary is classified as a killed mutant", %{tmp_dir: tmp_dir} do
    body =
      ~s(printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":1}\\n' "$MUEX_EXUNIT_RESULT_NONCE"\nexit 2\n)

    with_fake_mix(tmp_dir, body, fn ->
      assert {:ok, %{failures: 1}} = PortRunner.run_tests([], timeout_ms: 1_000, cd: tmp_dir)
    end)
  end

  @tag :tmp_dir
  test "only the keyed ExUnit result classifies the test process", %{tmp_dir: tmp_dir} do
    body = """
    printf 'MUEX_EXUNIT_RESULT:{"tests":1,"failures":1}\n'
    printf 'MUEX_EXUNIT_RESULT:wrong-token:{"tests":1,"failures":1}\n'
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    exit 0
    """

    with_fake_mix(tmp_dir, body, fn ->
      assert {:ok, %{failures: 0}} = PortRunner.run_tests([], timeout_ms: 1_000, cd: tmp_dir)
    end)
  end

  @tag :tmp_dir
  test "multiple keyed ExUnit results are rejected as ambiguous", %{tmp_dir: tmp_dir} do
    body = """
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":1}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":1}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    exit 2
    """

    with_fake_mix(tmp_dir, body, fn ->
      assert {:error, {:ambiguous_exunit_result, 2, _output}} =
               PortRunner.run_tests([], timeout_ms: 1_000, cd: tmp_dir)
    end)
  end

  test "ExUnit formatter writes keyed result and exact failure evidence" do
    test = %ExUnit.Test{
      module: __MODULE__,
      name: :"test formatter fixture",
      tags: %{file: "test/example_test.exs", line: 12},
      state: {:failed, [{:error, %RuntimeError{message: "fixture failed"}, []}]}
    }

    output =
      capture_io(fn ->
        assert {:noreply, %{tests: 1, failures: 1}} =
                 ExUnitFormatter.handle_cast({:test_finished, test}, %{tests: 0, failures: 0})
      end)

    assert "MUEX_EXUNIT_FAILURE:" <> encoded = String.trim(output)

    assert %{
             "module" => "Elixir.Muex.HardeningTest",
             "name" => "test formatter fixture",
             "file" => "test/example_test.exs",
             "line" => 12,
             "failures" => [failure]
           } = Jason.decode!(encoded)

    assert failure =~ "** (RuntimeError) fixture failed"

    token = "fixture-result-token"
    previous = System.get_env("MUEX_EXUNIT_RESULT_NONCE")
    System.put_env("MUEX_EXUNIT_RESULT_NONCE", token)

    on_exit(fn ->
      if previous,
        do: System.put_env("MUEX_EXUNIT_RESULT_NONCE", previous),
        else: System.delete_env("MUEX_EXUNIT_RESULT_NONCE")
    end)

    assert {:ok, state} = ExUnitFormatter.init([])

    output =
      capture_io(fn ->
        assert {:noreply, ^state} = ExUnitFormatter.handle_cast({:suite_finished, %{}}, state)
      end)

    line = String.trim(output)
    prefix = "MUEX_EXUNIT_RESULT:#{token}:"
    assert String.starts_with?(line, prefix)
    encoded = String.replace_prefix(line, prefix, "")
    assert %{"failures" => 0, "tests" => 0} = Jason.decode!(encoded)
  end

  @tag :tmp_dir
  test "timeout is a wall-clock deadline even while the child emits output", %{tmp_dir: tmp_dir} do
    body = "for _ in $(seq 1 50); do printf 'heartbeat\\n'; sleep 0.03; done\n"

    with_fake_mix(tmp_dir, body, fn ->
      started_at = System.monotonic_time(:millisecond)
      assert {:error, {:timeout, output}} = PortRunner.run_tests([], timeout_ms: 150, cd: tmp_dir)
      assert output =~ "heartbeat"
      assert System.monotonic_time(:millisecond) - started_at < 700
    end)
  end

  @tag :tmp_dir
  test "timeout terminates the mix shell and its background descendants", %{tmp_dir: tmp_dir} do
    shell_pid_file = Path.join(tmp_dir, "shell.pid")
    child_pid_file = Path.join(tmp_dir, "child.pid")

    body = """
    printf '%s' "$$" > '#{shell_pid_file}'
    sleep 60 &
    child_pid=$!
    printf '%s' "$child_pid" > '#{child_pid_file}'
    wait "$child_pid"
    """

    with_fake_mix(tmp_dir, body, fn ->
      assert {:error, {:timeout, _output}} =
               PortRunner.run_tests([], timeout_ms: 150, cd: tmp_dir)

      shell_pid = shell_pid_file |> File.read!() |> String.to_integer()
      child_pid = child_pid_file |> File.read!() |> String.to_integer()

      on_exit(fn ->
        terminate_fixture_process(shell_pid)
        terminate_fixture_process(child_pid)
      end)

      refute os_process_alive?(shell_pid)
      refute os_process_alive?(child_pid)
    end)
  end

  @tag :tmp_dir
  test "timeout freezes a late-forking tree before killing captured identities", %{
    tmp_dir: tmp_dir
  } do
    sleep = System.find_executable("sleep") || flunk("sleep executable missing")
    unrelated_port = Port.open({:spawn_executable, sleep}, [:binary, args: [~c"60"]])
    {:os_pid, unrelated_pid} = Port.info(unrelated_port, :os_pid)

    on_exit(fn ->
      if Port.info(unrelated_port), do: Port.close(unrelated_port)
      terminate_fixture_process(unrelated_pid)
    end)

    shell_pid_file = Path.join(tmp_dir, "late-shell.pid")
    spawner_pid_file = Path.join(tmp_dir, "late-spawner.pid")
    children_pid_file = Path.join(tmp_dir, "late-children.pid")

    body =
      """
      printf #Q#%s#Q# #Q#$$#Q# > #Q##{shell_pid_file}#Q#
      (
        printf #Q#%s#Q# #Q#$BASHPID#Q# > #Q##{spawner_pid_file}#Q#
        for _ in $(seq 1 100); do
          sleep 60 &
          printf #Q#%s\n#Q# #Q#$!#Q# >> #Q##{children_pid_file}#Q#
          sleep 0.002
        done
        wait
      ) &
      wait $!
      """
      |> String.replace("#Q#", <<34>>)

    with_fake_mix(tmp_dir, body, fn ->
      assert {:error, {:timeout, _output}} =
               PortRunner.run_tests([], timeout_ms: 60, cd: tmp_dir)

      pids =
        [shell_pid_file, spawner_pid_file, children_pid_file]
        |> Enum.flat_map(fn path ->
          if File.exists?(path),
            do: path |> File.read!() |> String.split("\n", trim: true),
            else: []
        end)
        |> Enum.map(&String.to_integer/1)
        |> Enum.uniq()

      on_exit(fn -> Enum.each(pids, &terminate_fixture_process/1) end)

      assert length(pids) > 2
      refute Enum.any?(pids, &os_process_alive?/1)
      assert os_process_alive?(unrelated_pid)
    end)
  end

  @tag :tmp_dir
  test "large process output streams to an audited file instead of accumulating in memory", %{
    tmp_dir: tmp_dir
  } do
    output_file = Path.join(tmp_dir, "large.log")

    body =
      "head -c 2000000 /dev/zero | tr '\\0' x\n" <>
        ~s(printf '\\nMUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\\n' "$MUEX_EXUNIT_RESULT_NONCE"\n)

    with_fake_mix(tmp_dir, body, fn ->
      assert {:ok, result} =
               PortRunner.run_tests([], timeout_ms: 5_000, cd: tmp_dir, output_file: output_file)

      assert result.output_artifact.path == output_file
      assert result.output_artifact.bytes > 2_000_000
      assert byte_size(result.output) < 70_000
      assert File.stat!(output_file).size == result.output_artifact.bytes

      expected_hash =
        :sha256 |> :crypto.hash(File.read!(output_file)) |> Base.encode16(case: :lower)

      assert result.output_artifact.sha256 == expected_hash
    end)
  end

  @tag :tmp_dir
  test "process output never truncates an existing artifact", %{tmp_dir: tmp_dir} do
    output_file = Path.join(tmp_dir, "existing.log")
    File.write!(output_file, "previous evidence\n")

    with_fake_mix(tmp_dir, "exit 0\n", fn ->
      assert {:error, :eexist} =
               PortRunner.run_compile(timeout_ms: 1_000, cd: tmp_dir, output_file: output_file)
    end)

    assert File.read!(output_file) == "previous evidence\n"
  end

  @tag :tmp_dir
  test "existing output symlinks are rejected and append-only audit failures surface", %{
    tmp_dir: tmp_dir
  } do
    output_file = Path.join(tmp_dir, "full.log")
    audit_dir = Path.join(tmp_dir, "audit")
    event_dir = Path.join(audit_dir, "events")
    checkpoint_path = Path.join(tmp_dir, "checkpoint-full.jsonl")
    File.ln_s!("/dev/full", output_file)
    File.mkdir_p!(event_dir)
    File.ln_s!("/dev/full", Path.join(event_dir, "fixture-mutant.jsonl"))
    File.ln_s!("/dev/full", checkpoint_path)

    with_fake_mix(tmp_dir, "exit 0\n", fn ->
      assert {:error, :eexist} =
               PortRunner.run_tests([], timeout_ms: 1_000, cd: tmp_dir, output_file: output_file)
    end)

    assert {:error, {:unsafe_audit_path, _path}} =
             Audit.append_event(audit_dir, "fixture-mutant", %{type: "attempt"})

    assert {:error, {:unsafe_checkpoint_path, ^checkpoint_path}} =
             Checkpoint.open(checkpoint_path, %{run: "run", source: "source"}, [])
  end

  @tag :tmp_dir
  test "sandbox mutations reject forged roots before destructive operations", %{tmp_dir: tmp_dir} do
    project_source = Path.join(tmp_dir, "lib/example.ex")
    File.mkdir_p!(Path.dirname(project_source))
    File.write!(project_source, "project original")
    [sandbox] = Sandbox.create_pool(1, project_root: tmp_dir, test_paths: [])

    external = Path.join(tmp_dir, "external")
    source = Path.join(external, "lib/example.ex")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "external original")
    forged = %{sandbox | root: external}

    assert {:error, {:unsafe_sandbox_root, ^external}} =
             Sandbox.apply_mutation(forged, "lib/example.ex", "mutated", nil)

    assert {:error, {:unsafe_sandbox_root, ^external}} =
             Sandbox.restore(forged, "lib/example.ex")

    assert File.read!(source) == "external original"
    Sandbox.cleanup([sandbox])
  end

  @tag :tmp_dir
  test "sandbox cleanup refuses external and symlink targets without deleting them", %{
    tmp_dir: tmp_dir
  } do
    external = Path.join(tmp_dir, "external")
    File.mkdir_p!(external)
    File.write!(Path.join(external, "keep"), "safe")

    assert_raise ArgumentError, ~r/unsafe_sandbox_root/, fn ->
      Sandbox.cleanup([%{root: external, owner_token: "forged"}])
    end

    assert File.read!(Path.join(external, "keep")) == "safe"

    project = mutation_fixture!(Path.join(tmp_dir, "owned"))

    [sandbox] =
      Sandbox.create_pool(1, project_root: project, test_paths: [Path.join(project, "test")])

    File.rm_rf!(sandbox.root)
    File.ln_s!(external, sandbox.root)

    assert_raise ArgumentError, ~r/unsafe_sandbox_root/, fn -> Sandbox.cleanup([sandbox]) end
    assert File.read!(Path.join(external, "keep")) == "safe"

    File.rm!(sandbox.root)
    File.mkdir_p!(sandbox.root)
    assert :ok = Sandbox.cleanup([sandbox])
  end

  @tag :tmp_dir
  test "worker errors wait for the reporting worker before cleanup and reply", %{tmp_dir: tmp_dir} do
    assert_reporting_worker_reaped(
      Path.join(tmp_dir, "infrastructure"),
      %{
        mutation: mutation(),
        result: :infrastructure_error,
        error: :fixture_failure,
        duration_ms: 1
      },
      [],
      {:infrastructure_error, "fixture-mutant", :fixture_failure}
    )

    checkpoint_path = Path.join(tmp_dir, "checkpoint-full.jsonl")

    assert {:ok, checkpoint} =
             Checkpoint.open(checkpoint_path, %{run: "run", source: "source"}, [mutation()])

    File.rm!(checkpoint_path)
    File.ln_s!("/dev/full", checkpoint_path)

    assert_reporting_worker_reaped(
      Path.join(tmp_dir, "checkpoint"),
      %{mutation: mutation(), result: :survived, error: nil, duration_ms: 1},
      [checkpoint: checkpoint],
      {:checkpoint_write_failed, {:unsafe_checkpoint_path, checkpoint_path}}
    )

    File.rm!(checkpoint_path)
    File.write!(checkpoint_path, "")
    assert :ok = Checkpoint.close(checkpoint)
  end

  @tag :tmp_dir
  test "a transient baseline failure is rebuilt, retried once, and fully audited", %{
    tmp_dir: tmp_dir
  } do
    project = mutation_fixture!(tmp_dir)
    calls = Path.join(tmp_dir, "baseline-test-calls")
    checkpoint_path = Path.join(tmp_dir, "checkpoint.jsonl")
    audit_dir = Path.join(tmp_dir, "audit")

    body = """
    if [ "${1:-}" = compile ]; then exit 0; fi
    printf 'test\n' >> '#{calls}'
    count=$(wc -l < '#{calls}')
    if [ "$count" = 1 ]; then
      printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":1}\n' "$MUEX_EXUNIT_RESULT_NONCE"
      exit 1
    fi
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    """

    with_fake_mix(tmp_dir, body, fn ->
      mutation = Map.merge(mutation(), %{ast: 2, original_ast: 1, description: "replace literal"})

      assert {:ok, checkpoint} =
               Checkpoint.open(checkpoint_path, %{run: "run", source: "source"}, [mutation])

      assert {:ok, [%{result: :survived}]} =
               Runner.run_all_result(
                 [mutation],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [Path.join(project, "test/example_test.exs")],
                 checkpoint: checkpoint,
                 audit_dir: audit_dir,
                 tce: false
               )

      assert calls |> File.read!() |> String.split("\n", trim: true) |> length() == 3

      baselines =
        checkpoint_path
        |> File.stream!()
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["type"] == "baseline"))

      assert Enum.map(baselines, &{&1["attempt"], &1["result"]["status"]}) == [
               {1, "failed"},
               {2, "passed"}
             ]

      for baseline <- baselines, kind <- ~w(compile test) do
        artifact = baseline["result"][kind]["output_artifact"]
        assert File.stat!(artifact["path"]).size == artifact["bytes"]

        assert artifact["sha256"] ==
                 :sha256
                 |> :crypto.hash(File.read!(artifact["path"]))
                 |> Base.encode16(case: :lower)
      end
    end)
  end

  @tag :tmp_dir
  test "baseline failure aborts before any mutation is executed", %{tmp_dir: tmp_dir} do
    project = mutation_fixture!(tmp_dir)

    body =
      "if [ \"${1:-}\" = compile ]; then exit 0; fi\n" <>
        "printf 'BASELINE_FAILED\\n'\nexit 23\n"

    with_fake_mix(tmp_dir, body, fn ->
      assert {:error, {:baseline_failed, _sandbox, {:test_process_failed, 23, output}}} =
               Runner.run_all_result(
                 [mutation()],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [Path.join(project, "test/example_test.exs")],
                 tce: false
               )

      assert output =~ "BASELINE_FAILED"
    end)
  end

  @tag :tmp_dir
  test "default mutation runs the full declared test corpus despite dependency hints", %{
    tmp_dir: tmp_dir
  } do
    project = mutation_fixture!(tmp_dir)
    direct_test = Path.join(project, "test/direct_test.exs")
    indirect_test = Path.join(project, "test/indirect_test.exs")
    test_calls = Path.join(tmp_dir, "test-calls")
    File.write!(direct_test, "")
    File.write!(indirect_test, "")

    body = """
    if [ "${1:-}" = compile ]; then exit 0; fi
    printf 'test\n' >> '#{test_calls}'
    count=$(wc -l < '#{test_calls}')
    failures=0
    status=0
    if [ "$count" = 2 ]; then
      case " $* " in
        *" test/indirect_test.exs "*) failures=1; status=1 ;;
      esac
    fi
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":2,"failures":%s}\n' "$MUEX_EXUNIT_RESULT_NONCE" "$failures"
    exit "$status"
    """

    with_fake_mix(tmp_dir, body, fn ->
      mutation = Map.merge(mutation(), %{ast: 2, original_ast: 1, description: "replace literal"})

      assert {:ok, [%{result: :killed}]} =
               Runner.run_all_result(
                 [mutation],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{Example => [direct_test]},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [direct_test, indirect_test],
                 tce: false
               )
    end)
  end

  @tag :tmp_dir
  test "shard baseline uses the source-file coverage union instead of the full corpus", %{
    tmp_dir: tmp_dir
  } do
    project = mutation_fixture!(tmp_dir)
    direct_test = Path.join(project, "test/direct_test.exs")
    indirect_test = Path.join(project, "test/indirect_test.exs")
    test_calls = Path.join(tmp_dir, "test-calls")
    File.write!(direct_test, "")
    File.write!(indirect_test, "")

    body = """
    if [ "${1:-}" = compile ]; then exit 0; fi
    printf '%s\n' "$*" >> '#{test_calls}'
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    exit 0
    """

    coverage_index = Coverage.put(Coverage.new(), "lib/example.ex", 99, direct_test)

    mutation = Map.merge(mutation(), %{ast: 2, original_ast: 1, description: "replace literal"})

    with_fake_mix(tmp_dir, body, fn ->
      assert {:ok, [%{result: :survived}]} =
               Runner.run_all_result(
                 [mutation],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [direct_test, indirect_test],
                 coverage_index: coverage_index,
                 tce: false
               )
    end)

    [baseline, mutant] = test_calls |> File.read!() |> String.split("\n", trim: true)
    assert baseline =~ "test/direct_test.exs"
    refute baseline =~ "test/indirect_test.exs"
    assert mutant =~ "test/direct_test.exs"
    refute mutant =~ "test/indirect_test.exs"
  end

  @tag :tmp_dir
  test "shard baseline is the union of tests possible for its covered mutations", %{
    tmp_dir: tmp_dir
  } do
    project = mutation_fixture!(tmp_dir)
    other_source = "defmodule Other do\n  def value, do: 1\nend\n"
    File.write!(Path.join(project, "lib/other.ex"), other_source)

    {:ok, other_ast} = Code.string_to_quoted(other_source)
    other_entry = %{path: "lib/other.ex", ast: other_ast, module_name: Other}
    first_test = Path.join(project, "test/first_test.exs")
    second_test = Path.join(project, "test/second_test.exs")
    unrelated_test = Path.join(project, "test/unrelated_test.exs")
    test_calls = Path.join(tmp_dir, "test-calls")

    for path <- [first_test, second_test, unrelated_test], do: File.write!(path, "")

    body = """
    if [ "${1:-}" = compile ]; then exit 0; fi
    printf '%s\n' "$*" >> '#{test_calls}'
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    exit 0
    """

    first = Map.merge(mutation(), %{ast: 2, original_ast: 1, description: "first"})

    second = %{
      first
      | id: "second-mutant",
        description: "second",
        location: %{file: "lib/other.ex", line: 2}
    }

    coverage_index =
      Coverage.new()
      |> Coverage.put("lib/example.ex", 2, first_test)
      |> Coverage.put("lib/other.ex", 2, second_test)

    with_fake_mix(tmp_dir, body, fn ->
      assert {:ok, results} =
               Runner.run_all_result(
                 [first, second],
                 %{"lib/example.ex" => file_entry(), "lib/other.ex" => other_entry},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example, "lib/other.ex" => Other},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [first_test, second_test, unrelated_test],
                 coverage_index: coverage_index,
                 tce: false
               )

      assert Enum.all?(results, &(&1.result == :survived))
    end)

    [baseline | mutant_calls] = test_calls |> File.read!() |> String.split("\n", trim: true)
    assert baseline =~ "test/first_test.exs"
    assert baseline =~ "test/second_test.exs"
    refute baseline =~ "test/unrelated_test.exs"
    assert Enum.any?(mutant_calls, &(&1 =~ "test/first_test.exs"))
    assert Enum.any?(mutant_calls, &(&1 =~ "test/second_test.exs"))
  end

  @tag :tmp_dir
  test "partial resume keeps the full immutable shard coverage union for its baseline", %{
    tmp_dir: tmp_dir
  } do
    project = mutation_fixture!(tmp_dir)
    other_source = "defmodule Other do\n  def value, do: 1\nend\n"
    File.write!(Path.join(project, "lib/other.ex"), other_source)

    {:ok, other_ast} = Code.string_to_quoted(other_source)
    other_entry = %{path: "lib/other.ex", ast: other_ast, module_name: Other}
    first_test = Path.join(project, "test/first_test.exs")
    second_test = Path.join(project, "test/second_test.exs")
    calls = Path.join(tmp_dir, "calls")
    File.write!(first_test, "")
    File.write!(second_test, "")

    body = """
    if [ "${1:-}" = compile ]; then exit 0; fi
    printf '%s\n' "$*" >> '#{calls}'
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    exit 0
    """

    first = Map.merge(mutation(), %{ast: 2, original_ast: 1, description: "first"})

    second = %{
      first
      | id: "second-mutant",
        description: "second",
        location: %{file: "lib/other.ex", line: 2}
    }

    coverage_index =
      Coverage.new()
      |> Coverage.put("lib/example.ex", 2, first_test)
      |> Coverage.put("lib/other.ex", 2, second_test)

    with_fake_mix(tmp_dir, body, fn ->
      assert {:ok, [%{result: :survived}]} =
               Runner.run_all_result(
                 [second],
                 %{"lib/example.ex" => file_entry(), "lib/other.ex" => other_entry},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example, "lib/other.ex" => Other},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [first_test, second_test],
                 coverage_index: coverage_index,
                 baseline_mutations: [first, second],
                 tce: false
               )
    end)

    [baseline, mutant] = calls |> File.read!() |> String.split("\n", trim: true)
    assert baseline =~ "test/first_test.exs"
    assert baseline =~ "test/second_test.exs"
    refute mutant =~ "test/first_test.exs"
    assert mutant =~ "test/second_test.exs"
  end

  @tag :tmp_dir
  test "unknown mutation lines keep the full corpus when source-file coverage is empty", %{
    tmp_dir: tmp_dir
  } do
    project = mutation_fixture!(tmp_dir)
    direct_test = Path.join(project, "test/direct_test.exs")
    indirect_test = Path.join(project, "test/indirect_test.exs")
    test_calls = Path.join(tmp_dir, "test-calls")
    File.write!(direct_test, "")
    File.write!(indirect_test, "")

    body = """
    if [ "${1:-}" = compile ]; then exit 0; fi
    printf '%s\n' "$*" >> '#{test_calls}'
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":2,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    exit 0
    """

    coverage_index = Coverage.put_executable(Coverage.new(), "lib/example.ex", 99)
    mutation = Map.merge(mutation(), %{ast: 2, original_ast: 1, description: "replace literal"})

    with_fake_mix(tmp_dir, body, fn ->
      assert {:ok, [%{result: :survived}]} =
               Runner.run_all_result(
                 [mutation],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [direct_test, indirect_test],
                 coverage_index: coverage_index,
                 tce: false
               )
    end)

    [baseline, mutant] = test_calls |> File.read!() |> String.split("\n", trim: true)
    assert baseline =~ "test/direct_test.exs"
    assert baseline =~ "test/indirect_test.exs"
    assert mutant =~ "test/direct_test.exs"
    assert mutant =~ "test/indirect_test.exs"
  end

  @tag :tmp_dir
  test "a shard containing only uncovered mutants runs a compile-only baseline", %{
    tmp_dir: tmp_dir
  } do
    project = mutation_fixture!(tmp_dir)
    calls = Path.join(tmp_dir, "calls")

    body = """
    printf '%s\n' "$*" >> '#{calls}'
    if [ "${1:-}" = test ]; then
      printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    fi
    exit 0
    """

    coverage_index = Coverage.put_executable(Coverage.new(), "lib/example.ex", 2)
    mutation = Map.merge(mutation(), %{ast: 2, original_ast: 1, description: "replace literal"})
    checkpoint_path = Path.join(tmp_dir, "checkpoint.jsonl")

    assert {:ok, checkpoint} =
             Checkpoint.open(
               checkpoint_path,
               %{run: "run", source: "source", campaign_fingerprint: "campaign"},
               [mutation]
             )

    with_fake_mix(tmp_dir, body, fn ->
      assert {:ok, [%{result: :no_coverage}]} =
               Runner.run_all_result(
                 [mutation],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [Path.join(project, "test/example_test.exs")],
                 coverage_index: coverage_index,
                 checkpoint: checkpoint,
                 tce: false
               )
    end)

    assert [baseline] = calls |> File.read!() |> String.split("\n", trim: true)
    assert String.starts_with?(baseline, "compile ")

    [_header, baseline_row, result_row] =
      checkpoint_path |> File.stream!() |> Enum.map(&Jason.decode!/1)

    assert baseline_row["tests"] == []

    assert baseline_row["commands"] == [
             ["mix", "compile", "--no-deps-check", "--no-archives-check"]
           ]

    assert baseline_row["result"]["test"] == nil
    assert result_row["status"] == "no_coverage"
  end

  @tag :tmp_dir
  test "a repeated timeout is terminal only after rebuild and a fresh baseline", %{
    tmp_dir: tmp_dir
  } do
    project = mutation_fixture!(tmp_dir)
    calls = Path.join(tmp_dir, "retry-calls")
    File.rm(calls)

    body = """
    printf 'call\n' >> '#{calls}'
    count=$(wc -l < '#{calls}')
    if [ "${1:-}" = test ] && { [ "$count" = 4 ] || [ "$count" = 8 ]; }; then
      sleep 60
    fi
    if [ "${1:-}" = test ]; then
      printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    fi
    exit 0
    """

    with_fake_mix(tmp_dir, body, fn ->
      mutation =
        Map.merge(mutation(), %{
          ast: 2,
          original_ast: 1,
          target_ordinal: 0,
          description: "replace literal"
        })

      assert {:ok, [result]} =
               Runner.run_all_result(
                 [mutation],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [Path.join(project, "test/example_test.exs")],
                 timeout_ms: 100,
                 baseline_timeout_ms: 1_000,
                 tce: false
               )

      assert result.result == :timeout
      assert %{attempts: [_, _], recovery: %{rebuilt: true}} = result.audit
    end)
  end

  @tag :tmp_dir
  test "a compile failure is invalid only after rebuild and a fresh baseline reproduce it", %{
    tmp_dir: tmp_dir
  } do
    project = mutation_fixture!(tmp_dir)
    calls = Path.join(tmp_dir, "compile-retry-calls")

    body = """
    printf 'call\n' >> '#{calls}'
    count=$(wc -l < '#{calls}')
    if [ "${1:-}" = compile ] && { [ "$count" = 3 ] || [ "$count" = 6 ]; }; then
      printf 'MUTANT_COMPILE_FAILED\n'
      exit 2
    fi
    if [ "${1:-}" = test ]; then
      printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    fi
    exit 0
    """

    with_fake_mix(tmp_dir, body, fn ->
      mutation =
        Map.merge(mutation(), %{
          ast: 2,
          original_ast: 1,
          target_ordinal: 0,
          description: "replace literal"
        })

      assert {:ok, [result]} =
               Runner.run_all_result(
                 [mutation],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [Path.join(project, "test/example_test.exs")],
                 tce: false
               )

      assert result.result == :invalid
      assert %{attempts: [_, _], recovery: %{rebuilt: true}} = result.audit
      assert calls |> File.read!() |> String.split("\n", trim: true) |> length() == 6
    end)
  end

  @tag :tmp_dir
  test "a transient recovery baseline failure is retried once and fully audited", %{
    tmp_dir: tmp_dir
  } do
    project = mutation_fixture!(tmp_dir)
    calls = Path.join(tmp_dir, "recovery-baseline-retry-calls")
    audit_dir = Path.join(tmp_dir, "audit")

    body = """
    printf 'call\n' >> '#{calls}'
    count=$(wc -l < '#{calls}')
    if [ "${1:-}" = compile ]; then
      if [ "$count" = 3 ] || [ "$count" = 7 ]; then exit 2; fi
      exit 0
    fi
    failures=0
    status=0
    if [ "$count" = 5 ]; then failures=1; status=1; fi
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":%s}\n' "$MUEX_EXUNIT_RESULT_NONCE" "$failures"
    exit "$status"
    """

    with_fake_mix(tmp_dir, body, fn ->
      mutation =
        Map.merge(mutation(), %{
          ast: 2,
          original_ast: 1,
          target_ordinal: 0,
          description: "replace literal"
        })

      assert {:ok, [%{result: :invalid, audit: %{recovery: recovery}}]} =
               Runner.run_all_result(
                 [mutation],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [Path.join(project, "test/example_test.exs")],
                 audit_dir: audit_dir,
                 tce: false
               )

      assert Enum.map(recovery.test_attempts, & &1.test.failures) == [1, 0]
      assert calls |> File.read!() |> String.split("\n", trim: true) |> length() == 7

      artifacts = Enum.map(recovery.test_attempts, & &1.test.output_artifact)
      assert artifacts |> Enum.map(& &1.path) |> Enum.uniq() |> length() == 2

      for artifact <- artifacts do
        assert File.stat!(artifact.path).size == artifact.bytes
      end
    end)
  end

  @tag :tmp_dir
  test "repeated recovery baseline failures remain terminal and auditable", %{tmp_dir: tmp_dir} do
    project = mutation_fixture!(tmp_dir)
    calls = Path.join(tmp_dir, "recovery-baseline-failure-calls")
    audit_dir = Path.join(tmp_dir, "audit")

    body = """
    printf 'call\n' >> '#{calls}'
    count=$(wc -l < '#{calls}')
    if [ "${1:-}" = compile ]; then
      if [ "$count" = 3 ]; then exit 2; fi
      exit 0
    fi
    failures=0
    status=0
    if [ "$count" = 5 ] || [ "$count" = 6 ]; then failures=1; status=1; fi
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":%s}\n' "$MUEX_EXUNIT_RESULT_NONCE" "$failures"
    exit "$status"
    """

    with_fake_mix(tmp_dir, body, fn ->
      mutation =
        Map.merge(mutation(), %{
          ast: 2,
          original_ast: 1,
          target_ordinal: 0,
          description: "replace literal"
        })

      assert {:error,
              {:infrastructure_error, "fixture-mutant",
               {:recovery_failed, :baseline_test_failures}}} =
               Runner.run_all_result(
                 [mutation],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [Path.join(project, "test/example_test.exs")],
                 audit_dir: audit_dir,
                 tce: false
               )

      assert calls |> File.read!() |> String.split("\n", trim: true) |> length() == 6

      recovery_failed =
        audit_dir
        |> Path.join("events/fixture-mutant.jsonl")
        |> File.stream!()
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["type"] == "recovery_failed"))

      assert Enum.map(recovery_failed["recovery"]["test_attempts"], & &1["test"]["failures"]) == [
               1,
               1
             ]
    end)
  end

  @tag :tmp_dir
  test "a repeatable pre-ExUnit test process failure kills the mutant after a healthy recovery",
       %{
         tmp_dir: tmp_dir
       } do
    project = mutation_fixture!(tmp_dir)
    calls = Path.join(tmp_dir, "pre-exunit-failure-calls")
    audit_dir = Path.join(tmp_dir, "audit")

    body = """
    printf 'call\n' >> '#{calls}'
    count=$(wc -l < '#{calls}')
    if [ "${1:-}" = compile ]; then exit 0; fi
    if [ "$count" = 4 ] || [ "$count" = 8 ]; then
      printf 'mutated application failed during boot\n'
      exit 1
    fi
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    exit 0
    """

    with_fake_mix(tmp_dir, body, fn ->
      mutation =
        Map.merge(mutation(), %{
          ast: 2,
          original_ast: 1,
          target_ordinal: 0,
          description: "replace literal"
        })

      assert {:ok, [%{result: :killed, error: nil, audit: %{recovery: recovery}}]} =
               Runner.run_all_result(
                 [mutation],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [Path.join(project, "test/example_test.exs")],
                 audit_dir: audit_dir,
                 tce: false
               )

      assert recovery.baseline.test.failures == 0
      assert calls |> File.read!() |> String.split("\n", trim: true) |> length() == 8
    end)
  end

  @tag :tmp_dir
  test "different pre-ExUnit failures remain infrastructure errors", %{tmp_dir: tmp_dir} do
    project = mutation_fixture!(tmp_dir)
    calls = Path.join(tmp_dir, "different-pre-exunit-failure-calls")
    audit_dir = Path.join(tmp_dir, "audit")

    body = """
    printf 'call\n' >> '#{calls}'
    count=$(wc -l < '#{calls}')
    if [ "${1:-}" = compile ]; then exit 0; fi
    if [ "$count" = 4 ]; then printf 'first boot failure\n'; exit 1; fi
    if [ "$count" = 8 ]; then printf 'second boot failure\n'; exit 1; fi
    printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    exit 0
    """

    with_fake_mix(tmp_dir, body, fn ->
      mutation =
        Map.merge(mutation(), %{
          ast: 2,
          original_ast: 1,
          target_ordinal: 0,
          description: "replace literal"
        })

      assert {:error,
              {:infrastructure_error, "fixture-mutant",
               {:divergent_attempts, :infrastructure_error, :infrastructure_error}}} =
               Runner.run_all_result(
                 [mutation],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [Path.join(project, "test/example_test.exs")],
                 audit_dir: audit_dir,
                 tce: false
               )
    end)
  end

  @tag :tmp_dir
  test "a transient compile failure remains infrastructure instead of invalid", %{
    tmp_dir: tmp_dir
  } do
    project = mutation_fixture!(tmp_dir)
    calls = Path.join(tmp_dir, "transient-compile-calls")

    body = """
    printf 'call\n' >> '#{calls}'
    count=$(wc -l < '#{calls}')
    if [ "${1:-}" = compile ] && [ "$count" = 3 ]; then exit 2; fi
    if [ "${1:-}" = test ]; then
      printf 'MUEX_EXUNIT_RESULT:%s:{"tests":1,"failures":0}\n' "$MUEX_EXUNIT_RESULT_NONCE"
    fi
    exit 0
    """

    with_fake_mix(tmp_dir, body, fn ->
      mutation =
        Map.merge(mutation(), %{
          ast: 2,
          original_ast: 1,
          target_ordinal: 0,
          description: "replace literal"
        })

      assert {:error,
              {:infrastructure_error, "fixture-mutant",
               {:divergent_attempts, :compile_failure, :survived}}} =
               Runner.run_all_result(
                 [mutation],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [Path.join(project, "test/example_test.exs")],
                 tce: false
               )

      assert calls |> File.read!() |> String.split("\n", trim: true) |> length() == 7
    end)
  end

  @tag :tmp_dir
  test "no-op mutation is rejected without another test process", %{tmp_dir: tmp_dir} do
    project = mutation_fixture!(tmp_dir)
    calls = Path.join(tmp_dir, "mix-calls")

    with_fake_mix(
      tmp_dir,
      "printf 'call\\n' >> '#{calls}'\nif [ \"${1:-}\" = compile ]; then exit 0; fi\nprintf 'MUEX_EXUNIT_RESULT:%s:{\"tests\":0,\"failures\":0}\\n' \"$MUEX_EXUNIT_RESULT_NONCE\"\nexit 0\n",
      fn ->
        ref = make_ref()

        output =
          capture_io(fn ->
            send(
              self(),
              {ref,
               Runner.run_all_result(
                 [mutation()],
                 %{"lib/example.ex" => file_entry()},
                 ElixirLanguage,
                 %{},
                 %{"lib/example.ex" => Example},
                 max_workers: 1,
                 project_root: project,
                 test_paths: [Path.join(project, "test/example_test.exs")],
                 verbose: true,
                 tce: false
               )}
            )
          end)

        assert_receive {^ref, {:ok, [result]}}

        assert result.result == :no_op
        assert result.error == :identical_source
        assert result.audit == %{classification: :no_op, reason: :identical_source}
        assert output =~ "="
        assert calls |> File.read!() |> String.split("\n", trim: true) |> length() == 2
      end
    )
  end

  @tag :tmp_dir
  test "checkpoint resumes terminal mutations and rejects another fingerprint", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "checkpoint.jsonl")
    mutations = Muex.assign_mutation_ids([mutation(), mutation()])
    metadata = %{run: "run", source: "source", campaign_fingerprint: "campaign"}

    assert {:ok, checkpoint} = Checkpoint.open(path, metadata, mutations)
    assert checkpoint.completed == %{}
    assert {:error, :checkpoint_locked} = Checkpoint.open(path, metadata, mutations)

    first = %{mutation: hd(mutations), result: :survived, duration_ms: 12, error: nil}
    assert :ok = Checkpoint.append_result(checkpoint, first)
    assert :ok = Checkpoint.close(checkpoint)

    assert {:ok, resumed} = Checkpoint.open(path, metadata, mutations)
    assert resumed.completed[hd(mutations).id].result == :survived
    assert :ok = Checkpoint.close(resumed)

    assert {:error, :checkpoint_fingerprint_mismatch} =
             Checkpoint.open(
               path,
               %{run: "different", source: "source", campaign_fingerprint: "campaign"},
               mutations
             )

    [header | _] = path |> File.stream!() |> Enum.map(&Jason.decode!/1)
    assert header["campaign_fingerprint"] == "campaign"
  end

  @tag :tmp_dir
  test "checkpoint lease releases when its owner crashes", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "crash-checkpoint.jsonl")
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:opened, Checkpoint.open(path, %{run: "run", source: "source"}, [])})
        Process.sleep(:infinity)
      end)

    assert_receive {:opened, {:ok, _checkpoint}}

    assert {:error, :checkpoint_locked} =
             Checkpoint.open(path, %{run: "run", source: "source"}, [])

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    Process.sleep(50)
    assert {:ok, reopened} = Checkpoint.open(path, %{run: "run", source: "source"}, [])
    assert :ok = Checkpoint.close(reopened)
  end

  @tag :tmp_dir
  test "checkpoint rejects symlink components before create and append", %{tmp_dir: tmp_dir} do
    real = Path.join(tmp_dir, "real")
    linked = Path.join(tmp_dir, "linked")
    File.mkdir_p!(real)
    File.ln_s!(real, linked)

    assert {:error, {:unsafe_checkpoint_path, _path}} =
             Checkpoint.open(
               Path.join(linked, "checkpoint.jsonl"),
               %{run: "run", source: "source"},
               []
             )

    safe_path = Path.join(tmp_dir, "safe/checkpoint.jsonl")
    assert {:ok, checkpoint} = Checkpoint.open(safe_path, %{run: "run", source: "source"}, [])
    File.rename!(Path.dirname(safe_path), Path.join(tmp_dir, "moved"))
    File.ln_s!(Path.join(tmp_dir, "moved"), Path.dirname(safe_path))

    assert {:error, {:unsafe_checkpoint_path, ^safe_path}} =
             Checkpoint.append_event(checkpoint, %{type: "attempt"})

    assert {:error, {:unsafe_checkpoint_path, ^safe_path}} = Checkpoint.close(checkpoint)

    File.rm!(Path.dirname(safe_path))
    File.rename!(Path.join(tmp_dir, "moved"), Path.dirname(safe_path))
    assert :ok = Checkpoint.close(checkpoint)
  end

  @tag :tmp_dir
  test "resume fingerprint covers lib and priv but ignores destination paths", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "priv"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))
    File.write!(Path.join(tmp_dir, "lib/example.ex"), "defmodule Example do\nend\n")
    File.write!(Path.join(tmp_dir, "lib/unselected.ex"), "defmodule Unselected do\nend\n")
    File.write!(Path.join(tmp_dir, "priv/data.txt"), "one\n")
    File.write!(Path.join(tmp_dir, "test/example_test.exs"), "")

    {:ok, first} =
      Muex.Config.from_opts(
        files: "lib/example.ex",
        test_paths: "test",
        project_root: tmp_dir,
        checkpoint: "one/checkpoint.jsonl",
        report_file: "one/report.json",
        audit_dir: "one/audit"
      )

    second = %{
      first
      | internal: %{first.internal | checkpoint: "two/checkpoint.jsonl"},
        report_file: "two/report.json",
        audit_dir: "two/audit"
    }

    files = [%{path: "lib/example.ex"}]

    assert Muex.checkpoint_metadata(first, files, [Path.join(tmp_dir, "test/example_test.exs")]) ==
             Muex.checkpoint_metadata(second, files, [Path.join(tmp_dir, "test/example_test.exs")])

    before = Muex.checkpoint_metadata(first, files, [Path.join(tmp_dir, "test/example_test.exs")])
    File.write!(Path.join(tmp_dir, "priv/data.txt"), "two\n")

    after_priv =
      Muex.checkpoint_metadata(first, files, [Path.join(tmp_dir, "test/example_test.exs")])

    refute before.run == after_priv.run

    File.write!(
      Path.join(tmp_dir, "lib/unselected.ex"),
      "defmodule Unselected do\n  def value, do: 1\nend\n"
    )

    after_lib =
      Muex.checkpoint_metadata(first, files, [Path.join(tmp_dir, "test/example_test.exs")])

    refute after_priv.run == after_lib.run
  end

  @tag :tmp_dir
  test "resume fingerprint covers repository hooks", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))
    File.mkdir_p!(Path.join(tmp_dir, ".githooks"))
    File.write!(Path.join(tmp_dir, "lib/example.ex"), "defmodule Example do\nend\n")
    File.write!(Path.join(tmp_dir, "test/example_test.exs"), "")
    hook = Path.join(tmp_dir, ".githooks/pre-commit")
    File.write!(hook, "mix format --check-formatted\n")

    assert {:ok, config} =
             Muex.Config.from_opts(
               files: "lib/example.ex",
               test_paths: "test",
               project_root: tmp_dir
             )

    files = [%{path: "lib/example.ex"}]
    tests = [Path.join(tmp_dir, "test/example_test.exs")]
    before = Muex.checkpoint_metadata(config, files, tests)

    File.write!(hook, "mix precommit\n")

    after_change = Muex.checkpoint_metadata(config, files, tests)
    refute before.run == after_change.run
  end

  @tag :tmp_dir
  test "resume fingerprint binds external coverage index contents, not its path", %{
    tmp_dir: tmp_dir
  } do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))
    File.write!(Path.join(tmp_dir, "lib/example.ex"), "defmodule Example do\nend\n")
    File.write!(Path.join(tmp_dir, "test/example_test.exs"), "")
    first_index = Path.join(tmp_dir, "first.etf")
    second_index = Path.join(tmp_dir, "second.etf")
    Coverage.write_index!(Coverage.new(), first_index)
    File.cp!(first_index, second_index)

    {:ok, first} =
      Muex.Config.from_opts(
        files: "lib/example.ex",
        test_paths: "test",
        project_root: tmp_dir,
        coverage_guided: true,
        coverage_index_file: first_index
      )

    {:ok, second} =
      Muex.Config.from_opts(
        files: "lib/example.ex",
        test_paths: "test",
        project_root: tmp_dir,
        coverage_guided: true,
        coverage_index_file: second_index
      )

    files = [%{path: "lib/example.ex"}]
    tests = [Path.join(tmp_dir, "test/example_test.exs")]

    assert Muex.checkpoint_metadata(first, files, tests) ==
             Muex.checkpoint_metadata(second, files, tests)

    Coverage.write_index!(
      Coverage.put(Coverage.new(), "lib/example.ex", 1, "test/example_test.exs"),
      second_index <> ".replacement"
    )

    File.rename!(second_index <> ".replacement", second_index)

    refute Muex.checkpoint_metadata(first, files, tests) ==
             Muex.checkpoint_metadata(second, files, tests)
  end

  @tag :tmp_dir
  test "resume fingerprint expands declared test directories and globs", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "lib/example.ex")
    test_dir = Path.join(tmp_dir, "test")
    test_file = Path.join(test_dir, "example_test.exs")
    File.mkdir_p!(Path.dirname(source))
    File.mkdir_p!(test_dir)
    File.write!(source, "defmodule Example do\nend\n")
    File.write!(test_file, "original\n")

    assert {:ok, config} =
             Muex.Config.from_opts(
               files: source,
               project_root: tmp_dir,
               test_paths: test_dir,
               checkpoint: "checkpoint.jsonl"
             )

    for declared_tests <- [test_dir, Path.join(test_dir, "**/*_test.exs")] do
      before = Muex.checkpoint_metadata(config, [%{path: "lib/example.ex"}], [declared_tests])
      File.write!(test_file, "changed\n")

      after_change =
        Muex.checkpoint_metadata(config, [%{path: "lib/example.ex"}], [declared_tests])

      refute before.run == after_change.run
      File.write!(test_file, "original\n")
    end
  end

  @tag :tmp_dir
  test "an empty selection still publishes a resumable checkpoint header", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "lib/empty.ex")
    checkpoint = Path.join(tmp_dir, "checkpoint.jsonl")
    report = Path.join(tmp_dir, "report.json")
    audit = Path.join(tmp_dir, "audit")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "defmodule EmptySelection do\nend\n")

    assert {:ok, config} =
             Muex.Config.from_opts(
               files: source,
               project_root: tmp_dir,
               test_paths: "test",
               no_filter: true,
               checkpoint: checkpoint,
               report_file: report,
               audit_dir: audit,
               format: "json",
               campaign_fingerprint: "campaign"
             )

    assert {:ok, %{results: []}} = Muex.run(config)
    assert [header] = checkpoint |> File.stream!() |> Enum.map(&Jason.decode!/1)
    assert header["total"] == 0
    assert header["campaign_fingerprint"] == "campaign"
    assert report |> File.read!() |> Jason.decode!() |> get_in(["summary", "total"]) == 0
  end

  @tag :tmp_dir
  test "an explicit report file is written for every output format", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "lib/example.ex")
    report = Path.join(tmp_dir, "report.json")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "defmodule TerminalReport do\nend\n")

    assert {:ok, config} =
             Muex.Config.from_opts(
               files: source,
               project_root: tmp_dir,
               test_paths: "test",
               no_filter: true,
               report_file: report
             )

    assert config.format == "terminal"
    assert {:ok, %{results: []}} = ExUnit.CaptureIO.with_io(fn -> Muex.run(config) end) |> elem(0)
    assert report |> File.read!() |> Jason.decode!() |> get_in(["summary", "total"]) == 0
  end

  @tag :tmp_dir
  test "audit plan records filter exclusions and is exhaustive only over the original source scope",
       %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "lib/reporter/example.ex")
    checkpoint = Path.join(tmp_dir, "checkpoint.jsonl")
    report = Path.join(tmp_dir, "report.json")
    audit = Path.join(tmp_dir, "audit")
    File.mkdir_p!(Path.dirname(source))

    File.write!(
      source,
      "defmodule Example.Reporter do\n  def value(flag), do: if(flag, do: 1, else: 2)\nend\n"
    )

    assert {:ok, config} =
             Muex.Config.from_opts(
               files: source,
               project_root: tmp_dir,
               test_paths: "test",
               checkpoint: checkpoint,
               report_file: report,
               audit_dir: audit,
               format: "json",
               campaign_fingerprint: "campaign"
             )

    assert {:ok, %{results: []}} = Muex.run(config)

    assert %{
             "source_file_count" => 1,
             "selected_source_file_count" => 0,
             "source_files" => [
               %{
                 "path" => "lib/reporter/example.ex",
                 "selected" => false,
                 "selection_reason" => "excluded_by_file_filter",
                 "filter_reason" => "Reporter/Formatter"
               }
             ],
             "candidate_count" => 0,
             "selected_count" => 0,
             "exhaustive" => false
           } = audit |> Path.join("plan.json") |> File.read!() |> Jason.decode!()
  end

  @tag :tmp_dir
  test "checkpoint keeps malformed baseline bytes in the output artifact", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "checkpoint.jsonl")
    output_path = Path.join(tmp_dir, "baseline.log")
    output = <<0x94, 0x80, 0xE2>>
    File.write!(output_path, output)

    artifact = %{
      path: output_path,
      bytes: byte_size(output),
      sha256: :sha256 |> :crypto.hash(output) |> Base.encode16(case: :lower)
    }

    process_result = %{
      output: output,
      output_artifact: artifact,
      exit_code: 0,
      duration_ms: 1,
      failures: 0
    }

    assert {:ok, checkpoint} =
             Checkpoint.open(
               path,
               %{run: "run", source: "source", campaign_fingerprint: "campaign"},
               [mutation()]
             )

    assert :ok =
             Checkpoint.append_baseline(
               checkpoint,
               1,
               ["test"],
               {:ok, %{compile: process_result, test: process_result}}
             )

    [_, baseline] = path |> File.stream!() |> Enum.map(&Jason.decode!/1)

    assert baseline["result"]["compile"]["output_artifact"] == %{
             "path" => output_path,
             "bytes" => byte_size(output),
             "sha256" => artifact.sha256
           }

    refute Map.has_key?(baseline["result"]["compile"], "output")
    assert File.read!(output_path) == output
  end

  defp with_fake_mix(tmp_dir, body, fun) do
    fake_bin = Path.join(tmp_dir, "bin")
    fake_mix = Path.join(fake_bin, "mix")
    original_path = System.get_env("PATH")
    File.mkdir_p!(fake_bin)
    File.write!(fake_mix, "#!/usr/bin/env bash\nset -euo pipefail\n#{body}")
    File.chmod!(fake_mix, 0o755)
    System.put_env("PATH", "#{fake_bin}:#{original_path}")

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
    end
  end

  defp with_system_env(environment, fun) do
    previous = Map.new(environment, fn {name, _value} -> {name, System.get_env(name)} end)

    try do
      Enum.each(environment, fn {name, value} -> System.put_env(name, value) end)
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp os_process_alive?(pid), do: File.exists?("/proc/#{pid}")

  defp terminate_fixture_process(pid) do
    if os_process_alive?(pid) do
      System.cmd("kill", ["-KILL", "--", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end

  defp coverage_fixture!(tmp_dir) do
    project = Path.join(tmp_dir, "coverage-project")
    File.mkdir_p!(Path.join(project, "lib"))
    File.mkdir_p!(Path.join(project, "test"))

    File.write!(
      Path.join(project, "mix.exs"),
      """
      defmodule MuexCoverageFixture.MixProject do
        use Mix.Project

        def project do
          [
            app: :muex_coverage_fixture,
            version: "0.1.0",
            elixir: "~> 1.15",
            compilers: [:coverage_probe] ++ Mix.compilers(),
            test_coverage: [output: System.get_env("MUEX_COVERAGE_OUTPUT_DIR", "cover")]
          ]
        end

        def application, do: []
      end

      defmodule Mix.Tasks.Compile.CoverageProbe do
        use Mix.Task.Compiler

        @impl Mix.Task
        def run(_args) do
          File.write!("compile-probe", "compiled\n", [:append])
          {:ok, []}
        end
      end
      """
    )

    File.write!(
      Path.join(project, "lib/example.ex"),
      """
      defmodule MuexCoverageFixture.Example do
        def value, do: 1
        def other, do: 2
      end
      """
    )

    File.write!(Path.join(project, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(
      Path.join(project, "test/example_test.exs"),
      """
      defmodule MuexCoverageFixture.ExampleTest do
        use ExUnit.Case

        @tag :tmp_dir
        test "value", %{tmp_dir: tmp_dir} do
          File.write!(Path.join(tmp_dir, "coverage-probe"), "isolated")
          assert MuexCoverageFixture.Example.value() == 1
        end
      end
      """
    )

    File.write!(
      Path.join(project, "test/other_test.exs"),
      """
      defmodule MuexCoverageFixture.OtherTest do
        use ExUnit.Case

        test "other" do
          assert MuexCoverageFixture.Example.other() == 2
        end
      end
      """
    )

    {compile_output, 0} =
      System.cmd("mix", ["compile"],
        cd: project,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_ROOT", Path.join(project, "_build")}],
        stderr_to_stdout: true
      )

    assert compile_output =~ "Generated muex_coverage_fixture app"
    File.rm!(Path.join(project, "compile-probe"))
    project
  end

  defp assert_reporting_worker_reaped(tmp_dir, result, opts, expected_error) do
    project = mutation_fixture!(tmp_dir)

    [sandbox] =
      sandboxes =
      Sandbox.create_pool(1, project_root: project, test_paths: [Path.join(project, "test")])

    sandbox_base = Path.dirname(sandbox.root)
    {:ok, pool} = Muex.WorkerPool.start_link(max_workers: 1)
    test_pid = self()
    worker_ref = make_ref()
    reply_tag = make_ref()

    worker =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        Process.link(pool)
        send(test_pid, {:reporting_worker_ready, worker_ref, self()})

        receive do
          {:EXIT, ^pool, :shutdown} ->
            send(test_pid, {:reporting_worker_shutting_down, worker_ref})
            Process.sleep(50)
        end
      end)

    assert_receive {:reporting_worker_ready, ^worker_ref, ^worker}

    :sys.replace_state(pool, fn state ->
      monitor_ref = Process.monitor(worker)

      %{
        state
        | caller: {test_pid, reply_tag},
          total_mutations: 1,
          opts: opts,
          sandboxes: sandboxes,
          active_workers: %{
            worker_ref => {mutation(), "lib/example.ex", 0, worker, monitor_ref}
          },
          monitor_to_worker: %{monitor_ref => worker_ref}
      }
    end)

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)

      if Process.alive?(pool) do
        try do
          GenServer.stop(pool, :normal, :infinity)
        catch
          :exit, _reason -> :ok
        end
      end

      Sandbox.cleanup(sandboxes)
    end)

    send(pool, {:worker_done, worker_ref, result})

    assert_receive {:reporting_worker_shutting_down, ^worker_ref}
    refute_receive {^reply_tag, _reply}, 25
    assert_receive {^reply_tag, {:error, ^expected_error}}
    refute Process.alive?(worker)
    refute File.exists?(sandbox_base)
  end

  defp mutation_fixture!(tmp_dir) do
    project = Path.join(tmp_dir, "project")
    File.mkdir_p!(Path.join(project, "lib"))
    File.mkdir_p!(Path.join(project, "test"))
    File.mkdir_p!(Path.join(project, "_build/test/lib/example_app/.mix"))

    File.write!(
      Path.join(project, "lib/example.ex"),
      "defmodule Example do\n  def value, do: 1\nend\n"
    )

    File.write!(Path.join(project, "test/example_test.exs"), "")
    File.write!(Path.join(project, "_build/test/lib/example_app/.mix/compile.elixir"), "manifest")
    project
  end

  defp file_entry do
    {:ok, ast} = Code.string_to_quoted("defmodule Example do\n  def value, do: 1\nend\n")
    %{path: "lib/example.ex", ast: ast, module_name: Example}
  end

  defp mutation do
    %{
      id: "fixture-mutant",
      ast: 2,
      original_ast: :not_in_source,
      target_ordinal: 0,
      mutator: Literal,
      description: "no-op fixture",
      location: %{file: "lib/example.ex", line: 2}
    }
  end

  defp continuation_shards do
    [
      %{selected_ids: ~w(a b c), result_ids: ~w(a), infrastructure_error_ids: []},
      %{selected_ids: ~w(d e), result_ids: ~w(d), infrastructure_error_ids: ~w(e)}
    ]
  end

  defp coverage_partition_manifest(index_path, tests, evidence_path, corpus_tests) do
    evidence = [
      %{
        path: evidence_path,
        bytes: File.stat!(evidence_path).size,
        sha256: sha256_file!(evidence_path)
      }
    ]

    %{
      version: 1,
      corpus_fingerprint: "fixture-corpus",
      corpus_test_count: length(corpus_tests),
      corpus_tests_sha256: sha256_term(corpus_tests),
      tests: tests,
      index_sha256: sha256_file!(index_path),
      evidence: evidence,
      batch: %{
        mode: "conservative_partition",
        tests: tests,
        test_count: length(tests),
        evidence: evidence
      }
    }
  end

  defp sha256_file!(path) do
    :sha256
    |> :crypto.hash(File.read!(path))
    |> Base.encode16(case: :lower)
  end

  defp sha256_term(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(Enum.sort(term)))
    |> Base.encode16(case: :lower)
  end

  defp drain_messages(message) do
    receive do
      ^message -> drain_messages(message)
    after
      0 -> :ok
    end
  end

  defp optimizer_mutation(id, ast, mutator) do
    %{
      id: id,
      ast: ast,
      original_ast: ast,
      target_ordinal: 0,
      mutator: mutator,
      description: id,
      location: %{file: "lib/example.ex", line: 2}
    }
  end
end
