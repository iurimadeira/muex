defmodule Mix.Tasks.Muex.Continuation do
  @shortdoc "Prepares or finalizes an immutable Muex continuation"
  @moduledoc """
  Splits and re-joins an interrupted mutation campaign.

  `prepare` seals a child campaign covering only the mutations the parent never
  finalized; `finalize` refuses to close unless every parent mutation is
  accounted for. Part of the seam documented in `docs/CAMPAIGN_API.md`, which is
  the single source for their options and artifact layout.
  """
  use Mix.Task

  alias Muex.Continuation.Artifact

  @switches [parent: :string, child: :string, blocked_ids: :string, shards: :integer]

  @impl Mix.Task
  def run([action | args]) when action in ~w(prepare finalize) do
    Mix.Task.run("app.start")
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [], do: Mix.raise("invalid muex.continuation options")

    result =
      case action do
        "prepare" -> prepare(opts)
        "finalize" -> Artifact.finalize(required!(opts, :child))
      end

    case result do
      {:ok, evidence} -> report(action, evidence)
      {:error, reason} -> Mix.raise("Muex continuation failed: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix muex.continuation prepare|finalize [options]")

  defp prepare(opts) do
    blocked_path = required!(opts, :blocked_ids)

    with {:ok, contents} <- File.read(blocked_path) do
      Artifact.prepare(
        required!(opts, :parent),
        required!(opts, :child),
        String.split(contents, "\n", trim: true),
        Keyword.get(opts, :shards, 8)
      )
    end
  end

  defp required!(opts, key), do: Keyword.get(opts, key) || Mix.raise("--#{key} is required")

  defp report("prepare", evidence) do
    Mix.shell().info(
      "prepared continuation: #{evidence.parent_selected_count} parent, #{evidence.pending_count} pending"
    )
  end

  defp report("finalize", evidence) do
    Mix.shell().info(
      "finalized continuation: #{evidence.parent_selected_count} parent mutations accounted for"
    )
  end
end
