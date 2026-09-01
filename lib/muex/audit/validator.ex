defmodule Muex.Audit.Validator do
  @moduledoc false

  @version 1
  @statuses ~w(killed survived invalid timeout equivalent no_coverage no_op)
  @valid_mutant_keys ~w(
    description id location mutated_sha256 mutated_source mutator original_sha256
    original_source patch selected selection_reason target_ordinal
  )
  @generation_error_mutant_keys ~w(
    description generation_error id location mutator original_sha256 original_source
    patch selected selection_reason target_ordinal
  )
  @identical_source_mutant_keys ~w(
    description generation_exclusion id location mutated_sha256 mutated_source mutator
    original_sha256 original_source patch selected selection_reason target_ordinal
  )
  @generation_error_keys ~w(inspect message reason tag type)
  @generation_exclusion_keys ~w(reason rendered_sha256)

  def validate(opts) do
    with {:ok, paths} <- required_paths(opts),
         :ok <- ensure_new_output(paths.output),
         {:ok, plan, plan_hash} <- read_json(paths.plan),
         {:ok, selected_ids} <- validate_plan(plan),
         {:ok, checkpoint_rows, checkpoint_hash} <- read_checkpoint(paths.checkpoint),
         {:ok, results} <- validate_checkpoint(checkpoint_rows, selected_ids, opts),
         {:ok, report, report_hash} <- read_json(paths.report),
         {:ok, status_counts, scores} <- validate_report(report, selected_ids, results),
         {:ok, artifacts} <- validate_artifacts(checkpoint_rows, opts[:artifact_roots] || []),
         input_hashes = %{plan: plan_hash, checkpoint: checkpoint_hash, report: report_hash},
         validation = validation(selected_ids, status_counts, scores, artifacts, input_hashes),
         :ok <- publish(paths.output, validation) do
      {:ok, validation}
    end
  end

  @doc false
  def validate_plan_file(path) do
    with {:ok, plan, plan_hash} <- read_json(Path.expand(path)),
         {:ok, selected_ids} <- validate_plan(plan) do
      {:ok, %{plan: plan, sha256: plan_hash, selected_ids: selected_ids}}
    end
  end

  @doc false
  def validate_evidence(opts) do
    with {:ok, paths} <- required_evidence_paths(opts),
         {:ok, plan, plan_hash} <- read_json(paths.plan),
         {:ok, selected_ids} <- validate_plan(plan),
         {:ok, checkpoint_rows, checkpoint_hash} <- read_checkpoint(paths.checkpoint),
         {:ok, results} <- validate_checkpoint(checkpoint_rows, selected_ids, opts),
         {:ok, report, report_hash} <- read_json(paths.report),
         {:ok, status_counts, scores} <- validate_report(report, selected_ids, results),
         {:ok, artifacts} <- validate_artifacts(checkpoint_rows, opts[:artifact_roots] || []) do
      input_hashes = %{plan: plan_hash, checkpoint: checkpoint_hash, report: report_hash}
      {:ok, validation(selected_ids, status_counts, scores, artifacts, input_hashes)}
    end
  end

  @doc false
  def validate_checkpoint_prefix(opts) do
    with {:ok, paths} <- required_prefix_paths(opts),
         {:ok, plan, plan_hash} <- read_json(paths.plan),
         {:ok, selected_ids} <- validate_plan(plan),
         {:ok, checkpoint_rows, checkpoint_hash} <- read_checkpoint(paths.checkpoint),
         {:ok, results} <- validate_checkpoint_prefix_rows(checkpoint_rows, selected_ids, opts),
         {:ok, infrastructure_error_ids} <-
           infrastructure_error_ids(checkpoint_rows, selected_ids),
         {:ok, artifacts} <- validate_artifacts(checkpoint_rows, opts[:artifact_roots] || []) do
      {:ok,
       %{
         selected_count: length(selected_ids),
         selected_ids: selected_ids,
         results: results,
         infrastructure_error_ids: infrastructure_error_ids,
         artifacts: artifacts,
         inputs: %{plan_sha256: plan_hash, checkpoint_sha256: checkpoint_hash}
       }}
    end
  end

  defp required_prefix_paths(opts) do
    case Enum.find(~w(plan checkpoint)a, &(not is_binary(opts[&1]))) do
      nil -> {:ok, %{plan: Path.expand(opts[:plan]), checkpoint: Path.expand(opts[:checkpoint])}}
      key -> {:error, {:missing_option, key}}
    end
  end

  defp required_paths(opts) do
    keys = ~w(plan checkpoint report output)a

    case Enum.find(keys, &(not is_binary(opts[&1]))) do
      nil -> {:ok, Map.new(keys, &{&1, Path.expand(opts[&1])})}
      key -> {:error, {:missing_option, key}}
    end
  end

  defp required_evidence_paths(opts) do
    keys = ~w(plan checkpoint report)a

    case Enum.find(keys, &(not is_binary(opts[&1]))) do
      nil -> {:ok, Map.new(keys, &{&1, Path.expand(opts[&1])})}
      key -> {:error, {:missing_option, key}}
    end
  end

  defp ensure_new_output(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :validation_exists}
      {:error, reason} -> {:error, {:validation_output_error, reason}}
    end
  end

  defp read_json(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, value} <- Jason.decode(contents) do
      {:ok, value, sha256(contents)}
    else
      {:error, reason} -> {:error, {:invalid_json, path, reason}}
    end
  end

  defp validate_plan(%{
         "version" => 1,
         "exhaustive" => exhaustive,
         "source_file_count" => source_file_count,
         "selected_source_file_count" => selected_source_file_count,
         "source_files" => source_files,
         "candidate_count" => candidate_count,
         "selected_count" => selected_count,
         "mutants" => mutants
       })
       when is_boolean(exhaustive) and is_list(source_files) and is_list(mutants) do
    if valid_counts?([
         source_file_count,
         selected_source_file_count,
         candidate_count,
         selected_count
       ]) and
         Enum.all?(mutants, &is_map/1) and Enum.all?(source_files, &is_map/1),
       do:
         validate_plan_entries(
           mutants,
           candidate_count,
           selected_count,
           source_files,
           source_file_count,
           selected_source_file_count,
           exhaustive
         ),
       else: {:error, :invalid_plan}
  end

  defp validate_plan(_), do: {:error, :invalid_plan}

  defp valid_counts?(counts), do: Enum.all?(counts, &(is_integer(&1) and &1 >= 0))

  defp validate_plan_entries(
         mutants,
         candidate_count,
         selected_count,
         source_files,
         source_file_count,
         selected_source_file_count,
         exhaustive
       ) do
    ids = Enum.map(mutants, &Map.get(&1, "id"))
    selected_ids = for %{"id" => id, "selected" => true} <- mutants, do: id
    source_paths = Enum.map(source_files, &Map.get(&1, "path"))
    selected_source_files = Enum.count(source_files, &(Map.get(&1, "selected") == true))

    expected_exhaustive =
      candidate_count == selected_count and source_file_count == selected_source_file_count

    with :ok <-
           validate_source_entries(
             source_files,
             source_paths,
             source_file_count,
             selected_source_file_count,
             selected_source_files
           ),
         :ok <- validate_mutant_entries(mutants, ids, candidate_count) do
      cond do
        selected_count != length(selected_ids) ->
          {:error, {:plan_selected_count_mismatch, selected_count, length(selected_ids)}}

        exhaustive != expected_exhaustive ->
          {:error, {:plan_exhaustive_mismatch, exhaustive, expected_exhaustive}}

        true ->
          {:ok, selected_ids}
      end
    end
  end

  defp validate_source_entries(
         source_files,
         source_paths,
         source_file_count,
         selected_source_file_count,
         selected_source_files
       ) do
    cond do
      Enum.any?(source_files, &(Map.get(&1, "selected") not in [true, false])) ->
        {:error, :plan_invalid_source_selection}

      Enum.any?(source_paths, &(not is_binary(&1) or &1 == "")) ->
        {:error, :plan_invalid_source_path}

      Enum.any?(source_files, &(not is_binary(Map.get(&1, "selection_reason")))) ->
        {:error, :plan_invalid_source_selection_reason}

      length(Enum.uniq(source_paths)) != length(source_paths) ->
        {:error, :plan_duplicate_source_path}

      source_file_count != length(source_files) ->
        {:error, {:plan_source_file_count_mismatch, source_file_count, length(source_files)}}

      selected_source_file_count != selected_source_files ->
        {:error,
         {:plan_selected_source_file_count_mismatch, selected_source_file_count,
          selected_source_files}}

      true ->
        :ok
    end
  end

  defp validate_mutant_entries(mutants, ids, candidate_count) do
    cond do
      Enum.any?(mutants, &(Map.get(&1, "selected") not in [true, false])) ->
        {:error, :plan_invalid_selection}

      Enum.any?(mutants, &(not valid_mutant_entry?(&1))) ->
        {:error, :plan_invalid_mutant_entry}

      Enum.any?(ids, &(not is_binary(&1) or &1 == "")) ->
        {:error, :plan_invalid_mutation_id}

      length(Enum.uniq(ids)) != length(ids) ->
        {:error, :plan_duplicate_mutation_id}

      candidate_count != length(mutants) ->
        {:error, {:plan_candidate_count_mismatch, candidate_count, length(mutants)}}

      true ->
        :ok
    end
  end

  defp valid_mutant_entry?(entry) do
    keys = entry |> Map.keys() |> Enum.sort()

    case keys do
      @valid_mutant_keys ->
        valid_standard_mutant?(entry)

      @generation_error_mutant_keys ->
        valid_generation_error_mutant?(entry)

      @identical_source_mutant_keys ->
        valid_identical_source_mutant?(entry)

      _other ->
        false
    end
  end

  defp valid_standard_mutant?(entry) do
    valid_common_mutant_fields?(entry) and
      valid_source_hash?(entry["mutated_source"], entry["mutated_sha256"]) and
      patch_matches_sources?(entry)
  end

  defp valid_generation_error_mutant?(entry) do
    valid_common_mutant_fields?(entry) and entry["selected"] == false and
      entry["selection_reason"] == "excluded_generation_error" and
      valid_generation_error?(entry["generation_error"])
  end

  defp valid_identical_source_mutant?(entry) do
    valid_common_mutant_fields?(entry) and entry["selected"] == false and
      entry["selection_reason"] == "excluded_identical_source" and
      valid_source_hash?(entry["mutated_source"], entry["mutated_sha256"]) and
      patch_matches_sources?(entry) and
      valid_generation_exclusion?(entry["generation_exclusion"], entry["mutated_sha256"])
  end

  defp valid_common_mutant_fields?(entry) do
    Enum.all?([
      present_string?(entry["id"]),
      entry["selected"] in [true, false],
      present_string?(entry["selection_reason"]),
      present_string?(entry["mutator"]),
      is_binary(entry["description"]),
      valid_location?(entry["location"]),
      is_integer(entry["target_ordinal"]) and entry["target_ordinal"] >= 0,
      valid_patch?(entry["patch"]),
      is_binary(entry["original_source"]),
      valid_source_hash?(entry["original_source"], entry["original_sha256"]) and
        valid_stable_id?(entry)
    ])
  end

  defp present_string?(value), do: is_binary(value) and value != ""

  defp valid_source_hash?(source, hash), do: is_binary(source) and sha256(source) == hash

  defp valid_stable_id?(entry) do
    %{"file" => file, "line" => line} = entry["location"]

    Muex.mutation_id(
      entry["mutator"],
      entry["description"],
      file,
      line,
      entry["patch"],
      entry["target_ordinal"]
    ) == entry["id"]
  end

  defp patch_matches_sources?(entry) do
    %{"before" => before, "after" => after_source} = entry["patch"]
    original = entry["original_source"]
    mutated = entry["mutated_source"]

    original == mutated or
      original
      |> source_indentations()
      |> Enum.any?(fn indentation ->
        patch_replaces_source?(
          original,
          mutated,
          indent_snippet(before, indentation),
          indent_snippet(after_source, indentation)
        )
      end)
  end

  defp patch_replaces_source?(original, mutated, before, after_source) do
    original
    |> replacement_candidates(before, after_source)
    |> Enum.member?(mutated)
  end

  defp source_indentations(source) do
    source
    |> then(&Regex.scan(~r/(?:\A|\n)([ \t]*)(?=\S)/, &1, capture: :all_but_first))
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end

  defp indent_snippet(snippet, indentation) do
    snippet
    |> String.split("\n")
    |> Enum.map_join("\n", &(indentation <> &1))
  end

  defp replacement_candidates(source, before, after_source) do
    source
    |> :binary.matches(before)
    |> Enum.map(fn {offset, length} ->
      prefix = binary_part(source, 0, offset)
      suffix_offset = offset + length
      suffix = binary_part(source, suffix_offset, byte_size(source) - suffix_offset)
      prefix <> after_source <> suffix
    end)
  end

  defp valid_location?(%{"file" => file, "line" => line} = location) do
    Enum.sort(Map.keys(location)) == ~w(file line) and is_binary(file) and file != "" and
      is_integer(line) and line >= 0
  end

  defp valid_location?(_location), do: false

  defp valid_patch?(%{"before" => before, "after" => after_source} = patch) do
    Enum.sort(Map.keys(patch)) == ~w(after before) and present_string?(before) and
      is_binary(after_source)
  end

  defp valid_patch?(_patch), do: false

  defp valid_generation_error?(error) when is_map(error) do
    Enum.sort(Map.keys(error)) == @generation_error_keys and
      error["tag"] == "error" and
      error["reason"] == "mutation_source_generation_failed" and
      Enum.all?(~w(type message inspect), &(is_binary(error[&1]) and error[&1] != "")) and
      String.length(error["inspect"]) <= 1_000
  end

  defp valid_generation_error?(_error), do: false

  defp valid_generation_exclusion?(exclusion, mutated_sha256) when is_map(exclusion) do
    Enum.sort(Map.keys(exclusion)) == @generation_exclusion_keys and
      exclusion["reason"] == "identical_source" and
      exclusion["rendered_sha256"] == mutated_sha256
  end

  defp valid_generation_exclusion?(_exclusion, _mutated_sha256), do: false

  defp valid_sha256?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp valid_sha256?(_value), do: false

  defp read_checkpoint(path) do
    with {:ok, contents} <- File.read(path),
         :ok <- require_final_newline(contents),
         {:ok, rows} <- decode_lines(contents) do
      {:ok, rows, sha256(contents)}
    end
  end

  defp require_final_newline(contents) do
    if contents != "" and String.ends_with?(contents, "\n"),
      do: :ok,
      else: {:error, :checkpoint_incomplete_line}
  end

  defp decode_lines(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, rows} ->
      case Jason.decode(line) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        {:error, _} -> {:halt, {:error, :checkpoint_corrupt}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp validate_checkpoint([header | rows], selected_ids, opts) do
    expected_set_fingerprint = digest(Enum.sort(selected_ids))
    campaign_fingerprint = opts[:campaign_fingerprint]

    with :ok <-
           validate_header(
             header,
             length(selected_ids),
             expected_set_fingerprint,
             campaign_fingerprint
           ),
         {:ok, baseline_tests} <- successful_baseline_tests(rows, selected_ids),
         :ok <- validate_result_test_scopes(rows, baseline_tests),
         {:ok, results} <- terminal_results(rows, MapSet.new(selected_ids)),
         :ok <- require_exact_results(results, selected_ids) do
      {:ok, results}
    end
  end

  defp validate_checkpoint([], _selected_ids, _opts), do: {:error, :checkpoint_empty}

  defp validate_checkpoint_prefix_rows([header | rows], selected_ids, opts) do
    expected_set_fingerprint = digest(Enum.sort(selected_ids))

    with :ok <-
           validate_header(
             header,
             length(selected_ids),
             expected_set_fingerprint,
             opts[:campaign_fingerprint]
           ),
         {:ok, baseline_tests} <- successful_baseline_tests(rows, selected_ids),
         :ok <- validate_result_test_scopes(rows, baseline_tests) do
      terminal_results(rows, MapSet.new(selected_ids))
    end
  end

  defp validate_checkpoint_prefix_rows([], _selected_ids, _opts), do: {:error, :checkpoint_empty}

  defp infrastructure_error_ids([_header | rows], selected_ids) do
    selected = MapSet.new(selected_ids)

    ids =
      for %{"type" => "infrastructure_error", "id" => id} <- rows,
          is_binary(id),
          do: id

    if Enum.any?(ids, &(not MapSet.member?(selected, &1))) do
      {:error, :checkpoint_unknown_infrastructure_mutation}
    else
      {:ok, Enum.uniq(ids)}
    end
  end

  defp validate_header(header, total, set_fingerprint, campaign_fingerprint)
       when is_map(header) do
    with :ok <- valid_header_identity(header),
         :ok <- valid_header_total(header, total),
         :ok <- valid_header_set(header, set_fingerprint),
         :ok <- valid_header_fingerprints(header) do
      valid_campaign_fingerprint(header, campaign_fingerprint)
    end
  end

  defp validate_header(_header, _total, _set_fingerprint, _campaign_fingerprint),
    do: {:error, :invalid_checkpoint_header}

  defp valid_header_identity(%{"type" => "header", "version" => 1}), do: :ok
  defp valid_header_identity(_header), do: {:error, :invalid_checkpoint_header}

  defp valid_header_total(%{"total" => total}, total), do: :ok

  defp valid_header_total(header, total),
    do: {:error, {:checkpoint_total_mismatch, header["total"], total}}

  defp valid_header_set(%{"mutation_set_fingerprint" => fingerprint}, fingerprint), do: :ok
  defp valid_header_set(_header, _fingerprint), do: {:error, :checkpoint_mutation_set_mismatch}

  defp valid_header_fingerprints(header) do
    if valid_sha256?(header["run_fingerprint"]) and valid_sha256?(header["source_fingerprint"]),
      do: :ok,
      else: {:error, :invalid_checkpoint_fingerprint}
  end

  defp valid_campaign_fingerprint(%{"campaign_fingerprint" => fingerprint}, fingerprint) do
    if valid_sha256?(fingerprint),
      do: :ok,
      else: {:error, :checkpoint_campaign_fingerprint_mismatch}
  end

  defp valid_campaign_fingerprint(_header, _fingerprint),
    do: {:error, :checkpoint_campaign_fingerprint_mismatch}

  defp successful_baseline_tests(_rows, []), do: {:ok, MapSet.new()}

  defp successful_baseline_tests(rows, _selected_ids) do
    scopes =
      for row <- rows,
          {:ok, tests} <- [successful_baseline_scope(row)],
          do: tests

    case Enum.uniq_by(scopes, &(&1 |> MapSet.to_list() |> Enum.sort())) do
      [] -> {:error, :checkpoint_missing_successful_baseline}
      [scope] -> {:ok, scope}
      _different_scopes -> {:error, :checkpoint_baseline_test_scope_mismatch}
    end
  end

  defp successful_baseline_scope(%{
         "type" => "baseline",
         "tests" => tests,
         "result" => %{"status" => "passed", "compile" => compile, "test" => test}
       })
       when is_list(tests) do
    valid_tests? = Enum.all?(tests, &(is_binary(&1) and &1 != ""))

    valid_test_result? =
      (tests == [] and is_nil(test)) or (tests != [] and successful_test_process?(test))

    if valid_tests? and successful_process?(compile) and valid_test_result?,
      do: {:ok, MapSet.new(tests)},
      else: :error
  end

  defp successful_baseline_scope(_row), do: :error

  defp validate_result_test_scopes(rows, baseline_tests) do
    Enum.reduce_while(rows, :ok, fn
      %{"type" => "result", "id" => id, "audit" => audit}, :ok ->
        case audit_test_paths(audit) do
          {:ok, tests} ->
            outside =
              tests
              |> MapSet.new()
              |> MapSet.difference(baseline_tests)
              |> MapSet.to_list()
              |> Enum.sort()

            if outside == [],
              do: {:cont, :ok},
              else: {:halt, {:error, {:checkpoint_result_tests_outside_baseline, id, outside}}}

          :error ->
            {:halt, {:error, :checkpoint_corrupt}}
        end

      _row, :ok ->
        {:cont, :ok}
    end)
  end

  defp audit_test_paths(audit) when is_map(audit) do
    with {:ok, own_tests} <- test_path_list(Map.get(audit, "tests")),
         {:ok, attempt_tests} <- attempt_test_paths(Map.get(audit, "attempts")) do
      {:ok, own_tests ++ attempt_tests}
    end
  end

  defp audit_test_paths(_audit), do: {:ok, []}

  defp attempt_test_paths(nil), do: {:ok, []}

  defp attempt_test_paths(attempts) when is_list(attempts) do
    Enum.reduce_while(attempts, {:ok, []}, fn attempt, {:ok, paths} ->
      case audit_test_paths(attempt) do
        {:ok, attempt_paths} -> {:cont, {:ok, paths ++ attempt_paths}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp attempt_test_paths(_attempts), do: :error

  defp test_path_list(nil), do: {:ok, []}

  defp test_path_list(tests) when is_list(tests) do
    if Enum.all?(tests, &(is_binary(&1) and &1 != "")), do: {:ok, tests}, else: :error
  end

  defp test_path_list(_tests), do: :error

  defp terminal_results(rows, selected_ids) do
    Enum.reduce_while(rows, {:ok, %{}}, fn
      %{"type" => "result", "id" => id, "status" => status} = row, {:ok, results}
      when status in @statuses ->
        cond do
          not MapSet.member?(selected_ids, id) ->
            {:halt, {:error, {:checkpoint_unknown_mutation, id}}}

          Map.has_key?(results, id) ->
            {:halt, {:error, {:checkpoint_duplicate_mutation, id}}}

          valid_result_evidence?(row, status) ->
            {:cont, {:ok, Map.put(results, id, status)}}

          true ->
            {:halt, {:error, {:checkpoint_missing_result_evidence, id, status}}}
        end

      %{"type" => type}, acc when type in ["baseline", "infrastructure_error"] ->
        {:cont, acc}

      _row, _acc ->
        {:halt, {:error, :checkpoint_corrupt}}
    end)
  end

  defp valid_result_evidence?(
         %{
           "audit" => %{
             "classification" => "reproduced_pre_exunit_failure",
             "test_process_failure" => signature,
             "attempts" => [first, second],
             "recovery" => recovery
           }
         },
         "killed"
       ) do
    reproduced_pre_exunit_failure?([first, second], signature) and successful_recovery?(recovery)
  end

  defp valid_result_evidence?(%{"audit" => audit}, status)
       when status in ["killed", "survived"] do
    single_attempt?(audit) and successful_process?(audit["compile"]) and
      test_result_matches?(audit["test"], status)
  end

  defp valid_result_evidence?(%{"audit" => %{"attempts" => [first, second]}}, "invalid") do
    Enum.all?([first, second], &(single_attempt?(&1) and failed_compile?(&1["compile"])))
  end

  defp valid_result_evidence?(%{"audit" => %{"attempts" => [first, second]}}, "timeout") do
    Enum.all?([first, second], &(single_attempt?(&1) and timed_out_attempt?(&1)))
  end

  defp valid_result_evidence?(%{"audit" => %{"classification" => status}}, status)
       when status in ["equivalent", "no_coverage", "no_op"], do: true

  defp valid_result_evidence?(_row, _status), do: false

  defp reproduced_pre_exunit_failure?(attempts, %{
         "exit_code" => exit_code,
         "bytes" => bytes,
         "sha256" => sha256
       })
       when is_integer(exit_code) and exit_code > 0 and is_integer(bytes) and bytes >= 0 and
              is_binary(sha256) do
    Enum.all?(attempts, fn attempt ->
      single_attempt?(attempt) and successful_process?(attempt["compile"]) and
        match?(
          %{
            "failure" => "test_process_failed",
            "exit_code" => ^exit_code,
            "error" => error,
            "output_artifact" => %{"bytes" => ^bytes, "sha256" => ^sha256}
          }
          when is_binary(error),
          attempt["test"]
        )
    end)
  end

  defp reproduced_pre_exunit_failure?(_attempts, _signature), do: false

  defp successful_recovery?(%{
         "rebuilt" => true,
         "baseline" => %{"compile" => compile, "test" => test}
       }) do
    successful_process?(compile) and successful_test_process?(test)
  end

  defp successful_recovery?(_recovery), do: false

  defp single_attempt?(%{"attempt" => attempt}) when is_integer(attempt) and attempt > 0, do: true
  defp single_attempt?(_attempt), do: false

  defp successful_process?(%{"exit_code" => 0, "output_artifact" => artifact})
       when is_map(artifact), do: true

  defp successful_process?(_result), do: false

  defp successful_test_process?(%{"failures" => 0} = result), do: successful_process?(result)
  defp successful_test_process?(_result), do: false

  defp test_result_matches?(%{"failures" => failures, "output_artifact" => artifact}, "killed")
       when is_integer(failures) and failures > 0 and is_map(artifact), do: true

  defp test_result_matches?(test, "survived"), do: successful_test_process?(test)
  defp test_result_matches?(_test, _status), do: false

  defp failed_compile?(%{"error" => error, "output_artifact" => artifact})
       when is_binary(error) and is_map(artifact),
       do: true

  defp failed_compile?(_compile), do: false

  defp timed_out_attempt?(attempt) do
    Enum.any?([attempt["compile"], attempt["test"]], fn
      %{"error" => error, "output_artifact" => artifact}
      when is_binary(error) and is_map(artifact) ->
        String.contains?(error, ":timeout")

      _result ->
        false
    end)
  end

  defp require_exact_results(results, selected_ids) do
    if MapSet.equal?(MapSet.new(Map.keys(results)), MapSet.new(selected_ids)),
      do: :ok,
      else: {:error, :checkpoint_incomplete_results}
  end

  defp validate_report(%{"summary" => summary, "mutations" => mutations}, selected_ids, results)
       when is_map(summary) and is_list(mutations) do
    if Enum.all?(mutations, &is_map/1) do
      report_ids = Enum.map(mutations, &Map.get(&1, "id"))

      with :ok <- require_report_ids(report_ids, selected_ids),
           :ok <- require_report_statuses(mutations, results),
           counts =
             Map.new(@statuses, &{&1, Enum.count(mutations, fn row -> row["status"] == &1 end)}),
           scores = scores(counts),
           :ok <- require_summary(summary, length(mutations), counts, scores) do
        {:ok, counts, scores}
      end
    else
      {:error, :invalid_report}
    end
  end

  defp validate_report(_, _selected_ids, _results), do: {:error, :invalid_report}

  defp require_report_ids(ids, selected_ids) do
    cond do
      Enum.any?(ids, &(not is_binary(&1))) -> {:error, :report_invalid_mutation_id}
      length(Enum.uniq(ids)) != length(ids) -> {:error, :report_duplicate_mutation_id}
      MapSet.new(ids) != MapSet.new(selected_ids) -> {:error, :report_mutation_set_mismatch}
      true -> :ok
    end
  end

  defp require_report_statuses(mutations, results) do
    Enum.reduce_while(mutations, :ok, fn row, :ok ->
      id = Map.get(row, "id")
      status = Map.get(row, "status")

      case Map.fetch(results, id) do
        {:ok, expected} when status == expected ->
          {:cont, :ok}

        {:ok, expected} ->
          {:halt, {:error, {:report_status_mismatch, id, expected, status}}}

        :error ->
          {:halt, {:error, {:report_unknown_mutation, id}}}
      end
    end)
  end

  defp scores(counts) do
    denominator = counts["killed"] + counts["survived"] + counts["timeout"]

    if denominator == 0 do
      %{low: 0.0, high: 0.0}
    else
      %{
        low: Float.round(counts["killed"] / denominator * 100, 2),
        high: Float.round((counts["killed"] + counts["timeout"]) / denominator * 100, 2)
      }
    end
  end

  defp require_summary(summary, total, counts, scores) do
    expected =
      counts
      |> Map.put("total", total)
      |> Map.put("mutation_score_low", scores.low)
      |> Map.put("mutation_score_high", scores.high)

    case Enum.find(expected, fn {key, value} -> not number_equal?(summary[key], value) end) do
      nil -> :ok
      {key, value} -> {:error, {:report_summary_mismatch, key, value, summary[key]}}
    end
  end

  defp number_equal?(actual, expected) when is_number(actual), do: abs(actual - expected) < 0.001
  defp number_equal?(_actual, _expected), do: false

  defp validate_artifacts(rows, roots) when is_list(roots) and roots != [] do
    roots = Enum.map(roots, &Path.expand/1)

    rows
    |> collect_artifacts()
    |> Enum.reduce_while({:ok, %{count: 0, bytes: 0, references: %{}}}, fn artifact,
                                                                           {:ok, totals} ->
      case validate_artifact(artifact, roots) do
        {:ok, path, bytes, reference} ->
          case Map.fetch(totals.references, path) do
            :error ->
              {:cont,
               {:ok,
                %{
                  count: totals.count + 1,
                  bytes: totals.bytes + bytes,
                  references: Map.put(totals.references, path, reference)
                }}}

            {:ok, ^reference} ->
              {:cont, {:ok, totals}}

            {:ok, _different} ->
              {:halt, {:error, {:invalid_artifact, path, :artifact_reference_mismatch}}}
          end

        {:error, path, reason} ->
          {:halt, {:error, {:invalid_artifact, path, reason}}}
      end
    end)
    |> case do
      {:ok, totals} -> {:ok, Map.take(totals, [:count, :bytes])}
      error -> error
    end
  end

  defp validate_artifacts(_rows, _roots), do: {:error, :missing_artifact_roots}

  defp collect_artifacts(value) when is_map(value) do
    own =
      case Map.fetch(value, "output_artifact") do
        {:ok, artifact} when is_map(artifact) -> [artifact]
        {:ok, _invalid} -> [:invalid_artifact]
        :error -> []
      end

    own ++
      Enum.flat_map(Map.delete(value, "output_artifact"), fn {_key, child} ->
        collect_artifacts(child)
      end)
  end

  defp collect_artifacts(value) when is_list(value),
    do: Enum.flat_map(value, &collect_artifacts/1)

  defp collect_artifacts(_value), do: []

  defp validate_artifact(
         %{"path" => raw_path, "bytes" => expected_bytes, "sha256" => expected_hash},
         roots
       )
       when is_binary(raw_path) and is_integer(expected_bytes) and expected_bytes >= 0 and
              is_binary(expected_hash) do
    path = Path.expand(raw_path)

    with {:ok, root, relative} <- allowed_root(path, roots),
         :ok <- reject_symlink_components(root, relative),
         {:ok, bytes, hash} <- hash_file(path),
         :ok <- compare_bytes(bytes, expected_bytes),
         :ok <- compare_hash(hash, expected_hash) do
      {:ok, path, bytes, {expected_bytes, expected_hash}}
    else
      {:error, reason} -> {:error, raw_path, reason}
    end
  end

  defp validate_artifact(%{"path" => path}, _roots),
    do: {:error, path, :invalid_artifact_metadata}

  defp validate_artifact(_artifact, _roots), do: {:error, nil, :invalid_artifact_metadata}

  defp allowed_root(path, roots) do
    Enum.find_value(roots, {:error, :artifact_outside_allowed_roots}, fn root ->
      relative = Path.relative_to(path, root)

      if relative != "." and Path.type(relative) != :absolute and
           not Enum.any?(Path.split(relative), &(&1 == "..")),
         do: {:ok, root, relative},
         else: false
    end)
  end

  defp reject_symlink_components(root, relative) do
    paths =
      relative
      |> Path.split()
      |> Enum.scan(root, &Path.join(&2, &1))

    Enum.reduce_while([root | paths], :ok, fn component, :ok ->
      case File.lstat(component) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :artifact_symlink}}
        {:ok, _stat} -> {:cont, :ok}
        {:error, _} -> {:halt, {:error, :artifact_missing}}
      end
    end)
  end

  defp hash_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.open(path, [:read, :binary], &hash_stream(&1, 0, :crypto.hash_init(:sha256))) do
          {:ok, {:ok, bytes, hash}} -> {:ok, bytes, hash}
          {:ok, {:error, _}} -> {:error, :artifact_unreadable}
          {:error, _} -> {:error, :artifact_unreadable}
        end

      {:ok, _} ->
        {:error, :artifact_not_regular}

      {:error, _} ->
        {:error, :artifact_missing}
    end
  end

  defp hash_stream(io, bytes, hash) do
    case IO.binread(io, 65_536) do
      :eof -> {:ok, bytes, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, reason}
      data -> hash_stream(io, bytes + byte_size(data), :crypto.hash_update(hash, data))
    end
  end

  defp compare_bytes(actual, expected) when actual == expected, do: :ok
  defp compare_bytes(_actual, _expected), do: {:error, :artifact_bytes_mismatch}
  defp compare_hash(actual, expected) when actual == expected, do: :ok
  defp compare_hash(_actual, _expected), do: {:error, :artifact_hash_mismatch}

  defp validation(selected_ids, counts, scores, artifacts, input_hashes) do
    %{
      version: @version,
      status: "valid",
      selected_count: length(selected_ids),
      result_count: length(selected_ids),
      status_counts: counts,
      mutation_score_low: scores.low,
      mutation_score_high: scores.high,
      artifacts: artifacts,
      inputs: %{
        plan_sha256: input_hashes.plan,
        checkpoint_sha256: input_hashes.checkpoint,
        report_sha256: input_hashes.report
      }
    }
  end

  defp publish(path, validation) do
    temporary = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <-
           File.write(temporary, Jason.encode!(validation, pretty: true) <> "\n", [
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
        {:error, {:validation_publish_failed, reason}}
    end
  end

  defp digest(term), do: term |> :erlang.term_to_binary() |> sha256()
  defp sha256(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
