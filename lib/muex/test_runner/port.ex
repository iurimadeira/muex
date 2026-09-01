defmodule Muex.TestRunner.Port do
  @moduledoc """
  Runs tests in isolated Erlang port processes.

  Each test run executes in a separate BEAM VM via port, providing complete isolation
  between mutations and preventing hot-swapping conflicts.

  The worker pool deletes the .beam file for the mutated module before calling this
  runner. `mix test` performs incremental compilation automatically, so only the
  single mutated file is recompiled — no `compile --force` needed. This is critical
  for umbrella projects where a forced recompile takes minutes per mutation.
  """
  @result_nonce_env "MUEX_EXUNIT_RESULT_NONCE"

  @type output_artifact :: %{
          path: Path.t() | nil,
          bytes: non_neg_integer(),
          sha256: String.t()
        }
  @type test_result :: %{
          optional(:tests) => non_neg_integer(),
          failures: non_neg_integer(),
          output: String.t(),
          output_artifact: output_artifact(),
          exit_code: non_neg_integer(),
          duration_ms: non_neg_integer()
        }
  @doc """
  Runs tests in an isolated port process.

  ## Parameters

    - `test_files` - List of test file paths to execute
    - `opts` - Options:
      - `:timeout_ms` - Test timeout in milliseconds (default: 5000)
      - `:mix_env` - Mix environment (default: "test")
      - `:cd` - Working directory for the port process (default: current dir).
        When running inside a sandbox, this should be the sandbox root.

  ## Returns

    `{:ok, test_result}` or `{:error, reason}`
  """
  @spec run_tests([Path.t()], keyword()) :: {:ok, test_result()} | {:error, term()}
  def run_tests(test_files, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5000)
    mix_env = Keyword.get(opts, :mix_env, "test")
    cd = Keyword.get(opts, :cd)
    no_compile = Keyword.get(opts, :no_compile, false)
    output_file = Keyword.get(opts, :output_file)
    result_nonce = result_nonce()
    start_time = System.monotonic_time(:millisecond)

    test_files
    |> spawn_test_port(mix_env, timeout_ms, cd, no_compile, output_file, result_nonce)
    |> handle_test_port_result(start_time, result_nonce)
  end

  defp handle_test_port_result({:ok, output, 0}, start_time, result_nonce) do
    duration_ms = System.monotonic_time(:millisecond) - start_time

    case exunit_result(output.text, result_nonce) do
      {:ok, %{failures: 0} = result} ->
        {:ok,
         Map.merge(result, %{
           output: output.text,
           output_artifact: output.artifact,
           exit_code: 0,
           duration_ms: duration_ms
         })}

      {:ok, result} ->
        {:error,
         add_artifact({:test_process_inconsistent, 0, result, output.text}, output.artifact)}

      :ambiguous ->
        {:error, add_artifact({:ambiguous_exunit_result, 0, output.text}, output.artifact)}

      :error ->
        {:error, add_artifact({:missing_exunit_result, 0, output.text}, output.artifact)}
    end
  end

  defp handle_test_port_result({:ok, output, exit_code}, start_time, result_nonce) do
    duration_ms = System.monotonic_time(:millisecond) - start_time

    case exunit_result(output.text, result_nonce) do
      {:ok, %{failures: failures} = result} when failures > 0 ->
        {:ok,
         Map.merge(result, %{
           output: output.text,
           output_artifact: output.artifact,
           exit_code: exit_code,
           duration_ms: duration_ms
         })}

      :ambiguous ->
        {:error,
         add_artifact({:ambiguous_exunit_result, exit_code, output.text}, output.artifact)}

      _other ->
        {:error, add_artifact(test_process_failure(output.text, exit_code), output.artifact)}
    end
  end

  defp handle_test_port_result({:error, {:timeout, output}}, _start_time, _result_nonce) do
    {:error, add_artifact({:timeout, output.text}, output.artifact)}
  end

  defp handle_test_port_result({:error, reason}, _start_time, _result_nonce), do: {:error, reason}

  defp test_process_failure(output, exit_code) do
    cond do
      compile_error?(output) -> {:compile_error, output}
      missing_test_helper?(output) -> {:no_test_summary, output}
      true -> {:test_process_failed, exit_code, output}
    end
  end

  @doc false
  @spec run_compile(keyword()) :: {:ok, test_result()} | {:error, term()}
  def run_compile(opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5000)
    mix_env = Keyword.get(opts, :mix_env, "test")
    cd = Keyword.get(opts, :cd)
    output_file = Keyword.get(opts, :output_file)
    start_time = System.monotonic_time(:millisecond)
    args = ["compile", "--no-deps-check", "--no-archives-check"]

    case spawn_mix_port(args, mix_env, timeout_ms, cd, output_file, []) do
      {:ok, output, 0} ->
        {:ok,
         %{
           failures: 0,
           output: output.text,
           output_artifact: output.artifact,
           exit_code: 0,
           duration_ms: System.monotonic_time(:millisecond) - start_time
         }}

      {:ok, output, exit_code} ->
        {:error, add_artifact({:compile_error, exit_code, output.text}, output.artifact)}

      {:error, {:timeout, output}} ->
        {:error, add_artifact({:timeout, output.text}, output.artifact)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp spawn_test_port(test_files, mix_env, timeout_ms, cd, no_compile, output_file, result_nonce) do
    # When the caller pre-compiled the mutated module and wrote the .beam
    # directly, we pass --no-compile to skip Mix's compilation phase entirely.
    # We also always pass --no-deps-check and --no-archives-check since deps
    # don't change between mutations.
    compile_flags =
      if no_compile do
        ["--no-compile", "--no-deps-check", "--no-archives-check"]
      else
        ["--no-deps-check", "--no-archives-check"]
      end

    # --max-failures 1: a mutant is killed by any failing test, so stop at the
    # first one instead of running the whole (selected) suite.
    args =
      ["test", "--max-failures", "1", "--formatter", "Muex.ExUnitFormatter"] ++
        compile_flags ++ test_files

    spawn_mix_port(args, mix_env, timeout_ms, cd, output_file, [{@result_nonce_env, result_nonce}])
  end

  defp spawn_mix_port(args, mix_env, timeout_ms, cd, output_file, extra_env) do
    runtime_temp_env = runtime_temp_env(cd)

    current_env =
      Enum.map(System.get_env(), fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    inherited_mix_paths = [
      ~c"MIX_ENV",
      ~c"MIX_BUILD_ROOT",
      ~c"MIX_BUILD_PATH",
      ~c"MIX_DEPS_PATH",
      String.to_charlist(@result_nonce_env)
    ]

    inherited_paths = inherited_mix_paths ++ Enum.map(runtime_temp_env, &elem(&1, 0))

    extra_env =
      Enum.map(extra_env, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    env =
      Enum.reject(current_env, fn {k, _v} -> k in inherited_paths end) ++
        [{~c"MIX_ENV", String.to_charlist(mix_env)} | extra_env] ++ runtime_temp_env

    cmd_args = Enum.map(args, &String.to_charlist/1)

    port_opts =
      maybe_add_cd(
        [:binary, :exit_status, :stderr_to_stdout, :hide, env: env, args: cmd_args],
        cd
      )

    with mix_path when is_binary(mix_path) <- System.find_executable("mix"),
         {:ok, output} <- open_output(output_file) do
      try do
        port = Port.open({:spawn_executable, mix_path}, port_opts)

        case port_process_identity(port) do
          {:ok, root} ->
            deadline = System.monotonic_time(:millisecond) + timeout_ms
            collect_port(port, root, output, deadline)

          {:error, _reason} = error ->
            safe_close(port)
            error
        end
      after
        safe_close_output(output)
      end
    else
      nil -> {:error, :mix_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_add_cd(port_opts, nil), do: port_opts
  defp maybe_add_cd(port_opts, cd), do: [{:cd, String.to_charlist(cd)} | port_opts]

  defp runtime_temp_env(nil), do: []

  defp runtime_temp_env(cd) when is_binary(cd) do
    canonical_cd = Path.expand(cd)
    runtime_temp = Path.join(canonical_cd, "tmp")

    with true <- cd == canonical_cd,
         {:ok, %{type: :directory}} <- File.lstat(cd),
         {:ok, ^cd} <- canonical_existing(cd),
         :ok <- ensure_directory(runtime_temp),
         {:ok, %{type: :directory}} <- File.lstat(runtime_temp),
         {:ok, ^runtime_temp} <- canonical_existing(runtime_temp) do
      temp_environment(runtime_temp)
    else
      _unsafe ->
        raise ArgumentError, "unsafe Muex sandbox temp directory: #{inspect(runtime_temp)}"
    end
  end

  defp runtime_temp_env(cd),
    do: raise(ArgumentError, "unsafe Muex sandbox temp directory: #{inspect(cd)}")

  defp ensure_directory(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_existing(path) do
    case System.cmd("realpath", ["-e", "--", path], stderr_to_stdout: true) do
      {canonical, 0} -> {:ok, String.trim(canonical)}
      {_message, _status} -> {:error, :not_canonical}
    end
  end

  defp temp_environment(runtime_temp) do
    value = String.to_charlist(runtime_temp)
    Enum.map(~w(TMPDIR TMP TEMP), &{String.to_charlist(&1), value})
  end

  defp collect_port(port, root, output, deadline) do
    collect_output(port, root, output, deadline)
  catch
    kind, reason ->
      terminate_port(port, root)
      :erlang.raise(kind, reason, __STACKTRACE__)
  after
    safe_close(port)
  end

  defp collect_output(port, root, output, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when is_binary(data) ->
        case write_output(output, data) do
          {:ok, output} ->
            collect_output(port, root, output, deadline)

          {:error, reason} ->
            terminate_port(port, root)
            drain_without_output(port, System.monotonic_time(:millisecond) + 500)
            {:error, reason}
        end

      {^port, {:exit_status, exit_code}} ->
        {:ok, finish_output(output), exit_code}

      {:EXIT, owner, _reason} when is_pid(owner) ->
        terminate_port(port, root)
        drain_without_output(port, System.monotonic_time(:millisecond) + 500)
        Process.exit(self(), :kill)

      _msg ->
        collect_output(port, root, output, deadline)
    after
      remaining_ms ->
        case terminate_port(port, root) do
          :ok ->
            deadline = System.monotonic_time(:millisecond) + 500

            case drain_after_kill(port, output, deadline) do
              {:ok, output} ->
                {:error, {:timeout, finish_output(output)}}

              {:error, reason} ->
                drain_without_output(port, deadline)
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp drain_after_kill(port, output, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when is_binary(data) ->
        case write_output(output, data) do
          {:ok, output} -> drain_after_kill(port, output, deadline)
          {:error, reason} -> {:error, reason}
        end

      {^port, {:exit_status, _exit_code}} ->
        {:ok, output}
    after
      remaining_ms -> {:ok, output}
    end
  end

  defp drain_without_output(port, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, _data}} -> drain_without_output(port, deadline)
      {^port, {:exit_status, _exit_code}} -> :ok
    after
      remaining_ms -> :ok
    end
  end

  defp terminate_port(port, root) do
    result = terminate_process_tree(root)
    safe_close(port)
    result
  end

  defp port_process_identity(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> process_identity(pid)
      nil -> {:error, :port_process_not_found}
    end
  end

  defp terminate_process_tree(root) do
    captured = %{root.pid => %{identity: root, parent_pid: nil}}

    case signal_identity(root, "STOP") do
      :ok ->
        case freeze_descendants(captured) do
          {:ok, frozen} ->
            terminate_captured(frozen, root.pid)

          {:error, reason, frozen} ->
            _cleanup = terminate_captured(frozen, root.pid)
            {:error, reason}
        end

      :gone ->
        {:error, :port_process_root_gone}

      {:error, _reason} = error ->
        error
    end
  end

  defp freeze_descendants(captured) do
    case process_tree() do
      {:ok, processes} ->
        additions = descendant_additions(captured, processes)

        case freeze_additions(additions, captured) do
          {:ok, ^captured} -> {:ok, captured}
          {:ok, expanded} -> freeze_descendants(expanded)
          {:error, reason, expanded} -> {:error, reason, expanded}
        end

      {:error, reason} ->
        {:error, reason, captured}
    end
  end

  defp descendant_additions(captured, processes) do
    processes_by_pid = Map.new(processes, &{&1.identity.pid, &1})
    expand_descendants(captured, processes_by_pid, [])
  end

  defp expand_descendants(captured, processes, additions) do
    discovered =
      processes
      |> Map.values()
      |> Enum.filter(fn process ->
        case {Map.get(captured, process.parent_pid), Map.get(processes, process.parent_pid)} do
          {%{identity: parent}, %{identity: snapshot_parent}} when parent == snapshot_parent ->
            not same_identity?(Map.get(captured, process.identity.pid), process.identity)

          _other ->
            false
        end
      end)
      |> Enum.sort_by(& &1.identity.pid)

    if discovered == [] do
      additions
    else
      expanded = Map.merge(captured, Map.new(discovered, &{&1.identity.pid, &1}))
      expand_descendants(expanded, processes, additions ++ discovered)
    end
  end

  defp same_identity?(%{identity: identity}, identity), do: true
  defp same_identity?(_captured, _identity), do: false

  defp freeze_additions(additions, captured) do
    Enum.reduce_while(additions, {:ok, captured}, fn process, {:ok, frozen} ->
      case signal_identity(process.identity, "STOP") do
        :ok -> {:cont, {:ok, Map.put(frozen, process.identity.pid, process)}}
        :gone -> {:cont, {:ok, frozen}}
        {:error, reason} -> {:halt, {:error, reason, frozen}}
      end
    end)
  end

  defp terminate_captured(captured, root_pid) do
    identities = descendants_postorder(root_pid, captured) ++ [captured[root_pid].identity]

    with :ok <- signal_identities(identities, "KILL") do
      await_process_exit(identities, 50)
    end
  end

  defp process_tree do
    if File.dir?("/proc"), do: proc_process_tree(), else: ps_process_tree()
  end

  defp proc_process_tree do
    case File.ls("/proc") do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          case Integer.parse(entry) do
            {pid, ""} -> [pid]
            _not_a_pid -> []
          end
        end)
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn pid, {:ok, processes} ->
          case proc_process(pid) do
            {:ok, process} -> {:cont, {:ok, [process | processes]}}
            {:error, :process_not_found} -> {:cont, {:ok, processes}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, processes} -> {:ok, Enum.reverse(processes)}
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        {:error, {:process_tree_snapshot_failed, reason}}
    end
  end

  defp ps_process_tree do
    case System.cmd("ps", ["-eo", "pid=,ppid=,lstart="], stderr_to_stdout: true) do
      {output, 0} ->
        parse_processes(output)

      {output, status} ->
        {:error, {:process_tree_snapshot_failed, status, output}}
    end
  end

  defp process_identity(pid) do
    if File.dir?("/proc") do
      case proc_process(pid) do
        {:ok, %{identity: identity}} -> {:ok, identity}
        {:error, _reason} = error -> error
      end
    else
      ps_process_identity(pid)
    end
  end

  defp proc_process(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> parse_proc_process(pid, stat)
      {:error, :enoent} -> {:error, :process_not_found}
      {:error, reason} -> {:error, {:process_identity_read_failed, pid, reason}}
    end
  end

  defp parse_proc_process(pid, stat) do
    case List.last(:binary.matches(stat, ") ")) do
      {comm_end, 2} ->
        prefix = binary_part(stat, 0, comm_end)
        rest_offset = comm_end + 2
        rest = binary_part(stat, rest_offset, byte_size(stat) - rest_offset)

        with [stat_pid, _command] <- String.split(prefix, " ", parts: 2),
             {^pid, ""} <- Integer.parse(stat_pid),
             fields when length(fields) > 19 <- String.split(rest),
             {parent_pid, ""} <- fields |> Enum.at(1) |> Integer.parse() do
          {:ok,
           %{
             identity: %{pid: pid, started_at: Enum.at(fields, 19)},
             parent_pid: parent_pid
           }}
        else
          _malformed -> {:error, {:process_identity_invalid, pid}}
        end

      nil ->
        {:error, {:process_identity_invalid, pid}}
    end
  end

  defp ps_process_identity(pid) do
    case System.cmd(
           "ps",
           ["-o", "pid=,ppid=,lstart=", "-p", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case parse_processes(output) do
          {:ok, [%{identity: identity}]} -> {:ok, identity}
          {:ok, []} -> {:error, :process_not_found}
          {:error, _reason} = error -> error
        end

      {_output, _status} ->
        {:error, :process_not_found}
    end
  end

  defp parse_processes(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, processes} ->
      case String.split(row) do
        [pid, parent_pid | started_at] when length(started_at) == 5 ->
          process = %{
            identity: %{pid: String.to_integer(pid), started_at: Enum.join(started_at, " ")},
            parent_pid: String.to_integer(parent_pid)
          }

          {:cont, {:ok, [process | processes]}}

        _malformed ->
          {:halt, {:error, {:process_tree_snapshot_invalid, row}}}
      end
    end)
    |> case do
      {:ok, processes} -> {:ok, Enum.reverse(processes)}
      {:error, _reason} = error -> error
    end
  end

  defp descendants_postorder(parent_pid, captured) do
    captured
    |> Map.values()
    |> Enum.filter(&(&1.parent_pid == parent_pid))
    |> Enum.sort_by(& &1.identity.pid)
    |> Enum.flat_map(fn process ->
      descendants_postorder(process.identity.pid, captured) ++ [process.identity]
    end)
  end

  defp signal_identities(identities, signal) do
    Enum.reduce_while(identities, :ok, fn identity, :ok ->
      case signal_identity(identity, signal) do
        :ok -> {:cont, :ok}
        :gone -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp signal_identity(identity, signal) do
    case process_identity(identity.pid) do
      {:ok, ^identity} ->
        case System.cmd(
               "kill",
               ["-#{signal}", "--", Integer.to_string(identity.pid)],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> :ok
          {output, status} -> signal_failure(identity, signal, status, output)
        end

      {:ok, _replacement} ->
        :gone

      {:error, :process_not_found} ->
        :gone

      {:error, _reason} = error ->
        error
    end
  end

  defp signal_failure(identity, signal, status, output) do
    case process_identity(identity.pid) do
      {:ok, ^identity} ->
        {:error, {:process_signal_failed, identity.pid, signal, status, output}}

      {:ok, _replacement} ->
        :gone

      {:error, :process_not_found} ->
        :gone

      {:error, _reason} = error ->
        error
    end
  end

  defp await_process_exit(identities, attempts_left) do
    case living_identities(identities) do
      {:ok, []} ->
        :ok

      {:ok, alive} when attempts_left == 0 ->
        {:error, {:process_cleanup_failed, alive}}

      {:ok, alive} ->
        Process.sleep(10)
        await_process_exit(alive, attempts_left - 1)

      {:error, _reason} = error ->
        error
    end
  end

  defp living_identities(identities) do
    Enum.reduce_while(identities, {:ok, []}, fn identity, {:ok, alive} ->
      case process_identity(identity.pid) do
        {:ok, ^identity} ->
          {:cont, {:ok, [identity | alive]}}

        {:ok, _replacement} ->
          {:cont, {:ok, alive}}

        {:error, :process_not_found} ->
          {:cont, {:ok, alive}}

        {:error, reason} ->
          {:halt, {:error, {:process_identity_unverifiable, identity.pid, reason}}}
      end
    end)
  end

  @compile_error_pattern ~r/\*\* \([\w.]*(?:Error|Missing[\w.]*)\)/

  defp compile_error?(output) do
    Regex.match?(@compile_error_pattern, output)
  end

  defp missing_test_helper?(output) do
    String.contains?(output, "Cannot run tests because test helper file")
  end

  defp open_output(nil),
    do:
      {:ok,
       %{io: nil, path: nil, capture: "", tail: "", bytes: 0, hash: :crypto.hash_init(:sha256)}}

  defp open_output(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      {:ok,
       %{io: io, path: path, capture: nil, tail: "", bytes: 0, hash: :crypto.hash_init(:sha256)}}
    end
  end

  defp write_output(output, data) do
    case binwrite(output.io, data) do
      :ok ->
        capture = if is_binary(output.capture), do: output.capture <> data
        tail = output.tail <> data

        tail =
          if byte_size(tail) > 65_536,
            do: binary_part(tail, byte_size(tail) - 65_536, 65_536),
            else: tail

        {:ok,
         %{
           output
           | capture: capture,
             tail: tail,
             bytes: output.bytes + byte_size(data),
             hash: :crypto.hash_update(output.hash, data)
         }}

      {:error, reason} ->
        {:error, {:output_write_failed, reason}}
    end
  end

  defp finish_output(output) do
    if output.io do
      :ok = :file.sync(output.io)
      :ok = File.close(output.io)
    end

    artifact = %{
      path: output.path,
      bytes: output.bytes,
      sha256: output.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
    }

    %{text: output.capture || output.tail, artifact: artifact}
  end

  defp binwrite(nil, _data), do: :ok

  defp binwrite(io, data) do
    IO.binwrite(io, data)
  rescue
    error in ErlangError -> {:error, error.original}
  end

  defp safe_close_output(%{io: nil}), do: :ok

  defp safe_close_output(%{io: io}) do
    File.close(io)
    :ok
  rescue
    _error in ErlangError -> :ok
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  catch
    :error, :badarg -> :ok
  end

  defp exunit_result(output, result_nonce) do
    marker = ~r/^MUEX_EXUNIT_RESULT:#{Regex.escape(result_nonce)}:(\{[^\n]+\})$/m

    case Regex.scan(marker, output, capture: :all_but_first) do
      [[json]] ->
        case Jason.decode(json, keys: :atoms) do
          {:ok, %{tests: tests, failures: failures}}
          when is_integer(tests) and tests >= 0 and is_integer(failures) and failures >= 0 ->
            {:ok, %{tests: tests, failures: failures}}

          _ ->
            :error
        end

      [] ->
        :error

      _multiple ->
        :ambiguous
    end
  end

  defp result_nonce do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp add_artifact(tuple, %{path: nil}), do: tuple

  defp add_artifact(tuple, artifact),
    do: tuple |> Tuple.to_list() |> Kernel.++([artifact]) |> List.to_tuple()
end
