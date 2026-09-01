defmodule Muex.WorkerPool do
  @moduledoc """
  Manages a pool of workers for parallel mutation testing across all files.

  Uses a global queue of mutations with per-file locking to maximize
  cross-file parallelism while preventing concurrent modifications to the
  same source file. Each worker operates in an isolated sandbox directory
  so that parallel `mix test` invocations don't see each other's mutations.

  ## Scheduling strategy

  When a worker slot becomes available, the pool picks the next mutation
  from any file that is not currently locked. This means mutations
  targeting different files run in true parallel, while mutations
  targeting the same file are serialized.
  """

  use GenServer

  alias Muex.Checkpoint
  alias Muex.Compiler
  alias Muex.Config
  alias Muex.Coverage
  alias Muex.Reporter
  alias Muex.Sandbox
  alias Muex.TestRunner.Port, as: PortRunner

  require Logger

  @default_max_workers 4
  @worker_shutdown_timeout_ms 2_000

  # `State` legitimately wraps opaque values (`MapSet`, `:queue`). Across the
  # self-recursive `schedule_workers/1` call, Dialyzer cannot keep a consistent
  # view of those fields and reports an opacity violation in either direction
  # (call_with_opaque / call_without_opaque) regardless of how the struct is
  # typed. The code uses only the public MapSet/:queue APIs, so disable opacity
  # checking for just these two scheduler functions.
  @dialyzer {:no_opaque, [schedule_workers: 1, maybe_finish_or_schedule: 1]}

  defmodule State do
    @moduledoc false

    @typedoc """
    Internal worker-pool state.

    `locked_files` and `available_sandboxes` hold the opaque `MapSet.t/0` and
    `:queue.queue/0`. Opacity checking is disabled for the recursive scheduler
    functions (see the `@dialyzer` attribute on the parent module) because
    Dialyzer cannot keep a consistent opaque view of them across that recursion.
    """
    @type t :: %__MODULE__{
            max_workers: non_neg_integer(),
            caller: GenServer.from() | nil,
            total_mutations: non_neg_integer() | nil,
            opts: keyword(),
            project_root: Path.t() | nil,
            test_paths: [Path.t()],
            baseline_test_paths: [Path.t()],
            pending_by_file: map(),
            locked_files: MapSet.t(),
            active_workers: map(),
            monitor_to_worker: map(),
            results: [map()],
            completed_mutations: non_neg_integer(),
            file_entries: map(),
            language_adapter: module() | nil,
            dependency_map: map(),
            file_to_module: map(),
            sandboxes: list(),
            available_sandboxes: :queue.queue()
          }

    defstruct [
      :max_workers,
      :caller,
      :total_mutations,
      :opts,
      # Root of the project under test (may differ from CWD)
      project_root: nil,
      # Expanded test file paths (resolved once at run start)
      test_paths: ["test"],
      baseline_test_paths: ["test"],
      # Map of file_path => :queue.queue(mutation)
      pending_by_file: %{},
      # MapSet of file paths currently being mutated
      locked_files: MapSet.new(),
      # Map of worker_ref => {mutation, file_path, sandbox_idx, monitor_ref}
      active_workers: %{},
      # Reverse map: monitor_ref => worker_ref (for :DOWN lookup)
      monitor_to_worker: %{},
      # Accumulated results (reverse order)
      results: [],
      completed_mutations: 0,
      # Map of file_path => file_entry
      file_entries: %{},
      # Language adapter module
      language_adapter: nil,
      # Dependency map and file→module map
      dependency_map: %{},
      file_to_module: %{},
      # List of sandbox structs, one per worker slot
      sandboxes: [],
      # Queue of available sandbox indices
      available_sandboxes: :queue.new()
    ]
  end

  @doc """
  Restores any source files left in a mutated state from a previous interrupted run.
  Checks for `.backup` files and replaces the originals.
  """
  def restore_backups(paths) when is_list(paths) do
    paths
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex.backup")))
    |> Enum.each(fn backup_file ->
      original_file = String.replace_suffix(backup_file, ".backup", "")
      Logger.warning("Restoring #{original_file} from backup (previous run interrupted)")
      File.rename!(backup_file, original_file)
    end)
  end

  def restore_backups(path) when is_binary(path), do: restore_backups([path])

  @doc """
  Starts the worker pool.

  ## Options

    - `:max_workers` - Maximum concurrent workers (default: #{@default_max_workers})
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Runs all mutations through the worker pool.

  Accepts the full set of mutations across all files. Mutations targeting
  different files run in parallel (up to `max_workers`); mutations targeting
  the same file are serialized automatically.

  ## Parameters

    - `pool` - The worker pool PID
    - `mutations` - List of all mutations to test (across all files)
    - `file_entries` - Map of file paths to file entry maps
    - `language_adapter` - The language adapter module
    - `dependency_map` - Map of modules to test files
    - `file_to_module` - Map of file paths to module names
    - `opts` - Options including `:timeout_ms`, `:test_paths`, `:verbose`

  ## Returns

    List of mutation result maps.
  """
  @spec run_mutations(
          pid(),
          [map()],
          %{Path.t() => map()},
          module(),
          map(),
          map(),
          keyword()
        ) :: [map()]
  def run_mutations(
        pool,
        mutations,
        file_entries,
        language_adapter,
        dependency_map,
        file_to_module,
        opts \\ []
      ) do
    case run_mutations_result(
           pool,
           mutations,
           file_entries,
           language_adapter,
           dependency_map,
           file_to_module,
           opts
         ) do
      {:ok, results} -> results
      {:error, reason} -> raise "mutation run failed: #{inspect(reason)}"
    end
  end

  @doc false
  @spec run_mutations_result(pid(), [map()], map(), module(), map(), map(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def run_mutations_result(
        pool,
        mutations,
        file_entries,
        language_adapter,
        dependency_map,
        file_to_module,
        opts \\ []
      ) do
    GenServer.call(
      pool,
      {:run_mutations, mutations, file_entries, language_adapter, dependency_map, file_to_module,
       opts},
      :infinity
    )
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    max_workers = Keyword.get(opts, :max_workers, @default_max_workers)

    # -- GenServer callbacks --
    state = %State{
      max_workers: max_workers,
      opts: opts
    }

    {:ok, state}
  end

  # Create sandboxes for parallel workers
  @impl true
  def handle_call(
        {:run_mutations, mutations, file_entries, language_adapter, dependency_map,
         file_to_module, opts},
        from,
        state
      ) do
    if Enum.empty?(mutations) do
      {:reply, {:ok, []}, state}
    else
      test_paths = Keyword.get(opts, :test_paths, ["test"])
      project_root = Keyword.get(opts, :project_root, File.cwd!())
      baseline_mutations = Keyword.get(opts, :baseline_mutations, mutations)

      baseline_test_paths =
        baseline_test_paths(baseline_mutations, test_paths, project_root, opts)

      sandboxes =
        Sandbox.create_pool(state.max_workers,
          project_root: project_root,
          test_paths: baseline_test_paths
        )

      case prepare_and_baseline(sandboxes, mutations, baseline_test_paths, project_root, opts) do
        :ok ->
          available_sandboxes =
            sandboxes
            |> Enum.with_index()
            |> Enum.reduce(:queue.new(), fn {_sb, idx}, q -> :queue.in(idx, q) end)

          pending_by_file =
            Enum.reduce(mutations, %{}, fn mutation, acc ->
              file_path = mutation.location.file
              queue = Map.get(acc, file_path, :queue.new())
              Map.put(acc, file_path, :queue.in(mutation, queue))
            end)

          new_state = %{
            state
            | pending_by_file: pending_by_file,
              file_entries: file_entries,
              language_adapter: language_adapter,
              dependency_map: dependency_map,
              file_to_module: file_to_module,
              project_root: project_root,
              test_paths: test_paths,
              baseline_test_paths: baseline_test_paths,
              opts: opts,
              caller: from,
              results: [],
              total_mutations: length(mutations),
              completed_mutations: 0,
              locked_files: MapSet.new(),
              active_workers: %{},
              monitor_to_worker: %{},
              sandboxes: sandboxes,
              available_sandboxes: available_sandboxes
          }

          {:noreply, schedule_workers(new_state)}

        {:error, reason} ->
          Sandbox.cleanup(sandboxes)
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_info({:worker_done, worker_ref, result}, state) do
    case Map.fetch(state.active_workers, worker_ref) do
      :error ->
        {:noreply, state}

      {:ok, {_mutation, file_path, sandbox_idx, pid, monitor_ref}} ->
        new_completed = state.completed_mutations + 1

        if result.result == :infrastructure_error do
          _ =
            Checkpoint.append_event(Keyword.get(state.opts, :checkpoint), %{
              type: "infrastructure_error",
              id: result.mutation.id,
              error: inspect(result.error),
              duration_ms: result.duration_ms
            })

          stop_with_error(
            {:infrastructure_error, result.mutation.id, result.error},
            state.active_workers,
            state
          )
        else
          case Checkpoint.append_result(Keyword.get(state.opts, :checkpoint), result) do
            :ok ->
              finish_worker(worker_ref, pid, monitor_ref)

              if Keyword.get(state.opts, :verbose, false) do
                try do
                  Reporter.print_progress(result, new_completed, state.total_mutations)
                rescue
                  UndefinedFunctionError -> :ok
                end
              end

              new_state = %{
                state
                | active_workers: Map.delete(state.active_workers, worker_ref),
                  monitor_to_worker: Map.delete(state.monitor_to_worker, monitor_ref),
                  results: [result | state.results],
                  completed_mutations: new_completed,
                  locked_files: MapSet.delete(state.locked_files, file_path),
                  available_sandboxes: :queue.in(sandbox_idx, state.available_sandboxes),
                  pending_by_file: cleanup_pending(state.pending_by_file, file_path)
              }

              maybe_finish_or_schedule(new_state)

            {:error, reason} ->
              stop_with_error({:checkpoint_write_failed, reason}, state.active_workers, state)
          end
        end
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case Map.fetch(state.monitor_to_worker, monitor_ref) do
      {:ok, _worker_ref} when reason in [:normal, :shutdown] ->
        # Normal exit — :worker_done handles completion. Just clean up the
        # monitor mapping so we don't leak entries.
        new_monitor_map = Map.delete(state.monitor_to_worker, monitor_ref)
        {:noreply, %{state | monitor_to_worker: new_monitor_map}}

      {:ok, worker_ref} ->
        {mutation, file_path, sandbox_idx, _pid, ^monitor_ref} =
          Map.fetch!(state.active_workers, worker_ref)

        # Worker crash is infrastructure failure; never dilute mutation score.
        Logger.warning("Mutation worker crashed: #{inspect(reason)}")

        # Best-effort restore of the sandbox before re-queueing it
        sandbox = Enum.at(state.sandboxes, sandbox_idx)

        try do
          Sandbox.restore(sandbox, file_path)
        rescue
          _ -> :ok
        end

        new_active = Map.delete(state.active_workers, worker_ref)
        new_monitor_map = Map.delete(state.monitor_to_worker, monitor_ref)
        new_locked = MapSet.delete(state.locked_files, file_path)
        new_available = :queue.in(sandbox_idx, state.available_sandboxes)

        new_pending = cleanup_pending(state.pending_by_file, file_path)

        _ = new_locked
        _ = new_available
        _ = new_pending

        _ =
          Checkpoint.append_event(Keyword.get(state.opts, :checkpoint), %{
            type: "infrastructure_error",
            id: mutation.id,
            error: inspect({:worker_crashed, reason})
          })

        stop_with_error(
          {:infrastructure_error, mutation.id, {:worker_crashed, reason}},
          new_active,
          %{
            state
            | monitor_to_worker: new_monitor_map
          }
        )

      :error ->
        # Worker already handled via :worker_done — ignore
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  def handle_info({:EXIT, pid, _reason}, state) when is_pid(pid), do: {:noreply, state}

  # -- Scheduling --

  # Try to fill all available worker slots with mutations from unlocked files.
  @spec schedule_workers(State.t()) :: State.t()
  defp schedule_workers(state) do
    available_slots = state.max_workers - map_size(state.active_workers)

    if available_slots > 0 and not :queue.is_empty(state.available_sandboxes) do
      case pick_next_mutation(state) do
        {:ok, mutation, file_path, new_pending} ->
          # Claim a sandbox
          {{:value, sandbox_idx}, new_available} = :queue.out(state.available_sandboxes)

          # Spawn worker and monitor it for crash recovery
          parent = self()
          worker_ref = make_ref()

          pid =
            spawn_link(fn ->
              Process.flag(:trap_exit, true)

              result =
                run_mutation_worker(
                  mutation,
                  file_path,
                  Enum.at(state.sandboxes, sandbox_idx),
                  state
                )

              Process.flag(:trap_exit, false)
              send(parent, {:worker_done, worker_ref, result})

              receive do
                {:worker_finished, ^worker_ref} -> :ok
              end
            end)

          monitor_ref = Process.monitor(pid)

          new_state = %{
            state
            | pending_by_file: new_pending,
              locked_files: MapSet.put(state.locked_files, file_path),
              active_workers:
                Map.put(
                  state.active_workers,
                  worker_ref,
                  {mutation, file_path, sandbox_idx, pid, monitor_ref}
                ),
              monitor_to_worker: Map.put(state.monitor_to_worker, monitor_ref, worker_ref),
              available_sandboxes: new_available
          }

          # Recurse to fill more slots
          schedule_workers(new_state)

        :none ->
          # No unlocked files with pending mutations — wait for a worker to finish
          state
      end
    else
      state
    end
  end

  # Find the next mutation from a file that is NOT currently locked.
  # Prioritizes files with the most pending mutations for better throughput.
  defp pick_next_mutation(state) do
    unlocked_files =
      state.pending_by_file
      |> Enum.reject(fn {file_path, queue} ->
        MapSet.member?(state.locked_files, file_path) or :queue.is_empty(queue)
      end)
      |> Enum.sort_by(fn {_path, queue} -> :queue.len(queue) end, :desc)

    case unlocked_files do
      [{file_path, queue} | _] ->
        {{:value, mutation}, new_queue} = :queue.out(queue)
        new_pending = Map.put(state.pending_by_file, file_path, new_queue)
        {:ok, mutation, file_path, new_pending}

      [] ->
        :none
    end
  end

  defp all_queues_empty?(pending_by_file) do
    Enum.all?(pending_by_file, fn {_path, queue} -> :queue.is_empty(queue) end)
  end

  defp cleanup_pending(pending_by_file, file_path) do
    case Map.get(pending_by_file, file_path) do
      nil ->
        Map.delete(pending_by_file, file_path)

      queue ->
        if :queue.is_empty(queue),
          do: Map.delete(pending_by_file, file_path),
          else: pending_by_file
    end
  end

  @spec maybe_finish_or_schedule(State.t()) :: {:noreply, State.t()}
  defp maybe_finish_or_schedule(state) do
    if map_size(state.active_workers) == 0 and all_queues_empty?(state.pending_by_file) do
      Sandbox.cleanup(state.sandboxes)
      GenServer.reply(state.caller, {:ok, Enum.reverse(state.results)})
      {:noreply, %{state | caller: nil}}
    else
      {:noreply, schedule_workers(state)}
    end
  end

  defp run_mutation_worker(mutation, file_path, sandbox, state) do
    first = run_mutation_attempt(mutation, file_path, sandbox, state, 1)

    case append_attempt_event(state, mutation.id, first, 1) do
      :ok ->
        if first.result in [:timeout, :infrastructure_error, :compile_failure] do
          retry_mutation(first, mutation, file_path, sandbox, state)
        else
          first
        end

      {:error, reason} ->
        audit_failure(first, reason)
    end
  end

  defp retry_mutation(first, mutation, file_path, sandbox, state) do
    case recover_sandbox(sandbox, state, mutation.id) do
      {:ok, recovery} ->
        record_recovery_and_retry(first, mutation, file_path, sandbox, state, recovery)

      {:error, reason, recovery} ->
        _ =
          Muex.Audit.append_event(Keyword.get(state.opts, :audit_dir), mutation.id, %{
            type: "recovery_failed",
            recovery: recovery,
            error: inspect(reason)
          })

        %{
          first
          | result: :infrastructure_error,
            error: {:recovery_failed, reason},
            audit: %{attempts: [first.audit], recovery: recovery}
        }
    end
  end

  defp record_recovery_and_retry(first, mutation, file_path, sandbox, state, recovery) do
    case Muex.Audit.append_event(Keyword.get(state.opts, :audit_dir), mutation.id, %{
           type: "recovery",
           recovery: recovery
         }) do
      :ok ->
        second = run_mutation_attempt(mutation, file_path, sandbox, state, 2)

        case append_attempt_event(state, mutation.id, second, 2) do
          :ok -> reconcile_attempts(first, second, recovery)
          {:error, reason} -> audit_failure(second, reason)
        end

      {:error, reason} ->
        audit_failure(first, reason)
    end
  end

  defp append_attempt_event(state, mutant_id, result, attempt) do
    Muex.Audit.append_event(Keyword.get(state.opts, :audit_dir), mutant_id, %{
      type: "attempt",
      attempt: attempt,
      status: result.result,
      duration_ms: result.duration_ms,
      error: inspect(result.error),
      timings: result.timings,
      audit: result.audit
    })
  end

  defp audit_failure(result, reason) do
    %{result | result: :infrastructure_error, error: {:audit_write_failed, reason}}
  end

  defp run_mutation_attempt(mutation, file_path, sandbox, state, attempt) do
    timeout_ms = Keyword.get(state.opts, :timeout_ms, 5000)
    start_time = System.monotonic_time(:millisecond)

    file_entry = Map.fetch!(state.file_entries, file_path)

    {result_type, error, timings, audit} =
      case select_tests(mutation, state) do
        # Coverage-guided: no test exercises this line, so nothing can kill it.
        :no_coverage ->
          {:no_coverage, nil, %{}, %{classification: :no_coverage}}

        {:run, test_files} ->
          case Compiler.compile_to_source(mutation, file_entry, state.language_adapter) do
            {:ok, mutated_source} ->
              case state.language_adapter.unparse(file_entry.ast) do
                {:ok, original_source} ->
                  if mutated_source == original_source do
                    {:no_op, :identical_source, %{},
                     %{classification: :no_op, reason: :identical_source}}
                  else
                    run_in_sandbox(
                      sandbox,
                      file_path,
                      mutated_source,
                      file_entry,
                      test_files,
                      %{
                        timeout_ms: timeout_ms,
                        audit_dir: Keyword.get(state.opts, :audit_dir),
                        mutant_id: mutation.id,
                        attempt: attempt
                      }
                    )
                  end

                {:error, reason} ->
                  {:infrastructure_error, {:original_source_unparse_failed, reason}, %{}, nil}
              end

            {:error, reason} ->
              {:infrastructure_error, {:mutation_source_generation_failed, reason}, %{}, nil}
          end
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    %{
      mutation: mutation,
      result: result_type,
      duration_ms: duration_ms,
      error: error,
      timings: timings,
      audit: audit
    }
  rescue
    e ->
      %{
        mutation: mutation,
        result: :infrastructure_error,
        duration_ms: 0,
        error: e,
        timings: %{},
        audit: nil
      }
  catch
    :exit, reason ->
      %{
        mutation: mutation,
        result: :infrastructure_error,
        duration_ms: 0,
        error: reason,
        timings: %{},
        audit: nil
      }
  end

  defp reconcile_attempts(%{result: :timeout} = first, %{result: :timeout} = second, recovery) do
    %{second | audit: %{attempts: [first.audit, second.audit], recovery: recovery}}
  end

  defp reconcile_attempts(
         %{result: :compile_failure} = first,
         %{result: :compile_failure} = second,
         recovery
       ) do
    %{
      second
      | result: :invalid,
        audit: %{attempts: [first.audit, second.audit], recovery: recovery}
    }
  end

  defp reconcile_attempts(
         %{result: :infrastructure_error, error: first_error} = first,
         %{result: :infrastructure_error, error: second_error} = second,
         recovery
       ) do
    case repeatable_test_process_failure(first_error, second_error) do
      {:ok, failure} ->
        %{
          second
          | result: :killed,
            error: nil,
            audit: %{
              classification: :reproduced_pre_exunit_failure,
              test_process_failure: failure,
              attempts: [first.audit, second.audit],
              recovery: recovery
            }
        }

      :error ->
        %{
          second
          | error: {:divergent_attempts, first.result, second.result},
            audit: %{attempts: [first.audit, second.audit], recovery: recovery}
        }
    end
  end

  defp reconcile_attempts(first, second, recovery) do
    %{
      second
      | result: :infrastructure_error,
        error: {:divergent_attempts, first.result, second.result},
        audit: %{attempts: [first.audit, second.audit], recovery: recovery}
    }
  end

  defp repeatable_test_process_failure(
         {:test_process_failed, exit_code, _first_output, %{bytes: bytes, sha256: sha256}},
         {:test_process_failed, exit_code, _second_output, %{bytes: bytes, sha256: sha256}}
       )
       when is_integer(exit_code) and exit_code > 0 and is_integer(bytes) and bytes >= 0 and
              is_binary(sha256),
       do: {:ok, %{exit_code: exit_code, bytes: bytes, sha256: sha256}}

  defp repeatable_test_process_failure(_first, _second), do: :error

  defp recover_sandbox(sandbox, state, mutant_id) do
    timeout_ms = Keyword.get(state.opts, :baseline_timeout_ms, 120_000)
    audit_dir = Keyword.get(state.opts, :audit_dir)
    files = Map.keys(state.file_entries)
    tests = relativize_paths(state.baseline_test_paths, state.project_root)

    with {:ok, _rebuilt} <- Sandbox.rebuild(sandbox, files, state.baseline_test_paths),
         {:ok, compile} <-
           PortRunner.run_compile(
             timeout_ms: timeout_ms,
             cd: sandbox.root,
             output_file: output_path(audit_dir, mutant_id, "recovery", "compile")
           ) do
      compile_audit = audit_process_result({:ok, compile})
      first = run_recovery_tests(sandbox, tests, timeout_ms, audit_dir, mutant_id, 1)

      case first do
        {:ok, test_audit} ->
          {:ok, recovery_audit(compile_audit, [test_audit])}

        {:error, :baseline_test_failures, test_audit} ->
          second = run_recovery_tests(sandbox, tests, timeout_ms, audit_dir, mutant_id, 2)

          case second do
            {:ok, second_audit} ->
              {:ok, recovery_audit(compile_audit, [test_audit, second_audit])}

            {:error, reason, second_audit} ->
              {:error, reason, recovery_audit(compile_audit, [test_audit, second_audit])}
          end

        {:error, reason, test_audit} ->
          {:error, reason, recovery_audit(compile_audit, [test_audit])}
      end
    else
      {:error, reason} -> {:error, reason, %{rebuilt: true}}
    end
  end

  defp run_recovery_tests(sandbox, tests, timeout_ms, audit_dir, mutant_id, attempt) do
    result =
      PortRunner.run_tests(tests,
        timeout_ms: timeout_ms,
        cd: sandbox.root,
        no_compile: true,
        output_file: output_path(audit_dir, mutant_id, "recovery-#{attempt}", "test")
      )

    audit = %{attempt: attempt, test: audit_process_result(result)}

    case result do
      {:ok, %{failures: 0}} -> {:ok, audit}
      {:ok, _test} -> {:error, :baseline_test_failures, audit}
      {:error, reason} -> {:error, reason, audit}
    end
  end

  defp recovery_audit(compile, test_attempts) do
    %{
      rebuilt: true,
      baseline: %{compile: compile, test: test_attempts |> List.last() |> Map.fetch!(:test)},
      test_attempts: test_attempts
    }
  end

  # Picks the test files to run for a mutation. With coverage guidance, runs
  # only the tests that execute the mutated line (or :no_coverage if none).
  # Without runtime coverage evidence, runs the full declared test corpus.
  # Paths are made project-root-relative for `mix test` in the sandbox.
  defp select_tests(mutation, state) do
    case Keyword.get(state.opts, :coverage_index) do
      nil ->
        default_selection(mutation, state)

      index ->
        case Coverage.tests_for(index, mutation.location.file, mutation.location.line) do
          # Executable line that no test runs: nothing can kill it.
          :no_coverage ->
            :no_coverage

          {:covered, tests} ->
            {:run, relativize_paths(tests, state.project_root)}

          # No coverage data for the line (e.g. a non-executable def/module
          # header, or a macro-expanded expression): use every test known to
          # execute the source file. With no such evidence, keep the full corpus
          # rather than skip a possibly-killable mutant.
          :unknown ->
            case Coverage.tests_for_file(index, mutation.location.file) do
              [] -> default_selection(mutation, state)
              tests -> {:run, relativize_paths(tests, state.project_root)}
            end
        end
    end
  end

  defp default_selection(_mutation, state) do
    state.test_paths
    |> Config.expand_test_paths()
    |> relativize_paths(state.project_root)
    |> then(&{:run, &1})
  end

  defp baseline_test_paths(mutations, test_paths, project_root, opts) do
    full_corpus = Config.expand_test_paths(test_paths)

    case Keyword.get(opts, :coverage_index) do
      nil ->
        full_corpus

      index ->
        mutations
        |> Enum.reduce_while(MapSet.new(), fn mutation, selected ->
          case tests_for_baseline(mutation, index) do
            :full_corpus ->
              {:halt, :full_corpus}

            tests ->
              {:cont,
               Enum.reduce(tests, selected, &MapSet.put(&2, Path.expand(&1, project_root)))}
          end
        end)
        |> case do
          :full_corpus -> full_corpus
          selected -> selected |> MapSet.to_list() |> Enum.sort()
        end
    end
  end

  defp tests_for_baseline(mutation, index) do
    case Coverage.tests_for(index, mutation.location.file, mutation.location.line) do
      {:covered, tests} ->
        tests

      :no_coverage ->
        []

      :unknown ->
        case Coverage.tests_for_file(index, mutation.location.file) do
          [] -> :full_corpus
          tests -> tests
        end
    end
  end

  defp run_in_sandbox(
         sandbox,
         file_path,
         mutated_source,
         file_entry,
         test_files,
         context
       ) do
    %{timeout_ms: timeout_ms, audit_dir: audit_dir, mutant_id: mutant_id, attempt: attempt} =
      context

    apply_started = System.monotonic_time(:millisecond)

    case Sandbox.apply_mutation(sandbox, file_path, mutated_source, file_entry.module_name) do
      {:ok, _precompiled} ->
        apply_ms = System.monotonic_time(:millisecond) - apply_started

        compile_output = output_path(audit_dir, mutant_id, attempt, "compile")
        test_output = output_path(audit_dir, mutant_id, attempt, "test")

        {result, error, compile_ms, test_ms, audit} =
          try do
            compile_started = System.monotonic_time(:millisecond)

            compile_result =
              PortRunner.run_compile(
                timeout_ms: timeout_ms,
                cd: sandbox.root,
                output_file: compile_output
              )

            measured_compile_ms = System.monotonic_time(:millisecond) - compile_started

            case compile_result do
              {:ok, compile} ->
                test_started = System.monotonic_time(:millisecond)

                test_result =
                  PortRunner.run_tests(test_files,
                    timeout_ms: timeout_ms,
                    cd: sandbox.root,
                    no_compile: true,
                    output_file: test_output
                  )

                measured_test_ms = System.monotonic_time(:millisecond) - test_started
                {status, test_error, _reported_test_ms} = classify_test_result(test_result)

                {status, test_error, compile.duration_ms, measured_test_ms,
                 audit_attempt(attempt, test_files, compile_result, test_result)}

              {:error, reason} ->
                {status, error, _duration} = classify_test_result({:error, reason})

                {status, error, measured_compile_ms, 0,
                 audit_attempt(attempt, test_files, compile_result, nil)}
            end
          rescue
            error ->
              {:infrastructure_error, error, 0, 0, %{attempt: attempt, exception: inspect(error)}}
          end

        cleanup_started = System.monotonic_time(:millisecond)
        Sandbox.restore(sandbox, file_path)
        cleanup_ms = System.monotonic_time(:millisecond) - cleanup_started

        {result, error,
         %{apply_ms: apply_ms, compile_ms: compile_ms, test_ms: test_ms, cleanup_ms: cleanup_ms},
         audit}

      {:error, reason} ->
        {:infrastructure_error, reason,
         %{apply_ms: System.monotonic_time(:millisecond) - apply_started}, nil}
    end
  end

  defp classify_test_result({:ok, %{failures: 0, duration_ms: duration}}),
    do: {:survived, nil, duration}

  defp classify_test_result({:ok, %{failures: _, duration_ms: duration}}),
    do: {:killed, nil, duration}

  defp classify_test_result({:error, {:timeout, output}}), do: {:timeout, {:timeout, output}, 0}

  defp classify_test_result({:error, {:timeout, output, artifact}}),
    do: {:timeout, {:timeout, output, artifact}, 0}

  defp classify_test_result({:error, {:compile_error, _, _, _} = reason}),
    do: {:compile_failure, reason, 0}

  defp classify_test_result({:error, {:compile_error, _, _} = reason}),
    do: {:compile_failure, reason, 0}

  defp classify_test_result({:error, {:compile_error, _} = reason}),
    do: {:compile_failure, reason, 0}

  defp classify_test_result({:error, reason}), do: {:infrastructure_error, reason, 0}

  defp output_path(nil, _id, _attempt, _kind), do: nil

  defp output_path(directory, id, attempt, kind) do
    Path.join([directory, "outputs", "#{id}.attempt-#{attempt}.#{kind}.log"])
  end

  defp audit_attempt(attempt, tests, compile_result, test_result) do
    %{
      attempt: attempt,
      tests: tests,
      commands: [
        ["mix", "compile", "--no-deps-check", "--no-archives-check"],
        [
          "mix",
          "test",
          "--max-failures",
          "1",
          "--formatter",
          "Muex.ExUnitFormatter",
          "--no-compile",
          "--no-deps-check",
          "--no-archives-check"
          | tests
        ]
      ],
      compile: audit_process_result(compile_result),
      test: audit_process_result(test_result)
    }
  end

  defp audit_process_result(nil), do: nil

  defp audit_process_result({:ok, result}) do
    Map.take(result, [:exit_code, :duration_ms, :failures, :tests, :output_artifact])
  end

  defp audit_process_result({:error, {:test_process_failed, exit_code, _output} = reason}) do
    %{
      error: inspect(reason),
      failure: :test_process_failed,
      exit_code: exit_code,
      output_artifact: tuple_artifact(reason)
    }
  end

  defp audit_process_result(
         {:error, {:test_process_failed, exit_code, _output, _artifact} = reason}
       ) do
    %{
      error: inspect(reason),
      failure: :test_process_failed,
      exit_code: exit_code,
      output_artifact: tuple_artifact(reason)
    }
  end

  defp audit_process_result({:error, reason}),
    do: %{error: inspect(reason), output_artifact: tuple_artifact(reason)}

  defp tuple_artifact(tuple) when is_tuple(tuple) do
    case tuple |> Tuple.to_list() |> List.last() do
      %{path: _path, bytes: _bytes, sha256: _sha256} = artifact -> artifact
      _ -> nil
    end
  end

  defp tuple_artifact(_other), do: nil

  # Convert absolute test file paths to relative so `mix test` (running in
  # the sandbox, which mirrors the project root) can resolve them.
  defp relativize_paths(paths, project_root) do
    Enum.map(paths, &Path.relative_to(&1, project_root))
  end

  defp prepare_and_baseline(sandboxes, mutations, test_paths, project_root, opts) do
    files = Enum.map(mutations, & &1.location.file)
    tests = test_paths |> Config.expand_test_paths() |> relativize_paths(project_root)
    timeout_ms = Keyword.get(opts, :baseline_timeout_ms, 120_000)
    checkpoint = Keyword.get(opts, :checkpoint)
    audit_dir = Keyword.get(opts, :audit_dir)

    sandboxes
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {sandbox, index}, :ok ->
      context = %{
        files: files,
        test_paths: test_paths,
        tests: tests,
        timeout_ms: timeout_ms,
        audit_dir: audit_dir,
        index: index
      }

      baseline_sandbox(sandbox, checkpoint, context)
    end)
  end

  defp baseline_sandbox(sandbox, checkpoint, context) do
    first =
      run_baseline_attempt(sandbox, Map.merge(context, %{attempt: 1, preparation: :prepare}))

    case Checkpoint.append_baseline(checkpoint, context.index, context.tests, 1, first) do
      :ok ->
        case first do
          {:ok, _} -> {:cont, :ok}
          {:error, _reason, _audit} -> retry_baseline(sandbox, checkpoint, context)
        end

      {:error, reason} ->
        {:halt, {:error, {:checkpoint_write_failed, reason}}}
    end
  end

  defp retry_baseline(sandbox, checkpoint, context) do
    second =
      run_baseline_attempt(sandbox, Map.merge(context, %{attempt: 2, preparation: :rebuild}))

    case Checkpoint.append_baseline(checkpoint, context.index, context.tests, 2, second) do
      :ok ->
        case second do
          {:ok, _} -> {:cont, :ok}
          {:error, reason, _audit} -> {:halt, {:error, {:baseline_failed, context.index, reason}}}
        end

      {:error, reason} ->
        {:halt, {:error, {:checkpoint_write_failed, reason}}}
    end
  end

  defp run_baseline_attempt(sandbox, context) do
    %{
      files: files,
      test_paths: test_paths,
      tests: tests,
      timeout_ms: timeout_ms,
      audit_dir: audit_dir,
      index: index,
      attempt: attempt,
      preparation: preparation
    } = context

    prepared =
      case preparation do
        :prepare ->
          Sandbox.prepare(sandbox, files)

        :rebuild ->
          case Sandbox.rebuild(sandbox, files, test_paths) do
            {:ok, _rebuilt} -> :ok
            {:error, _reason} = error -> error
          end
      end

    case prepared do
      :ok ->
        compile =
          PortRunner.run_compile(
            timeout_ms: timeout_ms,
            cd: sandbox.root,
            output_file: output_path(audit_dir, "baseline-#{index}", attempt, "compile")
          )

        case compile do
          {:ok, compile_result} ->
            run_baseline_tests(
              sandbox,
              tests,
              timeout_ms,
              audit_dir,
              index,
              attempt,
              compile,
              compile_result
            )

          {:error, reason} ->
            {:error, reason, %{compile: audit_process_result(compile), test: nil}}
        end

      {:error, reason} ->
        {:error, reason, %{compile: nil, test: nil}}
    end
  end

  defp run_baseline_tests(
         _sandbox,
         [],
         _timeout_ms,
         _audit_dir,
         _index,
         _attempt,
         _compile,
         compile_result
       ),
       do: {:ok, %{compile: compile_result, test: nil}}

  defp run_baseline_tests(
         sandbox,
         tests,
         timeout_ms,
         audit_dir,
         index,
         attempt,
         compile,
         compile_result
       ) do
    test =
      PortRunner.run_tests(tests,
        timeout_ms: timeout_ms,
        cd: sandbox.root,
        no_compile: true,
        output_file: output_path(audit_dir, "baseline-#{index}", attempt, "test")
      )

    case test do
      {:ok, %{failures: 0} = test_result} ->
        {:ok, %{compile: compile_result, test: test_result}}

      {:ok, test_result} ->
        {:error, :test_failures,
         %{compile: audit_process_result(compile), test: audit_process_result({:ok, test_result})}}

      {:error, reason} ->
        {:error, reason,
         %{compile: audit_process_result(compile), test: audit_process_result(test)}}
    end
  end

  defp stop_with_error(reason, active_workers, state) do
    shutdown_workers(active_workers)
    Sandbox.cleanup(state.sandboxes)
    GenServer.reply(state.caller, {:error, reason})

    {:noreply,
     %{
       state
       | caller: nil,
         active_workers: %{},
         monitor_to_worker: %{},
         sandboxes: [],
         pending_by_file: %{}
     }}
  end

  @impl true
  def terminate(_reason, state) do
    shutdown_workers(state.active_workers)

    if state.sandboxes != [] do
      Sandbox.cleanup(state.sandboxes)
    end

    :ok
  end

  defp finish_worker(worker_ref, pid, monitor_ref) do
    send(pid, {:worker_finished, worker_ref})
    deadline = System.monotonic_time(:millisecond) + @worker_shutdown_timeout_ms
    await_workers(%{monitor_ref => pid}, deadline)
  end

  defp shutdown_workers(active_workers) when map_size(active_workers) == 0, do: :ok

  defp shutdown_workers(active_workers) do
    workers =
      Map.new(active_workers, fn {_worker_ref, {_mutation, _file, _sandbox, pid, monitor_ref}} ->
        {monitor_ref, pid}
      end)

    Enum.each(workers, fn {_monitor_ref, pid} -> Process.exit(pid, :shutdown) end)

    deadline = System.monotonic_time(:millisecond) + @worker_shutdown_timeout_ms
    await_workers(workers, deadline)
  end

  defp await_workers(workers, _deadline) when map_size(workers) == 0, do: :ok

  defp await_workers(workers, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, monitor_ref, :process, _pid, _reason} when is_map_key(workers, monitor_ref) ->
        await_workers(Map.delete(workers, monitor_ref), deadline)
    after
      remaining_ms ->
        Enum.each(workers, fn {_monitor_ref, pid} -> Process.exit(pid, :kill) end)
        await_killed_workers(workers)
    end
  end

  defp await_killed_workers(workers) when map_size(workers) == 0, do: :ok

  defp await_killed_workers(workers) do
    receive do
      {:DOWN, monitor_ref, :process, _pid, _reason} when is_map_key(workers, monitor_ref) ->
        await_killed_workers(Map.delete(workers, monitor_ref))
    end
  end
end
