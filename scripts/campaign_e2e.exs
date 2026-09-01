# End-to-end proof of the campaign API described in docs/CAMPAIGN_API.md.
#
#     mix run scripts/campaign_e2e.exs
#
# Builds a throwaway fixture project, then drives the full external-wrapper
# chain with nothing but the public Mix tasks: audit-only inventory, campaign
# build, campaign slice, real shard execution, a simulated interruption,
# continuation prepare, child shard execution, validation, and finalize.
# Exits non-zero on the first step that fails.

muex_root = File.cwd!()
root = Path.join(System.tmp_dir!(), "muex-campaign-e2e-#{System.unique_integer([:positive])}")

defmodule E2E do
  def run!(root, args, env \\ []) do
    IO.puts("  $ mix " <> Enum.join(args, " "))

    case System.cmd("mix", args, cd: root, env: env, stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, status} ->
        IO.puts(output)
        IO.puts("FAILED (exit #{status}): mix #{Enum.join(args, " ")}")
        System.halt(1)
    end
  end

  def step(label, fun) do
    IO.puts("\n== #{label}")
    fun.()
  end

  def json!(path), do: path |> File.read!() |> Jason.decode!()

  def sha256(path) do
    :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
  end

  def write!(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end

mutation_args = ~w(--mutators return_value --min-complexity 0 --no-filter)

E2E.step("fixture project at #{root}", fn ->
  E2E.write!(root, "mix.exs", """
  defmodule CampaignE2E.MixProject do
    use Mix.Project

    def project,
      do: [
        app: :campaign_e2e,
        version: "0.1.0",
        elixir: "~> 1.14",
        deps: [{:muex, path: #{inspect(muex_root)}}]
      ]
  end
  """)

  # Deliberately not written in its rendered form: a comment and a keyword-form
  # body, which the audit inventory has to stay verifiable against.
  E2E.write!(root, "lib/example.ex", """
  defmodule CampaignE2E.Example do
    # keyword form plus a comment
    def value, do: :original

    def other do
      :second
    end
  end
  """)

  E2E.write!(root, "test/test_helper.exs", "ExUnit.start()\n")

  E2E.write!(root, "test/example_test.exs", """
  defmodule CampaignE2E.ExampleTest do
    use ExUnit.Case
    test "value", do: assert(CampaignE2E.Example.value() == :original)
    test "other", do: assert(CampaignE2E.Example.other() == :second)
  end
  """)

  # Resolve the path dependency's own deps offline, from this checkout.
  File.mkdir_p!(Path.join(root, "deps"))
  File.ln_s!(Path.join([muex_root, "deps", "jason"]), Path.join([root, "deps", "jason"]))
  jason_lock = muex_root |> Path.join("mix.lock") |> File.read!()
  [entry] = Regex.run(~r/"jason":.*?\},?\n/s, jason_lock)

  File.write!(
    Path.join(root, "mix.lock"),
    "%{\n  " <> String.trim_trailing(entry, ",\n") <> "\n}\n"
  )

  E2E.run!(root, ~w(deps.compile), [{"MIX_ENV", "test"}])
  E2E.run!(root, ~w(test), [{"MIX_ENV", "test"}])
end)

E2E.step("1. audit-only inventory", fn ->
  E2E.run!(
    root,
    ~w(muex --project-root . --files lib --test-paths test) ++
      mutation_args ++ ~w(--audit-only --audit-plan inventory.json)
  )
end)

E2E.step("2. campaign build", fn ->
  File.write!(Path.join(root, "sources.txt"), "lib/example.ex\n")
  File.write!(Path.join(root, "tests.txt"), "test/example_test.exs\n")

  File.write!(
    Path.join(root, "config.json"),
    Jason.encode!(%{preset: "none", optimize: true, optimize_level: "balanced", max_mutations: 0})
  )

  E2E.run!(
    root,
    ~w(muex.campaign build --project-root . --audit-plan inventory.json) ++
      ~w(--source-files sources.txt --test-files tests.txt --config-file config.json) ++
      ~w(--shards 1 --commit-sha campaign-e2e --output campaign.json)
  )
end)

plan = E2E.json!(Path.join(root, "campaign.json"))
fingerprint = plan["global_fingerprint"]

E2E.step("3. campaign slice", fn ->
  E2E.run!(
    root,
    ~w(muex.campaign slice --project-root . --plan campaign.json) ++
      ["--plan-sha256", E2E.sha256(Path.join(root, "campaign.json"))] ++
      ~w(--config-file config.json --shard 1 --output slice-1.json)
  )
end)

slice = E2E.json!(Path.join(root, "slice-1.json"))
inventory_key = E2E.sha256(Path.join(root, "inventory.json"))

shard_args = fn slice, ids_file, audit_dir, checkpoint, cache, report ->
  ~w(muex --project-root .) ++
    ["--files", Enum.join(slice["source_files"], ",")] ++
    ["--test-paths", Enum.join(slice["test_files"], ",")] ++
    mutation_args ++
    ["--mutant-ids-file", ids_file, "--audit-dir", audit_dir, "--checkpoint", checkpoint] ++
    ["--campaign-fingerprint", fingerprint] ++
    ["--inventory-cache-file", cache, "--inventory-cache-key", inventory_key] ++
    ["--format", "json", "--report-file", report]
end

E2E.step("4. shard execution (#{length(slice["mutant_ids"])} mutations)", fn ->
  File.write!(Path.join(root, "shard-1.ids"), Enum.join(slice["mutant_ids"], "\n") <> "\n")

  root
  |> E2E.run!(
    shard_args.(
      slice,
      "shard-1.ids",
      "invocation.a1/shard-1-audit",
      "shard-1.checkpoint.jsonl",
      "inventory-cache/shard-1.etf",
      "invocation.a1/shard-1.json"
    )
  )
  |> String.split("\n")
  |> Enum.filter(&String.contains?(&1, "Mutation Score"))
  |> Enum.each(&IO.puts("  " <> &1))
end)

E2E.step("5. simulate an interruption", fn ->
  checkpoint = Path.join(root, "shard-1.checkpoint.jsonl")
  rows = checkpoint |> File.read!() |> String.split("\n", trim: true)

  {kept, [_dropped | _]} =
    Enum.split_while(rows, &(not String.contains?(&1, ~s("type":"result"))))

  File.write!(checkpoint, Enum.map_join(kept, "", &(&1 <> "\n")))

  File.write!(
    Path.join(root, "campaign.manifest.json"),
    Jason.encode!(%{
      version: 1,
      status: "incomplete",
      terminal: %{reason: "signal_received"},
      current_invocation: "invocation.a1",
      fingerprint: fingerprint,
      shards: 1
    })
  )

  E2E.write!(root, "snapshot/lib/example.ex", File.read!(Path.join(root, "lib/example.ex")))
  File.write!(Path.join(root, "shard-1.files"), "lib/example.ex\n")
  File.write!(Path.join(root, "blocked.txt"), "")
end)

E2E.step("6. continuation prepare", fn ->
  E2E.run!(
    root,
    ~w(muex.continuation prepare --parent . --child child) ++
      ~w(--blocked-ids blocked.txt --shards 1)
  )
  |> String.trim()
  |> then(&IO.puts("  " <> &1))
end)

child_slice = %{"source_files" => slice["source_files"], "test_files" => slice["test_files"]}

E2E.step("7. child shard execution", fn ->
  # The child campaign manifest is wrapper-owned: it names the invocation
  # directory that `finalize` reads the child artifacts from.
  File.write!(
    Path.join(root, "child/campaign.manifest.json"),
    Jason.encode!(%{
      version: 1,
      status: "incomplete",
      terminal: %{reason: "signal_received"},
      current_invocation: "invocation.b1",
      fingerprint: fingerprint,
      shards: 1
    })
  )

  E2E.run!(
    root,
    shard_args.(
      child_slice,
      "child/shard-1.ids",
      "child/invocation.b1/shard-1-audit",
      "child/shard-1.checkpoint.jsonl",
      "child/inventory-cache/shard-1.etf",
      "child/invocation.b1/shard-1.json"
    )
  )
end)

E2E.step("8. validate the child shard", fn ->
  E2E.run!(
    root,
    ~w(muex.validate) ++
      ~w(--plan child/invocation.b1/shard-1-audit/plan.json) ++
      ~w(--checkpoint child/shard-1.checkpoint.jsonl) ++
      ~w(--report child/invocation.b1/shard-1.json) ++
      ~w(--artifact-root child/invocation.b1 --artifact-root child) ++
      ["--campaign-fingerprint", fingerprint] ++
      ~w(--output child/invocation.b1/shard-1.validation.json)
  )
  |> String.trim()
  |> then(&IO.puts("  " <> &1))
end)

E2E.step("9. continuation finalize", fn ->
  root
  |> E2E.run!(~w(muex.continuation finalize --child child))
  |> String.trim()
  |> then(&IO.puts("  " <> &1))
end)

IO.puts("\nOK: full campaign chain proven at #{root}")
