defmodule Mix.Tasks.Muex.Coverage do
  @shortdoc false
  @moduledoc false

  use Mix.Task

  alias Muex.Coverage
  alias Muex.Coverage.SelectiveTool
  alias Muex.Language.Elixir, as: ElixirLanguage

  @switches [
    project_root: :string,
    source_files: :string,
    test_files: :string,
    parts_file: :string,
    expected_tests_file: :string,
    index: :string,
    manifest: :string,
    audit_dir: :string,
    partition: :integer,
    output: :string
  ]

  @impl Mix.Task
  def run(["manifest" | args]) do
    opts = parse!(args, ~w(project_root source_files output)a)
    root = opts |> Keyword.fetch!(:project_root) |> Path.expand()

    SelectiveTool.write_manifest!(
      root,
      read_lines(Keyword.fetch!(opts, :source_files)),
      Mix.Project.compile_path(),
      Keyword.fetch!(opts, :output)
    )
  end

  def run(["export" | args]) do
    opts = parse!(args, ~w(project_root source_files test_files index audit_dir)a)
    root = opts |> Keyword.fetch!(:project_root) |> Path.expand()
    source_files = read_lines(Keyword.fetch!(opts, :source_files))
    relative_tests = read_lines(Keyword.fetch!(opts, :test_files))
    test_files = Enum.map(relative_tests, &Path.expand(&1, root))

    file_to_module = coverage_modules(source_files, root)

    audit_dir = Keyword.fetch!(opts, :audit_dir)

    index =
      Coverage.collect(test_files, file_to_module,
        cd: root,
        test_paths: [Path.join(root, "test")],
        output: audit_dir
      )

    index_path = Keyword.fetch!(opts, :index)
    Coverage.write_index!(index, index_path)
    batch_evidence = evidence(audit_dir)

    corpus_fingerprint =
      Coverage.corpus_fingerprint(
        root,
        source_files,
        test_files,
        System.get_env("MUEX_COVERAGE_MODULES_FILE")
      )

    write_json!(index_path <> ".manifest.json", %{
      version: 1,
      partition: Keyword.get(opts, :partition),
      tests: relative_tests,
      index_sha256: sha256_file!(index_path),
      corpus_fingerprint: corpus_fingerprint,
      evidence: batch_evidence,
      batch: %{
        mode: "conservative_partition",
        tests: relative_tests,
        test_count: length(relative_tests),
        evidence: batch_evidence
      }
    })

    :ok
  end

  def run(["merge" | args]) do
    opts = parse!(args, ~w(parts_file expected_tests_file index manifest)a)
    parts = read_lines(Keyword.fetch!(opts, :parts_file))
    expected_tests = opts |> Keyword.fetch!(:expected_tests_file) |> read_lines() |> Enum.sort()
    manifests = Enum.map(parts, &read_part!/1)
    actual_tests = Enum.flat_map(manifests, & &1["tests"])
    corpus_fingerprints = manifests |> Enum.map(& &1["corpus_fingerprint"]) |> Enum.uniq()

    if length(actual_tests) != length(Enum.uniq(actual_tests)) or
         Enum.sort(actual_tests) != expected_tests or length(corpus_fingerprints) != 1 do
      Mix.raise("coverage partitions are not disjoint and exhaustive")
    end

    indexes = Enum.map(parts, &Coverage.read_index!/1)
    index_path = Keyword.fetch!(opts, :index)
    Coverage.write_index!(Coverage.merge(indexes), index_path)

    manifest = %{
      version: 1,
      test_count: length(expected_tests),
      tests_sha256: sha256_term(expected_tests),
      index_sha256: sha256_file!(index_path),
      corpus_fingerprint: hd(corpus_fingerprints),
      parts:
        Enum.zip_with(parts, manifests, fn path, manifest ->
          %{
            path: path,
            test_count: length(manifest["tests"]),
            index_sha256: manifest["index_sha256"]
          }
        end)
    }

    manifest_path = Keyword.fetch!(opts, :manifest)
    write_json!(manifest_path, manifest)

    adjacent_manifest = index_path <> ".manifest.json"
    if adjacent_manifest != manifest_path, do: write_json!(adjacent_manifest, manifest)

    :ok
  end

  def run(["validate" | args]) do
    opts = parse!(args, ~w(expected_tests_file index manifest)a)
    expected_tests = opts |> Keyword.fetch!(:expected_tests_file) |> read_lines() |> Enum.sort()
    index_path = Keyword.fetch!(opts, :index)
    manifest = opts |> Keyword.fetch!(:manifest) |> File.read!() |> Jason.decode!()
    Coverage.read_index!(index_path)

    valid? =
      manifest["version"] == 1 and
        manifest["test_count"] == length(expected_tests) and
        manifest["tests_sha256"] == sha256_term(expected_tests) and
        manifest["index_sha256"] == sha256_file!(index_path) and
        is_binary(manifest["corpus_fingerprint"])

    if not valid?, do: Mix.raise("coverage index validation failed")
    :ok
  end

  def run(_args), do: Mix.raise("expected muex.coverage manifest, export, merge, or validate")

  defp parse!(args, required) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        missing = Enum.reject(required, &Keyword.has_key?(opts, &1))

        if missing == [],
          do: opts,
          else: Mix.raise("missing coverage options: #{inspect(missing)}")

      {_opts, rest, invalid} ->
        Mix.raise("invalid coverage options: #{inspect(invalid ++ rest)}")
    end
  end

  defp coverage_modules(source_files, root) do
    case System.get_env("MUEX_COVERAGE_MODULES_FILE") do
      manifest when is_binary(manifest) and manifest != "" ->
        manifest
        |> SelectiveTool.read_manifest!(Mix.Project.compile_path())
        |> Enum.group_by(& &1.source, & &1.module)

      _other ->
        source_files
        |> Enum.map(&Path.expand(&1, root))
        |> Muex.Loader.load_all(ElixirLanguage)
        |> case do
          {:ok, entries} ->
            Map.new(entries, fn entry ->
              {Path.relative_to(entry.path, root), entry.module_name}
            end)

          {:error, reason} ->
            Mix.raise("coverage source loading failed: #{inspect(reason)}")
        end
    end
  end

  defp read_part!(path) do
    manifest = path <> ".manifest.json"

    case manifest |> File.read!() |> Jason.decode!() do
      %{
        "version" => 1,
        "tests" => tests,
        "index_sha256" => sha256,
        "corpus_fingerprint" => corpus_fingerprint,
        "evidence" => evidence
      } =
          decoded
      when is_list(tests) and is_binary(sha256) and is_binary(corpus_fingerprint) and
             is_list(evidence) ->
        if Enum.all?(tests, &is_binary/1) and sha256 == sha256_file!(path) and
             valid_batch?(decoded["batch"], tests, evidence),
           do: decoded,
           else: Mix.raise("invalid coverage partition: #{path}")

      _other ->
        Mix.raise("invalid coverage partition manifest: #{manifest}")
    end
  end

  defp valid_batch?(
         %{
           "mode" => "conservative_partition",
           "tests" => batch_tests,
           "test_count" => test_count,
           "evidence" => batch_evidence
         },
         tests,
         evidence
       ) do
    batch_tests == tests and test_count == length(tests) and batch_evidence == evidence and
      Enum.all?(evidence, &valid_evidence?/1)
  end

  defp valid_batch?(_batch, _tests, _evidence), do: false

  defp valid_evidence?(%{"path" => path, "bytes" => bytes, "sha256" => sha256})
       when is_binary(path) and is_integer(bytes) and bytes >= 0 and is_binary(sha256) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: ^bytes}} -> sha256_file!(path) == sha256
      _other -> false
    end
  end

  defp valid_evidence?(_evidence), do: false

  defp read_lines(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp evidence(dir) do
    dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map(fn path ->
      %{path: path, bytes: File.stat!(path).size, sha256: sha256_file!(path)}
    end)
  end

  defp write_json!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    temporary = "#{path}.tmp-#{System.unique_integer([:positive, :monotonic])}"

    try do
      File.write!(temporary, Jason.encode!(value), [:exclusive])
      File.rename!(temporary, path)
    after
      if File.exists?(temporary), do: File.rm!(temporary)
    end
  end

  defp sha256_file!(path), do: path |> File.read!() |> sha256()
  defp sha256_term(term), do: term |> :erlang.term_to_binary() |> sha256()
  defp sha256(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)
end
