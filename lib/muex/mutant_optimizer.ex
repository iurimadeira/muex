defmodule Muex.MutantOptimizer do
  @moduledoc """
  Sophisticated heuristics to minimize the number of mutants while maintaining
  mutation testing effectiveness.

  This module implements several strategies:

  1. **Impact Analysis**: Prioritizes mutations in complex, frequently-tested code
     over simple getters or trivial functions

  2. **Selection Audit**: Exposes each optimizer stage without claiming
     similarity that has not been measured

  3. **Code Complexity Scoring**: Focuses on mutations in code with higher cyclomatic
     complexity, where bugs are more likely

  4. **Boundary Value Focus**: Prioritizes mutations at decision boundaries (>=, <=, ==)
     over less critical operators

  5. **Guard Clause Deprioritization**: Reduces mutation testing on simple validation
     guards that are typically well-covered by tests
  """

  @type mutation :: %{
          ast: tuple(),
          mutator: module(),
          description: String.t(),
          location: map()
        }

  @type filter_options :: [
          enabled: boolean(),
          min_complexity: non_neg_integer(),
          max_mutations_per_function: non_neg_integer(),
          keep_boundary_mutations: boolean()
        ]

  @doc """
  Filters and prioritizes mutations based on sophisticated heuristics.

  ## Options

  - `:enabled` - Enable optimization (default: false)
  - `:min_complexity` - Minimum complexity score to mutate (default: 2)
  - `:max_mutations_per_function` - Maximum mutations per function (default: 20)
  - `:keep_boundary_mutations` - Always keep boundary condition mutations (default: true)

  ## Returns

  A filtered and prioritized list of mutations.
  """
  @spec optimize(list(mutation()), filter_options()) :: list(mutation())
  def optimize(mutations, opts \\ []) do
    if Keyword.get(opts, :enabled, false) do
      mutations |> optimization_stages(opts) |> Map.fetch!(:prioritized)
    else
      mutations
    end
  end

  @doc """
  Returns every optimizer stage so callers can audit the exact selection reason.

  Equivalence hooks and heuristic equivalence detectors are deliberately absent.
  They have produced false positives; only a generated source that is byte-identical
  to the original may be classified separately as a no-op by the worker.
  """
  @spec optimization_stages(list(mutation()), filter_options()) :: map()
  def optimization_stages(mutations, opts \\ []) do
    keep_boundary = Keyword.get(opts, :keep_boundary_mutations, true)
    scored = score_by_impact(mutations)

    complexity =
      scored
      |> filter_by_complexity(Keyword.get(opts, :min_complexity, 2))
      |> preserve_boundary_mutations(scored, keep_boundary)

    clustered = cluster_and_sample(complexity, nil)

    limited =
      clustered
      |> limit_per_function(Keyword.get(opts, :max_mutations_per_function, 20))
      |> preserve_boundary_mutations(scored, keep_boundary)

    prioritized = prioritize_boundary_mutations(limited, keep_boundary)

    %{
      scored: scored,
      complexity: complexity,
      clustered: clustered,
      limited: limited,
      prioritized: prioritized
    }
  end

  @doc """
  Assigns impact scores to mutations based on code characteristics.

  Higher scores indicate mutations more likely to reveal test weaknesses:
  - Complex conditional logic: +5
  - Arithmetic in loops or recursion: +4
  - Boundary conditions (>=, <=, ==): +3
  - Function calls: +2
  - Simple assignments: +1
  """
  def score_by_impact(mutations) do
    Enum.map(mutations, fn mutation ->
      score = calculate_impact_score(mutation)
      Map.put(mutation, :impact_score, score)
    end)
  end

  @doc """
  Filters out mutations in trivially simple code.

  Removes mutations from:
  - Simple getters/setters
  - Trivial boolean guards
  - Single-operation functions
  """
  def filter_by_complexity(mutations, min_complexity) do
    Enum.filter(mutations, fn mutation ->
      complexity = estimate_complexity(mutation)
      complexity >= min_complexity
    end)
  end

  @doc """
  Compatibility stage that conserves all mutations.

  Muex does not currently calculate semantic or behavioral similarity, so this
  stage cannot soundly discard representative-looking mutants. The threshold
  argument remains accepted for callers using the previous API.
  """
  def cluster_and_sample(mutations, _similarity_threshold), do: mutations

  @doc """
  Limits the number of mutations per function to prevent explosion.

  Keeps the highest-impact mutations per function.
  """
  def limit_per_function(mutations, max_per_function) do
    mutations
    |> group_by_function()
    |> Enum.flat_map(fn {_function, group} ->
      group
      |> Enum.sort_by(& &1.impact_score, :desc)
      |> Enum.take(max_per_function)
    end)
  end

  @doc """
  Ensures boundary condition mutations are always included.

  Boundary mutations (>=, <=, ==, !=) are critical for finding off-by-one
  errors and are always kept regardless of other filters.
  """
  def prioritize_boundary_mutations(mutations, keep_boundary) do
    if keep_boundary do
      {boundary, regular} = Enum.split_with(mutations, &boundary_mutation?/1)
      boundary ++ regular
    else
      mutations
    end
  end

  # Private helper functions

  defp get_mutator_name(mutator) when is_atom(mutator) do
    mutator
    |> Module.split()
    |> List.last()
  end

  defp get_mutator_name(mutator) when is_binary(mutator), do: mutator

  defp calculate_impact_score(%{ast: ast, mutator: mutator, location: location}) do
    base_score = mutator_base_score(mutator)
    complexity_bonus = ast_complexity_bonus(ast)
    location_bonus = location_bonus(location)

    base_score + complexity_bonus + location_bonus
  end

  defp mutator_base_score(mutator) do
    mutator_name = get_mutator_name(mutator)

    case mutator_name do
      "Comparison" -> 3
      "Arithmetic" -> 2
      "Boolean" -> 3
      "Conditional" -> 4
      "FunctionCall" -> 2
      "Literal" -> 1
      _ -> 1
    end
  end

  defp ast_complexity_bonus(ast) do
    # Analyze AST depth and branching
    cond do
      has_nested_conditionals?(ast) -> 5
      has_recursion_or_loops?(ast) -> 4
      has_complex_pattern_matching?(ast) -> 3
      has_multiple_operations?(ast) -> 2
      true -> 0
    end
  end

  defp location_bonus(location) when is_map(location) do
    line = Map.get(location, :line, 0)

    # Functions early in file are often more important (public API)
    if is_integer(line) and line < 100, do: 1, else: 0
  end

  defp location_bonus(_), do: 0

  defp has_nested_conditionals?(ast) do
    case ast do
      {:if, _, _} -> contains_conditional?(ast)
      {:case, _, _} -> contains_conditional?(ast)
      {:cond, _, _} -> contains_conditional?(ast)
      _ -> false
    end
  end

  defp contains_conditional?(ast) when is_tuple(ast) and tuple_size(ast) == 3 do
    {op, _, args} = ast

    if op in [:if, :case, :cond, :unless] do
      true
    else
      args
      |> List.wrap()
      |> Enum.any?(&contains_conditional?/1)
    end
  end

  defp contains_conditional?(ast) when is_tuple(ast), do: false

  defp contains_conditional?(_), do: false

  defp has_recursion_or_loops?(ast) do
    # Simplified detection - look for common loop/recursion patterns
    case ast do
      {:Enum, _, [func, _]} when func in [:map, :reduce, :filter, :each] -> true
      {:|>, _, _} -> true
      _ -> false
    end
  end

  defp has_complex_pattern_matching?(ast) do
    case ast do
      {:case, _, [_, [do: clauses]]} when is_list(clauses) ->
        length(clauses) > 2

      {:->, _, _} ->
        true

      _ ->
        false
    end
  end

  defp has_multiple_operations?(ast) when is_tuple(ast) and tuple_size(ast) == 3 do
    {_, _, args} = ast
    is_list(args) and length(args) > 1
  end

  defp has_multiple_operations?(_), do: false

  defp estimate_complexity(%{ast: ast}) do
    # Calculate cyclomatic complexity approximation
    count_decision_points(ast) + 1
  end

  defp count_decision_points(ast) when is_tuple(ast) and tuple_size(ast) == 3 do
    {op, _, args} = ast

    current =
      if op in [:if, :case, :cond, :unless, :and, :or, :&&, :||] do
        1
      else
        0
      end

    children =
      args
      |> List.wrap()
      |> Enum.map(&count_decision_points/1)
      |> Enum.sum()

    current + children
  end

  defp count_decision_points(ast) when is_tuple(ast), do: 0

  defp count_decision_points(list) when is_list(list) do
    list |> Enum.map(&count_decision_points/1) |> Enum.sum()
  end

  defp count_decision_points(_), do: 0

  defp group_by_function(mutations) do
    Enum.group_by(mutations, fn mutation ->
      # Group by file and approximate line range (function)
      location = Map.get(mutation, :location, %{})
      file = Map.get(location, :file, "unknown")
      line = Map.get(location, :line, 0)
      function_group = div(line, 50)
      {file, function_group}
    end)
  end

  defp preserve_boundary_mutations(selected, original, true) do
    boundary = Enum.filter(original, &boundary_mutation?/1)
    boundary ++ Enum.reject(selected, &(&1 in boundary))
  end

  defp preserve_boundary_mutations(selected, _original, false), do: selected

  defp boundary_mutation?(%{mutator: mutator} = mutation) do
    get_mutator_name(mutator) == "Comparison" and
      Enum.any?(
        [Map.get(mutation, :original_ast), Map.get(mutation, :ast)],
        &boundary_operator?/1
      )
  end

  defp boundary_mutation?(_), do: false

  defp boundary_operator?({operator, _, _}) when operator in [:>=, :<=, :==, :!=, :!==, :===],
    do: true

  defp boundary_operator?(_ast), do: false

  @doc """
  Generates a summary report of the optimization results.
  """
  def optimization_report(original_mutations, optimized_mutations) do
    original_count = length(original_mutations)
    optimized_count = length(optimized_mutations)
    reduction = original_count - optimized_count
    reduction_pct = if original_count > 0, do: reduction / original_count * 100, else: 0.0

    by_mutator =
      optimized_mutations
      |> Enum.frequencies_by(fn m -> get_mutator_name(m.mutator) end)
      |> Enum.sort_by(fn {_, count} -> -count end)

    avg_impact =
      if optimized_count > 0 do
        total_impact =
          Enum.reduce(optimized_mutations, 0, fn m, acc ->
            acc + Map.get(m, :impact_score, 0)
          end)

        Float.round(total_impact / optimized_count, 2)
      else
        0.0
      end

    %{
      original_count: original_count,
      optimized_count: optimized_count,
      reduction: reduction,
      reduction_percentage: Float.round(reduction_pct, 1),
      by_mutator: by_mutator,
      average_impact_score: avg_impact
    }
  end
end
