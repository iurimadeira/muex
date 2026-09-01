defmodule Muex.Checkpoint do
  @moduledoc false

  @version 1
  @terminal ~w(killed survived invalid timeout equivalent no_coverage no_op)

  def open(nil, _metadata, _mutations), do: {:ok, %{path: nil, completed: %{}}}

  def open(path, metadata, mutations) do
    path = Path.expand(path)
    ids = Enum.map(mutations, & &1.id)
    header = header(metadata, ids)

    with :ok <- safe_checkpoint_path(path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- safe_checkpoint_path(path),
         {:ok, lease} <- acquire_lease(path) do
      case open_locked(path, header, ids, lease) do
        {:ok, checkpoint} -> {:ok, checkpoint}
        {:error, _reason} = error -> close_and_return(%{path: path, lease: lease}, error)
      end
    end
  end

  def close(nil), do: :ok
  def close(%{path: nil}), do: :ok

  def close(%{path: path, lease: lease}) do
    with :ok <- safe_checkpoint_path(path) do
      release_lease(lease)
    end
  end

  defp release_lease(lease) do
    request = make_ref()
    send(lease, {:release, self(), request})

    receive do
      {^request, :ok} -> :ok
    after
      1_000 -> {:error, :checkpoint_lease_release_timeout}
    end
  end

  def append_baseline(nil, _sandbox, _tests, _result), do: :ok
  def append_baseline(%{path: nil}, _sandbox, _tests, _result), do: :ok

  def append_baseline(checkpoint, sandbox, tests, result),
    do: append_baseline(checkpoint, sandbox, tests, 1, result)

  def append_baseline(nil, _sandbox, _tests, _attempt, _result), do: :ok
  def append_baseline(%{path: nil}, _sandbox, _tests, _attempt, _result), do: :ok

  def append_baseline(checkpoint, sandbox, tests, attempt, result) do
    append(checkpoint, %{
      type: "baseline",
      sandbox: sandbox,
      attempt: attempt,
      tests: tests,
      commands: baseline_commands(tests),
      result: encode_baseline(result),
      recorded_at: DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  def append_result(nil, _result), do: :ok
  def append_result(%{path: nil}, _result), do: :ok

  def append_result(checkpoint, result) do
    append(checkpoint, %{
      type: "result",
      id: result.mutation.id,
      status: Atom.to_string(result.result),
      duration_ms: result.duration_ms,
      error: encode_term(result.error),
      timings: Map.get(result, :timings, %{}),
      audit: Map.get(result, :audit)
    })
  end

  def append_event(nil, _event), do: :ok
  def append_event(%{path: nil}, _event), do: :ok

  def append_event(checkpoint, event),
    do:
      append(
        checkpoint,
        Map.put(event, :recorded_at, DateTime.to_iso8601(DateTime.utc_now()))
      )

  defp open_locked(path, header, ids, lease) do
    with :ok <- ensure_file(path, header),
         {:ok, lines} <- read_complete_lines(path),
         :ok <- validate_header(lines, header),
         {:ok, completed} <- load_results(tl(lines), MapSet.new(ids)) do
      {:ok, %{path: path, completed: completed, lease: lease}}
    end
  end

  defp acquire_lease(path) do
    owner = self()
    request = make_ref()
    lease = spawn(fn -> initialize_lease(owner, path <> ".lock", request) end)

    receive do
      {^request, :ok} -> {:ok, lease}
      {^request, {:error, :eexist}} -> {:error, :checkpoint_locked}
      {^request, {:error, reason}} -> {:error, {:checkpoint_lease_failed, reason}}
    after
      1_000 -> {:error, :checkpoint_lease_timeout}
    end
  end

  defp initialize_lease(owner, lock_path, request) do
    case File.mkdir(lock_path) do
      :ok ->
        monitor = Process.monitor(owner)
        send(owner, {request, :ok})
        lease_loop(owner, monitor, lock_path)

      {:error, reason} ->
        send(owner, {request, {:error, reason}})
    end
  end

  defp lease_loop(owner, monitor, lock_path) do
    receive do
      {:check, caller, request} ->
        send(caller, {request, :ok})
        lease_loop(owner, monitor, lock_path)

      {:release, caller, request} ->
        send(caller, {request, release_lock(lock_path)})

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        release_lock(lock_path)
    end
  end

  defp release_lock(lock_path) do
    with :ok <- safe_checkpoint_path(lock_path), do: File.rmdir(lock_path)
  end

  defp lease_active(lease) do
    request = make_ref()
    send(lease, {:check, self(), request})

    receive do
      {^request, :ok} -> :ok
    after
      1_000 -> {:error, :checkpoint_lease_lost}
    end
  end

  defp close_and_return(checkpoint, error) do
    case close(checkpoint) do
      :ok -> error
      {:error, _reason} = close_error -> close_error
    end
  end

  defp safe_checkpoint_path(path) do
    unsafe =
      path
      |> path_and_parents()
      |> Enum.find(fn component ->
        match?({:ok, %File.Stat{type: :symlink}}, File.lstat(component))
      end)

    if unsafe, do: {:error, {:unsafe_checkpoint_path, path}}, else: :ok
  end

  defp path_and_parents(path) do
    Stream.unfold(Path.expand(path), fn current ->
      parent = Path.dirname(current)
      if parent == current, do: nil, else: {current, parent}
    end)
  end

  defp header(metadata, ids) do
    %{
      type: "header",
      version: @version,
      campaign_fingerprint: Map.get(metadata, :campaign_fingerprint),
      run_fingerprint: metadata.run,
      source_fingerprint: metadata.source,
      mutation_set_fingerprint: digest(Enum.sort(ids)),
      total: length(ids)
    }
  end

  defp ensure_file(path, header) do
    if File.exists?(path) do
      :ok
    else
      File.write(path, Jason.encode!(header) <> "\n", [:binary, :sync])
    end
  end

  defp read_complete_lines(path) do
    with {:ok, contents} <- File.read(path) do
      parts = :binary.split(contents, "\n", [:global])

      complete_parts =
        case List.last(parts) do
          "" -> Enum.drop(parts, -1)
          _partial -> Enum.drop(parts, -1)
        end

      if List.last(parts) != "" do
        File.write!(path, Enum.join(complete_parts, "\n") <> "\n", [:binary, :sync])
      end

      decode_lines(complete_parts)
    end
  end

  defp decode_lines([]), do: {:error, :checkpoint_empty}

  defp decode_lines(lines) do
    lines
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, decoded} ->
      case Jason.decode(line) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        {:error, _} -> {:halt, {:error, :checkpoint_corrupt}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp validate_header([actual | _], expected) do
    if actual == stringify_keys(expected),
      do: :ok,
      else: {:error, :checkpoint_fingerprint_mismatch}
  end

  defp load_results(lines, valid_ids) do
    Enum.reduce_while(lines, {:ok, %{}}, fn
      %{"type" => "baseline"}, acc ->
        {:cont, acc}

      %{"type" => "infrastructure_error"}, acc ->
        {:cont, acc}

      %{"type" => "result", "id" => id, "status" => status} = row, {:ok, completed}
      when status in @terminal ->
        cond do
          not MapSet.member?(valid_ids, id) ->
            {:halt, {:error, :checkpoint_unknown_mutation}}

          Map.has_key?(completed, id) ->
            {:halt, {:error, :checkpoint_duplicate_mutation}}

          true ->
            result = %{
              result: String.to_existing_atom(status),
              duration_ms: Map.get(row, "duration_ms", 0),
              error: Map.get(row, "error"),
              timings: Map.get(row, "timings", %{})
            }

            {:cont, {:ok, Map.put(completed, id, result)}}
        end

      _row, _acc ->
        {:halt, {:error, :checkpoint_corrupt}}
    end)
  end

  defp append(%{path: path, lease: lease}, value) do
    with :ok <- lease_active(lease),
         :ok <- safe_checkpoint_path(path) do
      case File.open(path, [:append, :binary, :sync], fn file ->
             binwrite(file, Jason.encode!(value) <> "\n")
           end) do
        {:ok, :ok} -> :ok
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, _} = error -> error
      end
    end
  end

  defp binwrite(file, data) do
    IO.binwrite(file, data)
  rescue
    error in ErlangError -> {:error, error.original}
  end

  defp digest(term) do
    :sha256 |> :crypto.hash(:erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
  end

  defp encode_term(nil), do: nil
  defp encode_term(term) when is_binary(term) or is_number(term) or is_boolean(term), do: term
  defp encode_term(term), do: inspect(term)

  defp encode_baseline({:ok, %{compile: compile, test: test}}) do
    %{
      status: "passed",
      compile: Map.delete(compile, :output),
      test: if(is_map(test), do: Map.delete(test, :output))
    }
  end

  defp encode_baseline({:error, reason, audit}) do
    audit
    |> Map.new(fn {kind, result} ->
      {kind, if(is_map(result), do: Map.delete(result, :output), else: result)}
    end)
    |> Map.merge(%{status: "failed", error: encode_term(reason)})
  end

  defp encode_baseline({:error, reason}), do: %{status: "failed", error: encode_term(reason)}

  defp baseline_commands(tests) do
    compile = ["mix", "compile", "--no-deps-check", "--no-archives-check"]

    case tests do
      [] ->
        [compile]

      tests ->
        [
          compile,
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
        ]
    end
  end

  defp stringify_keys(value), do: value |> Jason.encode!() |> Jason.decode!()
end
