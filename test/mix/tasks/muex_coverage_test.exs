defmodule Mix.Tasks.Muex.CoverageTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Muex.Coverage, as: CoverageTask
  alias Muex.Coverage
  alias Muex.Coverage.SelectiveTool

  @moduletag :tmp_dir

  test "the coverage task and its manifest reader are a documented public seam" do
    assert is_binary(Mix.Task.shortdoc(CoverageTask))

    assert {:docs_v1, _, _, _, %{"en" => task_doc}, _, _} = Code.fetch_docs(CoverageTask)
    assert task_doc =~ "docs/CAMPAIGN_API.md"
    assert task_doc =~ "MUEX_COVERAGE_MODULES_FILE"

    assert {:docs_v1, _, _, _, %{"en" => tool_doc}, _, tool_docs} = Code.fetch_docs(SelectiveTool)
    assert tool_doc =~ "test_coverage: [tool: Muex.Coverage.SelectiveTool]"
    assert tool_doc =~ "MUEX_COVERAGE_MODULES_FILE"

    assert {_, _, _, %{"en" => _}, _} =
             List.keyfind(tool_docs, {:function, :read_manifest!, 2}, 0)
  end

  test "rejects an unknown subcommand" do
    assert_raise Mix.Error,
                 ~r/expected muex\.coverage manifest, export, merge, or validate/,
                 fn ->
                   CoverageTask.run(["reticulate"])
                 end
  end

  test "names the options a subcommand is missing" do
    assert_raise Mix.Error,
                 ~r/missing coverage options: \[:project_root, :source_files, :output\]/,
                 fn -> CoverageTask.run(["manifest"]) end

    assert_raise Mix.Error,
                 ~r/missing coverage options: \[:parts_file, :expected_tests_file\]/,
                 fn -> CoverageTask.run(["merge", "--index", "i", "--manifest", "m"]) end

    assert_raise Mix.Error, ~r/invalid coverage options/, fn ->
      CoverageTask.run(["validate", "--nope", "1"])
    end
  end

  test "manifest writes a selective manifest the public reader accepts", %{tmp_dir: tmp_dir} do
    sources = Path.join(tmp_dir, "sources.txt")
    output = Path.join(tmp_dir, "modules.json")
    File.write!(sources, "lib/muex/coverage.ex\n")

    assert :ok =
             CoverageTask.run([
               "manifest",
               "--project-root",
               ".",
               "--source-files",
               sources,
               "--output",
               output
             ])

    entries = SelectiveTool.read_manifest!(output, Mix.Project.compile_path())

    assert Enum.any?(entries, &(&1.module == Muex.Coverage))
    assert Enum.all?(entries, &(&1.source == "lib/muex/coverage.ex" and File.regular?(&1.beam)))
  end

  test "merge joins disjoint partitions into a validated index", %{tmp_dir: tmp_dir} do
    corpus = ~w(test/a_test.exs test/b_test.exs)
    a = partition!(tmp_dir, "a", ["test/a_test.exs"], corpus, "lib/a.ex")
    b = partition!(tmp_dir, "b", ["test/b_test.exs"], corpus, "lib/b.ex")

    expected = write_lines!(tmp_dir, "expected.txt", corpus)
    parts = write_lines!(tmp_dir, "parts.txt", [a, b])
    index = Path.join(tmp_dir, "merged.etf")
    manifest = Path.join(tmp_dir, "merged.manifest.json")

    assert :ok =
             CoverageTask.run([
               "merge",
               "--parts-file",
               parts,
               "--expected-tests-file",
               expected,
               "--index",
               index,
               "--manifest",
               manifest
             ])

    merged = Coverage.read_index!(index)
    assert Coverage.tests_for(merged, "lib/a.ex", 1) == {:covered, ["test/a_test.exs"]}
    assert Coverage.tests_for(merged, "lib/b.ex", 1) == {:covered, ["test/b_test.exs"]}

    decoded = manifest |> File.read!() |> Jason.decode!()
    assert decoded["version"] == 1
    assert decoded["test_count"] == 2
    assert Enum.map(decoded["parts"], & &1["path"]) == [a, b]
    assert File.read!(index <> ".manifest.json") == File.read!(manifest)

    assert :ok =
             CoverageTask.run([
               "validate",
               "--expected-tests-file",
               expected,
               "--index",
               index,
               "--manifest",
               manifest
             ])
  end

  test "merge refuses partitions that overlap or miss the corpus", %{tmp_dir: tmp_dir} do
    corpus = ~w(test/a_test.exs test/b_test.exs)
    a = partition!(tmp_dir, "a", ["test/a_test.exs"], corpus, "lib/a.ex")
    duplicate = partition!(tmp_dir, "duplicate", ["test/a_test.exs"], corpus, "lib/b.ex")

    expected = write_lines!(tmp_dir, "expected.txt", corpus)
    parts = write_lines!(tmp_dir, "parts.txt", [a, duplicate])

    assert_raise Mix.Error, ~r/coverage partitions are not disjoint and exhaustive/, fn ->
      CoverageTask.run([
        "merge",
        "--parts-file",
        parts,
        "--expected-tests-file",
        expected,
        "--index",
        Path.join(tmp_dir, "merged.etf"),
        "--manifest",
        Path.join(tmp_dir, "merged.manifest.json")
      ])
    end
  end

  test "merge refuses a partition whose index no longer matches its manifest", %{
    tmp_dir: tmp_dir
  } do
    corpus = ["test/a_test.exs"]
    a = partition!(tmp_dir, "a", corpus, corpus, "lib/a.ex")
    Coverage.write_index!(Coverage.put(Coverage.new(), "lib/a.ex", 99, "test/a_test.exs"), a)

    expected = write_lines!(tmp_dir, "expected.txt", corpus)
    parts = write_lines!(tmp_dir, "parts.txt", [a])

    assert_raise Mix.Error, ~r/invalid coverage partition/, fn ->
      CoverageTask.run([
        "merge",
        "--parts-file",
        parts,
        "--expected-tests-file",
        expected,
        "--index",
        Path.join(tmp_dir, "merged.etf"),
        "--manifest",
        Path.join(tmp_dir, "merged.manifest.json")
      ])
    end
  end

  test "validate refuses an index that drifted from its manifest", %{tmp_dir: tmp_dir} do
    corpus = ["test/a_test.exs"]
    part = partition!(tmp_dir, "a", corpus, corpus, "lib/a.ex")
    expected = write_lines!(tmp_dir, "expected.txt", corpus)
    parts = write_lines!(tmp_dir, "parts.txt", [part])
    index = Path.join(tmp_dir, "merged.etf")
    manifest = Path.join(tmp_dir, "merged.manifest.json")

    assert :ok =
             CoverageTask.run([
               "merge",
               "--parts-file",
               parts,
               "--expected-tests-file",
               expected,
               "--index",
               index,
               "--manifest",
               manifest
             ])

    Coverage.write_index!(Coverage.put(Coverage.new(), "lib/a.ex", 7, "test/a_test.exs"), index)

    assert_raise Mix.Error, ~r/coverage index validation failed/, fn ->
      CoverageTask.run([
        "validate",
        "--expected-tests-file",
        expected,
        "--index",
        index,
        "--manifest",
        manifest
      ])
    end
  end

  defp partition!(tmp_dir, name, tests, corpus, source) do
    index = Path.join(tmp_dir, "#{name}.etf")

    index_value =
      Enum.reduce(tests, Coverage.new(), &Coverage.put(&2, source, 1, &1))

    Coverage.write_index!(index_value, index)

    evidence_path = Path.join([tmp_dir, "audit-#{name}", "coverage.log"])
    File.mkdir_p!(Path.dirname(evidence_path))
    File.write!(evidence_path, name)

    evidence = [
      %{
        path: evidence_path,
        bytes: File.stat!(evidence_path).size,
        sha256: sha256_file!(evidence_path)
      }
    ]

    File.write!(
      index <> ".manifest.json",
      Jason.encode!(%{
        version: 1,
        tests: tests,
        corpus_test_count: length(corpus),
        corpus_tests_sha256: sha256_term(Enum.sort(corpus)),
        index_sha256: sha256_file!(index),
        corpus_fingerprint: "corpus-fingerprint",
        evidence: evidence,
        batch: %{
          mode: "conservative_partition",
          tests: tests,
          test_count: length(tests),
          evidence: evidence
        }
      })
    )

    index
  end

  defp write_lines!(tmp_dir, name, lines) do
    path = Path.join(tmp_dir, name)
    File.write!(path, Enum.map_join(lines, "\n", & &1) <> "\n")
    path
  end

  defp sha256_file!(path), do: path |> File.read!() |> sha256()
  defp sha256_term(term), do: term |> :erlang.term_to_binary() |> sha256()
  defp sha256(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)
end
