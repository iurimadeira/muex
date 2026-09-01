defmodule Muex do
  @moduledoc """
  Muex - Mutation testing library for Elixir, Erlang, and other languages.

  Muex provides a language-agnostic mutation testing framework with dependency
  injection for language adapters, making it easy to extend support to new languages.

  ## Architecture

  - `Muex.Language` - Behaviour for language adapters (parse, unparse, compile)
  - `Muex.Mutator` - Behaviour for mutation strategies
  - `Muex.Loader` - Discovers and loads source files
  - `Muex.Compiler` - Compiles mutated code and manages hot-swapping
  - `Muex.Runner` - Executes tests against mutants
  - `Muex.Reporter` - Reports mutation testing results

  ## Usage

  Run mutation testing via Mix task:

      mix muex

  With options:

      mix muex --files "lib/**/*.ex" --mutators arithmetic,comparison --fail-at 80

  ## Creating a Language Adapter

  To add support for a new language, implement the `Muex.Language` behaviour:

      defmodule Muex.Language.MyLanguage do
        @behaviour Muex.Language

        @impl true
        def parse(source), do: {:ok, parse_to_ast(source)}

        @impl true
        def unparse(ast), do: {:ok, ast_to_string(ast)}

        @impl true
        def compile(source, module_name), do: {:ok, compiled_module}

        @impl true
        def file_extensions, do: [".mylang"]

        @impl true
        def test_file_pattern, do: ~r/_test\.mylang$/
      end

  ## Creating a Mutator

  To add a new mutation strategy, implement the `Muex.Mutator` behaviour:

      defmodule Muex.Mutator.MyMutator do
        @behaviour Muex.Mutator

        @impl true
        def mutate(ast, context) do
          # Return list of mutations
          []
        end

        @impl true
        def name, do: "MyMutator"

        @impl true
        def description, do: "Custom mutation strategy"
      end
  """

  alias Muex.Reporter.Html, as: HtmlReporter
  alias Muex.Reporter.Json, as: JsonReporter
  alias Muex.Reporter.Patch

  @doc """
  Executes the full mutation testing pipeline from a `%Muex.Config{}`.

  Returns `{:ok, %{results: results, score: mutation_score}}` on success
  or `{:error, reason}` on failure. Never calls `Mix.raise` or `System.halt`;
  the caller decides how to handle the outcome.
  """
  @spec run(Muex.Config.t()) :: {:ok, map()} | {:error, term()}
  def run(%Muex.Config{} = config) do
    log("Loading files from #{Enum.join(config.files, ", ")}...", config.verbose)

    case Muex.Loader.load_all(config.files, config.language) do
      {:ok, []} when config.internal.audit_only ->
        do_run(config, [])

      {:ok, []} ->
        {:ok, %{results: [], score_low: 0.0, score_high: 0.0}}

      {:ok, [_ | _] = all_files} ->
        # Normalize file paths to be relative to the project root so that
        # downstream code (sandbox, PortRunner) can join them correctly.
        all_files = relativize_file_entries(all_files, config.project_root)
        log("Found #{length(all_files)} file(s)", config.verbose)
        do_run(config, all_files)
    end
  end

  @doc false
  def assign_mutation_ids(mutations) do
    {tagged, _counts} =
      Enum.map_reduce(mutations, %{}, fn mutation, counts ->
        patch = Patch.of(mutation)
        identity = mutation_identity(mutation, patch)
        ordinal = Map.get(counts, identity, 0)
        id = mutation_id(identity, ordinal)
        mutation = mutation |> Map.put(:id, id) |> Map.put(:target_ordinal, ordinal)
        {mutation, Map.put(counts, identity, ordinal + 1)}
      end)

    tagged
  end

  @doc false
  def mutation_id(mutator, description, file, line, patch, ordinal) do
    mutation_id({mutator, description, file, line, canonical_patch(patch)}, ordinal)
  end

  defp mutation_id(identity, ordinal), do: digest({"muex-stable-id-v1", identity, ordinal})

  defp mutation_identity(mutation, patch) do
    {
      inspect(mutation.mutator),
      mutation.description,
      mutation.location.file,
      mutation.location.line,
      canonical_patch(patch)
    }
  end

  defp canonical_patch(%{before: before, after: after_source}), do: {before, after_source}
  defp canonical_patch(%{"before" => before, "after" => after_source}), do: {before, after_source}

  defp do_run(config, all_files) do
    case resolve_changed(config) do
      {:error, reason} ->
        {:error, reason}

      {:ok, changed} ->
        scoped_files = scope_to_changed_files(all_files, changed)
        {files, filter_selections} = maybe_filter(scoped_files, config)

        source_selections =
          Map.merge(changed_scope_selections(all_files, scoped_files), filter_selections)

        input_fingerprint =
          inventory_fingerprint(config, all_files, files, source_selections, changed)

        inventory_state =
          if config.internal.audit_only do
            :disabled
          else
            Muex.InventoryCache.load(
              config.internal.inventory_cache_file,
              config.internal.inventory_cache_key,
              input_fingerprint,
              config.audit_dir
            )
          end

        case inventory_state do
          {:ok, all_mutations, provenance} ->
            log(
              "Mutation inventory cache hit: #{length(all_mutations)} mutation(s)",
              config.verbose
            )

            with :ok <- validate_cached_mutation_files(all_mutations, files),
                 :ok <- Muex.InventoryCache.write_provenance(config.audit_dir, provenance) do
              run_selected_mutations(config, files, all_mutations)
            end

          cache_state when cache_state in [:disabled, :miss] ->
            generate_and_run(
              config,
              all_files,
              files,
              source_selections,
              changed,
              input_fingerprint,
              cache_state
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp generate_and_run(
         config,
         all_files,
         files,
         source_selections,
         changed,
         input_fingerprint,
         cache_state
       ) do
    log("Generating mutations...", config.verbose)

    generated =
      files
      |> Enum.flat_map(fn file ->
        context = %{file: file.path, skip_calls: config.skip_calls}
        Muex.Mutator.walk(file.ast, config.mutators, context)
      end)
      |> assign_mutation_ids()

    generation_decisions = Muex.Audit.generation_decisions(generated, files, config.language)

    generation_candidates =
      Enum.filter(generated, &match?({:ok, _source}, Map.fetch!(generation_decisions, &1.id)))

    generation_reasons =
      generated
      |> Enum.reject(&match?({:ok, _source}, Map.fetch!(generation_decisions, &1.id)))
      |> Map.new(fn mutation ->
        reason =
          case Map.fetch!(generation_decisions, mutation.id) do
            {:excluded, :identical_source, _source} -> "excluded_identical_source"
            {:error, _error} -> "excluded_generation_error"
          end

        {mutation.id, reason}
      end)

    # Heuristic equivalence has produced false positives in real campaigns.
    # Only byte-identical rendered source is excluded during generation.
    {candidates, preselection_reasons} =
      preselect_mutations(generation_candidates, changed, config)

    preselection_reasons = Map.merge(generation_reasons, preselection_reasons)

    with {:ok, all_mutations, optimizer_reasons} <- select_mutations(candidates, config),
         selection_reasons = Map.merge(preselection_reasons, optimizer_reasons),
         :ok <-
           write_audit_plan(
             config,
             generated,
             generation_decisions,
             all_mutations,
             selection_reasons,
             {files, all_files, source_selections}
           ),
         :ok <- maybe_publish_inventory(config, input_fingerprint, all_mutations, cache_state) do
      if config.internal.audit_only do
        {:ok,
         %{
           audit_only: true,
           audit_plan: config.internal.audit_plan,
           selected_count: length(all_mutations)
         }}
      else
        run_selected_mutations(config, files, all_mutations)
      end
    end
  end

  defp write_audit_plan(
         %Muex.Config{internal: %{audit_only: true, audit_plan: path}} = config,
         candidates,
         generation_decisions,
         selected,
         selection_reasons,
         sources
       ) do
    Muex.Audit.write_plan_file(
      path,
      candidates,
      generation_decisions,
      selected,
      selection_reasons,
      sources,
      config
    )
  end

  defp write_audit_plan(
         config,
         candidates,
         generation_decisions,
         selected,
         selection_reasons,
         sources
       ) do
    Muex.Audit.write_plan(
      config.audit_dir,
      candidates,
      generation_decisions,
      selected,
      selection_reasons,
      sources,
      config
    )
  end

  defp maybe_publish_inventory(_config, _input_fingerprint, _mutations, :disabled), do: :ok

  defp maybe_publish_inventory(config, input_fingerprint, mutations, :miss) do
    plan_path = Path.join(config.audit_dir, "plan.json")

    with {:ok, provenance} <-
           Muex.InventoryCache.publish(
             config.internal.inventory_cache_file,
             config.internal.inventory_cache_key,
             input_fingerprint,
             mutations,
             plan_path
           ) do
      Muex.InventoryCache.write_provenance(config.audit_dir, provenance)
    end
  end

  defp run_selected_mutations(config, files, []) do
    metadata =
      checkpoint_metadata(
        config,
        files,
        absolutize_paths(config.test_paths, config.project_root)
      )

    use_checkpoint(
      Muex.Checkpoint.open(config.internal.checkpoint, metadata, []),
      fn _checkpoint ->
        with :ok <- output_report([], config) do
          {:ok, %{results: [], score_low: 0.0, score_high: 0.0}}
        end
      end
    )
  end

  defp run_selected_mutations(config, files, all_mutations),
    do: run_mutations(config, files, all_mutations)

  defp validate_cached_mutation_files(mutations, files) do
    files = MapSet.new(files, & &1.path)

    case Enum.find(mutations, &(not MapSet.member?(files, &1.location.file))) do
      nil ->
        :ok

      mutation ->
        {:error,
         "mutation inventory cache references unselected source file: #{mutation.location.file}"}
    end
  end

  defp inventory_fingerprint(config, all_files, files, source_selections, changed) do
    config_term =
      Map.take(config, [
        :language,
        :mutators,
        :min_score,
        :max_mutations,
        :filter,
        :optimize,
        :optimize_level,
        :min_complexity,
        :max_per_function,
        :keep_metadata,
        :preset,
        :mutant_id,
        :skip_calls
      ])

    sources = Enum.map(all_files, &{&1.path, digest(&1.original_source)})
    selected_files = Enum.map(files, & &1.path)
    selections = Enum.sort(source_selections)

    changed =
      if is_nil(changed) do
        nil
      else
        changed
        |> Enum.map(fn {path, lines} -> {path, lines |> Enum.to_list() |> Enum.sort()} end)
        |> Enum.sort()
      end

    digest({
      "mutation-inventory-v1",
      config_term,
      sources,
      selected_files,
      selections,
      changed,
      Application.spec(:muex, :vsn),
      Muex.module_info(:md5),
      Muex.Audit.module_info(:md5),
      Muex.MutantOptimizer.module_info(:md5),
      Enum.map(config.mutators, &{&1, &1.module_info(:md5)})
    })
  end

  defp select_mutations(candidates, %Muex.Config{mutant_id: id}) when is_binary(id) do
    case Enum.filter(candidates, &(&1.id == id)) do
      [] ->
        {:error, "unknown mutant id: #{id}"}

      mutations ->
        selected_ids = MapSet.new(mutations, & &1.id)

        reasons =
          Map.new(candidates, fn mutation ->
            reason =
              if MapSet.member?(selected_ids, mutation.id),
                do: "selected_by_mutant_id",
                else: "not_selected_by_mutant_id"

            {mutation.id, reason}
          end)

        {:ok, mutations, reasons}
    end
  end

  defp select_mutations(candidates, %Muex.Config{mutant_ids_file: path}) when is_binary(path),
    do: select_mutations_by_ids(candidates, path)

  defp select_mutations(candidates, config) do
    {optimized, optimizer_reasons} = optimize_with_reasons(candidates, config)
    selected = maybe_cap(optimized, config)
    optimized_ids = MapSet.new(optimized, & &1.id)
    selected_ids = MapSet.new(selected, & &1.id)

    reasons =
      Map.new(candidates, fn mutation ->
        reason =
          cond do
            MapSet.member?(selected_ids, mutation.id) ->
              Map.fetch!(optimizer_reasons, mutation.id)

            MapSet.member?(optimized_ids, mutation.id) ->
              "excluded_by_max_mutations"

            true ->
              Map.fetch!(optimizer_reasons, mutation.id)
          end

        {mutation.id, reason}
      end)

    {:ok, selected, reasons}
  end

  @doc false
  def select_mutations_by_ids(candidates, path) do
    case File.read(path) do
      {:ok, contents} ->
        ids = String.split(contents, "\n", trim: true)
        unique_ids = MapSet.new(ids)
        candidate_ids = MapSet.new(candidates, & &1.id)
        missing = unique_ids |> MapSet.difference(candidate_ids) |> Enum.sort()

        cond do
          MapSet.size(unique_ids) != length(ids) ->
            {:error, "mutant ids file contains duplicate ids"}

          missing != [] ->
            {:error, "unknown mutant ids: #{Enum.join(missing, ", ")}"}

          true ->
            selected = Enum.filter(candidates, &MapSet.member?(unique_ids, &1.id))

            reasons =
              Map.new(candidates, fn mutation ->
                reason =
                  if MapSet.member?(unique_ids, mutation.id),
                    do: "selected_by_mutant_ids_file",
                    else: "not_selected_by_mutant_ids_file"

                {mutation.id, reason}
              end)

            {:ok, selected, reasons}
        end

      {:error, reason} ->
        {:error, "cannot read mutant ids file: #{:file.format_error(reason)}"}
    end
  end

  # `nil` means no --since: run over everything. Otherwise resolve the diff
  # against the given ref once, up front.
  defp resolve_changed(%Muex.Config{internal: %{changed_diff_file: path}}) when is_binary(path) do
    case File.read(path) do
      {:ok, diff} ->
        {:ok, Muex.GitDiff.changed_lines(diff)}

      {:error, reason} ->
        {:error, "cannot read pinned changed-lines diff #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp resolve_changed(%Muex.Config{since: nil}), do: {:ok, nil}

  defp resolve_changed(%Muex.Config{since: ref} = config) do
    case Muex.GitDiff.changed_since(ref, cd: config.project_root) do
      {:ok, changed} ->
        log("Scoping to #{map_size(changed)} file(s) changed since #{ref}", config.verbose)
        {:ok, changed}

      {:error, reason} ->
        {:error, "git diff against #{ref} failed: #{reason}"}
    end
  end

  # Restrict the file set to those touched by the --since diff (nil = no scoping).
  defp scope_to_changed_files(files, nil), do: files

  defp scope_to_changed_files(files, changed),
    do: Enum.filter(files, &Map.has_key?(changed, &1.path))

  defp changed_scope_selections(all_files, scoped_files) do
    scoped_paths = MapSet.new(scoped_files, & &1.path)

    all_files
    |> Enum.reject(&MapSet.member?(scoped_paths, &1.path))
    |> Map.new(fn file ->
      {file.path, %{selected: false, selection_reason: "excluded_outside_changed_files"}}
    end)
  end

  defp maybe_filter(files, %Muex.Config{filter: false} = config) do
    log("Skipping file filtering", config.verbose)

    selections =
      Map.new(files, fn file ->
        {file.path, %{selected: true, selection_reason: "selected_without_file_filter"}}
      end)

    {files, selections}
  end

  defp maybe_filter(files, %Muex.Config{filter: true} = config) do
    log("Analyzing files for mutation testing suitability...", config.verbose)

    {included, excluded, selections} =
      Muex.FileAnalyzer.filter_files_with_reasons(files,
        min_score: config.min_score,
        verbose: config.verbose
      )

    log(
      "Selected #{length(included)} file(s), skipped #{length(excluded)} file(s)",
      config.verbose
    )

    {included, selections}
  end

  # Drop mutations with no usable source location (line: 0). These are
  # typically compile-time metadata or macro-generated nodes that produce
  # invalid mutants and clutter reports. Opt out with --keep-metadata-mutations.
  defp maybe_drop_unlocatable(mutations, %Muex.Config{keep_metadata: true}), do: mutations

  defp maybe_drop_unlocatable(mutations, %Muex.Config{verbose: verbose}) do
    {located, unlocated} = Enum.split_with(mutations, &locatable?/1)

    if verbose and unlocated != [] do
      log("Dropping #{length(unlocated)} mutation(s) with no source location (line: 0)", true)
    end

    located
  end

  @doc false
  def preselect_mutations(mutations, changed, config) do
    eligible = maybe_drop_unlocatable(mutations, config)
    located_ids = ids(eligible)
    eligible = Muex.GitDiff.filter_mutations(eligible, changed)
    changed_ids = ids(eligible)

    reasons =
      mutations
      |> Enum.reject(&MapSet.member?(changed_ids, &1.id))
      |> Map.new(fn mutation ->
        reason =
          if MapSet.member?(located_ids, mutation.id),
            do: "excluded_outside_changed_lines",
            else: "excluded_unlocatable"

        {mutation.id, reason}
      end)

    {eligible, reasons}
  end

  defp locatable?(mutation) do
    case get_in(mutation, [:location, :line]) do
      line when is_integer(line) and line > 0 -> true
      _ -> false
    end
  end

  defp optimize_with_reasons(mutations, %Muex.Config{optimize: false}) do
    {mutations, Map.new(mutations, &{&1.id, "selected_without_optimizer"})}
  end

  defp optimize_with_reasons(mutations, %Muex.Config{optimize: true} = config) do
    opts = Muex.Config.optimizer_opts(config)
    stages = Muex.MutantOptimizer.optimization_stages(mutations, opts)
    complexity_ids = ids(stages.complexity)
    limited_ids = ids(stages.limited)

    reasons =
      Map.new(mutations, fn mutation ->
        reason =
          cond do
            not MapSet.member?(complexity_ids, mutation.id) -> "excluded_by_min_complexity"
            not MapSet.member?(limited_ids, mutation.id) -> "excluded_by_function_limit"
            true -> "selected_by_#{config.optimize_level}_optimizer"
          end

        {mutation.id, reason}
      end)

    {stages.prioritized, reasons}
  end

  defp ids(mutations), do: MapSet.new(mutations, & &1.id)

  defp maybe_cap(mutations, %Muex.Config{max_mutations: max})
       when max > 0 and length(mutations) > max do
    Enum.take(mutations, max)
  end

  defp maybe_cap(mutations, _config), do: mutations

  # With coverage guidance, build the line->tests index up front by running each
  # test file under coverage. Returns nil when disabled (the worker then runs
  # the full declared non-eval test corpus).
  defp maybe_collect_coverage(%Muex.Config{coverage_guided: false}, _test_paths, _file_to_module),
    do: nil

  defp maybe_collect_coverage(
         %Muex.Config{coverage_guided: true, internal: %{coverage_index_file: path}} = config,
         test_paths,
         file_to_module
       )
       when is_binary(path) do
    project_root = config.project_root
    test_files = Muex.Config.expand_test_paths(test_paths)

    expected =
      config.internal.coverage_corpus_fingerprint ||
        Muex.Coverage.corpus_fingerprint(
          project_root,
          Map.keys(file_to_module),
          test_files,
          System.get_env("MUEX_COVERAGE_MODULES_FILE")
        )

    case Muex.Coverage.read_bound_index(path, expected) do
      {:ok, index} -> index
      :stale -> nil
    end
  end

  defp maybe_collect_coverage(
         %Muex.Config{coverage_guided: true} = config,
         test_paths,
         file_to_module
       ) do
    test_files = Muex.Config.expand_test_paths(test_paths)
    log("Collecting coverage from #{length(test_files)} test file(s)...", config.verbose)

    output = if config.audit_dir, do: Path.join(config.audit_dir, "coverage")

    Muex.Coverage.collect(test_files, file_to_module,
      cd: config.project_root,
      test_paths: test_paths,
      output: output
    )
  end

  defp run_mutations(config, files, all_mutations) do
    log("Testing #{length(all_mutations)} mutation(s)", config.verbose)

    # Make test paths absolute so coverage collection and the worker pool can
    # find files on disk regardless of CWD. Config stores them as-is (relative
    # or absolute) — we absolutize here, once.
    abs_test_paths = absolutize_paths(config.test_paths, config.project_root)

    file_entries = Map.new(files, fn file -> {file.path, file} end)
    file_to_module = Map.new(files, fn file -> {file.path, file.module_name} end)

    coverage_index = maybe_collect_coverage(config, abs_test_paths, file_to_module)

    log(
      "Running tests...
",
      config.verbose
    )

    metadata = checkpoint_metadata(config, files, abs_test_paths)

    use_checkpoint(
      Muex.Checkpoint.open(config.internal.checkpoint, metadata, all_mutations),
      fn checkpoint ->
        pending = Enum.reject(all_mutations, &Map.has_key?(checkpoint.completed, &1.id))

        with {:ok, new_results} <-
               Muex.Runner.run_all_result(
                 pending,
                 file_entries,
                 config.language,
                 %{},
                 file_to_module,
                 max_workers: config.concurrency,
                 timeout_ms: config.timeout_ms,
                 baseline_timeout_ms: config.baseline_timeout_ms,
                 verbose: config.verbose,
                 test_paths: abs_test_paths,
                 project_root: config.project_root,
                 tce: config.tce,
                 coverage_index: coverage_index,
                 baseline_mutations: all_mutations,
                 checkpoint: checkpoint,
                 audit_dir: config.audit_dir
               ) do
          results = merge_checkpoint_results(all_mutations, checkpoint.completed, new_results)

          case output_report(results, config) do
            {:error, _} = err -> err
            _ -> build_result(results)
          end
        end
      end
    )
  end

  @doc false
  defp use_checkpoint({:ok, checkpoint}, operation) do
    operation.(checkpoint)
  after
    :ok = Muex.Checkpoint.close(checkpoint)
  end

  defp use_checkpoint({:error, _reason} = error, _operation), do: error

  def checkpoint_metadata(config, files, test_paths) do
    source_paths = Enum.map(files, &Path.join(config.project_root, &1.path))
    expanded_test_paths = Muex.Config.expand_test_paths(test_paths)

    run_paths =
      expanded_test_paths ++
        Enum.flat_map(
          ~w(lib priv test/support config bin assets docs scripts vendor .github .githooks),
          fn relative ->
            path = Path.join(config.project_root, relative)

            cond do
              File.regular?(path) -> [path]
              File.dir?(path) -> Path.wildcard(Path.join(path, "**/*"), match_dot: true)
              true -> []
            end
          end
        ) ++
        Enum.map(~w(mix.exs mix.lock), &Path.join(config.project_root, &1))

    config_term =
      config
      |> Map.from_struct()
      |> Map.delete(:internal)
      |> Map.put(:coverage_index_file, config.internal.coverage_index_file)
      |> Map.put(:coverage_corpus_fingerprint, config.internal.coverage_corpus_fingerprint)
      |> Map.put(:inventory_cache_file, config.internal.inventory_cache_file)
      |> Map.put(:inventory_cache_key, config.internal.inventory_cache_key)
      |> Map.drop([
        :project_root,
        :report_file,
        :audit_dir,
        :fail_at,
        :format,
        :verbose
      ])
      |> Map.put(
        :coverage_index_sha256,
        coverage_index_sha256(config.internal.coverage_index_file)
      )
      |> Map.delete(:coverage_index_file)

    %{
      campaign_fingerprint: config.campaign_fingerprint,
      source: fingerprint_files(source_paths, config.project_root),
      run:
        digest({
          config_term,
          fingerprint_files(run_paths, config.project_root),
          System.version(),
          :erlang.system_info(:otp_release),
          Application.spec(:muex, :vsn),
          Muex.module_info(:md5)
        })
    }
  end

  defp coverage_index_sha256(nil), do: nil

  defp coverage_index_sha256(path) do
    :sha256
    |> :crypto.hash(File.read!(path))
    |> Base.encode16(case: :lower)
  end

  defp fingerprint_files(paths, root) do
    paths
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn path, hash ->
      relative = Path.relative_to(path, root)
      :crypto.hash_update(hash, :erlang.term_to_binary({relative, File.read!(path)}))
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp merge_checkpoint_results(mutations, completed, new_results) do
    new_by_id = Map.new(new_results, &{&1.mutation.id, &1})

    Enum.map(mutations, fn mutation ->
      case Map.fetch(new_by_id, mutation.id) do
        {:ok, result} -> result
        :error -> completed |> Map.fetch!(mutation.id) |> Map.put(:mutation, mutation)
      end
    end)
  end

  defp build_result(results) do
    killed = Enum.count(results, &(&1.result == :killed))
    survived = Enum.count(results, &(&1.result == :survived))
    timeout = Enum.count(results, &(&1.result == :timeout))

    # Invalids are excluded: they tell us nothing about test quality.
    # Timeouts are ambiguous -- they could be killed or survived.
    denom = killed + survived + timeout

    {score_low, score_high} =
      if denom > 0 do
        # Low bound (pessimistic): assume all timeouts survived
        low = Float.round(killed / denom * 100, 2)
        # High bound (optimistic): assume all timeouts were killed
        high = Float.round((killed + timeout) / denom * 100, 2)
        {low, high}
      else
        {0.0, 0.0}
      end

    {:ok, %{results: results, score_low: score_low, score_high: score_high}}
  end

  defp output_report(results, %Muex.Config{format: "json", report_file: nil}) do
    log(JsonReporter.to_json(results))
  end

  defp output_report(results, %Muex.Config{format: "json", report_file: path}) do
    JsonReporter.generate(results, output_file: path)
  end

  defp output_report(results, %Muex.Config{format: "html", verbose: verbose}) do
    HtmlReporter.generate(results)
    log("HTML report generated: muex-report.html", verbose)
  end

  defp output_report(results, %Muex.Config{format: "terminal"}) do
    Muex.Reporter.print_summary(results)
  end

  defp output_report(_results, %Muex.Config{format: other}) do
    {:error, "Unknown format: #{other}. Use terminal, json, or html"}
  end

  # Convert relative paths to absolute, anchored at `root`.
  defp absolutize_paths(paths, root) do
    Enum.map(paths, fn path ->
      case Path.type(path) do
        :absolute -> path
        _ -> Path.join(root, path)
      end
    end)
  end

  # Make all file paths relative to the project root. This is essential
  # when --path points to an external project: the Loader returns absolute
  # paths, but the sandbox expects paths relative to its project root.
  defp relativize_file_entries(files, project_root) do
    Enum.map(files, fn file ->
      relative_path =
        file.path
        |> Path.expand()
        |> Path.relative_to(project_root)

      %{file | path: relative_path}
    end)
  end

  defp log(msg, verbose \\ true) do
    if verbose do
      if Code.ensure_loaded?(Mix) and function_exported?(Mix, :shell, 0) do
        Mix.shell().info(msg)
      else
        IO.puts(msg)
      end
    end
  end

  defp digest(term) do
    :sha256 |> :crypto.hash(:erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
  end
end
