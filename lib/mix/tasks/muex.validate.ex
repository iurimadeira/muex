defmodule Mix.Tasks.Muex.Validate do
  @shortdoc "Validates one Muex audit shard"

  @moduledoc false
  use Mix.Task

  alias Muex.Audit.Validator

  @switches [
    plan: :string,
    checkpoint: :string,
    report: :string,
    artifact_root: :keep,
    campaign_fingerprint: :string,
    output: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> validate(opts)
      {_opts, _rest, invalid} -> Mix.raise("invalid muex.validate options: #{inspect(invalid)}")
    end
  end

  defp validate(opts) do
    opts = Keyword.put(opts, :artifact_roots, Keyword.get_values(opts, :artifact_root))

    case Validator.validate(opts) do
      {:ok, validation} ->
        Mix.shell().info("validated #{validation.result_count} mutation results")

      {:error, reason} ->
        Mix.raise("Muex audit validation failed: #{inspect(reason)}")
    end
  end
end
