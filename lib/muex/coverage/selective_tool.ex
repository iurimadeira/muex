defmodule Muex.Coverage.SelectiveTool do
  @moduledoc """
  Mix coverage tool that instruments only the campaign's selected modules.

  The module manifest is generated from an already compiled application build.
  Ordinary `mix test --cover` runs do not select this tool.

  A campaign selects it from the project under test:

      test_coverage: [tool: Muex.Coverage.SelectiveTool]

  and points `MUEX_COVERAGE_MODULES_FILE` at a manifest written by
  `write_manifest!/4` (or by `mix muex.coverage manifest`). The tool raises
  `Mix.Error` when that variable is unset, when the manifest is malformed or
  carries an unsupported version, and when a listed beam is missing, duplicated,
  or resolves outside the compile path. It never traverses beams the manifest
  did not list.

  `mix muex.coverage` drives this tool for a campaign; see
  `docs/CAMPAIGN_API.md`.
  """

  alias Mix.Tasks.Test.Coverage, as: MixCoverage

  @manifest_version 1

  @doc false
  def start(compile_path, opts) do
    manifest_path =
      case System.get_env("MUEX_COVERAGE_MODULES_FILE") do
        path when is_binary(path) and path != "" -> path
        _other -> Mix.raise("MUEX_COVERAGE_MODULES_FILE is required for selective coverage")
      end

    entries = read_manifest!(manifest_path, compile_path)
    Mix.shell().info("Cover compiling #{length(entries)} selected modules ...")
    Mix.ensure_application!(:tools)

    if Keyword.get(opts, :local_only, true), do: :cover.local_only()

    _ = :cover.stop()
    {:ok, _pid} = :cover.start()

    Enum.each(entries, fn %{beam: beam, module: expected_module} ->
      case :cover.compile_beam(String.to_charlist(beam)) do
        {:ok, ^expected_module} -> :ok
        {:error, reason} -> Mix.raise("failed to cover compile #{beam}: #{inspect(reason)}")
      end
    end)

    case opts[:export] do
      nil -> fn -> MixCoverage.generate_cover_results(opts) end
      name -> fn -> export_atomically!(name, opts) end
    end
  end

  @doc "Writes the selected source/module/beam manifest from an existing build."
  @spec write_manifest!(Path.t(), [Path.t()], Path.t(), Path.t()) :: :ok
  def write_manifest!(project_root, source_files, compile_path, output) do
    root = canonical_existing!(project_root, "project root")
    compile_path = canonical_existing!(compile_path, "compile path")

    sources =
      source_files
      |> Enum.map(&selected_source!(&1, root))
      |> Enum.uniq_by(& &1.canonical)
      |> Enum.sort_by(& &1.relative)

    source_by_canonical = Map.new(sources, &{&1.canonical, &1})

    entries =
      (compile_path
       |> Path.join("*.beam")
       |> Path.wildcard()
       |> Enum.flat_map(&entry_for_selected_source(&1, root, source_by_canonical))) ++
        compiler_manifest_entries(compile_path, root, source_by_canonical)

    entries =
      entries
      |> Enum.uniq_by(& &1.module)
      |> Enum.sort_by(&{&1.source, &1.module})

    validate_source_coverage!(sources, entries)
    validate_expected_modules!(sources, entries)

    write_json_atomically!(output, %{
      version: @manifest_version,
      source_files: Enum.map(sources, & &1.relative),
      modules: entries
    })
  end

  @doc """
  Reads a manifest written by `write_manifest!/4`, resolved against `compile_path`.

  Returns one entry per selected module as `%{source: relative path, module: atom,
  beam: path}`. Raises `Mix.Error` on a malformed or unsupported manifest, on a
  duplicate module, and on a beam that is missing or outside `compile_path`.
  """
  @spec read_manifest!(Path.t(), Path.t()) :: [
          %{source: String.t(), module: module(), beam: Path.t()}
        ]
  def read_manifest!(manifest_path, compile_path) do
    manifest_path = canonical_regular_file!(manifest_path, "selective coverage manifest")
    compile_path = canonical_existing!(compile_path, "compile path")

    modules = manifest_path |> decode_manifest!() |> manifest_modules!()

    entries = Enum.map(modules, &validated_entry!(&1, compile_path))

    ensure_unique_modules!(entries)

    entries
  end

  defp decode_manifest!(manifest_path) do
    case manifest_path |> File.read!() |> Jason.decode() do
      {:ok, value} -> value
      {:error, _reason} -> Mix.raise("invalid selective coverage manifest: malformed JSON")
    end
  end

  defp manifest_modules!(%{
         "version" => @manifest_version,
         "source_files" => sources,
         "modules" => modules
       })
       when is_list(sources) and is_list(modules) and modules != [] do
    if Enum.all?(sources, &(is_binary(&1) and &1 != "")),
      do: modules,
      else: Mix.raise("invalid selective coverage manifest: malformed source_files")
  end

  defp manifest_modules!(_manifest) do
    Mix.raise("invalid selective coverage manifest: unsupported version or shape")
  end

  defp ensure_unique_modules!(entries) do
    if length(entries) != entries |> Enum.map(& &1.module) |> Enum.uniq() |> length() do
      Mix.raise("invalid selective coverage manifest: duplicate modules")
    end
  end

  defp selected_source!(source, root) when is_binary(source) do
    expanded = Path.expand(source, root)
    canonical = canonical_regular_file!(expanded, "selected source")

    if !within?(canonical, root) do
      Mix.raise("selected coverage source is outside project root: #{source}")
    end

    %{canonical: canonical, relative: Path.relative_to(canonical, root)}
  end

  defp selected_source!(_source, _root), do: Mix.raise("selected coverage source must be a path")

  defp entry_for_selected_source(beam, root, source_by_canonical) do
    with {:ok, module, source} <- beam_metadata(beam),
         expanded_source = Path.expand(source, root),
         {:ok, canonical_source} <- canonical_path(expanded_source),
         %{relative: relative} <- source_by_canonical[canonical_source] do
      [%{source: relative, module: Atom.to_string(module), beam: Path.basename(beam)}]
    else
      _other -> []
    end
  end

  defp beam_metadata(beam) do
    case :beam_lib.chunks(String.to_charlist(beam), [:compile_info]) do
      {:ok, {module, [compile_info: compile_info]}} when is_atom(module) ->
        case Keyword.get(compile_info, :source) do
          source when is_list(source) -> {:ok, module, List.to_string(source)}
          source when is_binary(source) -> {:ok, module, source}
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp compiler_manifest_entries(compile_path, root, source_by_canonical) do
    manifest = Path.join([Path.dirname(compile_path), ".mix", "compile.elixir"])
    {modules, _sources} = Mix.Compilers.Elixir.read_manifest(manifest)

    Enum.flat_map(modules, &compiler_module_entry(&1, compile_path, root, source_by_canonical))
  end

  defp compiler_module_entry(
         {module, {:module, _kind, module_sources, _digest, _recompile?, _timestamp}},
         compile_path,
         root,
         source_by_canonical
       )
       when is_atom(module) and is_list(module_sources) do
    module_sources
    |> selected_compiler_source(root, source_by_canonical)
    |> build_compiler_entry(module, compile_path)
  end

  defp compiler_module_entry(_module, _compile_path, _root, _source_by_canonical), do: []

  defp build_compiler_entry(nil, _module, _compile_path), do: []

  defp build_compiler_entry(relative, module, compile_path) do
    beam_name = Atom.to_string(module) <> ".beam"

    if !File.regular?(Path.join(compile_path, beam_name)) do
      Mix.raise("expected coverage module has no beam: #{inspect(module)}")
    end

    [%{source: relative, module: Atom.to_string(module), beam: beam_name}]
  end

  defp selected_compiler_source(module_sources, root, source_by_canonical) do
    Enum.find_value(module_sources, fn source ->
      with source when is_binary(source) <- source,
           {:ok, canonical} <- source |> Path.expand(root) |> canonical_path(),
           %{relative: relative} <- source_by_canonical[canonical] do
        relative
      else
        _other -> nil
      end
    end)
  end

  defp validate_source_coverage!(sources, entries) do
    covered = MapSet.new(entries, & &1.source)

    case Enum.find(sources, &(&1.relative not in covered)) do
      nil -> :ok
      source -> Mix.raise("selected source has no compiled beam: #{source.relative}")
    end
  end

  defp validate_expected_modules!(sources, entries) do
    actual_modules = MapSet.new(entries, & &1.module)

    sources
    |> Enum.map(& &1.canonical)
    |> Muex.Loader.load_all(Muex.Language.Elixir)
    |> case do
      {:ok, loaded} -> loaded
      {:error, reason} -> Mix.raise("selected coverage source loading failed: #{inspect(reason)}")
    end
    |> Enum.each(fn
      %{module_name: module} when is_atom(module) and not is_nil(module) ->
        if Atom.to_string(module) not in actual_modules do
          Mix.raise("expected coverage module has no beam: #{inspect(module)}")
        end

      %{module_name: nil} ->
        :ok
    end)
  end

  defp validated_entry!(entry, compile_path) when is_map(entry) do
    source = manifest_string!(entry, "source")
    module_name = manifest_string!(entry, "module")
    beam_name = manifest_string!(entry, "beam")
    validate_beam_name!(beam_name)
    canonical_beam = validate_beam_file!(beam_name, compile_path)
    module = beam_module!(canonical_beam)
    validate_beam_module!(module, module_name)

    %{source: source, module: module, beam: canonical_beam}
  end

  defp validated_entry!(_entry, _compile_path) do
    Mix.raise("invalid selective coverage manifest: malformed module entry")
  end

  defp validate_beam_name!(beam_name) do
    if Path.type(beam_name) != :relative or Path.basename(beam_name) != beam_name or
         Path.extname(beam_name) != ".beam" do
      Mix.raise("coverage beam is outside compile path: #{beam_name}")
    end
  end

  defp validate_beam_file!(beam_name, compile_path) do
    beam = Path.join(compile_path, beam_name)

    if !File.regular?(beam) do
      Mix.raise("missing coverage beam: #{beam_name}")
    end

    canonical_beam = canonical_regular_file!(beam, "coverage beam")

    if !within?(canonical_beam, compile_path) do
      Mix.raise("coverage beam is outside compile path: #{beam_name}")
    end

    canonical_beam
  end

  defp validate_beam_module!(module, module_name) do
    if Atom.to_string(module) != module_name do
      Mix.raise("coverage beam module mismatch: expected #{module_name}, got #{inspect(module)}")
    end
  end

  defp manifest_string!(manifest, key) do
    case manifest[key] do
      value when is_binary(value) and value != "" -> value
      _other -> Mix.raise("invalid selective coverage manifest: malformed module entry")
    end
  end

  defp beam_module!(beam) do
    case :beam_lib.info(String.to_charlist(beam)) do
      info when is_list(info) -> Keyword.fetch!(info, :module)
      _other -> Mix.raise("invalid coverage beam: #{beam}")
    end
  end

  defp export_atomically!(name, opts) when is_binary(name) do
    if Path.basename(name) != name do
      Mix.raise("coverage export name must not contain a path")
    end

    output = opts |> Keyword.get(:output, "cover") |> Path.expand()
    File.mkdir_p!(output)
    destination = Path.join(output, "#{name}.coverdata")
    temporary = "#{destination}.tmp-#{System.unique_integer([:positive, :monotonic])}"

    Mix.shell().info("\nExporting cover results ...\n")

    try do
      case :cover.export(String.to_charlist(temporary)) do
        :ok ->
          File.rename!(temporary, destination)
          Mix.shell().info("Run \"mix test.coverage\" once all exports complete")

        {:error, reason} ->
          Mix.raise("coverage export failed: #{inspect(reason)}")
      end
    after
      if File.exists?(temporary), do: File.rm!(temporary)
    end
  end

  defp export_atomically!(_name, _opts), do: Mix.raise("coverage export name must be a string")

  defp write_json_atomically!(path, value) do
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))
    temporary = "#{path}.tmp-#{System.unique_integer([:positive, :monotonic])}"

    try do
      File.write!(temporary, Jason.encode!(value), [:exclusive])
      File.rename!(temporary, path)
    after
      if File.exists?(temporary), do: File.rm!(temporary)
    end

    :ok
  end

  defp canonical_regular_file!(path, label) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> canonical_existing!(path, label)
      _other -> Mix.raise("#{label} is not a regular file: #{path}")
    end
  end

  defp canonical_existing!(path, label) do
    case canonical_path(path) do
      {:ok, canonical} -> canonical
      :error -> Mix.raise("#{label} does not exist: #{path}")
    end
  end

  defp canonical_path(path) do
    case System.cmd("realpath", ["-e", "--", Path.expand(path)], stderr_to_stdout: true) do
      {canonical, 0} -> {:ok, String.trim(canonical)}
      {_output, _status} -> :error
    end
  end

  defp within?(path, parent), do: path == parent or String.starts_with?(path, parent <> "/")
end
