defmodule Mix.Tasks.Muex.Campaign do
  @shortdoc "Builds an immutable sharded mutation campaign plan"

  @moduledoc """
  Seals and slices an immutable, sharded mutation campaign plan.

  `build` turns an audited inventory into a content-addressed, source-file-atomic
  plan; `slice` materializes the exact work of one shard under its own
  `slice_sha256`. Both are part of the seam documented in
  `docs/CAMPAIGN_API.md`, which is the single source for their options, their
  artifacts, and the coverage binding they carry.
  """
  use Mix.Task

  alias Muex.Audit.Validator
  alias Muex.CampaignPlan
  alias Muex.Continuation.Artifact
  alias Muex.Coverage

  @switches [
    project_root: :string,
    audit_plan: :string,
    source_files: :string,
    test_files: :string,
    coverage_index: :string,
    selective_manifest: :string,
    config_file: :string,
    shards: :integer,
    commit_sha: :string,
    plan: :string,
    plan_sha256: :string,
    shard: :integer,
    output: :string,
    auxiliary_paths_file: :string
  ]

  @impl Mix.Task
  def run(["slice" | args]) do
    Mix.Task.run("app.start")

    with {:ok, opts} <-
           parse(args, ~w(project_root plan plan_sha256 config_file shard output)a),
         plan_sha256 = Keyword.fetch!(opts, :plan_sha256),
         {:ok, plan} <- CampaignPlan.read(Keyword.fetch!(opts, :plan), plan_sha256),
         {:ok, config} <- read_json(Keyword.fetch!(opts, :config_file)),
         {:ok, slice} <-
           CampaignPlan.execution_slice(
             Keyword.fetch!(opts, :project_root),
             plan,
             Keyword.fetch!(opts, :shard),
             Keyword.get(opts, :coverage_index),
             config: config,
             plan_artifact_sha256: plan_sha256
           ),
         :ok <- CampaignPlan.write_execution_slice(slice, Keyword.fetch!(opts, :output)) do
      Mix.shell().info(
        "materialized shard #{slice["shard"]} with #{length(slice["mutant_ids"])} mutations"
      )

      :ok
    else
      {:error, reason} -> Mix.raise("Muex campaign slice failed: #{inspect(reason)}")
    end
  end

  def run(["build" | args]), do: build(args)
  def run(args), do: build(args)

  defp build(args) do
    Mix.Task.run("app.start")

    with {:ok, opts} <-
           parse(
             args,
             ~w(project_root audit_plan source_files test_files config_file shards output)a
           ),
         root = opts |> Keyword.fetch!(:project_root) |> Path.expand(),
         source_files = read_lines(Keyword.fetch!(opts, :source_files)),
         test_files = read_lines(Keyword.fetch!(opts, :test_files)),
         auxiliary_paths = read_optional_lines(opts[:auxiliary_paths_file]),
         {:ok, config} <- read_json(Keyword.fetch!(opts, :config_file)),
         {:ok, inventory} <-
           read_inventory(root, Keyword.fetch!(opts, :audit_plan), source_files, config),
         coverage_fingerprint <-
           Coverage.corpus_fingerprint(
             root,
             source_files,
             test_files,
             Keyword.get(opts, :selective_manifest),
             auxiliary_paths
           ),
         {coverage, coverage_sha256} <-
           read_coverage(Keyword.get(opts, :coverage_index), coverage_fingerprint),
         {:ok, plan} <-
           CampaignPlan.build(root, inventory.mutations, source_files, test_files, coverage,
             shards: Keyword.fetch!(opts, :shards),
             config: config,
             coverage_fingerprint: coverage_fingerprint,
             coverage_index_sha256: coverage_sha256,
             audit_plan_sha256: inventory.sha256,
             audit_optimizer: inventory.optimizer,
             commit_sha: Keyword.get(opts, :commit_sha)
           ),
         :ok <- CampaignPlan.write(plan, Keyword.fetch!(opts, :output)) do
      Mix.shell().info(
        "planned #{length(plan["requirements"])} mutations across #{length(plan["shards"])} shards"
      )

      :ok
    else
      {:error, reason} -> Mix.raise("Muex campaign planning failed: #{inspect(reason)}")
    end
  end

  defp parse(args, required) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        case Enum.find(required, &(not Keyword.has_key?(opts, &1))) do
          nil -> {:ok, opts}
          key -> {:error, {:missing_option, key}}
        end

      {_opts, rest, invalid} ->
        {:error, {:invalid_options, invalid ++ rest}}
    end
  end

  defp read_inventory(root, path, source_files, config) do
    with {:ok, %{plan: plan, sha256: sha256, selected_ids: [_ | _]}} <-
           Validator.validate_plan_file(path),
         %{"mutants" => mutants, "source_files" => sources, "optimizer" => optimizer} <- plan,
         true <- Enum.sort(Enum.map(sources, & &1["path"])) == Enum.sort(source_files),
         true <- optimizer == expected_optimizer(config),
         selected = Enum.filter(mutants, &(&1["selected"] == true)),
         :ok <- validate_original_sources(root, selected) do
      mutations =
        Enum.map(selected, fn mutant ->
          %{
            id: mutant["id"],
            location: %{
              file: mutant["location"]["file"],
              line: mutant["location"]["line"]
            }
          }
        end)

      {:ok, %{mutations: mutations, optimizer: optimizer, sha256: sha256}}
    else
      _invalid -> {:error, :invalid_campaign_inventory}
    end
  end

  defp validate_original_sources(root, mutants) do
    Enum.reduce_while(mutants, :ok, fn mutant, :ok ->
      relative = mutant["location"]["file"]

      with {:ok, canonical} <- Artifact.validate_snapshot_path(root, relative),
           {:ok, contents} <- File.read(canonical),
           true <- sha256(contents) == mutant["original_sha256"] do
        {:cont, :ok}
      else
        _invalid -> {:halt, {:error, :stale_campaign_inventory}}
      end
    end)
  end

  defp expected_optimizer(config) do
    %{
      "enabled" => config["optimize"],
      "level" => config["optimize_level"],
      "heuristic_equivalence" => false,
      "tce" => false,
      "max_mutations" => config["max_mutations"]
    }
  end

  defp read_coverage(nil, _fingerprint), do: {nil, nil}

  defp read_coverage(path, fingerprint) do
    case Coverage.read_bound_index_snapshot(path, fingerprint) do
      {:ok, snapshot} -> {snapshot.index, snapshot.sha256}
      :stale -> {nil, nil}
    end
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, contents} -> Jason.decode(contents)
      {:error, _reason} = error -> error
    end
  end

  defp read_lines(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp read_optional_lines(nil), do: []
  defp read_optional_lines(path), do: read_lines(path)

  defp sha256(contents) do
    :sha256
    |> :crypto.hash(contents)
    |> Base.encode16(case: :lower)
  end
end
