# Campaign API

Muex ships the seam an external orchestrator ("the wrapper") uses to run one
mutation campaign across many machines, resume it after an interruption, and
keep every artifact content-addressed and independently verifiable.

The wrapper never links against Muex internals. Everything below is driven by
four public Mix tasks:

| Task | Role |
| --- | --- |
| `mix muex --audit-only` | Publish the mutation inventory without running anything |
| `mix muex.campaign build` | Seal an immutable, sharded campaign plan from that inventory |
| `mix muex.campaign slice` | Materialize the exact work of one shard |
| `mix muex` (shard form) | Execute one shard's mutations against a checkpoint |
| `mix muex.validate` | Turn a shard's checkpoint plus report into a validation artifact |
| `mix muex.continuation prepare` / `finalize` | Split and re-join an interrupted campaign |

Muex owns every artifact it writes. The wrapper owns the campaign manifest, the
source snapshot, and the per-shard file lists described under
[Wrapper-owned artifacts](#wrapper-owned-artifacts).

## 1. Inventory

```sh
mix muex --project-root . \
  --files lib --test-paths test \
  --mutators return_value --min-complexity 0 --no-filter \
  --audit-only --audit-plan inventory.json
```

No test and no mutant runs. `inventory.json` is the authoritative plan: every
candidate mutation with its stable ID, location, selection reason, patch
snippet, and the SHA-256 of the source file it was generated from.

Relative paths are resolved against `--project-root` and stay relative inside
the artifact. Passing absolute `--files` puts absolute paths in the inventory,
which `mix muex.campaign build` then cannot match against its own source list —
use relative paths.

## 2. Plan

```sh
mix muex.campaign build --project-root . \
  --audit-plan inventory.json \
  --source-files sources.txt --test-files tests.txt \
  --config-file config.json \
  --shards 4 --commit-sha "$SHA" --output campaign.json
```

`sources.txt` and `tests.txt` are newline-delimited relative paths.
`config.json` records the mutation configuration the campaign is bound to:

```json
{"preset": "none", "optimize": true, "optimize_level": "balanced", "max_mutations": 0}
```

Build refuses the inventory unless all of these hold:

* the inventory validates (`Muex.Audit.Validator`),
* its source-file set equals `sources.txt` exactly,
* its optimizer block matches `config.json`,
* every source file carrying a *selected* mutation still hashes to the
  inventory's `original_sha256` (files whose mutations were all excluded are not
  re-hashed).

The result is content-addressed. Sharding is source-file-atomic — a file's
mutations never straddle two shards — and greedy min-work packed.

## 3. Slice

```sh
mix muex.campaign slice --project-root . \
  --plan campaign.json --plan-sha256 "$(sha256sum campaign.json | cut -d' ' -f1)" \
  --config-file config.json --shard 1 --output slice-1.json
```

`--plan-sha256` is mandatory: the slice is refused when the plan artifact drifts
by a single byte. The slice carries `source_files`, `test_files`, `mutant_ids`,
`requirements`, the coverage binding, and its own `slice_sha256`.

## 4. Shard execution

The wrapper turns one slice into one `mix muex` invocation. `mutant_ids` goes to
a newline-delimited file; `source_files` and `test_files` are passed as
comma-separated lists.

`$GLOBAL_FINGERPRINT` is the plan's `global_fingerprint`. `$INVENTORY_KEY` is any
campaign-wide lowercase 64-hex string that identifies the inventory the shards
share — `sha256sum inventory.json` is the obvious choice. Anything else is
rejected before the run starts, and `--inventory-cache-key` and
`--inventory-cache-file` both require `--audit-dir`.

```sh
mix muex --project-root . \
  --files "$(paste -sd, shard-1.sources)" \
  --test-paths "$(paste -sd, shard-1.tests)" \
  --mutators return_value --min-complexity 0 --no-filter \
  --mutant-ids-file shard-1.ids \
  --audit-dir invocation.a1/shard-1-audit \
  --checkpoint shard-1.checkpoint.jsonl \
  --campaign-fingerprint "$GLOBAL_FINGERPRINT" \
  --inventory-cache-file inventory-cache/shard-1.etf \
  --inventory-cache-key "$INVENTORY_KEY" \
  --format json --report-file invocation.a1/shard-1.json
```

The checkpoint is append-only JSONL and is the resume point: re-running the shard
skips every mutation already recorded there. Give each attempt its own
`invocation.<id>` directory, though — a warm inventory cache hard-links its plan
into `--audit-dir`, so pointing a second attempt at a directory an earlier one
already filled fails with `cannot link cached mutation plan: file already
exists`. Keep `--checkpoint`, move `--audit-dir` and `--report-file`.

`mix muex --formatter` injection means **muex must be a dependency of the target
project** (`{:muex, path: "..."}` or a released version). A shard run against a
project that does not depend on muex fails with `missing_exunit_result` and an
undefined `Muex.ExUnitFormatter`.

## 5. Validation

```sh
mix muex.validate \
  --plan invocation.a1/shard-1-audit/plan.json \
  --checkpoint shard-1.checkpoint.jsonl \
  --report invocation.a1/shard-1.json \
  --artifact-root invocation.a1 --artifact-root . \
  --campaign-fingerprint "$GLOBAL_FINGERPRINT" \
  --output invocation.a1/shard-1.validation.json
```

`--artifact-root` may be repeated; every artifact path referenced by the
checkpoint must live under one of them.

## 6. Continuation

An interrupted campaign is resumed by splitting it into a child campaign that
covers only the mutations the parent never finalized.

```sh
mix muex.continuation prepare --parent . --child child \
  --blocked-ids blocked.txt --shards 4
```

`prepare` partitions the parent's selected mutations into
`imported_finalized ⊎ child_finalized ⊎ infra_blocked` and seals that partition
with `parent_selected_ids_sha256`. Child shard allocation preserves the parent's
shard boundaries so each child shard can reuse its parent shard's inventory
cache.

Each child shard is then executed and validated as in steps 4 and 5, with one
constraint: it must reuse its **parent** shard's `--files`, `--test-paths`,
mutation flags and `--inventory-cache-key`, because the imported cache is bound
to the parent's inputs. Only `--mutant-ids-file`, `--audit-dir`, `--checkpoint`,
`--inventory-cache-file` and `--report-file` move into `child/`. A child run
scoped to its own file list is rejected with `mutation inventory cache input
fingerprint mismatch`. Finally:

```sh
mix muex.continuation finalize --child child
```

`finalize` refuses to close unless every parent mutation is accounted for. It
re-validates each child shard from that shard's plan, checkpoint and report — the
same evidence `mix muex.validate` consumes — and records the path of
`shard-N.validation.json` without reading it; `prepare` likewise never reads the
parent's report.

## Wrapper-owned artifacts

`mix muex.continuation prepare` reads a parent campaign directory that Muex does
not create. The wrapper must lay it out exactly as follows.

```
<parent>/
  campaign.manifest.json
  snapshot/…                        # the exact sources the campaign ran against
  shard-N.files                     # relative paths, one per line, validated against snapshot/
  shard-N.checkpoint.jsonl
  inventory-cache/shard-N.etf
  inventory-cache/shard-N.plan.json # sidecar audited plan, published with the cache
  invocation.<id>/
    shard-N-audit/plan.json
    shard-N.json                    # --report-file output
    shard-N.validation.json         # mix muex.validate output
```

`campaign.manifest.json`:

```json
{
  "version": 1,
  "status": "incomplete",
  "terminal": {"reason": "signal_received"},
  "current_invocation": "invocation.a1",
  "fingerprint": "<global_fingerprint from the campaign plan>",
  "shards": 1
}
```

* `status` must be `"incomplete"` and `terminal.reason` must be
  `"signal_received"` — a campaign that ended any other way is not resumable.
* `shards` must equal the `--shards` passed to `prepare`.
* `current_invocation` names an `invocation.<id>` directory whose `<id>` matches
  `[A-Za-z0-9]+`.
* `shard-N.files` paths are relative and are re-validated against
  `<parent>/snapshot`: no absolute paths, no `.`/`..`, no symlink components.
* `inventory-cache/shard-N.etf` and `inventory-cache/shard-N.plan.json` travel
  together — `prepare` reads both, and a cache copied without its sidecar fails
  with `cannot read mutation inventory cache plan`. Both are consumed through
  `File.ln`, so the cache directory must sit on the same filesystem as the
  `--audit-dir` of the run that reads it.

`prepare` writes `continuation.plan.json`, `shard-N.ids`, `shard-N.files`, and
the seeded `inventory-cache/` into the child directory. The child's own
`campaign.manifest.json` stays wrapper-owned: write it with the same shape as
the parent's, naming the child invocation directory, before running
`finalize`. `finalize` reads it together with each child shard's checkpoint,
report, and validation artifact.

## Proving the chain

`scripts/campaign_e2e.exs` drives every step above against a throwaway fixture
project and fails on the first step that breaks:

```sh
mix run scripts/campaign_e2e.exs
```

## Notes

* `--report-file` writes the structured JSON report for every `--format`. The
  continuation flow needs that file, so it is always safe to pass.
* Mutation IDs are stable across invocations: `Muex.mutation_id/6` over the
  mutator, description, file, line, patch, and target ordinal. It is an internal
  helper (`@doc false`) that hashes `inspect(mutator)` and expects the patch as a
  `%{before: _, after: _}` map; called with anything else it returns a different
  digest instead of an error, so read IDs out of the artifacts rather than
  recomputing them.
* The inventory cache is Erlang term format decoded with `:safe`, which cannot
  create atoms of its own. The cache therefore carries the names of the atoms its
  payload needs (Muex's map keys and whatever the mutators put in the cached AST)
  as a plain list of binaries, capped at 100_000 names, which the reader interns
  before decoding the payload. Funs, pids, and refs remain undecodable, and
  `mix muex.continuation prepare` still parses the parent snapshot sources before
  importing a parent cache.
* `original_source` in the inventory is the verbatim bytes on disk, while
  `patch` and `mutated_source` are renderings of the AST. Sources that are not
  already written in their rendered form (comments, `def f, do: x`) are fully
  supported; the validator reconstructs against both forms.
