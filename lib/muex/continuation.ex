defmodule Muex.Continuation do
  @moduledoc false

  def plan(shards, blocked_ids, shard_count)
      when is_list(shards) and is_list(blocked_ids) and shard_count > 0 do
    selected_ids = Enum.flat_map(shards, & &1.selected_ids)
    finalized_ids = Enum.flat_map(shards, & &1.result_ids)
    infrastructure = shards |> Enum.flat_map(& &1.infrastructure_error_ids) |> MapSet.new()
    selected = MapSet.new(selected_ids)
    finalized = MapSet.new(finalized_ids)
    blocked = MapSet.new(blocked_ids)

    with :ok <- unique?(selected, selected_ids, :selected),
         :ok <- unique?(finalized, finalized_ids, :finalized),
         :ok <- unique?(blocked, blocked_ids, :infra_blocked),
         :ok <- subset?(finalized, selected, :finalized_outside_parent_plan),
         :ok <- subset?(blocked, selected, :infra_blocked_outside_parent_plan),
         :ok <-
           subset?(blocked, infrastructure, :infra_blocked_without_parent_infrastructure_error),
         :ok <- disjoint?(finalized, blocked, :infra_blocked_already_finalized) do
      pending =
        selected |> MapSet.difference(finalized) |> MapSet.difference(blocked) |> Enum.sort()

      assignments =
        pending
        |> Enum.with_index()
        |> Enum.group_by(fn {_id, index} -> rem(index, shard_count) + 1 end, fn {id, _index} ->
          id
        end)
        |> then(fn grouped -> Map.new(1..shard_count, &{&1, Map.get(grouped, &1, [])}) end)

      {:ok,
       %{
         selected_ids: selected,
         imported_finalized_ids: finalized,
         infra_blocked_ids: blocked,
         pending_ids: MapSet.new(pending),
         assignments: assignments
       }}
    end
  end

  defp unique?(set, ids, label) do
    if MapSet.size(set) == length(ids), do: :ok, else: {:error, {:duplicate_ids, label}}
  end

  defp subset?(left, right, error) do
    if MapSet.subset?(left, right), do: :ok, else: {:error, error}
  end

  defp disjoint?(left, right, error) do
    if MapSet.disjoint?(left, right), do: :ok, else: {:error, error}
  end

  @doc false
  def cache_compatible_plan(shards, blocked_ids, shard_count)
      when is_list(shards) and is_list(blocked_ids) and shard_count > 0 do
    with {:ok, base} <- plan(shards, blocked_ids, shard_count),
         pending_by_parent = pending_by_parent(shards, base.pending_ids),
         {:ok, allocations} <- allocate_workers(pending_by_parent, shard_count) do
      assignments =
        allocations
        |> Enum.flat_map(fn {parent_shard, workers} ->
          ids = Map.fetch!(pending_by_parent, parent_shard)

          ids
          |> Enum.with_index()
          |> Enum.group_by(fn {_id, index} -> rem(index, workers) end, fn {id, _index} -> id end)
          |> Enum.sort()
          |> Enum.map(fn {_worker, assigned} -> %{parent_shard: parent_shard, ids: assigned} end)
        end)
        |> Enum.with_index(1)
        |> Map.new(fn {assignment, child_shard} -> {child_shard, assignment} end)

      {:ok, %{base | assignments: assignments}}
    end
  end

  defp pending_by_parent(shards, pending) do
    shards
    |> Enum.with_index(1)
    |> Map.new(fn {shard, index} ->
      ids = shard.selected_ids |> Enum.filter(&MapSet.member?(pending, &1)) |> Enum.sort()
      {Map.get(shard, :shard, index), ids}
    end)
    |> Map.reject(fn {_shard, ids} -> ids == [] end)
  end

  defp allocate_workers(pending_by_parent, shard_count)
       when map_size(pending_by_parent) > shard_count,
       do: {:error, :insufficient_cache_compatible_shards}

  defp allocate_workers(pending_by_parent, _shard_count) when map_size(pending_by_parent) == 0,
    do: {:error, :no_pending_mutations}

  defp allocate_workers(pending_by_parent, shard_count) do
    sources = Enum.sort_by(pending_by_parent, fn {shard, ids} -> {-length(ids), shard} end)
    remaining = shard_count - length(sources)

    [{largest, _ids} | _] = sources

    allocations =
      sources
      |> Enum.map(fn {shard, _ids} ->
        {shard, if(shard == largest, do: remaining + 1, else: 1)}
      end)
      |> Enum.sort()

    {:ok, allocations}
  end
end
