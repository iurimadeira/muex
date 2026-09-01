defmodule Muex.InventoryCache do
  @moduledoc false

  @version 1

  def load(nil, nil, _input_fingerprint, _audit_dir), do: :disabled

  def load(path, cache_key, input_fingerprint, audit_dir) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :miss

      {:ok, %File.Stat{type: :regular}} ->
        with {:ok, envelope} <- read_envelope(path),
             :ok <- validate_envelope(envelope, cache_key, input_fingerprint),
             :ok <- validate_plan(path, envelope),
             :ok <- materialize_plan(path, audit_dir) do
          {:ok, envelope.mutations, metadata(path, envelope, "hit")}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, "invalid mutation inventory cache type: #{type}"}

      {:error, reason} ->
        {:error, "cannot inspect mutation inventory cache: #{:file.format_error(reason)}"}
    end
  end

  def publish(path, cache_key, input_fingerprint, mutations, plan_path) do
    envelope = envelope(path, cache_key, input_fingerprint, mutations, plan_path)

    with :ok <- validate_envelope(envelope, cache_key, input_fingerprint),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- publish_plan(plan_path, cached_plan_path(path), envelope),
         :ok <- publish_envelope(path, envelope) do
      {:ok, metadata(path, envelope, "miss")}
    end
  end

  @doc false
  def import_subset(parent_path, child_path, ids) when is_list(ids) do
    requested = MapSet.new(ids)

    cond do
      Path.expand(parent_path) == Path.expand(child_path) ->
        {:error, "parent and child mutation inventory caches must differ"}

      MapSet.size(requested) != length(ids) ->
        {:error, "subset mutant ids contain duplicates"}

      true ->
        do_import_subset(parent_path, child_path, requested)
    end
  end

  def write_provenance(nil, _metadata), do: :ok

  def write_provenance(audit_dir, metadata) do
    path = Path.join(audit_dir, "inventory-cache.json")
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(audit_dir),
         :ok <- File.write(temporary, Jason.encode!(metadata, pretty: true), [:binary, :sync]) do
      File.rename(temporary, path)
    end
  end

  defp do_import_subset(parent_path, child_path, requested) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(parent_path),
         {:ok, envelope} <- read_envelope(parent_path),
         :ok <- validate_envelope(envelope, envelope.cache_key, envelope.input_fingerprint),
         :ok <- validate_plan(parent_path, envelope),
         {:ok, plan} <- read_plan(cached_plan_path(parent_path)),
         :ok <- validate_plan_inventory(plan, envelope),
         :ok <- validate_requested_ids(requested, envelope),
         selected = Enum.filter(envelope.mutations, &MapSet.member?(requested, &1.id)),
         rewritten = rewrite_plan(plan, requested),
         :ok <- File.mkdir_p(Path.dirname(child_path)),
         temporary_plan = child_path <> ".import-plan.#{System.unique_integer([:positive])}",
         :ok <-
           File.write(temporary_plan, Jason.encode!(rewritten, pretty: true), [:binary, :sync]),
         result =
           publish(
             child_path,
             envelope.cache_key,
             envelope.input_fingerprint,
             selected,
             temporary_plan
           ),
         :ok <- File.rm(temporary_plan),
         {:ok, metadata} <- result do
      {:ok,
       metadata
       |> Map.put(:status, "imported_subset")
       |> Map.put(:parent_cache_file, parent_path)
       |> Map.put(:parent_cache_sha256, digest_file(parent_path))
       |> Map.put(:parent_plan_sha256, digest_file(cached_plan_path(parent_path)))}
    else
      {:ok, %File.Stat{type: type}} ->
        {:error, "invalid parent mutation inventory cache type: #{type}"}

      {:error, :enoent} ->
        {:error, "parent mutation inventory cache is missing"}

      {:error, reason} when is_atom(reason) ->
        {:error, "cannot import mutation inventory cache: #{:file.format_error(reason)}"}

      {:error, _reason} = error ->
        error
    end
  end

  defp read_plan(path) do
    case File.read(path) do
      {:ok, contents} ->
        Jason.decode(contents)

      {:error, reason} ->
        {:error, "cannot read mutation inventory cache plan: #{:file.format_error(reason)}"}
    end
  end

  defp validate_plan_inventory(
         %{"mutants" => mutants, "selected_count" => selected_count},
         envelope
       )
       when is_list(mutants) do
    selected_ids = for %{"id" => id, "selected" => true} <- mutants, do: id
    envelope_ids = Enum.map(envelope.mutations, & &1.id)
    mutant_ids = Enum.map(mutants, &Map.get(&1, "id"))

    cond do
      Enum.any?(mutant_ids, &(not is_binary(&1))) ->
        {:error, "invalid mutation inventory cache plan mutants"}

      MapSet.size(MapSet.new(mutant_ids)) != length(mutant_ids) ->
        {:error, "mutation inventory cache plan has duplicate ids"}

      selected_count != length(selected_ids) ->
        {:error, "mutation inventory cache plan selected count mismatch"}

      MapSet.new(selected_ids) != MapSet.new(envelope_ids) ->
        {:error, "mutation inventory cache plan selected ids mismatch"}

      true ->
        :ok
    end
  end

  defp validate_plan_inventory(_plan, _envelope),
    do: {:error, "invalid mutation inventory cache plan"}

  defp validate_requested_ids(requested, envelope) do
    available = MapSet.new(envelope.mutations, & &1.id)
    missing = requested |> MapSet.difference(available) |> Enum.sort()

    if missing == [],
      do: :ok,
      else: {:error, "unknown subset mutant ids: #{Enum.join(missing, ", ")}"}
  end

  defp rewrite_plan(plan, requested) do
    mutants =
      plan["mutants"]
      |> Enum.filter(&MapSet.member?(requested, &1["id"]))
      |> Enum.map(fn mutant ->
        mutant
        |> Map.put("selected", true)
        |> Map.put("selection_reason", "selected_by_continuation")
      end)

    plan
    |> Map.put("exhaustive", plan["source_file_count"] == plan["selected_source_file_count"])
    |> Map.put("candidate_count", MapSet.size(requested))
    |> Map.put("selected_count", MapSet.size(requested))
    |> Map.put("mutants", mutants)
  end

  defp envelope(path, cache_key, input_fingerprint, mutations, plan_path) do
    %File.Stat{size: plan_bytes} = File.stat!(plan_path)

    %{
      version: @version,
      cache_key: cache_key,
      input_fingerprint: input_fingerprint,
      selected_count: length(mutations),
      ids_sha256: digest(Enum.map(mutations, & &1.id)),
      locations_sha256: digest(Enum.map(mutations, & &1.location)),
      mutations: mutations,
      plan_sha256: digest_file(plan_path),
      plan_bytes: plan_bytes,
      plan_name: Path.basename(cached_plan_path(path))
    }
  end

  defp validate_envelope(
         %{
           version: @version,
           cache_key: cache_key,
           input_fingerprint: input_fingerprint,
           selected_count: selected_count,
           ids_sha256: ids_sha256,
           locations_sha256: locations_sha256,
           mutations: mutations,
           plan_sha256: plan_sha256,
           plan_bytes: plan_bytes,
           plan_name: plan_name
         },
         expected_key,
         expected_input
       ) do
    with :ok <- valid?(cache_key == expected_key, "mutation inventory cache key mismatch"),
         :ok <-
           valid?(
             input_fingerprint == expected_input,
             "mutation inventory cache input fingerprint mismatch"
           ),
         :ok <-
           valid?(
             is_list(mutations) and Enum.all?(mutations, &valid_mutation?/1),
             "invalid mutation inventory cache mutations"
           ),
         :ok <-
           valid?(selected_count == length(mutations), "mutation inventory cache count mismatch"),
         :ok <-
           valid?(
             ids_sha256 == digest(Enum.map(mutations, & &1.id)),
             "mutation inventory cache id digest mismatch"
           ),
         :ok <-
           valid?(
             locations_sha256 == digest(Enum.map(mutations, & &1.location)),
             "mutation inventory cache location digest mismatch"
           ),
         :ok <-
           valid?(
             MapSet.size(MapSet.new(mutations, & &1.id)) == selected_count,
             "mutation inventory cache contains duplicate ids"
           ),
         :ok <-
           valid?(
             valid_digest?(plan_sha256) and is_integer(plan_bytes) and plan_bytes >= 0,
             "invalid mutation inventory cache plan metadata"
           ) do
      valid?(
        plan_name != "" and Path.basename(plan_name) == plan_name,
        "invalid mutation inventory cache plan name"
      )
    end
  end

  defp validate_envelope(_envelope, _expected_key, _expected_input),
    do: {:error, "invalid mutation inventory cache envelope"}

  defp valid?(true, _message), do: :ok
  defp valid?(false, message), do: {:error, message}

  defp valid_mutation?(%{
         id: id,
         ast: _ast,
         original_ast: _original_ast,
         mutator: mutator,
         description: description,
         location: %{file: file, line: line}
       }) do
    valid_digest?(id) and is_atom(mutator) and is_binary(description) and is_binary(file) and
      is_integer(line) and line >= 0
  end

  defp valid_mutation?(_mutation), do: false

  defp validate_plan(path, envelope) do
    plan_path = cached_plan_path(path)

    case File.lstat(plan_path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        cond do
          size != envelope.plan_bytes ->
            {:error, "mutation inventory cache plan size mismatch"}

          digest_file(plan_path) != envelope.plan_sha256 ->
            {:error, "mutation inventory cache plan digest mismatch"}

          true ->
            :ok
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, "invalid mutation inventory cache plan type: #{type}"}

      {:error, reason} ->
        {:error, "cannot inspect mutation inventory cache plan: #{:file.format_error(reason)}"}
    end
  end

  defp materialize_plan(cache_path, audit_dir) do
    destination = Path.join(audit_dir, "plan.json")

    with :ok <- File.mkdir_p(audit_dir) do
      case File.ln(cached_plan_path(cache_path), destination) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, "cannot link cached mutation plan: #{:file.format_error(reason)}"}
      end
    end
  end

  defp publish_plan(source, destination, envelope) do
    case File.ln(source, destination) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.lstat(destination) do
          {:ok, %File.Stat{type: :regular, size: size}}
          when size == envelope.plan_bytes ->
            if digest_file(destination) == envelope.plan_sha256,
              do: :ok,
              else: {:error, "existing mutation inventory plan digest mismatch"}

          _other ->
            {:error, "existing mutation inventory plan is invalid"}
        end

      {:error, reason} ->
        {:error, "cannot publish mutation inventory plan: #{:file.format_error(reason)}"}
    end
  end

  defp publish_envelope(path, envelope) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    case File.write(temporary, encode(envelope), [:binary, :exclusive, :sync]) do
      :ok ->
        result =
          case File.ln(temporary, path) do
            :ok ->
              :ok

            {:error, :eexist} ->
              validate_existing(path, envelope)

            {:error, reason} ->
              {:error, "cannot publish mutation inventory cache: #{:file.format_error(reason)}"}
          end

        _ = File.rm(temporary)
        result

      {:error, reason} ->
        {:error, "cannot write mutation inventory cache: #{:file.format_error(reason)}"}
    end
  end

  defp validate_existing(path, expected) do
    with {:ok, actual} <- read_envelope(path),
         :ok <- validate_envelope(actual, expected.cache_key, expected.input_fingerprint) do
      if actual.ids_sha256 == expected.ids_sha256 and actual.plan_sha256 == expected.plan_sha256,
        do: :ok,
        else: {:error, "existing mutation inventory cache differs"}
    end
  end

  defp read_envelope(path) do
    case File.read(path) do
      {:ok, binary} ->
        decode(binary)

      {:error, reason} ->
        {:error, "cannot read mutation inventory cache: #{:file.format_error(reason)}"}
    end
  end

  # A `:safe` decode cannot create atoms, and a reader such as
  # `mix muex.continuation prepare` never runs a mutator, so the cache ships the
  # name of every atom it contains — Muex's own map keys and whatever the
  # mutators synthesized into the cached AST alike — as a list of binaries the
  # reader interns before decoding the envelope itself. The outer term holds no
  # atom, so it always decodes under `:safe`.
  @max_cached_atoms 100_000

  defp encode(envelope) do
    names = envelope |> collect_atoms(%{}) |> Map.keys() |> Enum.map(&Atom.to_string/1)
    :erlang.term_to_binary({names, :erlang.term_to_binary(envelope)}, compressed: 6)
  end

  defp collect_atoms(atom, acc) when is_atom(atom), do: Map.put(acc, atom, true)
  defp collect_atoms([], acc), do: acc
  defp collect_atoms([head | tail], acc), do: collect_atoms(tail, collect_atoms(head, acc))

  defp collect_atoms(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> collect_atoms(acc)

  defp collect_atoms(map, acc) when is_map(map), do: map |> Map.to_list() |> collect_atoms(acc)

  # Numbers, binaries, and bitstrings are the remaining leaves and carry no atom;
  # pids, refs, ports, and funs cannot survive a `:safe` decode anyway.
  defp collect_atoms(_leaf, acc), do: acc

  defp decode(binary) do
    case safe_decode(binary) do
      {:ok, {names, payload}} when is_binary(payload) ->
        with :ok <- intern_atoms(names), do: safe_decode(payload)

      {:ok, _other} ->
        {:error, "invalid mutation inventory cache ETF"}

      error ->
        error
    end
  end

  defp intern_atoms(names) when is_list(names) do
    if length(names) <= @max_cached_atoms and Enum.all?(names, &is_binary/1) do
      Enum.each(names, &String.to_atom/1)
      :ok
    else
      {:error, "invalid mutation inventory cache atom table"}
    end
  rescue
    _error in [ArgumentError, SystemLimitError] ->
      {:error, "invalid mutation inventory cache atom table"}
  end

  defp intern_atoms(_names), do: {:error, "invalid mutation inventory cache atom table"}

  defp safe_decode(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    _error in ArgumentError -> {:error, "invalid mutation inventory cache ETF"}
  end

  defp metadata(path, envelope, status) do
    %{
      version: @version,
      status: status,
      cache_key: envelope.cache_key,
      cache_file: path,
      input_fingerprint: envelope.input_fingerprint,
      selected_count: envelope.selected_count,
      ids_sha256: envelope.ids_sha256,
      locations_sha256: envelope.locations_sha256,
      plan_sha256: envelope.plan_sha256,
      plan_bytes: envelope.plan_bytes
    }
  end

  defp cached_plan_path(path), do: Path.rootname(path, ".etf") <> ".plan.json"

  defp valid_digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)

  defp digest(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value))
    |> Base.encode16(case: :lower)
  end

  defp digest_file(path) do
    path
    |> File.stream!(1_048_576, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
