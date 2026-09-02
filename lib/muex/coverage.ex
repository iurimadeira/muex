defmodule Muex.Coverage do
  @moduledoc """
  A line-level coverage index: which test files execute which source lines.

  Used to run, for each mutant, only the tests that actually exercise the
  mutated line — and to skip mutants on lines no test covers (`:no_coverage`)
  rather than wasting a full test run on a mutant nothing can catch.

  The index is a plain map (`%{file => %{line => MapSet of test files}}`); build
  it with `new/0` + `put/4` and query it with `tests_for/3` / `covered?/3`.
  """

  alias Muex.Sandbox

  @index_version 1

  @type t :: %{Path.t() => %{pos_integer() => MapSet.t(Path.t())}}

  @doc "Returns an empty index."
  @spec new() :: t()
  def new, do: %{}

  @doc "Writes a validated, versioned coverage index atomically."
  @spec write_index!(t(), Path.t()) :: :ok
  def write_index!(index, path) do
    validate_index!(index)
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))
    temporary = "#{path}.tmp-#{System.unique_integer([:positive, :monotonic])}"
    payload = :erlang.term_to_binary(%{version: @index_version, index: index}, compressed: 6)

    try do
      File.write!(temporary, payload, [:binary, :exclusive])
      File.rename!(temporary, path)
    after
      if File.exists?(temporary), do: File.rm!(temporary)
    end

    :ok
  end

  @doc "Reads and validates a versioned coverage index."
  @spec read_index!(Path.t()) :: t()
  def read_index!(path) do
    path
    |> File.read!()
    |> decode_index!()
  rescue
    error in [ArgumentError] ->
      reraise ArgumentError,
              [message: "invalid coverage index: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  defp decode_index!(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      %{version: @index_version, index: index} when map_size(index) >= 0 ->
        validate_index!(index)

      _other ->
        raise ArgumentError, "invalid coverage index: unsupported version or shape"
    end
  end

  @doc false
  def read_bound_index(path, expected_fingerprint) do
    case read_bound_index_snapshot(path, expected_fingerprint) do
      {:ok, snapshot} -> {:ok, snapshot.index}
      :stale -> :stale
    end
  end

  @doc false
  def read_bound_index_snapshot(path, expected_fingerprint) do
    manifest_path = path <> ".manifest.json"

    with {:ok, index_bytes} <- File.read(path),
         digest = sha256(index_bytes),
         {:ok, manifest_bytes} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(manifest_bytes),
         true <- manifest["version"] == 1,
         true <- manifest["corpus_fingerprint"] == expected_fingerprint,
         true <- manifest["index_sha256"] == digest,
         {:ok, index} <- decode_index(index_bytes) do
      {:ok, %{index: index, sha256: digest}}
    else
      _stale_or_missing -> :stale
    end
  end

  defp decode_index(binary) do
    {:ok, decode_index!(binary)}
  rescue
    _error in ArgumentError -> :stale
  end

  @doc false
  def corpus_fingerprint(
        project_root,
        source_files,
        test_files,
        selective_manifest \\ nil,
        auxiliary_paths \\ []
      ) do
    root = Path.expand(project_root)
    auxiliary_snapshot = fingerprint_auxiliary_paths(root, auxiliary_paths)

    corpus_fingerprint_from_auxiliary_snapshot(
      root,
      source_files,
      test_files,
      selective_manifest,
      auxiliary_snapshot
    )
  end

  @doc false
  def corpus_fingerprint_from_auxiliary_snapshot(
        project_root,
        source_files,
        test_files,
        selective_manifest,
        auxiliary_snapshot
      ) do
    root = Path.expand(project_root)

    common = {
      fingerprint_files(root, source_files),
      fingerprint_files(root, test_files),
      fingerprint_optional_file(selective_manifest),
      System.version(),
      :erlang.system_info(:otp_release),
      Application.spec(:muex, :vsn)
    }

    case auxiliary_snapshot do
      [] -> digest(Tuple.insert_at(common, 0, "muex-coverage-corpus-v1"))
      entries -> digest({"muex-coverage-corpus-v2", common, entries})
    end
  end

  @doc "Records that `test_file` executes `line` of `file`."
  @spec put(t(), Path.t(), pos_integer(), Path.t()) :: t()
  def put(index, file, line, test_file) do
    Map.update(index, file, %{line => MapSet.new([test_file])}, fn lines ->
      Map.update(lines, line, MapSet.new([test_file]), &MapSet.put(&1, test_file))
    end)
  end

  @doc "Records that `line` of `file` is executable (even if no test runs it)."
  @spec put_executable(t(), Path.t(), pos_integer()) :: t()
  def put_executable(index, file, line) do
    Map.update(index, file, %{line => MapSet.new()}, &Map.put_new(&1, line, MapSet.new()))
  end

  @doc """
  Returns the coverage status of `file:line`:

    * `{:covered, sorted_test_files}` — at least one test executes the line;
    * `:no_coverage` — the line is executable but no test runs it;
    * `:unknown` — there is no coverage data for the line (e.g. it is not an
      executable line, like a `defmodule`/`def` header), so coverage can't
      decide and the caller should run the mutant normally.
  """
  @spec tests_for(t(), Path.t(), pos_integer()) ::
          {:covered, [Path.t()]} | :no_coverage | :unknown
  def tests_for(index, file, line) do
    case get_in(index, [file, line]) do
      nil ->
        :unknown

      set ->
        if MapSet.size(set) == 0,
          do: :no_coverage,
          else: {:covered, set |> MapSet.to_list() |> Enum.sort()}
    end
  end

  @doc "Returns every test that executes at least one line of `file`."
  @spec tests_for_file(t(), Path.t()) :: [Path.t()]
  def tests_for_file(index, file) do
    index
    |> Map.get(file, %{})
    |> Map.values()
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @doc "Merges coverage indexes by unioning their test sets."
  @spec merge([t()]) :: t()
  def merge(indexes) when is_list(indexes) do
    Enum.reduce(indexes, new(), fn index, merged ->
      validate_index!(index)

      Enum.reduce(index, merged, fn {file, lines}, file_acc ->
        Enum.reduce(lines, file_acc, fn {line, tests}, line_acc ->
          Enum.reduce(tests, put_executable(line_acc, file, line), fn test, test_acc ->
            put(test_acc, file, line, test)
          end)
        end)
      end)
    end)
  end

  @doc "Records that `test_file` executes every line in `lines` of `file`."
  @spec put_lines(t(), Path.t(), [pos_integer()], Path.t()) :: t()
  def put_lines(index, file, lines, test_file) do
    Enum.reduce(lines, index, fn line, idx -> put(idx, file, line, test_file) end)
  end

  @doc "Whether any test covers `file:line`."
  @spec covered?(t(), Path.t(), pos_integer()) :: boolean()
  def covered?(index, file, line), do: match?({:covered, _}, tests_for(index, file, line))

  defp validate_index!(index) when is_map(index) do
    valid? =
      Enum.all?(index, fn
        {file, lines} when is_binary(file) and is_map(lines) ->
          Enum.all?(lines, fn
            {line, %MapSet{} = tests} when is_integer(line) and line > 0 ->
              Enum.all?(tests, &is_binary/1)

            _other ->
              false
          end)

        _other ->
          false
      end)

    if valid?, do: index, else: raise(ArgumentError, "invalid coverage index: malformed entries")
  end

  defp validate_index!(_index), do: raise(ArgumentError, "invalid coverage index: expected a map")

  defp fingerprint_files(root, paths) do
    paths
    |> Enum.map(&Path.expand(&1, root))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn path -> {Path.relative_to(path, root), sha256_file(path)} end)
  end

  defp fingerprint_optional_file(nil), do: nil
  defp fingerprint_optional_file(""), do: nil
  defp fingerprint_optional_file(path), do: sha256_file(path)

  defp fingerprint_auxiliary_paths(root, paths) do
    root
    |> Sandbox.validate_auxiliary_paths!(paths)
    |> Enum.map(fn relative ->
      path = Path.join(root, relative)
      {relative, fingerprint_auxiliary_tree(path, root)}
    end)
  end

  defp fingerprint_auxiliary_tree(path, root) do
    case File.lstat!(path) do
      %File.Stat{type: :regular} ->
        [{Path.relative_to(path, root), sha256_file(path)}]

      %File.Stat{type: :directory} ->
        children = path |> File.ls!() |> Enum.sort()

        [
          {Path.relative_to(path, root), :directory}
          | Enum.flat_map(children, &fingerprint_auxiliary_tree(Path.join(path, &1), root))
        ]
    end
  end

  defp sha256_file(path) do
    case File.read(path) do
      {:ok, bytes} -> sha256(bytes)
      {:error, reason} -> {:missing, reason}
    end
  end

  defp digest(term), do: term |> :erlang.term_to_binary() |> sha256()
  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @doc """
  Extracts the executed line numbers from a `:cover.analyse(_, :calls, :line)`
  result, i.e. the lines with a non-zero call count.
  """
  @spec covered_lines([{{module(), pos_integer()}, non_neg_integer()}]) :: [pos_integer()]
  def covered_lines(line_analysis) do
    for {{_module, line}, calls} <- line_analysis, calls > 0, do: line
  end

  @doc """
  Builds a conservative coverage index by running all test files in one
  partition under `:cover`.

  Runs one `mix test <files...> --cover --export-coverage` subprocess, then
  attributes every source line covered by the batch to every test file in that
  batch. This can select extra tests for a mutant, but cannot omit a test on the
  strength of unavailable per-test attribution. Returns a `t()` index.

  Options: `:cd` (project root, default `File.cwd!/0`), `:test_paths`,
  `:auxiliary_paths` (explicit project-relative roots/files mirrored into the
  private sandbox), and `:output` (persistent coverage evidence directory).
  """
  @spec collect([Path.t()], %{Path.t() => module()}, keyword()) :: t()
  def collect(test_files, file_to_module, opts \\ []) do
    collect_with_auxiliary_snapshot(test_files, file_to_module, opts).index
  end

  @doc false
  def collect_with_auxiliary_snapshot(test_files, file_to_module, opts \\ []) do
    project_root = opts |> Keyword.get(:cd, File.cwd!()) |> Path.expand()
    test_paths = Keyword.get(opts, :test_paths, [Path.join(project_root, "test")])
    auxiliary_paths = Keyword.get(opts, :auxiliary_paths, [])
    output = persistent_output(opts[:output])
    module_to_path = invert(file_to_module)
    ensure_cover_started()

    sandbox_test_paths =
      test_files ++
        Enum.map(test_paths, fn path ->
          if File.dir?(path),
            do: Path.join(path, "test_helper.exs"),
            else: Path.join(Path.dirname(path), "test_helper.exs")
        end) ++ [Path.join(project_root, "test/test_helper.exs")]

    [sandbox] =
      sandboxes =
      Sandbox.create_pool(1,
        project_root: project_root,
        test_paths: Enum.uniq(sandbox_test_paths),
        auxiliary_paths: auxiliary_paths
      )

    try do
      prepare_sandbox!(sandbox, Map.keys(file_to_module))
      auxiliary_snapshot = fingerprint_auxiliary_paths(sandbox.root, auxiliary_paths)

      sandbox_test_files = Enum.map(test_files, &Path.relative_to(&1, project_root))
      coverdata = run_with_coverage!(test_files, sandbox_test_files, sandbox.root, output)

      %{
        index: merge_coverage(new(), test_files, coverdata, module_to_path),
        auxiliary_snapshot: auxiliary_snapshot
      }
    after
      Sandbox.cleanup(sandboxes)
    end
  end

  defp persistent_output(nil) do
    Path.join(
      System.tmp_dir!(),
      "muex_coverage_evidence_#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp persistent_output(output), do: Path.expand(output)

  defp prepare_sandbox!(sandbox, files) do
    case Sandbox.prepare(sandbox, files) do
      :ok ->
        :ok

      {:error, {:app_build_missing, _path}} ->
        :ok

      {:error, {:app_not_detected, _path} = reason} ->
        if File.ls!(Path.join([sandbox.root, "_build", "test", "lib"])) == [],
          do: :ok,
          else: raise("coverage sandbox preparation failed: #{inspect(reason)}")

      {:error, reason} ->
        raise "coverage sandbox preparation failed: #{inspect(reason)}"
    end
  end

  defp invert(file_to_module) do
    for {path, modules} <- file_to_module,
        module <- List.wrap(modules),
        not is_nil(module),
        into: %{},
        do: {module, path}
  end

  defp ensure_cover_started do
    case :cover.start() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp run_with_coverage!(test_files, sandbox_test_files, cd, output) do
    name =
      "muex_cov_" <>
        (:sha256
         |> :crypto.hash(:erlang.term_to_binary(test_files))
         |> Base.encode16(case: :lower))

    runtime_output = Path.join(cd, "cover")
    runtime_temp = Path.join(cd, "tmp")
    File.mkdir_p!(runtime_temp)
    File.mkdir_p!(runtime_output)
    File.mkdir_p!(output)

    {command_output, code} =
      System.cmd(
        "mix",
        ["test" | sandbox_test_files] ++ ["--no-compile", "--cover", "--export-coverage", name],
        cd: cd,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_ROOT", Path.join(cd, "_build")},
          {"MIX_BUILD_PATH", nil},
          {"MIX_DEPS_PATH", nil},
          {"MUEX_COVERAGE_OUTPUT_DIR", runtime_output},
          {"TMPDIR", runtime_temp},
          {"TMP", runtime_temp},
          {"TEMP", runtime_temp}
        ],
        stderr_to_stdout: true
      )

    log = Path.join(output, "#{name}.log")

    File.write!(log, ["test_files=", Enum.join(test_files, ","), "\n", command_output], [
      :exclusive
    ])

    runtime_coverdata = Path.join(runtime_output, "#{name}.coverdata")
    coverdata = Path.join(output, "#{name}.coverdata")

    cond do
      code != 0 ->
        raise "coverage collection failed for #{Enum.join(test_files, ", ")} with exit #{code}; output: #{log}"

      not File.regular?(runtime_coverdata) ->
        raise "coverage collection failed for #{Enum.join(test_files, ", ")}: missing #{runtime_coverdata}; output: #{log}"

      true ->
        File.cp!(runtime_coverdata, coverdata)
        coverdata
    end
  end

  defp merge_coverage(index, test_files, coverdata, module_to_path) do
    :cover.reset()
    :cover.import(String.to_charlist(coverdata))

    Enum.reduce(module_to_path, index, fn {module, path}, idx ->
      case :cover.analyse(module, :calls, :line) do
        {:ok, line_analysis} -> merge_module(idx, path, line_analysis, test_files)
        _ -> idx
      end
    end)
  end

  # Register every executable line of the module (so an uncovered line reads as
  # :no_coverage, not :unknown), and conservatively attribute covered lines to
  # every test file in the partition batch.
  # `:cover` sometimes reports line 0 for module-level entries; those are not
  # real lines, so they are skipped (and read back as :unknown).
  defp merge_module(index, path, line_analysis, test_files) do
    Enum.reduce(line_analysis, index, fn {{_module, line}, calls}, idx ->
      cond do
        line < 1 ->
          idx

        calls > 0 ->
          Enum.reduce(test_files, put_executable(idx, path, line), &put(&2, path, line, &1))

        true ->
          put_executable(idx, path, line)
      end
    end)
  end
end
