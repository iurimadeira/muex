defmodule Muex.WorkerPoolTest do
  use ExUnit.Case, async: true

  alias Muex.WorkerPool

  describe "start_link/1" do
    test "starts worker pool with default max_workers" do
      assert {:ok, pid} = WorkerPool.start_link()
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts worker pool with custom max_workers" do
      assert {:ok, pid} = WorkerPool.start_link(max_workers: 8)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "run_mutations/7" do
    test "returns empty list for no mutations" do
      {:ok, pool} = WorkerPool.start_link(max_workers: 2)

      file_entry = %{
        path: "test/fixtures/sample.ex",
        ast: {:defmodule, [], []},
        module_name: Sample
      }

      results =
        WorkerPool.run_mutations_result(
          pool,
          [],
          file_entry,
          Muex.Language.Elixir,
          %{},
          %{},
          timeout_ms: 1000
        )

      assert results == {:ok, []}

      assert [] =
               WorkerPool.run_mutations(
                 pool,
                 [],
                 file_entry,
                 Muex.Language.Elixir,
                 %{},
                 %{},
                 timeout_ms: 1000
               )

      GenServer.stop(pool)
    end
  end

  test "Runner.run_all/6 preserves the v0.9.1 list return" do
    assert [] = Muex.Runner.run_all([], %{}, Muex.Language.Elixir, %{}, %{}, [])
  end
end
