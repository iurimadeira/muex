defmodule Mix.Tasks.Muex do
  @shortdoc "Run mutation testing"
  @moduledoc """
  Run mutation testing on your project.

  ## Usage

      mix muex [options]

  ## Options

    * `--files` - Directory, file, or glob pattern (default: "lib")
    * `--path` - Synonym for --files
    * `--app` - Target a specific app in an umbrella project (sets --files and --test-paths automatically)
    * `--test-paths` - Comma-separated test directories, files, or glob patterns (default: "test")
    * `--language` - Language adapter to use (default: "elixir")
    * `--mutators` - Comma-separated list of mutators (default: all)
    * `--concurrency` - Number of parallel mutations (default: number of schedulers)
    * `--timeout` - Test timeout in milliseconds (default: 10000)
    * `--fail-at` - Minimum mutation score to pass (default: 80)
    * `--format` - Output format: terminal, json, html (default: terminal)
    * `--min-score` - Minimum complexity score for files to include (default: 20)
    * `--max-mutations` - Maximum number of mutations to test (0 = unlimited, default: 0)
    * `--no-filter` - Disable intelligent file filtering
    * `--verbose` - Show detailed progress information (file analysis, optimization, etc.)
    * `--optimize` - Enable mutation optimization heuristics (default: enabled)
    * `--no-optimize` - Disable mutation optimization heuristics
    * `--optimize-level` - Optimization preset: conservative, balanced, aggressive (default: balanced)
    * `--min-complexity` - Minimum complexity for mutations (default: 2, with --optimize)
    * `--max-per-function` - Max mutations per function (default: 20, with --optimize)
    * `--tce` - Rejected: compiler-equivalence detection is disabled as unsound
    * `--since` - Only test mutations on lines changed since a git ref, e.g. --since main (PR scoping)
    * `--coverage-guided` - Run only the tests that cover each mutated line (default: disabled)
    * `--keep-metadata-mutations` - Keep mutations with no source location (line: 0); dropped by default
    * `--checkpoint` - Append terminal mutation results to a resumable JSONL checkpoint
    * `--report-file` - Write the structured report atomically to this exact path
    * `--audit-dir` - Write full plans, attempt events, and untruncated process output artifacts
    * `--audit-only` - Generate optimized inventory without running tests or mutants
    * `--audit-plan` - Exact authoritative plan output path required by --audit-only
    * `--baseline-timeout` - Separate timeout in milliseconds for each sandbox baseline
    * `--mutant-id` - Deterministically select one mutation ID from the generated plan
    * `--preset` - Framework preset to prune DSL noise: phoenix, ecto, ash, none (default: none)

  ## Campaign options

  These are the seam an external campaign wrapper drives; see
  `docs/CAMPAIGN_API.md` for the full contract.

    * `--project-root` - Anchor for every relative path
    * `--mutant-ids-file` - Newline-delimited stable mutation IDs for one shard
    * `--campaign-fingerprint` - Bind checkpoint evidence to an outer campaign
    * `--inventory-cache-file` / `--inventory-cache-key` - Reuse a campaign-owned
      content-addressed inventory across shard invocations; both are required
      together, they require `--audit-dir`, and the key must be a lowercase
      64-character SHA-256 digest
    * `--coverage-index-file` / `--coverage-corpus-fingerprint` - Consume a
      campaign-owned coverage index instead of measuring coverage in-process;
      the index requires `--coverage-guided` and the fingerprint requires the
      index
    * `--changed-diff-file` - Supply the `--since` diff as a file
    * `--mutator-paths` - Comma-separated directories of custom mutator modules

  ## Examples

      mix muex                          # Run with intelligent filtering
      mix muex --no-filter                # Run on all files
      mix muex --files "lib/muex"          # Specific directory
      mix muex --files "lib/muex/*.ex"     # Glob pattern
      mix muex --mutators arithmetic,comparison
      mix muex --fail-at 80               # Fail below 80%
      mix muex --format json              # JSON output
      mix muex --format html              # HTML report
      mix muex --verbose                  # Detailed progress
      mix muex --optimize --optimize-level aggressive
      mix muex --app my_app               # Umbrella: specific app
      mix muex --test-paths "test/unit,test/integration"
      mix muex --preset phoenix           # Prune Phoenix component/router DSL noise
      mix muex --since main               # Only mutate lines changed since main
      mix muex --coverage-guided          # Run only tests covering each mutated line
      mix muex --audit-only --audit-plan tmp/plan.json
      mix muex --files "lib/my_module.ex" --test-paths "test/my_module_test.exs"
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    case Muex.Config.from_args(args) do
      {:error, reason} ->
        Mix.raise(reason)

      {:ok, config} ->
        config |> Muex.run() |> handle_result(config)
    end
  end

  defp handle_result({:error, reason}, _config), do: Mix.raise(error_message(reason))

  defp handle_result(
         {:ok, %{audit_only: true, audit_plan: path, selected_count: selected_count}},
         _config
       ) do
    Mix.shell().info(
      "Audit inventory published to #{path} with #{selected_count} selected mutations"
    )

    :ok
  end

  defp handle_result({:ok, %{results: []} = result}, config) do
    Mix.shell().info("No mutations to test; nothing to score.")
    enforce_score(result, config)
  end

  defp handle_result({:ok, result}, config), do: enforce_score(result, config)

  defp enforce_score(%{score_low: score_low, score_high: score_high}, config) do
    if score_low < config.fail_at do
      score_str =
        if score_low == score_high,
          do: "#{score_low}%",
          else: "#{score_low}%..#{score_high}%"

      Mix.raise("Mutation score #{score_str} is below threshold #{config.fail_at}%")
    end
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)
end
