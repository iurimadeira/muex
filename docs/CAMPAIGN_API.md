# Campaign API

Muex ships the seam an external orchestrator ("the wrapper") uses to run one
mutation campaign across many machines, resume it after an interruption, and
keep every artifact content-addressed and independently verifiable.

The wrapper never links against Muex internals. Everything below is driven by
public Mix tasks:

| Task | Role |
| --- | --- |
| `mix muex --audit-only` | Publish the mutation inventory without running anything |
| `mix muex.campaign build` | Seal an immutable, sharded campaign plan from that inventory |
| `mix muex.campaign slice` | Materialize the exact work of one shard |
| `mix muex` (shard form) | Execute one shard's mutations against a checkpoint |
| `mix muex.validate` | Turn a shard's checkpoint plus report into a validation artifact |
| `mix muex.continuation prepare` / `finalize` | Split and re-join an interrupted campaign |
| `mix muex.coverage` | Build, merge, and validate the coverage index a campaign binds to |

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

* the inventory validates (Muex.Audit.Validator),
* its source-file set equals `sources.txt` exactly,
* its optimizer block matches `config.json`,
* every source file carrying a *selected* mutation still hashes to the
  inventory's `original_sha256` (files whose mutations were all excluded are not
  re-hashed).

The result is content-addressed. Sharding is source-file-atomic — a file's
mutations never straddle two shards — and greedy min-work packed.

Pass `--coverage-index` (and the matching `--selective-manifest`) to bind the
plan to a coverage index; see
[Coverage-guided campaigns](#coverage-guided-campaigns).

## 3. Slice

```sh
mix muex.campaign slice --project-root . \
  --plan campaign.json --plan-sha256 "$(sha256sum campaign.json | cut -d' ' -f1)" \
  --config-file config.json --shard 1 --output slice-1.json
```

`--plan-sha256` is mandatory: the slice is refused when the plan artifact drifts
by a single byte. The slice carries `source_files`, `test_files`, `mutant_ids`,
`requirements`, the coverage binding, and its own `slice_sha256`. Pass
`--coverage-index <path>` to resolve that binding; see
[Coverage-guided campaigns](#coverage-guided-campaigns).

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
  --auxiliary-paths-file auxiliary.txt \
  --format json --report-file invocation.a1/shard-1.json
```

`--auxiliary-paths-file` uses the same validated project-relative snapshot
contract as coverage export. Muex copies each listed file or directory read-only
into every shard sandbox, including the baseline run, and binds its bytes into
the checkpoint fingerprint.

The checkpoint is append-only JSONL and is the resume point: re-running the shard
skips every mutation already recorded there. Give each attempt its own
`invocation.<id>` directory, though — a warm inventory cache hard-links its plan
into `--audit-dir`, so pointing a second attempt at a directory an earlier one
already filled fails with `cannot link cached mutation plan: file already
exists`. Keep `--checkpoint`, move `--audit-dir` and `--report-file`.

`mix muex --formatter` injection means **muex must be a dependency of the target
project** (`{:muex, path: "..."}` or a released version). A shard run against a
project that does not depend on muex fails with `missing_exunit_result` and an
undefined Muex.ExUnitFormatter.

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

## Coverage-guided campaigns

A campaign may bind itself to a prebuilt line-level coverage index so each
mutant runs only the tests that execute its line. The index is built by
`mix muex.coverage`, bound into the plan at build time, resolved per shard at
slice time, and consumed by the shard run.

The project under test selects Muex's coverage tool in its `mix.exs`:

```elixir
test_coverage: [tool: Muex.Coverage.SelectiveTool]
```

`Muex.Coverage.SelectiveTool` instruments only the modules named by
`MUEX_COVERAGE_MODULES_FILE`, from an already compiled build. Once selected it
applies to every `mix test --cover` run in that project and raises when the
variable is unset, so select it in a coverage-only configuration rather than in
the project's ordinary test config.

### 1. Selective manifest

```sh
mix muex.coverage manifest --project-root . \
  --source-files sources.txt --output selective.json
```

`sources.txt` is the same newline-delimited list the campaign is built from.
The manifest maps each selected source to its module and beam inside the
current `Mix.Project.compile_path/0`, so the build must already be compiled.

It is mandatory whenever the project under test selects
`Muex.Coverage.SelectiveTool`: the tool raises `Mix.Error` when
`MUEX_COVERAGE_MODULES_FILE` is unset, which fails the `export` subprocess. It
is optional only for a project that keeps another coverage tool, where `export`
then instruments every source that tool can load and the corpus fingerprint is
computed without a manifest.

### 2. Export

Split `tests.txt` into disjoint partitions and export each one — on one machine
or many. Each partition writes an index and an adjacent
`<index>.manifest.json`:

```sh
export MUEX_COVERAGE_MODULES_FILE=selective.json
mix muex.coverage export --project-root . \
  --source-files sources.txt \
  --test-files part-1.txt --corpus-test-files tests.txt \
  --auxiliary-paths-file auxiliary.txt \
  --partition 1 --index coverage/part-1.etf --audit-dir audit/part-1
```

`export` shells out to `mix test --no-compile --cover`; the coverage tool that
actually instruments the run is whichever one the project's own
`test_coverage:` names, not one `export` imposes.

`--test-files` is this partition's tests; `--corpus-test-files` is always the
whole campaign corpus, so every partition agrees on the same
`corpus_fingerprint`. `--audit-dir` receives the raw `.coverdata` exports, and
their paths, sizes, and digests are recorded as the partition's `evidence`.
`--auxiliary-paths-file` is optional. Each nonblank line names an explicit
project-relative existing file or directory that tests need inside the private
coverage sandbox. Traversal, absolute paths, missing paths, symlinks, and
special files are rejected. Muex copies and makes these snapshots read-only;
tests never execute through live links to the project. The listed names and
exact snapshot contents participate in the corpus fingerprint.

### 3. Merge and validate

```sh
printf '%s\n' coverage/part-1.etf coverage/part-2.etf > parts.txt
mix muex.coverage merge --parts-file parts.txt \
  --expected-tests-file tests.txt \
  --index coverage.etf --manifest coverage.manifest.json

mix muex.coverage validate --expected-tests-file tests.txt \
  --index coverage.etf --manifest coverage.manifest.json
```

`parts.txt` lists *index* paths, each of which must still have its adjacent
`<index>.manifest.json`. Merge refuses to proceed unless every partition
manifest still matches its index byte for byte (`invalid coverage partition`),
and unless the partitions are disjoint, exhaustive over `tests.txt`, and share
one `corpus_fingerprint` and one corpus digest (`coverage partitions are not
disjoint and exhaustive`). Because evidence is re-`lstat`ed and re-hashed, run
`merge` from the same working directory as the exports, with their
`--audit-dir` contents still in place.

`merge` writes its manifest to `--manifest` and mirrors it to
`coverage.etf.manifest.json` when the two differ. That adjacent file is what
binds the index later, so keep the pair together.

### 4. Binding the index to a campaign

```sh
mix muex.campaign build --project-root . \
  --audit-plan inventory.json \
  --source-files sources.txt --test-files tests.txt \
  --auxiliary-paths-file auxiliary.txt \
  --config-file config.json \
  --coverage-index coverage.etf --selective-manifest selective.json \
  --shards 4 --commit-sha "$SHA" --output campaign.json
```

Build recomputes the corpus fingerprint from `--project-root`,
`--source-files`, `--test-files`, `--auxiliary-paths-file`, and
`--selective-manifest`, then reads the
index only if `coverage.etf.manifest.json` declares `version` 1, that exact
`corpus_fingerprint`, and an `index_sha256` equal to the index's own digest.
The plan records the binding as

```json
{"coverage": {"corpus_fingerprint": "<64 hex>", "index_sha256": "<64 hex>"}}
```

and `index_sha256` is `null` when no usable index was bound. Coverage is a
planning input, never a gate: an index that fails any of those checks is
dropped and the plan is still built, with per-mutant requirements falling back
to the full test corpus.

`--selective-manifest` must name the same file `MUEX_COVERAGE_MODULES_FILE`
named during export. Setting it in one place and not the other changes the
fingerprint and silently costs the campaign its coverage.
Likewise, coverage export and campaign build must receive the same auxiliary
path list; changing any listed path or its contents makes the index stale.

### 5. Resolving the binding per shard

`mix muex.campaign slice --coverage-index coverage.etf` re-checks the index
against the plan's binding and reports the result in `slice["coverage"]["status"]`:

| Status | Meaning |
| --- | --- |
| `valid` | the artifact matches the plan's `corpus_fingerprint` and `index_sha256`; `test_files` stay coverage-scoped |
| `unavailable` | the plan was built without a usable index; the shard runs its declared corpus |
| `stale` | the plan is bound to an index this artifact does not satisfy |

A `stale` artifact expands **only that shard** to the full declared corpus and
marks it: `slice["fallback_reasons"] == ["coverage_artifact_stale"]`, and every
requirement gets `"fallback_reason" => "coverage_artifact_stale"` with
`estimated_work` recomputed. Degradation is deliberate — a drifted index must
never silence a mutant. It is also lossy: a missing file, unreadable manifest,
wrong version, fingerprint mismatch, digest mismatch, and undecodable index all
collapse into the same `stale`, so an orchestrator that needs to tell them apart
must re-run `mix muex.coverage validate` against the artifact. Passing no
`--coverage-index` at all to a slice of a bound plan collapses into `stale` the
same way, and is the most common operational cause.

### 6. Consuming the index in a shard run

```sh
mix muex --project-root . \
  ... \
  --coverage-guided \
  --coverage-index-file coverage.etf \
  --coverage-corpus-fingerprint "$(jq -r .coverage.corpus_fingerprint campaign.json)" \
  --auxiliary-paths-file auxiliary.txt
```

`--coverage-index-file` requires `--coverage-guided`, and
`--coverage-corpus-fingerprint` requires `--coverage-index-file`; the
fingerprint must be a lowercase SHA-256 digest. Passing the plan's fingerprint
explicitly is the safe form: without it the run recomputes the fingerprint from
its own `--files`, `--test-paths` and `MUEX_COVERAGE_MODULES_FILE`, which a
shard-scoped file list will not reproduce. A rejected index is not an error,
but it is not free either: once `--coverage-index-file` is passed, the run does
not fall back to measuring coverage in-process. It falls back to the full
declared test corpus for that shard, so the shard stays correct while running
every declared test for every mutant.

Omitting `--coverage-index-file` entirely leaves `--coverage-guided` measuring
coverage in-process for that shard.

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
* Mutation IDs are stable across invocations: Muex.mutation_id/6 over the
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
