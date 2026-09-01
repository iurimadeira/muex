defmodule Muex.CampaignPlan do
  @moduledoc """
  Builds and validates immutable, content-addressed mutation campaign plans.

  A plan assigns whole source files to deterministic shards. It records the
  exact mutants and tests required by every file so executors do not need to
  rediscover campaign scope independently.
  """

  alias Muex.Continuation.Artifact
  alias Muex.Coverage

  @version 1

  @type plan :: map()

  @doc """
  Builds a campaign plan from the complete optimized mutation inventory and
  the complete non-eval source and test corpora.
  """
  @spec build(Path.t(), [map()], [Path.t()], [Path.t()], Coverage.t() | nil, keyword()) ::
          {:ok, plan()} | {:error, term()}
  def build(project_root, mutations, source_files, test_files, coverage_index, opts) do
    root = Path.expand(project_root)
    shard_count = Keyword.fetch!(opts, :shards)

    with :ok <- validate_shard_count(shard_count),
         :ok <- validate_mutations(mutations),
         :ok <- validate_coverage_binding(coverage_index, opts),
         {:ok, sources} <- fingerprint_paths(root, source_files),
         {:ok, tests} <- fingerprint_paths(root, test_files),
         {:ok, requirements} <- requirements(root, mutations, tests, coverage_index),
         {:ok, files} <- file_units(sources, requirements, tests, opts) do
      shards = assign_shards(files, shard_count)
      toolchain = toolchain()
      config_fingerprint = digest(Keyword.get(opts, :config, %{}))
      coverage_fingerprint = Keyword.fetch!(opts, :coverage_fingerprint)

      global_fingerprint =
        digest({
          "muex-campaign-global-v1",
          Enum.map(sources, &Map.take(&1, ~w(path sha256))),
          Enum.map(tests, &Map.take(&1, ~w(path sha256))),
          Enum.map(files, &{&1["path"], &1["fingerprint"]}),
          coverage_fingerprint,
          config_fingerprint,
          toolchain
        })

      plan = %{
        "version" => @version,
        "metadata" => %{
          "commit_sha" => Keyword.get(opts, :commit_sha),
          "audit_plan_sha256" => Keyword.get(opts, :audit_plan_sha256),
          "audit_optimizer" => Keyword.get(opts, :audit_optimizer)
        },
        "toolchain" => toolchain,
        "config_fingerprint" => config_fingerprint,
        "coverage" => %{
          "corpus_fingerprint" => coverage_fingerprint,
          "index_sha256" => Keyword.get(opts, :coverage_index_sha256)
        },
        "inputs" => %{"source_files" => sources, "test_files" => tests},
        "files" => files,
        "requirements" => requirements,
        "shards" => shards,
        "global_fingerprint" => global_fingerprint
      }

      {:ok, Map.put(plan, "plan_sha256", plan_digest(plan))}
    end
  end

  @doc "Validates the plan envelope and all source and test contents."
  @spec validate(Path.t(), plan()) :: :ok | {:error, term()}
  def validate(project_root, plan), do: validate(project_root, plan, [])

  @doc "Validates a plan against current content, toolchain, and optional config."
  @spec validate(Path.t(), plan(), keyword()) :: :ok | {:error, term()}
  def validate(project_root, %{"version" => @version} = plan, opts) do
    root = Path.expand(project_root)

    cond do
      plan["plan_sha256"] != plan |> Map.delete("plan_sha256") |> plan_digest() ->
        {:error, :campaign_plan_hash_mismatch}

      not valid_structure?(root, plan) ->
        {:error, :invalid_campaign_plan_structure}

      plan["toolchain"] != toolchain() ->
        {:error, :campaign_toolchain_mismatch}

      Keyword.has_key?(opts, :config) and
          plan["config_fingerprint"] != digest(Keyword.fetch!(opts, :config)) ->
        {:error, :campaign_config_mismatch}

      true ->
        stale =
          plan
          |> get_in(["inputs"])
          |> Map.values()
          |> List.flatten()
          |> Enum.filter(fn %{"path" => path, "sha256" => expected} ->
            file_digest(Path.join(root, path)) != {:ok, expected}
          end)
          |> Enum.map(& &1["path"])
          |> Enum.sort()

        if stale == [], do: :ok, else: {:error, {:stale_files, stale}}
    end
  end

  def validate(_project_root, _plan, _opts), do: {:error, :invalid_campaign_plan}

  defp valid_structure?(
         root,
         %{
           "config_fingerprint" => config_fingerprint,
           "coverage" => coverage,
           "global_fingerprint" => global_fingerprint,
           "inputs" => %{"source_files" => sources, "test_files" => tests},
           "metadata" => metadata,
           "toolchain" => plan_toolchain
         } = plan
       ) do
    valid_digest?(config_fingerprint) and valid_digest?(global_fingerprint) and
      valid_coverage?(coverage) and valid_metadata?(metadata) and
      valid_toolchain?(plan_toolchain) and valid_inputs?(root, sources) and
      valid_inputs?(root, tests) and valid_plan_relations?(plan)
  end

  defp valid_structure?(_root, _plan), do: false

  defp valid_coverage?(%{
         "corpus_fingerprint" => fingerprint,
         "index_sha256" => index_sha256
       }),
       do: valid_digest?(fingerprint) and (is_nil(index_sha256) or valid_digest?(index_sha256))

  defp valid_coverage?(_coverage), do: false

  defp valid_metadata?(%{
         "commit_sha" => commit_sha,
         "audit_plan_sha256" => audit_sha256,
         "audit_optimizer" => optimizer
       }),
       do:
         (is_nil(commit_sha) or is_binary(commit_sha)) and
           ((is_nil(audit_sha256) and is_nil(optimizer)) or
              (valid_digest?(audit_sha256) and is_map(optimizer)))

  defp valid_metadata?(_metadata), do: false

  defp valid_toolchain?(%{"elixir" => elixir, "muex" => muex, "otp" => otp}),
    do: Enum.all?([elixir, muex, otp], &(is_binary(&1) and &1 != ""))

  defp valid_toolchain?(_toolchain), do: false

  defp valid_inputs?(root, entries) when is_list(entries) do
    paths = Enum.map(entries, &Map.get(&1, "path"))

    paths == Enum.sort(paths) and length(paths) == length(Enum.uniq(paths)) and
      Enum.all?(entries, fn
        %{"path" => path, "sha256" => sha256} when is_binary(path) ->
          valid_digest?(sha256) and normalize_path(root, path) == {:ok, path}

        _entry ->
          false
      end)
  end

  defp valid_inputs?(_root, _entries), do: false

  defp valid_plan_relations?(%{
         "config_fingerprint" => config_fingerprint,
         "coverage" => coverage,
         "files" => files,
         "global_fingerprint" => global_fingerprint,
         "inputs" => %{"source_files" => sources, "test_files" => tests},
         "requirements" => requirements,
         "shards" => shards,
         "toolchain" => plan_toolchain
       })
       when is_list(files) and is_list(requirements) and is_list(shards) do
    source_map = Map.new(sources, &{&1["path"], &1["sha256"]})
    test_map = Map.new(tests, &{&1["path"], &1["sha256"]})

    valid_requirements?(requirements, source_map, test_map) and
      valid_files?(files, requirements, source_map, test_map, config_fingerprint, plan_toolchain) and
      valid_shards?(shards, files) and
      valid_global_fingerprint?(
        files,
        sources,
        tests,
        coverage,
        config_fingerprint,
        plan_toolchain,
        global_fingerprint
      )
  end

  defp valid_plan_relations?(_plan), do: false

  defp valid_requirements?(requirements, source_map, test_map) do
    ids = Enum.map(requirements, &Map.get(&1, "mutant_id"))

    ids == Enum.sort(ids) and length(ids) == length(Enum.uniq(ids)) and
      Enum.all?(requirements, &valid_requirement?(&1, source_map, test_map))
  end

  defp valid_requirement?(
         %{
           "estimated_work" => estimated_work,
           "fallback_reason" => fallback_reason,
           "line" => line,
           "mutant_id" => id,
           "source_file" => source_file,
           "test_files" => test_files
         },
         source_map,
         test_map
       ) do
    present_string?(id) and Map.has_key?(source_map, source_file) and
      sorted_subset?(test_files, Map.keys(test_map)) and is_integer(line) and line >= 0 and
      estimated_work == length(test_files) and
      (is_nil(fallback_reason) or present_string?(fallback_reason))
  end

  defp valid_requirement?(_requirement, _source_map, _test_map), do: false

  defp valid_files?(files, requirements, source_map, test_map, config_fingerprint, plan_toolchain) do
    paths = Enum.map(files, &Map.get(&1, "path"))

    paths == Enum.sort(paths) and paths == source_map |> Map.keys() |> Enum.sort() and
      Enum.all?(files, fn file ->
        valid_file?(
          file,
          requirements,
          source_map,
          test_map,
          config_fingerprint,
          plan_toolchain
        )
      end)
  end

  defp valid_file?(
         %{
           "estimated_work" => estimated_work,
           "fallback_reasons" => fallback_reasons,
           "fingerprint" => fingerprint,
           "mutant_ids" => mutant_ids,
           "path" => path,
           "sha256" => sha256,
           "test_files" => test_files
         },
         requirements,
         source_map,
         test_map,
         config_fingerprint,
         plan_toolchain
       ) do
    owned = Enum.filter(requirements, &(&1["source_file"] == path))
    expected_ids = Enum.map(owned, & &1["mutant_id"])
    expected_tests = owned |> Enum.flat_map(& &1["test_files"]) |> Enum.uniq() |> Enum.sort()

    expected_reasons =
      owned
      |> Enum.map(& &1["fallback_reason"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    expected_work = Enum.sum(Enum.map(owned, & &1["estimated_work"]))

    Map.get(source_map, path) == sha256 and mutant_ids == expected_ids and
      test_files == expected_tests and fallback_reasons == expected_reasons and
      estimated_work == expected_work and
      fingerprint ==
        file_fingerprint(
          path,
          sha256,
          test_files,
          test_map,
          config_fingerprint,
          plan_toolchain
        )
  end

  defp valid_file?(
         _file,
         _requirements,
         _source_map,
         _test_map,
         _config_fingerprint,
         _toolchain
       ),
       do: false

  defp valid_shards?(shards, files) when shards != [] do
    shard_numbers = Enum.map(shards, &Map.get(&1, "shard"))
    all_paths = Enum.map(files, & &1["path"])
    assigned_paths = Enum.flat_map(shards, &Map.get(&1, "source_files", []))

    shard_numbers == Enum.to_list(1..length(shards)) and Enum.sort(assigned_paths) == all_paths and
      length(assigned_paths) == length(Enum.uniq(assigned_paths)) and
      Enum.all?(shards, &valid_shard?(&1, files))
  end

  defp valid_shards?(_shards, _files), do: false

  defp valid_shard?(
         %{
           "estimated_work" => estimated_work,
           "fallback_reasons" => fallback_reasons,
           "mutant_ids" => mutant_ids,
           "source_files" => source_files,
           "test_files" => test_files
         },
         files
       ) do
    assigned = Enum.filter(files, &(&1["path"] in source_files))
    expected_ids = assigned |> Enum.flat_map(& &1["mutant_ids"]) |> Enum.sort()
    expected_tests = assigned |> Enum.flat_map(& &1["test_files"]) |> Enum.uniq() |> Enum.sort()

    expected_reasons =
      assigned |> Enum.flat_map(& &1["fallback_reasons"]) |> Enum.uniq() |> Enum.sort()

    source_files == Enum.sort(source_files) and mutant_ids == expected_ids and
      test_files == expected_tests and fallback_reasons == expected_reasons and
      estimated_work == Enum.sum(Enum.map(assigned, & &1["estimated_work"]))
  end

  defp valid_shard?(_shard, _files), do: false

  defp valid_global_fingerprint?(
         files,
         sources,
         tests,
         coverage,
         config_fingerprint,
         plan_toolchain,
         expected
       ) do
    expected ==
      digest({
        "muex-campaign-global-v1",
        Enum.map(sources, &Map.take(&1, ~w(path sha256))),
        Enum.map(tests, &Map.take(&1, ~w(path sha256))),
        Enum.map(files, &{&1["path"], &1["fingerprint"]}),
        coverage["corpus_fingerprint"],
        config_fingerprint,
        plan_toolchain
      })
  end

  defp sorted_subset?(values, allowed) when is_list(values) do
    values == Enum.sort(values) and length(values) == length(Enum.uniq(values)) and
      Enum.all?(values, &(&1 in allowed))
  end

  defp sorted_subset?(_values, _allowed), do: false

  defp present_string?(value), do: is_binary(value) and value != ""

  @doc "Writes a campaign plan atomically without following symlink components."
  @spec write(plan(), Path.t()) :: :ok | {:error, term()}
  def write(plan, path), do: Artifact.publish_json(path, plan)

  @doc "Writes a validated execution slice atomically."
  @spec write_execution_slice(map(), Path.t()) :: :ok | {:error, term()}
  def write_execution_slice(
        %{
          "plan_sha256" => plan_sha256,
          "source_files" => source_files,
          "mutant_ids" => mutant_ids,
          "test_files" => test_files,
          "requirements" => requirements
        } = slice,
        path
      )
      when is_binary(plan_sha256) and is_list(source_files) and is_list(mutant_ids) and
             is_list(test_files) and is_list(requirements) do
    with :ok <- validate_slice_digest(slice),
         :ok <- validate_slice_structure(slice) do
      Artifact.publish_json(path, slice)
    end
  end

  def write_execution_slice(_slice, _path), do: {:error, :invalid_campaign_slice}

  @doc "Reads an execution slice bound to trusted artifact bytes and its content digest."
  @spec read_execution_slice(Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read_execution_slice(path, expected_sha256) do
    with true <- valid_digest?(expected_sha256),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, contents} <- File.read(path),
         true <- sha256(contents) == expected_sha256,
         {:ok, slice} <- Jason.decode(contents),
         :ok <- validate_slice_digest(slice),
         :ok <- validate_slice_structure(slice) do
      {:ok, slice}
    else
      false ->
        {:error, :campaign_slice_artifact_hash_mismatch}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:invalid_campaign_slice_type, type}}

      {:error, reason}
      when reason in [:invalid_campaign_slice_digest, :invalid_campaign_slice_structure] ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:cannot_read_campaign_slice, reason}}
    end
  end

  @doc "Reads a campaign plan and verifies its content-addressed envelope."
  @spec read(Path.t()) :: {:ok, plan()} | {:error, term()}
  def read(path), do: read_plan(path, nil)

  @doc "Reads a campaign plan only when its bytes match a trusted digest."
  @spec read(Path.t(), String.t()) :: {:ok, plan()} | {:error, term()}
  def read(path, expected_sha256) when is_binary(expected_sha256) do
    if valid_digest?(expected_sha256),
      do: read_plan(path, expected_sha256),
      else: {:error, :invalid_expected_plan_sha256}
  end

  defp read_plan(path, expected_sha256) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, contents} <- File.read(path),
         :ok <- validate_artifact_digest(contents, expected_sha256),
         {:ok, plan} <- Jason.decode(contents),
         :ok <- validate_plan_hash(plan) do
      {:ok, plan}
    else
      {:ok, %File.Stat{type: type}} ->
        {:error, {:invalid_campaign_plan_type, type}}

      {:error, reason}
      when reason in [
             :campaign_plan_hash_mismatch,
             :campaign_plan_artifact_hash_mismatch,
             :invalid_campaign_plan
           ] ->
        {:error, reason}

      {:error, reason} when is_atom(reason) ->
        {:error, {:cannot_read_campaign_plan, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_artifact_digest(_contents, nil), do: :ok

  defp validate_artifact_digest(contents, expected) do
    if sha256(contents) == expected,
      do: :ok,
      else: {:error, :campaign_plan_artifact_hash_mismatch}
  end

  @doc "Returns one one-based shard slice from a validated plan."
  @spec slice(plan(), pos_integer()) :: {:ok, map()} | {:error, :unknown_shard}
  def slice(%{"shards" => shards}, shard_number) when is_integer(shard_number) do
    case Enum.find(shards, &(&1["shard"] == shard_number)) do
      nil -> {:error, :unknown_shard}
      shard -> {:ok, shard}
    end
  end

  @doc """
  Materializes a shard for execution after validating the global plan and
  coverage artifact. A missing or stale artifact expands only this shard to
  the full declared test corpus.
  """
  @spec execution_slice(Path.t(), plan(), pos_integer(), Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def execution_slice(project_root, plan, shard_number, coverage_index_path, opts) do
    with :ok <- validate(project_root, plan, opts),
         {:ok, shard} <- slice(plan, shard_number) do
      requirements =
        Enum.filter(plan["requirements"], &(&1["mutant_id"] in shard["mutant_ids"]))

      case coverage_status(plan["coverage"], coverage_index_path) do
        "stale" ->
          full_tests = Enum.map(plan["inputs"]["test_files"], & &1["path"])

          requirements =
            Enum.map(requirements, fn requirement ->
              requirement
              |> Map.put("test_files", full_tests)
              |> Map.put("fallback_reason", "coverage_artifact_stale")
              |> Map.put("estimated_work", length(full_tests))
            end)

          slice =
            shard
            |> Map.put("test_files", full_tests)
            |> Map.put("fallback_reasons", ["coverage_artifact_stale"])
            |> Map.put("estimated_work", length(requirements) * length(full_tests))
            |> execution_metadata(plan, requirements, "stale", opts)

          {:ok, seal_slice(slice)}

        status ->
          {:ok, shard |> execution_metadata(plan, requirements, status, opts) |> seal_slice()}
      end
    end
  end

  defp execution_metadata(shard, plan, requirements, status, opts) do
    shard
    |> Map.put("requirements", requirements)
    |> Map.put("plan_sha256", plan["plan_sha256"])
    |> Map.put("plan_artifact_sha256", Keyword.fetch!(opts, :plan_artifact_sha256))
    |> Map.put("global_fingerprint", plan["global_fingerprint"])
    |> Map.put("coverage", %{
      "status" => status,
      "corpus_fingerprint" => plan["coverage"]["corpus_fingerprint"],
      "index_sha256" => plan["coverage"]["index_sha256"]
    })
  end

  defp coverage_status(%{"index_sha256" => nil}, _path), do: "unavailable"

  defp coverage_status(
         %{"index_sha256" => expected_sha256, "corpus_fingerprint" => fingerprint},
         path
       )
       when is_binary(path) do
    case Coverage.read_bound_index_snapshot(path, fingerprint) do
      {:ok, %{sha256: ^expected_sha256}} -> "valid"
      _invalid -> "stale"
    end
  end

  defp coverage_status(_coverage, _path), do: "stale"

  defp seal_slice(slice), do: Map.put(slice, "slice_sha256", slice_digest(slice))

  defp valid_slice_digest?(%{"slice_sha256" => expected} = slice) when is_binary(expected),
    do: slice |> Map.delete("slice_sha256") |> slice_digest() == expected

  defp valid_slice_digest?(_slice), do: false

  defp validate_slice_digest(slice) do
    if valid_slice_digest?(slice), do: :ok, else: {:error, :invalid_campaign_slice_digest}
  end

  defp validate_slice_structure(%{
         "coverage" => %{
           "corpus_fingerprint" => corpus_fingerprint,
           "index_sha256" => index_sha256,
           "status" => status
         },
         "estimated_work" => estimated_work,
         "fallback_reasons" => fallback_reasons,
         "global_fingerprint" => global_fingerprint,
         "mutant_ids" => mutant_ids,
         "plan_artifact_sha256" => plan_artifact_sha256,
         "plan_sha256" => plan_sha256,
         "requirements" => requirements,
         "shard" => shard,
         "source_files" => source_files,
         "test_files" => test_files
       }) do
    requirement_ids = Enum.map(requirements, &Map.get(&1, "mutant_id"))

    valid =
      valid_slice_identity?(
        shard,
        plan_sha256,
        plan_artifact_sha256,
        global_fingerprint,
        corpus_fingerprint,
        index_sha256,
        status
      ) and
        valid_slice_lists?(source_files, test_files, fallback_reasons, mutant_ids) and
        mutant_ids == requirement_ids and
        Enum.all?(requirements, &valid_slice_requirement?(&1, source_files, test_files)) and
        estimated_work == Enum.sum(Enum.map(requirements, & &1["estimated_work"]))

    if valid, do: :ok, else: {:error, :invalid_campaign_slice_structure}
  end

  defp validate_slice_structure(_slice), do: {:error, :invalid_campaign_slice_structure}

  defp valid_slice_identity?(
         shard,
         plan_sha256,
         plan_artifact_sha256,
         global_fingerprint,
         corpus_fingerprint,
         index_sha256,
         status
       ) do
    is_integer(shard) and shard > 0 and valid_digest?(plan_sha256) and
      valid_digest?(plan_artifact_sha256) and valid_digest?(global_fingerprint) and
      valid_digest?(corpus_fingerprint) and
      (is_nil(index_sha256) or valid_digest?(index_sha256)) and
      status in ~w(valid stale unavailable)
  end

  defp valid_slice_lists?(source_files, test_files, fallback_reasons, mutant_ids) do
    sorted_subset?(source_files, source_files) and sorted_subset?(test_files, test_files) and
      sorted_subset?(fallback_reasons, fallback_reasons) and
      sorted_subset?(mutant_ids, mutant_ids)
  end

  defp valid_slice_requirement?(requirement, source_files, test_files) do
    case requirement do
      %{
        "estimated_work" => work,
        "fallback_reason" => reason,
        "line" => line,
        "mutant_id" => id,
        "source_file" => source,
        "test_files" => tests
      } ->
        present_string?(id) and source in source_files and sorted_subset?(tests, test_files) and
          is_integer(line) and line >= 0 and work == length(tests) and
          (is_nil(reason) or present_string?(reason))

      _invalid ->
        false
    end
  end

  defp slice_digest(slice), do: digest({"muex-campaign-slice-v1", slice})

  @doc """
  Rebalances pending mutations for a continuation without changing their IDs
  or recorded source/test requirements. Source files remain atomic units.
  """
  @spec continuation(plan(), [String.t()], pos_integer()) :: {:ok, map()} | {:error, term()}
  def continuation(plan, pending_ids, shard_count) do
    requested = MapSet.new(pending_ids)
    available = MapSet.new(plan["requirements"], & &1["mutant_id"])
    missing = requested |> MapSet.difference(available) |> Enum.sort()

    with :ok <- validate_plan_hash(plan),
         :ok <- validate_shard_count(shard_count),
         true <- MapSet.size(requested) == length(pending_ids),
         [] <- missing do
      requirements =
        plan["requirements"]
        |> Enum.filter(&MapSet.member?(requested, &1["mutant_id"]))
        |> Enum.sort_by(& &1["mutant_id"])

      by_file = Enum.group_by(requirements, & &1["source_file"])
      original_files = Map.new(plan["files"], &{&1["path"], &1})

      files =
        by_file
        |> Enum.map(fn {path, file_requirements} ->
          original = Map.fetch!(original_files, path)

          original
          |> Map.put("mutant_ids", Enum.map(file_requirements, & &1["mutant_id"]))
          |> Map.put(
            "test_files",
            file_requirements |> Enum.flat_map(& &1["test_files"]) |> Enum.uniq() |> Enum.sort()
          )
          |> Map.put(
            "fallback_reasons",
            file_requirements
            |> Enum.map(& &1["fallback_reason"])
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()
            |> Enum.sort()
          )
          |> Map.put(
            "estimated_work",
            Enum.sum(Enum.map(file_requirements, & &1["estimated_work"]))
          )
        end)

      shards =
        files
        |> assign_shards(shard_count)
        |> Enum.map(fn shard ->
          shard_requirements =
            Enum.filter(requirements, &(&1["mutant_id"] in shard["mutant_ids"]))

          Map.put(shard, "requirements", shard_requirements)
        end)

      artifact = %{
        "version" => @version,
        "parent_plan_sha256" => plan["plan_sha256"],
        "global_fingerprint" => plan["global_fingerprint"],
        "selected_ids" => Enum.sort(pending_ids),
        "shards" => shards
      }

      {:ok, Map.put(artifact, "continuation_sha256", digest(artifact))}
    else
      false -> {:error, :duplicate_continuation_ids}
      [_ | _] = ids -> {:error, {:unknown_continuation_ids, ids}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_plan_hash(%{"version" => @version, "plan_sha256" => expected} = plan)
       when is_binary(expected) do
    if plan |> Map.delete("plan_sha256") |> plan_digest() == expected,
      do: :ok,
      else: {:error, :campaign_plan_hash_mismatch}
  end

  defp validate_plan_hash(_plan), do: {:error, :invalid_campaign_plan}

  defp requirements(root, mutations, tests, coverage_index) do
    declared_tests = Map.new(tests, &{&1["path"], &1})

    mutations
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while({:ok, []}, fn mutation, {:ok, acc} ->
      file = normalize_path(root, mutation.location.file)

      with {:ok, file} <- file,
           {:ok, selected, reason} <-
             selected_tests(root, mutation, file, coverage_index, declared_tests) do
        requirement = %{
          "mutant_id" => mutation.id,
          "source_file" => file,
          "line" => mutation.location.line,
          "test_files" => selected,
          "fallback_reason" => reason,
          "estimated_work" => length(selected)
        }

        {:cont, {:ok, [requirement | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, requirements} -> {:ok, Enum.reverse(requirements)}
      error -> error
    end
  end

  defp selected_tests(_root, _mutation, _file, nil, declared_tests) do
    {:ok, declared_tests |> Map.keys() |> Enum.sort(), "coverage_unavailable"}
  end

  defp selected_tests(root, mutation, file, coverage_index, declared_tests) do
    case Coverage.tests_for(coverage_index, file, mutation.location.line) do
      {:covered, paths} -> declared_coverage_tests(root, paths, declared_tests, nil)
      :no_coverage -> {:ok, [], nil}
      :unknown -> unknown_tests(root, file, coverage_index, declared_tests)
    end
  end

  defp unknown_tests(root, file, coverage_index, declared_tests) do
    case Coverage.tests_for_file(coverage_index, file) do
      [] -> {:ok, declared_tests |> Map.keys() |> Enum.sort(), "unknown_without_file_evidence"}
      paths -> declared_coverage_tests(root, paths, declared_tests, "unknown_with_file_evidence")
    end
  end

  defp declared_coverage_tests(root, paths, declared_tests, reason) do
    with {:ok, normalized} <- normalize_paths(root, paths) do
      undeclared = Enum.reject(normalized, &Map.has_key?(declared_tests, &1))

      if undeclared == [],
        do: {:ok, normalized, reason},
        else: {:error, {:coverage_references_undeclared_tests, undeclared}}
    end
  end

  defp file_units(sources, requirements, tests, opts) do
    config_fingerprint = digest(Keyword.get(opts, :config, %{}))
    toolchain = toolchain()
    by_file = Enum.group_by(requirements, & &1["source_file"])
    test_fingerprints = Map.new(tests, &{&1["path"], &1["sha256"]})

    files =
      Enum.map(sources, fn source ->
        file_requirements = Map.get(by_file, source["path"], [])

        relevant_tests =
          file_requirements |> Enum.flat_map(& &1["test_files"]) |> Enum.uniq() |> Enum.sort()

        mutant_ids = Enum.map(file_requirements, & &1["mutant_id"])

        fallback_reasons =
          file_requirements
          |> Enum.map(& &1["fallback_reason"])
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort()

        estimated_work = Enum.sum(Enum.map(file_requirements, & &1["estimated_work"]))

        fingerprint =
          file_fingerprint(
            source["path"],
            source["sha256"],
            relevant_tests,
            test_fingerprints,
            config_fingerprint,
            toolchain
          )

        %{
          "path" => source["path"],
          "sha256" => source["sha256"],
          "mutant_ids" => mutant_ids,
          "test_files" => relevant_tests,
          "fallback_reasons" => fallback_reasons,
          "estimated_work" => estimated_work,
          "fingerprint" => fingerprint
        }
      end)

    unknown_sources =
      by_file
      |> Map.keys()
      |> Enum.reject(&Enum.any?(sources, fn source -> source["path"] == &1 end))

    if unknown_sources == [],
      do: {:ok, files},
      else: {:error, {:mutations_outside_source_corpus, Enum.sort(unknown_sources)}}
  end

  defp assign_shards(files, shard_count) do
    initial = for shard <- 1..shard_count, do: %{shard: shard, work: 0, files: []}

    files
    |> Enum.sort_by(&{-&1["estimated_work"], &1["path"]})
    |> Enum.reduce(initial, fn file, shards ->
      target = Enum.min_by(shards, &{&1.work, &1.shard})

      Enum.map(shards, fn shard ->
        if shard.shard == target.shard,
          do: %{shard | work: shard.work + file["estimated_work"], files: [file | shard.files]},
          else: shard
      end)
    end)
    |> Enum.map(fn shard ->
      assigned = Enum.sort_by(shard.files, & &1["path"])

      %{
        "shard" => shard.shard,
        "source_files" => Enum.map(assigned, & &1["path"]),
        "mutant_ids" => assigned |> Enum.flat_map(& &1["mutant_ids"]) |> Enum.sort(),
        "test_files" =>
          assigned |> Enum.flat_map(& &1["test_files"]) |> Enum.uniq() |> Enum.sort(),
        "fallback_reasons" =>
          assigned |> Enum.flat_map(& &1["fallback_reasons"]) |> Enum.uniq() |> Enum.sort(),
        "estimated_work" => shard.work
      }
    end)
  end

  defp file_fingerprint(
         path,
         source_sha256,
         relevant_tests,
         test_fingerprints,
         config_fingerprint,
         plan_toolchain
       ) do
    digest({
      "muex-campaign-file-v1",
      path,
      source_sha256,
      Enum.map(relevant_tests, &{&1, Map.fetch!(test_fingerprints, &1)}),
      config_fingerprint,
      plan_toolchain
    })
  end

  defp fingerprint_paths(root, paths) do
    with {:ok, normalized} <- normalize_paths(root, paths) do
      normalized
      |> Enum.map(fn path ->
        case file_digest(Path.join(root, path)) do
          {:ok, sha256} -> {:ok, %{"path" => path, "sha256" => sha256}}
          {:error, reason} -> {:error, {:cannot_fingerprint, path, reason}}
        end
      end)
      |> collect_results()
    end
  end

  defp normalize_paths(root, paths) do
    paths
    |> Enum.map(&normalize_path(root, &1))
    |> collect_results()
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp normalize_path(root, path) when is_binary(path) do
    expanded = Path.expand(path, root)
    relative = Path.relative_to(expanded, root)

    with true <-
           relative != expanded and relative != ".." and not String.starts_with?(relative, "../"),
         {:ok, _canonical} <- Artifact.validate_snapshot_path(root, relative) do
      {:ok, relative}
    else
      _unsafe -> {:error, {:unsafe_campaign_path, path}}
    end
  end

  defp normalize_path(_root, path), do: {:error, {:unsafe_campaign_path, path}}

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp validate_shard_count(count) when is_integer(count) and count > 0, do: :ok
  defp validate_shard_count(_count), do: {:error, :invalid_shard_count}

  defp validate_mutations(mutations) when is_list(mutations) do
    ids = Enum.map(mutations, &Map.get(&1, :id))

    cond do
      Enum.any?(ids, &(not is_binary(&1) or &1 == "")) -> {:error, :invalid_mutation_id}
      length(Enum.uniq(ids)) != length(ids) -> {:error, :duplicate_mutation_ids}
      true -> :ok
    end
  end

  defp validate_mutations(_mutations), do: {:error, :invalid_mutation_inventory}

  defp validate_coverage_binding(nil, opts) do
    if valid_digest?(Keyword.fetch!(opts, :coverage_fingerprint)),
      do: :ok,
      else: {:error, :invalid_coverage_binding}
  end

  defp validate_coverage_binding(_index, opts) do
    fingerprint = Keyword.fetch!(opts, :coverage_fingerprint)
    index_sha256 = Keyword.get(opts, :coverage_index_sha256)

    cond do
      not valid_digest?(fingerprint) -> {:error, :invalid_coverage_binding}
      is_nil(index_sha256) -> {:error, :unbound_coverage_index}
      not valid_digest?(index_sha256) -> {:error, :invalid_coverage_binding}
      true -> :ok
    end
  end

  defp toolchain do
    %{
      "muex" => to_string(Application.spec(:muex, :vsn)),
      "elixir" => System.version(),
      "otp" => to_string(:erlang.system_info(:otp_release))
    }
  end

  defp file_digest(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, sha256(contents)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp plan_digest(plan), do: digest({"muex-campaign-plan-v1", plan})
  defp valid_digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp digest(term), do: term |> :erlang.term_to_binary() |> sha256()
  defp sha256(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)
end
