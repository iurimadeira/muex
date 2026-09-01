defmodule Muex.SelectiveCoverageToolTest do
  use ExUnit.Case, async: false

  alias Muex.Coverage
  alias Muex.Coverage.SelectiveTool

  setup do
    previous_manifest = System.get_env("MUEX_COVERAGE_MODULES_FILE")

    on_exit(fn ->
      :cover.stop()

      case previous_manifest do
        nil -> System.delete_env("MUEX_COVERAGE_MODULES_FILE")
        value -> System.put_env("MUEX_COVERAGE_MODULES_FILE", value)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "instruments only modules selected by source manifest", %{tmp_dir: tmp_dir} do
    fixture = coverage_fixture!(tmp_dir, [:selected, :unselected])
    manifest = Path.join(tmp_dir, "modules.json")

    SelectiveTool.write_manifest!(
      fixture.root,
      [fixture.sources.selected],
      fixture.compile_path,
      manifest
    )

    System.put_env("MUEX_COVERAGE_MODULES_FILE", manifest)

    callback =
      SelectiveTool.start(fixture.compile_path,
        export: "selected",
        output: Path.join(tmp_dir, "cover")
      )

    assert fixture.modules.selected in :cover.modules()
    refute fixture.modules.unselected in :cover.modules()
    callback.()
  end

  @tag :tmp_dir
  test "rejects malformed, missing, and outside beam entries", %{tmp_dir: tmp_dir} do
    fixture = coverage_fixture!(tmp_dir, [:selected])
    module = fixture.modules.selected
    source = Path.relative_to(fixture.sources.selected, fixture.root)

    invalid = Path.join(tmp_dir, "invalid.json")
    File.write!(invalid, "not-json")
    System.put_env("MUEX_COVERAGE_MODULES_FILE", invalid)

    assert_raise Mix.Error, ~r/invalid selective coverage manifest/, fn ->
      SelectiveTool.start(fixture.compile_path, [])
    end

    missing = Path.join(tmp_dir, "missing.json")
    write_manifest!(missing, source, module, "Elixir.Missing.beam")
    System.put_env("MUEX_COVERAGE_MODULES_FILE", missing)

    assert_raise Mix.Error, ~r/missing coverage beam/, fn ->
      SelectiveTool.start(fixture.compile_path, [])
    end

    outside = Path.join(tmp_dir, "outside.json")
    write_manifest!(outside, source, module, "../Elixir.Outside.beam")
    System.put_env("MUEX_COVERAGE_MODULES_FILE", outside)

    assert_raise Mix.Error, ~r/outside compile path/, fn ->
      SelectiveTool.start(fixture.compile_path, [])
    end
  end

  @tag :tmp_dir
  test "manifest generation fails when a selected source has no beam", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "project")
    compile_path = Path.join(root, "_build/test/lib/example/ebin")
    source = Path.join(root, "lib/missing.ex")
    File.mkdir_p!(compile_path)
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "defmodule MissingCoverageBeam do\nend\n")

    assert_raise Mix.Error, ~r/selected source has no compiled beam/, fn ->
      SelectiveTool.write_manifest!(
        root,
        [source],
        compile_path,
        Path.join(tmp_dir, "modules.json")
      )
    end
  end

  @tag :tmp_dir
  test "export preserves exact per-test line attribution", %{tmp_dir: tmp_dir} do
    fixture = coverage_fixture!(tmp_dir, [:selected])
    manifest = Path.join(tmp_dir, "modules.json")
    output = Path.join(tmp_dir, "cover")
    module = fixture.modules.selected

    SelectiveTool.write_manifest!(
      fixture.root,
      [fixture.sources.selected],
      fixture.compile_path,
      manifest
    )

    System.put_env("MUEX_COVERAGE_MODULES_FILE", manifest)

    callback = SelectiveTool.start(fixture.compile_path, export: "one-test", output: output)
    assert module.hit() == :hit
    callback.()

    coverdata = Path.join(output, "one-test.coverdata")
    assert File.regular?(coverdata)
    assert Path.wildcard(Path.join(output, "*.tmp-*")) == []

    :cover.stop()
    {:ok, _pid} = :cover.start()
    :ok = :cover.import(String.to_charlist(coverdata))
    {:ok, analysis} = :cover.analyse(module, :calls, :line)

    assert 2 in Coverage.covered_lines(analysis)
    refute 3 in Coverage.covered_lines(analysis)
  end

  @tag :tmp_dir
  test "does not traverse or compile unlisted beams", %{tmp_dir: tmp_dir} do
    fixture = coverage_fixture!(tmp_dir, [:selected])
    invalid_unlisted = Path.join(fixture.compile_path, "Elixir.InvalidUnlisted.beam")
    File.write!(invalid_unlisted, "not-a-beam")
    manifest = Path.join(tmp_dir, "modules.json")

    write_manifest!(
      manifest,
      Path.relative_to(fixture.sources.selected, fixture.root),
      fixture.modules.selected,
      Path.basename(fixture.beams.selected)
    )

    System.put_env("MUEX_COVERAGE_MODULES_FILE", manifest)
    _callback = SelectiveTool.start(fixture.compile_path, [])

    assert fixture.modules.selected in :cover.modules()
  end

  test "missing coverage keys remain unknown and therefore conservative" do
    assert Coverage.tests_for(Coverage.new(), "lib/example.ex", 42) == :unknown
  end

  @tag :tmp_dir
  test "external indexes are accepted only for the exact source, test, and selective corpus", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "project")
    source = Path.join(root, "lib/example.ex")
    test_file = Path.join(root, "test/example_test.exs")
    selective = Path.join(root, "selective.json")
    index_path = Path.join(root, "coverage.etf")
    File.mkdir_p!(Path.dirname(source))
    File.mkdir_p!(Path.dirname(test_file))
    File.write!(source, "defmodule Example do\nend\n")
    File.write!(test_file, "test")
    File.write!(selective, "{}")

    index = Coverage.put(Coverage.new(), "lib/example.ex", 1, "test/example_test.exs")
    Coverage.write_index!(index, index_path)
    fingerprint = Coverage.corpus_fingerprint(root, [source], [test_file], selective)

    File.write!(
      index_path <> ".manifest.json",
      Jason.encode!(%{
        version: 1,
        corpus_fingerprint: fingerprint,
        index_sha256: sha256_file!(index_path)
      })
    )

    assert {:ok, ^index} = Coverage.read_bound_index(index_path, fingerprint)

    for {path, replacement} <- [
          {source, "defmodule Changed do\nend\n"},
          {test_file, "changed test"},
          {selective, ~s({"changed":true})}
        ] do
      original = File.read!(path)
      File.write!(path, replacement)
      stale = Coverage.corpus_fingerprint(root, [source], [test_file], selective)
      assert :stale = Coverage.read_bound_index(index_path, stale)
      File.write!(path, original)
    end
  end

  defp coverage_fixture!(tmp_dir, names) do
    root = Path.join(tmp_dir, "project")
    compile_path = Path.join(root, "_build/test/lib/example/ebin")
    File.mkdir_p!(compile_path)

    fixtures =
      Map.new(names, fn name ->
        unique = System.unique_integer([:positive, :monotonic])

        module =
          Module.concat([
            __MODULE__,
            Macro.camelize(to_string(name)) <> Integer.to_string(unique)
          ])

        source = Path.join(root, "lib/#{name}.ex")

        File.mkdir_p!(Path.dirname(source))

        File.write!(
          source,
          "defmodule #{inspect(module)} do\n  def hit, do: :hit\n  def miss, do: :miss\nend\n"
        )

        compiler_options = Code.compiler_options()
        Code.compiler_options(debug_info: true)

        compiled =
          try do
            Code.compile_file(source)
          after
            Code.compiler_options(compiler_options)
          end

        [{^module, binary}] = compiled
        beam = Path.join(compile_path, Atom.to_string(module) <> ".beam")
        File.write!(beam, binary)
        :code.purge(module)
        :code.delete(module)
        {name, %{module: module, source: source, beam: beam}}
      end)

    %{
      root: root,
      compile_path: compile_path,
      modules: Map.new(fixtures, fn {name, value} -> {name, value.module} end),
      sources: Map.new(fixtures, fn {name, value} -> {name, value.source} end),
      beams: Map.new(fixtures, fn {name, value} -> {name, value.beam} end)
    }
  end

  defp write_manifest!(path, source, module, beam) do
    File.write!(
      path,
      Jason.encode!(%{
        version: 1,
        source_files: [source],
        modules: [%{source: source, module: Atom.to_string(module), beam: beam}]
      })
    )
  end

  defp sha256_file!(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
