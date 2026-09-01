defmodule Muex.Config do
  @moduledoc """
  Central configuration for Muex mutation testing runs.

  Parses command-line arguments into a normalized struct consumed by the
  pipeline. Supports umbrella apps (`--app`), explicit test paths
  (`--test-paths`), and all existing flags.

  ## Compile-Time Configuration

  Custom language adapters and mutators can be registered via
  `Application.compile_env/3` in `config/config.exs` (or any imported
  config file). These maps are merged into the built-in adapters/mutators
  at compile time.

    * `:languages` - A `%{String.t() => module()}` map of additional
      language adapters. Each key is the CLI name passed to `--language`
      and the value is a module implementing the `Muex.Language` behaviour.

          config :muex, languages: %{"lua" => MyApp.Language.Lua}

    * `:mutators` - A `%{String.t() => module()}` map of additional
      mutators. Each key is the CLI name usable in `--mutators` and the
      value is a module implementing the `Muex.Mutator` behaviour.

          config :muex, mutators: %{"string" => MyApp.Mutator.String}

  The built-in language adapters (`"elixir"`, `"erlang"`) and mutators
  (`"arithmetic"`, `"comparison"`, `"boolean"`, `"literal"`,
  `"function_call"`, `"conditional"`) are always available. Entries in the
  compile-time maps override built-in entries with the same key.

  ## CLI Options

    * `--files` / `--path` - Source directory, file, or glob pattern (default: `"lib"`)
    * `--test-paths` - Comma-separated list of test directories, files, or glob
      patterns (default: `"test"`). Each entry is resolved independently: a
      directory is expanded to `dir/**/*_test.exs`, a glob is used as-is, and a
      regular file is taken literally.
    * `--app` - Target a single OTP application inside an umbrella project.
      Sets `--files` to `apps/<app>/lib` and `--test-paths` to
      `apps/<app>/test` unless those flags are provided explicitly.
    * `--language` - Language adapter: `elixir` or `erlang` (default: `elixir`)
    * `--mutators` - Comma-separated list of mutator names (default: all)
    * `--mutator-paths` - Comma-separated directories containing custom mutator
      modules implementing `Muex.Mutator` behaviour. Files are compiled and
      loaded at runtime.
    * `--concurrency` - Number of parallel workers (default: number of schedulers)
    * `--timeout` - Test timeout in milliseconds (default: 10000)
    * `--fail-at` - Minimum mutation score percentage to pass (default: 80)
    * `--format` - Output format: `terminal`, `json`, `html` (default: `terminal`)
    * `--min-score` - Minimum file complexity score for inclusion (default: 20)
    * `--max-mutations` - Cap total mutations tested; 0 = unlimited (default: 0)
    * `--no-filter` - Disable intelligent file filtering
    * `--verbose` - Show detailed progress information
    * `--optimize` / `--no-optimize` - Enable/disable mutation optimization (default: enabled)
    * `--tce` - Rejected because compiler-equivalence detection is not sound.
      `--no-tce` is accepted for compatibility and is always the effective mode.
    * `--since` - Only test mutations on lines changed since the given git ref
      (e.g. `--since main`), using `git diff <ref>...HEAD` (PR semantics)
    * `--coverage-guided` - Run only the tests that cover each mutated line, and
      skip mutations on lines no test exercises (default: disabled)
    * `--optimize-level` - Preset: `conservative`, `balanced`, `aggressive` (default: `balanced`)
    * `--min-complexity` - Override minimum complexity for optimizer
    * `--max-per-function` - Override maximum mutations per function for optimizer
    * `--keep-metadata-mutations` - Keep mutations that have no usable source
      location (reported at `line: 0`). These are typically compile-time
      metadata; they remain in the audit plan as `excluded_unlocatable` unless kept.
    * `--checkpoint` - Append terminal results to a resumable JSONL checkpoint
    * `--report-file` - Atomically write JSON output to this exact path
    * `--audit-dir` - Store the complete plan, append-only events, and process outputs
    * `--baseline-timeout` - Separate per-sandbox baseline timeout in milliseconds
    * `--mutant-id` - Select exactly one stable mutation ID
    * `--mutant-ids-file` - Newline-delimited file of stable mutation IDs to run;
      the shard-scoped form of `--mutant-id`
    * `--campaign-fingerprint` - Bind checkpoint evidence to an outer campaign
    * `--inventory-cache-file` / `--inventory-cache-key` - Reuse a
      campaign-owned, content-addressed mutation inventory and audited plan;
      both are required together, they require `--audit-dir`, and the key must
      be a lowercase 64-character SHA-256 digest
    * `--project-root` - Anchor for every relative path (default: derived from
      `--files`)
    * `--audit-only` / `--audit-plan` - Publish the optimized inventory to the
      given exact path without running any test or mutant
    * `--coverage-index-file` / `--coverage-corpus-fingerprint` - Consume a
      campaign-owned coverage index instead of measuring coverage in-process;
      the index requires `--coverage-guided` and the fingerprint requires the
      index
    * `--changed-diff-file` - Supply the `--since` diff as a file instead of
      shelling out to git
    * `--preset` - Framework preset that prunes noisy DSL calls: `phoenix`,
      `ecto`, `ash`, or `none` (default: `none`).

  ## Presets

  Presets reduce invalid/noisy mutations in framework-heavy modules by
  pruning known DSL macros during traversal (in addition to the always-on
  pruning of aliases, directives, docs, and keyword keys):

    * `phoenix` - component and router DSL (`attr`, `slot`, `~H`, `scope`,
      `pipeline`, `plug`, `live`, `get`/`post`/..., and similar)
    * `ecto` - schema DSL (`schema`, `field`, `belongs_to`, `has_many`, ...)
    * `ash` - resource DSL (`attributes`, `relationships`, `actions`, ...)

  When `--mutators` is not given and a preset other than `none` is selected,
  Muex focuses on function-body operators (`arithmetic`, `boolean`,
  `comparison`, `conditional`, `return_value`, `statement_deletion`) and
  omits the noisier `literal` and `function_call` mutators. Passing
  `--mutators` explicitly always overrides this default.
  """

  alias Muex.Config.Internal
  alias Muex.Language.Elixir, as: ElixirLanguage

  @type t :: %__MODULE__{
          files: [String.t()],
          test_paths: [String.t()],
          app: String.t() | nil,
          project_root: Path.t(),
          internal: Internal.t(),
          language: module(),
          mutators: [module()],
          concurrency: pos_integer(),
          timeout_ms: pos_integer(),
          fail_at: number(),
          format: String.t(),
          min_score: non_neg_integer(),
          max_mutations: non_neg_integer(),
          filter: boolean(),
          verbose: boolean(),
          optimize: boolean(),
          tce: boolean(),
          since: String.t() | nil,
          coverage_guided: boolean(),
          optimize_level: String.t(),
          min_complexity: non_neg_integer() | nil,
          max_per_function: pos_integer() | nil,
          keep_metadata: boolean(),
          preset: String.t(),
          skip_calls: [atom()],
          report_file: Path.t() | nil,
          audit_dir: Path.t() | nil,
          baseline_timeout_ms: pos_integer(),
          mutant_id: String.t() | nil,
          mutant_ids_file: Path.t() | nil,
          campaign_fingerprint: String.t() | nil
        }
  @enforce_keys [:files, :test_paths, :project_root, :internal, :language, :mutators]
  defstruct [
    :files,
    :test_paths,
    :app,
    :project_root,
    :internal,
    :language,
    :mutators,
    concurrency: 4,
    timeout_ms: 10_000,
    fail_at: 80,
    format: "terminal",
    min_score: 20,
    max_mutations: 0,
    filter: true,
    verbose: false,
    optimize: true,
    tce: false,
    since: nil,
    coverage_guided: false,
    optimize_level: "balanced",
    min_complexity: nil,
    max_per_function: nil,
    keep_metadata: false,
    preset: "none",
    skip_calls: [],
    report_file: nil,
    audit_dir: nil,
    baseline_timeout_ms: 120_000,
    mutant_id: nil,
    mutant_ids_file: nil,
    campaign_fingerprint: nil
  ]

  @option_spec files: :string,
               path: :string,
               test_paths: :string,
               app: :string,
               project_root: :string,
               language: :string,
               mutators: :string,
               mutator_paths: :string,
               concurrency: :integer,
               timeout: :integer,
               fail_at: :integer,
               format: :string,
               min_score: :integer,
               max_mutations: :integer,
               no_filter: :boolean,
               verbose: :boolean,
               optimize: :boolean,
               no_optimize: :boolean,
               tce: :boolean,
               no_tce: :boolean,
               since: :string,
               changed_diff_file: :string,
               coverage_guided: :boolean,
               coverage_index_file: :string,
               coverage_corpus_fingerprint: :string,
               optimize_level: :string,
               min_complexity: :integer,
               max_per_function: :integer,
               keep_metadata_mutations: :boolean,
               checkpoint: :string,
               report_file: :string,
               audit_dir: :string,
               audit_only: :boolean,
               audit_plan: :string,
               baseline_timeout: :integer,
               mutant_id: :string,
               mutant_ids_file: :string,
               campaign_fingerprint: :string,
               inventory_cache_file: :string,
               inventory_cache_key: :string,
               preset: :string
  @doc "Parses a list of CLI argument strings into a `%Config{}`.\n\nReturns `{:ok, config}` or `{:error, reason}`.\n"
  @spec from_args([String.t()]) :: {:ok, t()} | {:error, String.t()}
  def from_args(args) do
    case OptionParser.parse(args, strict: @option_spec) do
      {_opts, _rest, [_ | _] = invalid} ->
        {:error, "Invalid options: #{inspect(invalid)}"}

      {opts, _rest, _} ->
        from_opts(opts)
    end
  end

  @doc "Builds a `%Config{}` from a keyword list (already parsed by OptionParser or\nassembled programmatically).\n\nReturns `{:ok, config}` or `{:error, reason}`.\n"
  @spec from_opts(keyword()) :: {:ok, t()} | {:error, String.t()}
  def from_opts(opts) do
    app = Keyword.get(opts, :app)
    extra_paths = parse_mutator_paths(Keyword.get(opts, :mutator_paths))

    files = resolve_files(opts, app)
    project_root = resolve_project_root(Keyword.get(opts, :project_root), files)

    with {:ok, language} <- resolve_language(Keyword.get(opts, :language, "elixir")),
         {:ok, preset} <- validate_preset(Keyword.get(opts, :preset, "none")),
         {:ok, mutators} <-
           resolve_mutators(Keyword.get(opts, :mutators), extra_paths, language, preset),
         {:ok, optimize_level} <-
           validate_optimize_level(Keyword.get(opts, :optimize_level, "balanced")),
         :ok <- validate_positive(opts, :concurrency),
         :ok <- validate_positive(opts, :timeout),
         :ok <- validate_positive(opts, :baseline_timeout),
         :ok <- validate_coverage_index(opts),
         :ok <- validate_inventory_cache(opts),
         :ok <- validate_audit_only(opts),
         :ok <- validate_mutant_selection(opts),
         :ok <- validate_tce_disabled(opts) do
      config = %__MODULE__{
        files: files,
        test_paths: resolve_test_paths(opts, app),
        app: app,
        project_root: project_root,
        internal: %Internal{
          audit_only: Keyword.get(opts, :audit_only, false),
          audit_plan: Keyword.get(opts, :audit_plan),
          changed_diff_file: Keyword.get(opts, :changed_diff_file),
          checkpoint: Keyword.get(opts, :checkpoint),
          coverage_index_file: Keyword.get(opts, :coverage_index_file),
          coverage_corpus_fingerprint: Keyword.get(opts, :coverage_corpus_fingerprint),
          inventory_cache_file: Keyword.get(opts, :inventory_cache_file),
          inventory_cache_key: Keyword.get(opts, :inventory_cache_key)
        },
        language: language,
        mutators: mutators,
        concurrency: Keyword.get(opts, :concurrency, System.schedulers_online()),
        timeout_ms: Keyword.get(opts, :timeout, 10_000),
        fail_at: Keyword.get(opts, :fail_at, 80),
        format: Keyword.get(opts, :format, "terminal"),
        min_score: Keyword.get(opts, :min_score, 20),
        max_mutations: Keyword.get(opts, :max_mutations, 0),
        filter: not Keyword.get(opts, :no_filter, false),
        verbose: Keyword.get(opts, :verbose, false),
        optimize: resolve_optimize(opts),
        tce: false,
        since: Keyword.get(opts, :since),
        coverage_guided: Keyword.get(opts, :coverage_guided, false),
        optimize_level: optimize_level,
        min_complexity: Keyword.get(opts, :min_complexity),
        max_per_function: Keyword.get(opts, :max_per_function),
        keep_metadata: Keyword.get(opts, :keep_metadata_mutations, false),
        preset: preset,
        skip_calls: preset_skip_calls(preset),
        report_file: Keyword.get(opts, :report_file),
        audit_dir: Keyword.get(opts, :audit_dir),
        baseline_timeout_ms: Keyword.get(opts, :baseline_timeout, 120_000),
        mutant_id: Keyword.get(opts, :mutant_id),
        mutant_ids_file: Keyword.get(opts, :mutant_ids_file),
        campaign_fingerprint: Keyword.get(opts, :campaign_fingerprint)
      }

      {:ok, config}
    end
  end

  defp validate_mutant_selection(opts) do
    if Keyword.has_key?(opts, :mutant_id) and Keyword.has_key?(opts, :mutant_ids_file),
      do: {:error, "--mutant-id and --mutant-ids-file are mutually exclusive"},
      else: :ok
  end

  defp validate_audit_only(opts) do
    audit_only? = Keyword.get(opts, :audit_only, false)
    audit_plan = Keyword.get(opts, :audit_plan)

    cond do
      audit_only? and (not is_binary(audit_plan) or audit_plan == "") ->
        {:error, "--audit-only requires --audit-plan"}

      is_binary(audit_plan) and not audit_only? ->
        {:error, "--audit-plan requires --audit-only"}

      true ->
        :ok
    end
  end

  defp validate_coverage_index(opts) do
    index? = Keyword.has_key?(opts, :coverage_index_file)
    fingerprint = Keyword.get(opts, :coverage_corpus_fingerprint)

    cond do
      index? and not Keyword.get(opts, :coverage_guided, false) ->
        {:error, "--coverage-index-file requires --coverage-guided"}

      is_binary(fingerprint) and not index? ->
        {:error, "--coverage-corpus-fingerprint requires --coverage-index-file"}

      is_binary(fingerprint) and not Regex.match?(~r/\A[a-f0-9]{64}\z/, fingerprint) ->
        {:error, "--coverage-corpus-fingerprint must be a lowercase SHA-256 digest"}

      true ->
        :ok
    end
  end

  defp validate_inventory_cache(opts) do
    file = Keyword.get(opts, :inventory_cache_file)
    key = Keyword.get(opts, :inventory_cache_key)

    cond do
      is_nil(file) and is_nil(key) ->
        :ok

      is_nil(file) or is_nil(key) ->
        {:error, "--inventory-cache-file and --inventory-cache-key must be provided together"}

      is_nil(Keyword.get(opts, :audit_dir)) ->
        {:error, "--inventory-cache-file requires --audit-dir"}

      not Regex.match?(~r/\A[a-f0-9]{64}\z/, key) ->
        {:error, "--inventory-cache-key must be a lowercase SHA-256 digest"}

      true ->
        :ok
    end
  end

  defp validate_positive(opts, key) do
    case Keyword.fetch(opts, key) do
      :error ->
        :ok

      {:ok, value} when is_integer(value) and value > 0 ->
        :ok

      {:ok, _value} ->
        {:error,
         "--#{key |> Atom.to_string() |> String.replace("_", "-")} must be a positive integer"}
    end
  end

  @doc "Returns optimizer options derived from the config's optimization settings.\n"
  @spec optimizer_opts(t()) :: keyword()
  def optimizer_opts(%__MODULE__{} = config) do
    base =
      case config.optimize_level do
        "conservative" ->
          [
            enabled: true,
            min_complexity: 1,
            max_mutations_per_function: 50,
            keep_boundary_mutations: true
          ]

        "balanced" ->
          [
            enabled: true,
            min_complexity: 2,
            max_mutations_per_function: 20,
            keep_boundary_mutations: true
          ]

        "aggressive" ->
          [
            enabled: true,
            min_complexity: 3,
            max_mutations_per_function: 10,
            keep_boundary_mutations: true
          ]
      end

    base =
      if config.min_complexity do
        Keyword.put(base, :min_complexity, config.min_complexity)
      else
        base
      end

    if config.max_per_function do
      Keyword.put(base, :max_mutations_per_function, config.max_per_function)
    else
      base
    end
  end

  @doc """
  Expands a list of test path entries into actual file paths on disk.

  Each entry is treated as follows:
    - Directory -> expands to `dir/**/*_test.exs`
    - Glob pattern (contains `*` or `?`) -> expanded via `Path.wildcard/1`
    - Regular file -> taken literally
    - Other -> attempted as a wildcard pattern
  """
  @spec expand_test_paths([String.t()]) :: [Path.t()]
  def expand_test_paths(paths) when is_list(paths) do
    paths |> Enum.flat_map(&expand_test_path/1) |> Enum.uniq()
  end

  @doc "Expands a single test path entry into matching file paths.\n\nHandles directories, glob patterns, regular files, and fallback wildcard.\n"
  @spec expand_test_path(String.t()) :: [Path.t()]
  def expand_test_path(path) do
    cond do
      String.contains?(path, ["*", "?"]) -> Path.wildcard(path)
      File.dir?(path) -> Path.wildcard(Path.join([path, "**", "*_test.exs"]))
      File.regular?(path) -> [path]
      true -> Path.wildcard(path)
    end
  end

  defp resolve_files(opts, app) do
    explicit = Keyword.get(opts, :files) || Keyword.get(opts, :path)

    cond do
      explicit ->
        explicit
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      app ->
        [Path.join(["apps", app, "lib"])]

      true ->
        ["lib"]
    end
  end

  defp resolve_test_paths(opts, app) do
    case Keyword.get(opts, :test_paths) do
      nil ->
        if app do
          [Path.join(["apps", app, "test"])]
        else
          ["test"]
        end

      raw ->
        raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end
  end

  defp resolve_optimize(opts) do
    cond do
      Keyword.get(opts, :no_optimize, false) -> false
      Keyword.has_key?(opts, :optimize) -> Keyword.get(opts, :optimize)
      true -> true
    end
  end

  defp validate_tce_disabled(opts) do
    if Keyword.get(opts, :tce, false),
      do: {:error, "--tce is disabled because compiler-equivalence detection is not sound"},
      else: :ok
  end

  defp parse_mutator_paths(nil), do: []

  defp parse_mutator_paths(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @language_map Map.merge(
                  %{"elixir" => ElixirLanguage, "erlang" => Muex.Language.Erlang},
                  Application.compile_env(:muex, :languages, %{})
                )
  defp resolve_language(name) do
    module =
      Map.get_lazy(@language_map, name, fn ->
        Module.concat([Muex.Language, Macro.camelize(name)])
      end)

    case Code.ensure_loaded(module) do
      {:module, ^module} -> {:ok, module}
      _ -> {:error, "Unknown language: #{name}"}
    end
  end

  @doc false
  def language_for_path(path) do
    extension = Path.extname(path)

    @language_map
    |> Map.values()
    |> Enum.uniq()
    |> Enum.find_value(fn module ->
      with {:module, ^module} <- Code.ensure_loaded(module),
           true <- extension in module.file_extensions() do
        module
      else
        _other -> nil
      end
    end)
    |> case do
      nil -> {:error, "no language adapter for #{extension}"}
      module -> {:ok, module}
    end
  end

  @doc false
  def all_mutators(extra_paths \\ [], language \\ ElixirLanguage) do
    builtin = discover_mutators(:muex)
    external = load_external_mutators(extra_paths)

    (builtin ++ external)
    |> Enum.uniq()
    |> Enum.filter(fn mod -> language in mod.supported_languages() end)
    |> Enum.sort_by(&Module.split/1)
  end

  defp discover_mutators(app) do
    case :application.get_key(app, :modules) do
      {:ok, modules} -> Enum.filter(modules, &mutator?/1)
      :undefined -> []
    end
  end

  defp load_external_mutators(paths) when paths in [[], nil] do
    []
  end

  defp load_external_mutators(paths) do
    paths
    |> Enum.flat_map(fn path -> path |> Path.join("**/*.ex") |> Path.wildcard() end)
    |> Enum.flat_map(fn file ->
      file
      |> Code.compile_file()
      |> Enum.map(fn {mod, _bytecode} -> mod end)
      |> Enum.filter(&mutator?/1)
    end)
  end

  defp mutator?(mod) do
    behaviours =
      :attributes |> mod.module_info() |> Keyword.get_values(:behaviour) |> List.flatten()

    Muex.Mutator in behaviours
  rescue
    _ -> false
  end

  defp mutator_map(extra_paths, language) do
    Map.new(all_mutators(extra_paths, language), fn mod ->
      key = mod |> Module.split() |> List.last() |> Macro.underscore()
      {key, mod}
    end)
  end

  defp resolve_mutators(nil, extra_paths, language, preset) do
    case preset_focus_mutators(preset, extra_paths, language) do
      nil -> {:ok, all_mutators(extra_paths, language)}
      mutators -> {:ok, mutators}
    end
  end

  defp resolve_mutators(raw, extra_paths, language, _preset) do
    names = raw |> String.split(",") |> Enum.map(&String.trim/1)

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case Map.fetch(mutator_map(extra_paths, language), name) do
        {:ok, mod} -> {:cont, {:ok, acc ++ [mod]}}
        :error -> {:halt, {:error, "Unknown mutator: #{name}"}}
      end
    end)
  end

  defp validate_optimize_level(level) when level in ~w(conservative balanced aggressive) do
    {:ok, level}
  end

  defp validate_optimize_level(other) do
    {:error, "Unknown optimization level: #{other}. Use conservative, balanced, or aggressive"}
  end

  # DSL call names pruned during traversal for each framework preset. These
  # are macros whose "literals" are compile-time metadata (option keys,
  # route paths, field names) rather than runtime values.
  @preset_skip_calls %{
    "none" => [],
    "phoenix" => [
      :attr,
      :slot,
      :embed_templates,
      :sigil_H,
      :scope,
      :pipeline,
      :pipe_through,
      :plug,
      :live,
      :live_session,
      :forward,
      :resources,
      :get,
      :post,
      :put,
      :patch,
      :delete,
      :options,
      :head,
      :on_mount
    ],
    "ecto" => [
      :schema,
      :embedded_schema,
      :field,
      :belongs_to,
      :has_many,
      :has_one,
      :many_to_many,
      :embeds_one,
      :embeds_many,
      :timestamps
    ],
    "ash" => [
      :attributes,
      :attribute,
      :relationships,
      :relationship,
      :actions,
      :action,
      :resource,
      :code_interface,
      :policies,
      :policy
    ]
  }

  # Focused mutator set used when a preset is active and --mutators is omitted.
  @preset_focus_mutators ~w(arithmetic boolean comparison conditional return_value statement_deletion)

  defp validate_preset(preset) when preset in ~w(none phoenix ecto ash) do
    {:ok, preset}
  end

  defp validate_preset(other) do
    {:error, "Unknown preset: #{other}. Use phoenix, ecto, ash, or none"}
  end

  defp preset_skip_calls(preset), do: Map.fetch!(@preset_skip_calls, preset)

  defp preset_focus_mutators("none", _extra_paths, _language), do: nil

  defp preset_focus_mutators(_preset, extra_paths, language) do
    map = mutator_map(extra_paths, language)

    @preset_focus_mutators
    |> Enum.map(&Map.get(map, &1))
    |> Enum.reject(&is_nil/1)
  end

  # Detect the project root from an explicit option or by walking up from
  # the first --files path to find the nearest mix.exs.
  defp resolve_project_root(nil, files) do
    first_path = List.first(files) || "lib"
    find_mix_project_root(Path.expand(first_path))
  end

  defp resolve_project_root(explicit, _files), do: Path.expand(explicit)

  defp find_mix_project_root(path) do
    # If `path` is a file, start from its parent directory
    dir = if File.dir?(path), do: path, else: Path.dirname(path)

    if File.regular?(Path.join(dir, "mix.exs")) do
      dir
    else
      parent = Path.dirname(dir)

      if parent == dir do
        # Reached filesystem root — fall back to CWD
        File.cwd!()
      else
        find_mix_project_root(parent)
      end
    end
  end
end
