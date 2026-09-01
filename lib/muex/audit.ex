defmodule Muex.Audit do
  @moduledoc false

  alias Muex.Compiler
  alias Muex.Continuation.Artifact
  alias Muex.Reporter.Patch

  @inspect_limit 1_000

  @doc false
  def generation_decisions(candidates, files, language) do
    entries = Map.new(files, &{&1.path, &1})

    original_sources =
      Map.new(files, fn file ->
        {file.path, preserve_line_endings(render_original(file, language), file.original_source)}
      end)

    Map.new(candidates, fn mutation ->
      file = Map.fetch!(entries, mutation.location.file)
      original_source = Map.fetch!(original_sources, mutation.location.file)
      {mutation.id, generation_decision(mutation, file, language, original_source)}
    end)
  end

  def write_plan(
        nil,
        _candidates,
        _generation_decisions,
        _selected,
        _selection_reasons,
        _sources,
        _config
      ),
      do: :ok

  def write_plan(
        directory,
        candidates,
        generation_decisions,
        selected,
        selection_reasons,
        sources,
        config
      ) do
    plan =
      build_plan(candidates, generation_decisions, selected, selection_reasons, sources, config)

    with :ok <- safe_audit_path(directory),
         :ok <- File.mkdir_p(directory),
         :ok <- safe_audit_path(directory) do
      atomic_json(Path.join(directory, "plan.json"), plan)
    end
  end

  @doc false
  def write_plan_file(
        path,
        candidates,
        generation_decisions,
        selected,
        selection_reasons,
        sources,
        config
      ) do
    plan =
      build_plan(candidates, generation_decisions, selected, selection_reasons, sources, config)

    with :ok <- safe_audit_path(path) do
      Artifact.publish_json(path, plan)
    end
  end

  defp build_plan(
         candidates,
         generation_decisions,
         selected,
         selection_reasons,
         {files, source_files, source_selections},
         config
       ) do
    selected_ids = MapSet.new(selected, & &1.id)
    entries = Map.new(files, &{&1.path, &1})

    source_file_entries =
      Enum.map(source_files, fn file ->
        source_selections
        |> Map.fetch!(file.path)
        |> Map.put(:path, file.path)
      end)

    selected_source_file_count = Enum.count(source_file_entries, & &1.selected)

    mutants =
      Enum.map(candidates, fn mutation ->
        file = Map.fetch!(entries, mutation.location.file)

        entry = %{
          id: mutation.id,
          selected: MapSet.member?(selected_ids, mutation.id),
          selection_reason: Map.fetch!(selection_reasons, mutation.id),
          mutator: inspect(mutation.mutator),
          description: mutation.description,
          location: mutation.location,
          target_ordinal: mutation.target_ordinal,
          patch: Patch.of(mutation),
          original_source: file.original_source,
          original_sha256: digest(file.original_source)
        }

        case Map.fetch!(generation_decisions, mutation.id) do
          {:ok, mutated_source} ->
            entry
            |> Map.put(:mutated_source, mutated_source)
            |> Map.put(:mutated_sha256, digest(mutated_source))

          {:excluded, :identical_source, mutated_source} ->
            entry
            |> Map.put(:mutated_source, mutated_source)
            |> Map.put(:mutated_sha256, digest(mutated_source))
            |> Map.put(:generation_exclusion, %{
              reason: "identical_source",
              rendered_sha256: digest(mutated_source)
            })

          {:error, generation_error} ->
            Map.put(entry, :generation_error, generation_error)
        end
      end)

    %{
      version: 1,
      optimizer: %{
        enabled: config.optimize,
        level: config.optimize_level,
        heuristic_equivalence: false,
        tce: false,
        max_mutations: config.max_mutations
      },
      exhaustive:
        selected_source_file_count == length(source_files) and
          length(candidates) == length(selected),
      source_file_count: length(source_files),
      selected_source_file_count: selected_source_file_count,
      source_files: source_file_entries,
      candidate_count: length(candidates),
      selected_count: length(selected),
      mutants: mutants
    }
  end

  def append_event(nil, _mutant_id, _event), do: :ok

  def append_event(directory, mutant_id, event) do
    path = Path.join([directory, "events", "#{mutant_id}.jsonl"])

    with :ok <- safe_audit_path(path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- safe_audit_path(path) do
      case File.open(path, [:append, :binary, :sync], fn file ->
             row = Map.put(event, :recorded_at, DateTime.to_iso8601(DateTime.utc_now()))
             binwrite(file, Jason.encode!(row) <> "\n")
           end) do
        {:ok, :ok} -> :ok
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, _reason} = error -> error
      end
    end
  end

  defp atomic_json(path, value) do
    temporary = "#{path}.tmp-#{System.unique_integer([:positive, :monotonic])}"

    try do
      with :ok <- safe_audit_path(path),
           :ok <-
             File.write(temporary, Jason.encode!(value, pretty: true), [
               :binary,
               :sync,
               :exclusive
             ]),
           :ok <- safe_audit_path(path) do
        File.rename(temporary, path)
      end
    after
      File.rm(temporary)
    end
  end

  defp safe_audit_path(path) do
    unsafe =
      path
      |> path_and_parents()
      |> Enum.find(fn component ->
        match?({:ok, %File.Stat{type: :symlink}}, File.lstat(component))
      end)

    if unsafe, do: {:error, {:unsafe_audit_path, path}}, else: :ok
  end

  defp path_and_parents(path) do
    Stream.unfold(Path.expand(path), fn current ->
      parent = Path.dirname(current)
      if parent == current, do: nil, else: {current, parent}
    end)
  end

  defp generation_decision(mutation, file, language, original_source) do
    with {:ok, mutated_source} <- Compiler.compile_to_source(mutation, file, language),
         mutated_source = preserve_line_endings(mutated_source, file.original_source),
         {:ok, original_source} <- original_source do
      if mutated_source == original_source,
        do: {:excluded, :identical_source, mutated_source},
        else: {:ok, mutated_source}
    else
      result -> normalize_generation_result(result)
    end
  rescue
    error -> normalize_generation_result({:error, error})
  catch
    kind, reason -> normalize_generation_result({:error, {kind, reason}})
  end

  @doc false
  def preserve_line_endings({:ok, source}, reference),
    do: {:ok, preserve_line_endings(source, reference)}

  def preserve_line_endings({:error, _reason} = error, _reference), do: error

  def preserve_line_endings(source, reference) do
    ending =
      case Regex.run(~r/(?:\r?\n)+\z/, reference) do
        [line_endings] -> line_endings
        nil -> ""
      end

    Regex.replace(~r/(?:\r?\n)+\z/, source, "") <> ending
  end

  defp render_original(file, language) do
    language.unparse(file.ast)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_generation_result(result) do
    reason = if match?({:error, _reason}, result), do: elem(result, 1), else: result

    {:error,
     %{
       tag: "error",
       reason: "mutation_source_generation_failed",
       type: error_type(reason),
       message: error_message(reason),
       inspect: limited_inspect(result)
     }}
  end

  defp error_type(%{__exception__: true, __struct__: module}),
    do: module |> Module.split() |> List.last()

  defp error_type(value) when is_atom(value), do: "atom"
  defp error_type(value) when is_binary(value), do: "string"
  defp error_type(value) when is_tuple(value), do: "tuple"
  defp error_type(value) when is_list(value), do: "list"
  defp error_type(value) when is_map(value), do: "map"
  defp error_type(_value), do: "term"

  defp error_message(%{__exception__: true} = error), do: Exception.message(error)
  defp error_message(reason), do: limited_inspect(reason)

  defp limited_inspect(value) do
    value
    |> inspect(limit: 20, printable_limit: 500, width: 80)
    |> String.slice(0, @inspect_limit)
  end

  defp binwrite(file, data) do
    IO.binwrite(file, data)
  rescue
    error in ErlangError -> {:error, error.original}
  end

  defp digest(value) do
    :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
  end
end
