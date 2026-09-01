defmodule Muex.AuditValidatorTest do
  use ExUnit.Case, async: true

  alias Muex.Audit.Validator
  alias Muex.Continuation.Artifact

  @campaign_fingerprint String.duplicate("c", 64)
  @statuses ~w(killed survived timeout)

  @tag :tmp_dir
  test "validates one complete shard and publishes immutable evidence", %{tmp_dir: tmp_dir} do
    fixture = valid_fixture!(tmp_dir)

    assert {:ok, validation} = Validator.validate(fixture.opts)
    assert validation.status == "valid"
    assert validation.selected_count == 3
    assert validation.result_count == 3

    assert validation.status_counts == %{
             "equivalent" => 0,
             "invalid" => 0,
             "killed" => 1,
             "no_coverage" => 0,
             "no_op" => 0,
             "survived" => 1,
             "timeout" => 1
           }

    assert validation.artifacts == %{count: 5, bytes: 37}

    assert fixture.output |> File.read!() |> Jason.decode!() == stringify(validation)
    assert {:error, :validation_exists} = Validator.validate(fixture.opts)
  end

  @tag :tmp_dir
  test "continuation finalization rejects a forged validation sidecar", %{tmp_dir: child} do
    invocation = Path.join(child, "invocation.fixture")
    audit_dir = Path.join(invocation, "shard-1-audit")
    File.mkdir_p!(audit_dir)
    fixture = valid_fixture!(Path.join(child, "fixture"))

    plan_path = Path.join(audit_dir, "plan.json")
    checkpoint_path = Path.join(child, "shard-1.checkpoint.jsonl")
    report_path = Path.join(invocation, "shard-1.json")
    File.rename!(fixture.plan, plan_path)
    File.rename!(fixture.checkpoint, checkpoint_path)
    File.rename!(fixture.report, report_path)

    plan = read_json!(plan_path)
    selected_ids = for %{"id" => id, "selected" => true} <- plan["mutants"], do: id
    report = read_json!(report_path)
    write_json!(report_path, put_in(report, ["summary", "killed"], 99))

    write_json!(Path.join(invocation, "shard-1.validation.json"), %{
      "status" => "valid",
      "result_count" => length(selected_ids),
      "inputs" => %{
        "plan_sha256" => sha256(File.read!(plan_path)),
        "checkpoint_sha256" => sha256(File.read!(checkpoint_path)),
        "report_sha256" => sha256(File.read!(report_path))
      }
    })

    write_json!(Path.join(child, "campaign.manifest.json"), %{
      "current_invocation" => "invocation.fixture"
    })

    write_json!(Path.join(child, "continuation.plan.json"), %{
      "parent_fingerprint" => @campaign_fingerprint,
      "parent_selected_count" => length(selected_ids),
      "parent_selected_ids_sha256" => mutation_set_fingerprint(Enum.sort(selected_ids)),
      "imported_finalized" => [],
      "infra_blocked_ids" => [],
      "assignments" => [%{"child_shard" => 1, "ids" => selected_ids}]
    })

    assert {:error, {:invalid_child_shard, 1}} = Artifact.finalize(child)
    refute File.exists?(Path.join(child, "continuation.aggregate.json"))
  end

  @tag :tmp_dir
  test "rejects disagreement between plan, checkpoint, and report", %{tmp_dir: tmp_dir} do
    first_id = stable_fixture_id(0)
    fixture = valid_fixture!(tmp_dir)
    report = read_json!(fixture.report)
    [first | rest] = report["mutations"]

    write_json!(fixture.report, %{
      report
      | "mutations" => [%{first | "status" => "survived"} | rest]
    })

    assert {:error, {:report_status_mismatch, ^first_id, "killed", "survived"}} =
             Validator.validate(fixture.opts)

    fixture = valid_fixture!(Path.join(tmp_dir, "counts"))
    plan = read_json!(fixture.plan)
    write_json!(fixture.plan, %{plan | "selected_count" => 2})

    assert {:error, {:plan_selected_count_mismatch, 2, 3}} = Validator.validate(fixture.opts)

    fixture = valid_fixture!(Path.join(tmp_dir, "exhaustive"))
    plan = read_json!(fixture.plan)
    write_json!(fixture.plan, %{plan | "exhaustive" => true})

    assert {:error, {:plan_exhaustive_mismatch, true, false}} = Validator.validate(fixture.opts)
  end

  @tag :tmp_dir
  test "rejects malformed generation-error plan entries", %{tmp_dir: tmp_dir} do
    fixture = valid_fixture!(tmp_dir)
    plan = read_json!(fixture.plan)
    invalid = List.last(plan["mutants"])
    malformed = update_in(invalid, ["generation_error"], &Map.delete(&1, "type"))

    write_json!(fixture.plan, %{
      plan
      | "mutants" => List.replace_at(plan["mutants"], -1, malformed)
    })

    assert {:error, :plan_invalid_mutant_entry} = Validator.validate(fixture.opts)
  end

  @tag :tmp_dir
  test "rejects tampered source hashes, patches, and stable mutation ids", %{tmp_dir: tmp_dir} do
    for {field, value} <- [
          {"original_sha256", sha256("tampered")},
          {"mutated_source", "3"},
          {"patch", %{"before" => "unrelated", "after" => "2"}},
          {"id", String.duplicate("f", 64)}
        ] do
      fixture = valid_fixture!(Path.join(tmp_dir, field))
      plan = read_json!(fixture.plan)
      [first | rest] = plan["mutants"]
      write_json!(fixture.plan, %{plan | "mutants" => [Map.put(first, field, value) | rest]})

      assert {:error, :plan_invalid_mutant_entry} = Validator.validate(fixture.opts)
    end
  end

  @tag :tmp_dir
  test "nested patches preserve every byte outside the indented replacement", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "nested-plan.json")
    original = "defmodule Example do\n  def value do\n    :original\n  end\nend\n"
    mutated = "defmodule Example do\n  def value do\n    nil\n  end\nend\n"
    write_json!(path, nested_plan(original, mutated))

    assert {:ok, %{selected_ids: [_id]}} = Validator.validate_plan_file(path)

    for drifted <- [
          " defmodule Example do\n  def value do\n    nil\n  end\nend\n",
          String.trim_trailing(mutated, "\n")
        ] do
      write_json!(path, nested_plan(original, drifted))
      assert {:error, :plan_invalid_mutant_entry} = Validator.validate_plan_file(path)
    end
  end

  @tag :tmp_dir
  test "accepts patches against sources that are not rendered canonically", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "non-canonical-plan.json")

    original =
      "defmodule Example do\n  # keyword form plus a comment\n  def value, do: :original\nend\n"

    mutated = "defmodule Example do\n  def value do\n    nil\n  end\nend\n"
    write_json!(path, nested_plan(original, mutated))

    assert {:ok, %{selected_ids: [_id]}} = Validator.validate_plan_file(path)

    for drifted <- [
          " defmodule Example do\n  def value do\n    nil\n  end\nend\n",
          String.trim_trailing(mutated, "\n")
        ] do
      write_json!(path, nested_plan(original, drifted))
      assert {:error, :plan_invalid_mutant_entry} = Validator.validate_plan_file(path)
    end
  end

  @tag :tmp_dir
  test "rejects patches against sources that cannot be parsed", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "unparsable-plan.json")
    original = "defmodule Example do\n  def value, do: :original\n"
    mutated = "defmodule Example do\n  def value do\n    nil\n  end\nend\n"
    write_json!(path, nested_plan(original, mutated))

    assert {:error, :plan_invalid_mutant_entry} = Validator.validate_plan_file(path)
  end

  @tag :tmp_dir
  test "rejects a checkpoint without a successful baseline", %{tmp_dir: tmp_dir} do
    fixture = valid_fixture!(tmp_dir)
    rows = fixture.checkpoint |> checkpoint_rows!() |> Enum.reject(&(&1["type"] == "baseline"))
    File.write!(fixture.checkpoint, Enum.map_join(rows, "", &(Jason.encode!(&1) <> "\n")))

    assert {:error, :checkpoint_missing_successful_baseline} = Validator.validate(fixture.opts)
  end

  @tag :tmp_dir
  test "rejects mutation tests outside the successful shard baseline", %{tmp_dir: tmp_dir} do
    first_id = stable_fixture_id(0)
    fixture = valid_fixture!(tmp_dir)
    [header, baseline, first | rest] = checkpoint_rows!(fixture.checkpoint)
    first = put_in(first, ["audit", "tests"], ["test/not-baselined_test.exs"])

    File.write!(
      fixture.checkpoint,
      Enum.map_join([header, baseline, first | rest], "", &(Jason.encode!(&1) <> "\n"))
    )

    assert {:error,
            {:checkpoint_result_tests_outside_baseline, ^first_id,
             [
               "test/not-baselined_test.exs"
             ]}} = Validator.validate(fixture.opts)
  end

  @tag :tmp_dir
  test "accepts a header-only checkpoint when the plan selects no mutations", %{tmp_dir: tmp_dir} do
    fixture = valid_fixture!(tmp_dir)
    plan = read_json!(fixture.plan)

    write_json!(fixture.plan, %{
      plan
      | "candidate_count" => 0,
        "selected_count" => 0,
        "exhaustive" => true,
        "mutants" => []
    })

    [header | _rows] = checkpoint_rows!(fixture.checkpoint)

    header = %{
      header
      | "mutation_set_fingerprint" => mutation_set_fingerprint([]),
        "total" => 0
    }

    File.write!(fixture.checkpoint, Jason.encode!(header) <> "\n")

    write_json!(fixture.report, %{
      "summary" => %{
        "total" => 0,
        "killed" => 0,
        "survived" => 0,
        "invalid" => 0,
        "timeout" => 0,
        "equivalent" => 0,
        "no_coverage" => 0,
        "no_op" => 0,
        "mutation_score_low" => 0.0,
        "mutation_score_high" => 0.0
      },
      "mutations" => []
    })

    assert {:ok, validation} = Validator.validate(fixture.opts)
    assert validation.selected_count == 0
    assert validation.result_count == 0
  end

  @tag :tmp_dir
  test "validates a finalized checkpoint prefix without requiring the full shard", %{
    tmp_dir: tmp_dir
  } do
    first_id = stable_fixture_id(0)
    second_id = stable_fixture_id(1)
    fixture = valid_fixture!(tmp_dir)
    [header, baseline, first | _rest] = checkpoint_rows!(fixture.checkpoint)

    infrastructure = %{
      "type" => "infrastructure_error",
      "id" => second_id,
      "error" => "blocked"
    }

    File.write!(
      fixture.checkpoint,
      Enum.map_join([header, baseline, first, infrastructure], "", &(Jason.encode!(&1) <> "\n"))
    )

    assert {:ok, prefix} = Validator.validate_checkpoint_prefix(fixture.opts)
    assert Map.keys(prefix.results) == [first_id]
    assert prefix.infrastructure_error_ids == [second_id]
    assert prefix.selected_count == 3
  end

  @tag :tmp_dir
  test "rejects a terminal mutation without status-appropriate evidence", %{tmp_dir: tmp_dir} do
    first_id = stable_fixture_id(0)
    fixture = valid_fixture!(tmp_dir)
    [header, successful_baseline, first | rest] = checkpoint_rows!(fixture.checkpoint)
    first = Map.delete(first, "audit")
    rows = [header, successful_baseline, first | rest]
    File.write!(fixture.checkpoint, Enum.map_join(rows, "", &(Jason.encode!(&1) <> "\n")))

    assert {:error, {:checkpoint_missing_result_evidence, ^first_id, "killed"}} =
             Validator.validate(fixture.opts)
  end

  @tag :tmp_dir
  test "accepts a reproduced pre-ExUnit failure only when both attempts and recovery agree", %{
    tmp_dir: tmp_dir
  } do
    first_id = stable_fixture_id(0)
    fixture = valid_fixture!(Path.join(tmp_dir, "matching"))
    put_reproduced_pre_exunit_evidence!(fixture, "boot failed\n")
    assert {:ok, _validation} = Validator.validate(fixture.opts)

    fixture = valid_fixture!(Path.join(tmp_dir, "divergent"))
    put_reproduced_pre_exunit_evidence!(fixture, "different boot failure\n")

    assert {:error, {:checkpoint_missing_result_evidence, ^first_id, "killed"}} =
             Validator.validate(fixture.opts)
  end

  @tag :tmp_dir
  test "rejects output artifacts that escape, use symlinks, or fail byte integrity", %{
    tmp_dir: tmp_dir
  } do
    for {case_name, alter, expected} <- [
          {"escape", &escape_artifact!/1, :artifact_outside_allowed_roots},
          {"symlink", &symlink_artifact!/1, :artifact_symlink},
          {"hash", &corrupt_artifact!/1, :artifact_bytes_mismatch}
        ] do
      fixture = valid_fixture!(Path.join(tmp_dir, case_name))
      artifact_path = alter.(fixture)

      assert {:error, {:invalid_artifact, ^artifact_path, ^expected}} =
               Validator.validate(fixture.opts)
    end
  end

  defp valid_fixture!(root) do
    audit_outputs = Path.join(root, "audit/outputs")
    File.mkdir_p!(audit_outputs)

    ids = Enum.map(0..2, &stable_fixture_id/1)

    artifacts =
      ids
      |> Enum.zip(@statuses)
      |> Map.new(fn {id, status} ->
        path = Path.join(audit_outputs, "#{id}.log")
        bytes = "#{status}\n"
        File.write!(path, bytes)

        {id,
         %{
           "path" => path,
           "bytes" => byte_size(bytes),
           "sha256" => sha256(bytes)
         }}
      end)

    baseline_compile =
      write_artifact!(Path.join(audit_outputs, "baseline-compile.log"), "compile\n")

    baseline_test = write_artifact!(Path.join(audit_outputs, "baseline-test.log"), "test\n")

    plan = Path.join(root, "plan.json")
    checkpoint = Path.join(root, "checkpoint.jsonl")
    report = Path.join(root, "report.json")
    output = Path.join(root, "validation.json")

    write_json!(plan, %{
      "version" => 1,
      "exhaustive" => false,
      "source_file_count" => 1,
      "selected_source_file_count" => 1,
      "source_files" => [
        %{
          "path" => "lib/example.ex",
          "selected" => true,
          "selection_reason" => "selected_without_file_filter"
        }
      ],
      "candidate_count" => 4,
      "selected_count" => 3,
      "mutants" =>
        Enum.with_index(ids, &valid_plan_mutant/2) ++
          [invalid_plan_mutant()]
    })

    checkpoint_rows =
      [
        %{
          "type" => "header",
          "version" => 1,
          "campaign_fingerprint" => @campaign_fingerprint,
          "run_fingerprint" => String.duplicate("a", 64),
          "source_fingerprint" => String.duplicate("b", 64),
          "mutation_set_fingerprint" => mutation_set_fingerprint(ids),
          "total" => 3
        },
        %{
          "type" => "baseline",
          "sandbox" => 1,
          "attempt" => 1,
          "tests" => ["test/example_test.exs"],
          "result" => %{
            "status" => "passed",
            "compile" => successful_process(baseline_compile),
            "test" => successful_process(baseline_test, 0)
          }
        }
      ] ++
        Enum.zip_with(ids, @statuses, fn id, status ->
          %{
            "type" => "result",
            "id" => id,
            "status" => status,
            "audit" => result_evidence(status, artifacts[id])
          }
        end)

    File.write!(checkpoint, Enum.map_join(checkpoint_rows, "", &(Jason.encode!(&1) <> "\n")))

    write_json!(report, %{
      "summary" => %{
        "total" => 3,
        "killed" => 1,
        "survived" => 1,
        "invalid" => 0,
        "timeout" => 1,
        "equivalent" => 0,
        "no_coverage" => 0,
        "no_op" => 0,
        "mutation_score_low" => 33.33,
        "mutation_score_high" => 66.67
      },
      "mutations" => Enum.zip_with(ids, @statuses, &%{"id" => &1, "status" => &2})
    })

    %{
      plan: plan,
      checkpoint: checkpoint,
      report: report,
      output: output,
      artifact_roots: [audit_outputs],
      opts: [
        plan: plan,
        checkpoint: checkpoint,
        report: report,
        artifact_roots: [audit_outputs],
        campaign_fingerprint: @campaign_fingerprint,
        output: output
      ]
    }
  end

  defp escape_artifact!(fixture) do
    path = Path.join(Path.dirname(hd(fixture.artifact_roots)), "escaped.log")
    File.write!(path, "killed\n")
    replace_first_artifact!(fixture, artifact(path, "killed\n"))
    path
  end

  defp symlink_artifact!(fixture) do
    target = Path.join(Path.dirname(hd(fixture.artifact_roots)), "target.log")
    path = Path.join(hd(fixture.artifact_roots), "linked.log")
    File.write!(target, "killed\n")
    File.ln_s!(target, path)
    replace_first_artifact!(fixture, artifact(path, "killed\n"))
    path
  end

  defp corrupt_artifact!(fixture) do
    checkpoint = checkpoint_rows!(fixture.checkpoint)
    artifact = get_in(Enum.at(checkpoint, 2), ["audit", "compile", "output_artifact"])
    File.write!(artifact["path"], "changed after audit\n")
    artifact["path"]
  end

  defp replace_first_artifact!(fixture, replacement) do
    [header, baseline, first | rest] = checkpoint_rows!(fixture.checkpoint)
    first = put_in(first, ["audit", "compile", "output_artifact"], replacement)

    File.write!(
      fixture.checkpoint,
      Enum.map_join([header, baseline, first | rest], "", &(Jason.encode!(&1) <> "\n"))
    )
  end

  defp put_reproduced_pre_exunit_evidence!(fixture, second_output) do
    outputs = hd(fixture.artifact_roots)
    first_failure = write_artifact!(Path.join(outputs, "pre-exunit-1.log"), "boot failed\n")
    second_failure = write_artifact!(Path.join(outputs, "pre-exunit-2.log"), second_output)
    first_compile = write_artifact!(Path.join(outputs, "pre-exunit-compile-1.log"), "compile\n")
    second_compile = write_artifact!(Path.join(outputs, "pre-exunit-compile-2.log"), "compile\n")
    recovery_compile = write_artifact!(Path.join(outputs, "recovery-compile.log"), "compile\n")
    recovery_test = write_artifact!(Path.join(outputs, "recovery-test.log"), "test\n")

    attempt = fn number, compile, failure ->
      %{
        "attempt" => number,
        "tests" => ["test/example_test.exs"],
        "compile" => successful_process(compile),
        "test" => %{
          "error" => "{:test_process_failed, 1, output}",
          "exit_code" => 1,
          "failure" => "test_process_failed",
          "output_artifact" => failure
        }
      }
    end

    audit = %{
      "classification" => "reproduced_pre_exunit_failure",
      "test_process_failure" => %{
        "exit_code" => 1,
        "bytes" => first_failure["bytes"],
        "sha256" => first_failure["sha256"]
      },
      "attempts" => [
        attempt.(1, first_compile, first_failure),
        attempt.(2, second_compile, second_failure)
      ],
      "recovery" => %{
        "rebuilt" => true,
        "baseline" => %{
          "compile" => successful_process(recovery_compile),
          "test" => successful_process(recovery_test, 0)
        }
      }
    }

    [header, baseline, first | rest] = checkpoint_rows!(fixture.checkpoint)
    first = Map.put(first, "audit", audit)

    File.write!(
      fixture.checkpoint,
      Enum.map_join([header, baseline, first | rest], "", &(Jason.encode!(&1) <> "\n"))
    )
  end

  defp result_evidence("killed", artifact) do
    %{
      "attempt" => 1,
      "tests" => ["test/example_test.exs"],
      "compile" => successful_process(artifact),
      "test" => successful_process(artifact, 1, 1)
    }
  end

  defp result_evidence("survived", artifact) do
    %{
      "attempt" => 1,
      "tests" => ["test/example_test.exs"],
      "compile" => successful_process(artifact),
      "test" => successful_process(artifact, 0)
    }
  end

  defp result_evidence("timeout", artifact) do
    attempt = %{
      "attempt" => 1,
      "tests" => ["test/example_test.exs"],
      "compile" => successful_process(artifact),
      "test" => %{"error" => "{:timeout, output}", "output_artifact" => artifact}
    }

    %{"attempts" => [attempt, %{attempt | "attempt" => 2}]}
  end

  defp successful_process(artifact, failures \\ nil, exit_code \\ 0) do
    then(%{"exit_code" => exit_code, "output_artifact" => artifact}, fn process ->
      if is_nil(failures), do: process, else: Map.put(process, "failures", failures)
    end)
  end

  defp valid_plan_mutant(id, ordinal) do
    %{
      "id" => id,
      "selected" => true,
      "selection_reason" => "selected",
      "mutator" => "Muex.Mutator.Literal",
      "description" => "fixture",
      "location" => %{"file" => "lib/example.ex", "line" => 1},
      "target_ordinal" => ordinal,
      "patch" => %{"before" => "1", "after" => "2"},
      "original_source" => "1",
      "original_sha256" => sha256("1"),
      "mutated_source" => "2",
      "mutated_sha256" => sha256("2")
    }
  end

  defp nested_plan(original, mutated) do
    patch = %{"before" => "def value do\n  :original\nend", "after" => "def value do\n  nil\nend"}

    id =
      Muex.mutation_id(
        "Muex.Mutator.ReturnValue",
        "nested fixture",
        "lib/example.ex",
        2,
        patch,
        0
      )

    %{
      "version" => 1,
      "exhaustive" => true,
      "source_file_count" => 1,
      "selected_source_file_count" => 1,
      "source_files" => [
        %{"path" => "lib/example.ex", "selected" => true, "selection_reason" => "selected"}
      ],
      "candidate_count" => 1,
      "selected_count" => 1,
      "mutants" => [
        %{
          "id" => id,
          "selected" => true,
          "selection_reason" => "selected",
          "mutator" => "Muex.Mutator.ReturnValue",
          "description" => "nested fixture",
          "location" => %{"file" => "lib/example.ex", "line" => 2},
          "target_ordinal" => 0,
          "patch" => patch,
          "original_source" => original,
          "original_sha256" => sha256(original),
          "mutated_source" => mutated,
          "mutated_sha256" => sha256(mutated)
        }
      ]
    }
  end

  defp stable_fixture_id(ordinal) do
    Muex.mutation_id(
      "Muex.Mutator.Literal",
      "fixture",
      "lib/example.ex",
      1,
      %{"before" => "1", "after" => "2"},
      ordinal
    )
  end

  defp invalid_plan_mutant do
    id =
      Muex.mutation_id(
        "Muex.Mutator.Literal",
        "fixture",
        "lib/example.ex",
        1,
        %{"before" => "1", "after" => "invalid"},
        0
      )

    %{
      "id" => id,
      "selected" => false,
      "selection_reason" => "excluded_generation_error",
      "mutator" => "Muex.Mutator.Literal",
      "description" => "fixture",
      "location" => %{"file" => "lib/example.ex", "line" => 1},
      "target_ordinal" => 0,
      "patch" => %{"before" => "1", "after" => "invalid"},
      "original_source" => "1",
      "original_sha256" => sha256("1"),
      "generation_error" => %{
        "tag" => "error",
        "reason" => "mutation_source_generation_failed",
        "type" => "FunctionClauseError",
        "message" => "no function clause matching",
        "inspect" => "{:error, %FunctionClauseError{}}"
      }
    }
  end

  defp write_artifact!(path, bytes) do
    File.write!(path, bytes)
    artifact(path, bytes)
  end

  defp checkpoint_rows!(path), do: path |> File.stream!() |> Enum.map(&Jason.decode!/1)

  defp artifact(path, bytes),
    do: %{"path" => path, "bytes" => byte_size(bytes), "sha256" => sha256(bytes)}

  defp mutation_set_fingerprint(ids), do: ids |> :erlang.term_to_binary() |> sha256()
  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
  defp write_json!(path, value), do: File.write!(path, Jason.encode!(value) <> "\n")
  defp stringify(value), do: value |> Jason.encode!() |> Jason.decode!()
end
