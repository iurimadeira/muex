defmodule Muex.Continuation.Artifact do
  @moduledoc false

  alias Muex.Audit.Validator
  alias Muex.Continuation
  alias Muex.InventoryCache

  @doc false
  def prepare(parent, child, blocked_ids, shard_count) do
    with {:ok, manifest} <- read_json_regular(Path.join(parent, "campaign.manifest.json")),
         :ok <- validate_parent_manifest(manifest, shard_count),
         {:ok, invocation} <- parent_invocation(parent, manifest),
         {:ok, shards} <- validate_parent_shards(parent, invocation, manifest, shard_count),
         {:ok, plan} <- Continuation.cache_compatible_plan(shards, blocked_ids, shard_count),
         :ok <- preload_parent_sources(parent, plan.assignments),
         :ok <- File.mkdir_p(Path.join(child, "inventory-cache")),
         {:ok, assignments} <- import_assignments(parent, child, plan.assignments),
         evidence = evidence(manifest, parent, invocation, shards, plan, assignments),
         :ok <- atomic_json(Path.join(child, "continuation.plan.json"), evidence) do
      {:ok, evidence}
    end
  end

  @doc false
  def finalize(child) do
    path = Path.join(child, "continuation.plan.json")

    with {:ok, plan} <- read_json_regular(path),
         {:ok, child_ids, validations} <- validate_child_shards(child, plan),
         :ok <- validate_final_partition(plan, child_ids),
         accounted =
           MapSet.union(
             imported_ids(plan),
             MapSet.union(child_ids, MapSet.new(plan["infra_blocked_ids"]))
           ),
         aggregate = %{
           version: 1,
           status: "complete",
           parent_selected_count: plan["parent_selected_count"],
           imported_finalized_count: length(plan["imported_finalized"]),
           child_finalized_count: MapSet.size(child_ids),
           infra_blocked_count: length(plan["infra_blocked_ids"]),
           infra_blocked_ids: plan["infra_blocked_ids"],
           accounted_ids_sha256: digest(Enum.sort(MapSet.to_list(accounted))),
           validations: validations,
           continuation_plan_sha256: digest_file(path)
         },
         :ok <- atomic_json(Path.join(child, "continuation.aggregate.json"), aggregate) do
      {:ok, aggregate}
    end
  end

  defp validate_parent_manifest(
         %{
           "status" => "incomplete",
           "terminal" => %{"reason" => "signal_received"},
           "current_invocation" => invocation,
           "fingerprint" => fingerprint,
           "shards" => shard_count
         },
         shard_count
       )
       when is_binary(invocation) and is_binary(fingerprint), do: :ok

  defp validate_parent_manifest(_manifest, _shard_count), do: {:error, :invalid_parent_manifest}

  defp parent_invocation(parent, %{"current_invocation" => name}) do
    path = Path.join(parent, name)

    if Regex.match?(~r/\Ainvocation\.[A-Za-z0-9]+\z/, name) and regular_directory?(path),
      do: {:ok, path},
      else: {:error, :invalid_parent_invocation}
  end

  defp validate_parent_shards(parent, invocation, manifest, shard_count) do
    1..shard_count
    |> Enum.reduce_while({:ok, []}, fn shard, {:ok, acc} ->
      opts = [
        plan: Path.join(invocation, "shard-#{shard}-audit/plan.json"),
        checkpoint: Path.join(parent, "shard-#{shard}.checkpoint.jsonl"),
        artifact_roots: [invocation, parent],
        campaign_fingerprint: manifest["fingerprint"]
      ]

      case Validator.validate_checkpoint_prefix(opts) do
        {:ok, prefix} ->
          entry = %{
            shard: shard,
            selected_ids: prefix.selected_ids,
            result_ids: Map.keys(prefix.results),
            result_statuses: prefix.results,
            infrastructure_error_ids: prefix.infrastructure_error_ids,
            plan_sha256: prefix.inputs.plan_sha256,
            checkpoint_sha256: prefix.inputs.checkpoint_sha256,
            artifacts: prefix.artifacts
          }

          {:cont, {:ok, [entry | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_parent_shard, shard, reason}}}
      end
    end)
    |> then(fn
      {:ok, shards} -> {:ok, Enum.reverse(shards)}
      error -> error
    end)
  end

  defp import_assignments(parent, child, assignments) do
    assignments
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {child_shard, assignment}, {:ok, acc} ->
      source = Path.join(parent, "inventory-cache/shard-#{assignment.parent_shard}.etf")
      destination = Path.join(child, "inventory-cache/shard-#{child_shard}.etf")
      ids_path = Path.join(child, "shard-#{child_shard}.ids")
      files_source = Path.join(parent, "shard-#{assignment.parent_shard}.files")
      files_destination = Path.join(child, "shard-#{child_shard}.files")

      with :ok <- write_lines(ids_path, assignment.ids),
           :ok <- copy_regular(files_source, files_destination),
           {:ok, provenance} <- InventoryCache.import_subset(source, destination, assignment.ids) do
        row = %{
          child_shard: child_shard,
          parent_shard: assignment.parent_shard,
          ids: assignment.ids,
          ids_sha256: digest(assignment.ids),
          count: length(assignment.ids),
          cache: provenance
        }

        {:cont, {:ok, [row | acc]}}
      else
        {:error, reason} -> {:halt, {:error, {:assignment_import_failed, child_shard, reason}}}
      end
    end)
    |> then(fn
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end)
  end

  defp preload_parent_sources(parent, assignments) do
    shards =
      assignments
      |> Map.values()
      |> Enum.map(& &1.parent_shard)
      |> Enum.uniq()

    with {:ok, files} <- read_source_lists(parent, shards),
         absolute = Enum.uniq(files),
         {:ok, _entries} <- Muex.Loader.load_all(absolute, Muex.Language.Elixir, exclude: []) do
      :ok
    else
      {:error, reason} -> {:error, {:cannot_preload_parent_sources, reason}}
    end
  end

  defp read_source_lists(parent, shards) do
    Enum.reduce_while(shards, {:ok, []}, fn shard, {:ok, acc} ->
      path = Path.join(parent, "shard-#{shard}.files")

      with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
           {:ok, body} <- File.read(path),
           {:ok, sources} <- validate_source_paths(parent, String.split(body, "\n", trim: true)) do
        {:cont, {:ok, sources ++ acc}}
      else
        _error -> {:halt, {:error, :unsafe_source_file_list}}
      end
    end)
  end

  defp validate_source_paths(parent, entries) do
    snapshot = Path.join(parent, "snapshot")

    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, paths} ->
      case validate_snapshot_path(snapshot, entry) do
        {:ok, path} -> {:cont, {:ok, [path | paths]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc false
  def validate_snapshot_path(snapshot, entry) when is_binary(entry) do
    snapshot = Path.expand(snapshot)
    parts = Path.split(entry)
    candidate = Path.expand(entry, snapshot)

    with :relative <- Path.type(entry),
         true <- parts != [] and Enum.all?(parts, &(&1 not in [".", ".."])),
         true <- Path.join(parts) == entry,
         true <- String.starts_with?(candidate, snapshot <> "/"),
         {:ok, ^snapshot} <- canonical_existing(snapshot),
         false <- symlink_component?(snapshot, parts),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(candidate),
         {:ok, ^candidate} <- canonical_existing(candidate) do
      {:ok, candidate}
    else
      _unsafe -> {:error, :unsafe_source_file_list}
    end
  end

  def validate_snapshot_path(_snapshot, _entry), do: {:error, :unsafe_source_file_list}

  defp symlink_component?(snapshot, parts) do
    [snapshot | Enum.scan(parts, snapshot, &Path.join(&2, &1))]
    |> Enum.any?(fn path -> match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)) end)
  end

  defp canonical_existing(path) do
    case System.cmd("realpath", ["-e", "--", path], stderr_to_stdout: true) do
      {canonical, 0} -> {:ok, String.trim(canonical)}
      {_output, _status} -> {:error, :not_canonical}
    end
  end

  defp evidence(manifest, parent, invocation, shards, plan, assignments) do
    imported =
      shards
      |> Enum.flat_map(fn shard ->
        Enum.map(shard.result_statuses, fn {id, status} -> %{id: id, status: status} end)
      end)
      |> Enum.sort_by(& &1.id)

    %{
      version: 1,
      parent_campaign: parent,
      parent_invocation: invocation,
      parent_manifest_sha256: digest_file(Path.join(parent, "campaign.manifest.json")),
      parent_snapshot_sha256: get_in(manifest, ["snapshot_source", "sha256"]),
      parent_fingerprint: manifest["fingerprint"],
      parent_selected_count: MapSet.size(plan.selected_ids),
      parent_selected_ids_sha256: digest(Enum.sort(MapSet.to_list(plan.selected_ids))),
      parent_shards:
        Enum.map(
          shards,
          &Map.drop(&1, [:selected_ids, :result_ids, :result_statuses, :infrastructure_error_ids])
        ),
      imported_finalized: imported,
      infra_blocked_ids: Enum.sort(plan.infra_blocked_ids),
      pending_count: MapSet.size(plan.pending_ids),
      assignments: assignments
    }
  end

  defp validate_child_shards(child, %{"assignments" => assignments} = plan)
       when is_list(assignments) do
    with {:ok, invocation} <- child_invocation(child) do
      assignments
      |> Enum.reduce_while({:ok, MapSet.new(), []}, fn assignment, {:ok, ids, validations} ->
        shard = assignment["child_shard"]
        plan_path = Path.join(invocation, "shard-#{shard}-audit/plan.json")
        checkpoint = Path.join(child, "shard-#{shard}.checkpoint.jsonl")
        report = Path.join(invocation, "shard-#{shard}.json")
        validation_path = Path.join(invocation, "shard-#{shard}.validation.json")

        validator_opts = [
          plan: plan_path,
          checkpoint: checkpoint,
          report: report,
          artifact_roots: [invocation, child],
          campaign_fingerprint: plan["parent_fingerprint"]
        ]

        with {:ok, validation} <- Validator.validate_evidence(validator_opts),
             {:ok, shard_plan} <- read_json_regular(plan_path),
             selected = for(%{"id" => id, "selected" => true} <- shard_plan["mutants"], do: id),
             true <- MapSet.new(selected) == MapSet.new(assignment["ids"]),
             true <- validation.status == "valid" and validation.result_count == length(selected) do
          {:cont, {:ok, MapSet.union(ids, MapSet.new(selected)), [validation_path | validations]}}
        else
          _error -> {:halt, {:error, {:invalid_child_shard, shard}}}
        end
      end)
      |> then(fn
        {:ok, ids, validations} -> {:ok, ids, Enum.reverse(validations)}
        error -> error
      end)
    end
  end

  defp validate_child_shards(_child, _plan), do: {:error, :invalid_continuation_plan}

  defp validate_final_partition(plan, child_ids) do
    selected = plan["parent_selected_count"]
    imported = MapSet.new(plan["imported_finalized"], & &1["id"])
    blocked = MapSet.new(plan["infra_blocked_ids"])

    accounted = MapSet.union(imported, MapSet.union(child_ids, blocked))

    if MapSet.disjoint?(imported, child_ids) and MapSet.disjoint?(imported, blocked) and
         MapSet.disjoint?(child_ids, blocked) and
         MapSet.size(accounted) == selected and
         digest(Enum.sort(MapSet.to_list(accounted))) == plan["parent_selected_ids_sha256"],
       do: :ok,
       else: {:error, :continuation_partition_mismatch}
  end

  defp imported_ids(plan), do: MapSet.new(plan["imported_finalized"], & &1["id"])

  defp read_json_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        with {:ok, body} <- File.read(path), do: Jason.decode(body)

      _other ->
        {:error, :unsafe_or_missing_artifact}
    end
  end

  defp copy_regular(source, destination) do
    case File.lstat(source) do
      {:ok, %File.Stat{type: :regular}} ->
        if File.exists?(destination),
          do: {:error, :destination_exists},
          else: File.cp(source, destination)

      _other ->
        {:error, :unsafe_or_missing_artifact}
    end
  end

  defp regular_directory?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  defp child_invocation(child) do
    with {:ok, %{"current_invocation" => name}} <-
           read_json_regular(Path.join(child, "campaign.manifest.json")),
         true <- is_binary(name) and Regex.match?(~r/\Ainvocation\.[A-Za-z0-9]+\z/, name),
         invocation = Path.join(child, name),
         true <- regular_directory?(invocation) do
      {:ok, invocation}
    else
      _error -> {:error, :invalid_child_invocation}
    end
  end

  defp write_lines(path, lines),
    do: File.write(path, Enum.map_join(lines, "", &(&1 <> "\n")), [:binary, :sync, :exclusive])

  defp atomic_json(path, value) do
    temporary = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <-
           File.write(temporary, Jason.encode!(value, pretty: true) <> "\n", [
             :binary,
             :sync,
             :exclusive
           ]),
         :ok <- File.ln(temporary, path),
         :ok <- File.rm(temporary) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, {:cannot_publish_artifact, reason}}
    end
  end

  defp digest(term), do: term |> :erlang.term_to_binary() |> sha256()
  defp sha256(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp digest_file(path) do
    path
    |> File.stream!(1_048_576, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
