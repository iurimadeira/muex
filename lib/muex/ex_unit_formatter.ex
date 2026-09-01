defmodule Muex.ExUnitFormatter do
  @moduledoc false

  use GenServer

  @result_nonce_env "MUEX_EXUNIT_RESULT_NONCE"

  def init(_opts) do
    {:ok, %{tests: 0, failures: 0, result_nonce: System.fetch_env!(@result_nonce_env)}}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:failed, failures}} = test}, state) do
    IO.puts("MUEX_EXUNIT_FAILURE:" <> Jason.encode!(failure_event(test, failures)))
    {:noreply, %{state | tests: state.tests + 1, failures: state.failures + 1}}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: nil}}, state) do
    {:noreply, %{state | tests: state.tests + 1}}
  end

  def handle_cast({:test_finished, %ExUnit.Test{}}, state), do: {:noreply, state}

  def handle_cast({:suite_finished, _times_us}, state) do
    result = Map.take(state, [:tests, :failures])
    IO.puts("MUEX_EXUNIT_RESULT:#{state.result_nonce}:" <> Jason.encode!(result))
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp failure_event(test, failures) do
    %{
      module: Atom.to_string(test.module),
      name: Atom.to_string(test.name),
      file: test.tags[:file],
      line: test.tags[:line],
      failures:
        Enum.map(failures, fn {kind, reason, stacktrace} ->
          Exception.format(kind, reason, stacktrace)
        end)
    }
  end
end
