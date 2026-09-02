# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Public coverage seam**: `mix muex.coverage` (`manifest`, `export`, `merge`, `validate`) and `Muex.Coverage.SelectiveTool` are now documented public API, with the full coverage-guided orchestrator flow — artifacts, inputs, fingerprint binding, and degradation semantics — in [docs/CAMPAIGN_API.md](docs/CAMPAIGN_API.md). `Muex.Coverage.SelectiveTool.read_manifest!/2` is now documented and specced. No behaviour changed.

## [0.10.0] - 2026-09-01

Adds the public seam an external orchestrator uses to run one mutation campaign
across many machines and resume it after an interruption. See
[docs/CAMPAIGN_API.md](docs/CAMPAIGN_API.md).

### Added
- **Audit-only inventory**: `mix muex --audit-only --audit-plan <file>` publishes the full mutation inventory — stable mutation ID, location, selection reason, patch snippet, and the SHA-256 of the source it was generated from — without compiling a mutant or running a test.
- **`mix muex.campaign build`**: seals a content-addressed, source-file-atomic campaign plan from an audited inventory. Refuses the inventory unless it validates, its source set matches `--source-files` exactly, its optimizer block matches `--config-file`, and every source carrying a selected mutation still hashes to the recorded `original_sha256`.
- **`mix muex.campaign slice`**: materializes one shard's work (`source_files`, `test_files`, `mutant_ids`, requirements, coverage binding) under its own `slice_sha256`. `--plan-sha256` is mandatory, so a plan that drifted by one byte is rejected.
- **Shard execution**: `mix muex` accepts `--mutant-ids-file`, `--campaign-fingerprint`, `--checkpoint`, and `--audit-dir` to run exactly one shard of a sealed plan. The checkpoint is append-only JSONL and is the resume point — re-running a shard skips every mutation already recorded.
- **`mix muex.validate`**: turns a shard's plan, checkpoint, and report into a validation artifact, with every referenced artifact path constrained to a declared `--artifact-root`.
- **`mix muex.continuation prepare` / `finalize`**: splits an interrupted campaign into a child campaign covering only the mutations the parent never finalized, sealed with `parent_selected_ids_sha256`, and refuses to close unless every parent mutation is accounted for.
- **`mix muex.coverage`**: helper task backing coverage-index and shard-partition generation for campaign runs. Not covered by `docs/CAMPAIGN_API.md` as of this release; documented under [Unreleased].
- **Inventory cache**: `--inventory-cache-file` / `--inventory-cache-key` let sibling shards and child campaigns reuse one mutation inventory instead of regenerating it per shard.
- **New campaign CLI options**: `--audit-dir`, `--audit-only`, `--audit-plan`, `--campaign-fingerprint`, `--checkpoint`, `--inventory-cache-file`, `--inventory-cache-key`, `--mutant-ids-file`, `--report-file`.
- **`--baseline-timeout`**: separate timeout for the baseline test run, independent of the per-mutant `--timeout`.
- **Additional `mix muex` switches**, plumbing for an orchestrator rather than part of the documented seam: `--changed-diff-file` (feed a precomputed diff instead of shelling out to git for `--since`), `--coverage-index-file` and `--coverage-corpus-fingerprint` (bind a coverage-guided run to a prebuilt index), and `--mutant-id` (run exactly one mutation). None are covered by `docs/CAMPAIGN_API.md` as of this release; `--coverage-index-file` and `--coverage-corpus-fingerprint` are documented under [Unreleased].
- **`scripts/campaign_e2e.exs`**: drives inventory → build → slice → shard → validate → continuation against a throwaway fixture project and fails on the first broken step.

### Fixed
- **Audit validation against rendered sources**: the validator reconstructed a mutation's patch against the AST-rendered form of the source while comparing it to the verbatim bytes on disk, so a source that is not already written in its rendered form (comments, `def f, do: x`) failed validation. It now reconstructs against both forms.
- **`--report-file` ignored outside JSON**: `--report-file` was only honored with `--format json`, which broke the continuation flow for terminal and HTML runs. It now writes the structured report for every format.
- **Inventory cache decode under `:safe`**: `:erlang.binary_to_term/2` with `:safe` cannot create atoms, so a cached plan referencing an atom absent from the reading node failed to decode. The cache now carries the names its payload needs as a plain list of binaries (capped at 100_000), interned before the payload is decoded.

### Changed
- **Audit rendering goes through the language adapter**: the audit validator renders through the `Muex.Language` seam (`parse/1`, `unparse/1`) instead of hardcoded `Code.string_to_quoted` / `Macro.to_string`, so it no longer assumes the plan is Elixir. Note that `Muex.Language.Erlang.parse/1` is single-form (`:erl_parse.parse_form/1`), so a multi-form `.erl` source still falls through to comparing verbatim bytes — a pre-existing adapter limitation this release does not change.

## [0.9.0] - 2026-08-26

Special thanks to [@e-fu](https://github.com/e-fu) for extensive bug reports, detailed reproductions, and code contributions!

### Fixed
- **Behavior Definition vs Implementation Filtering**: `Muex.FileAnalyzer` no longer skips modules that implement a behavior (`@behaviour SomeBehaviour`). Only modules defining multiple `@callback` annotations are skipped as behavior definitions ([#22](https://github.com/Oeditus/muex/issues/22)). (Credit: [@e-fu](https://github.com/e-fu))
- **Threshold Enforcement on Empty Runs**: `mix muex` now enforces the `--fail-at` threshold when zero mutations are tested rather than silently passing ([#22](https://github.com/Oeditus/muex/issues/22)). (Credit: [@e-fu](https://github.com/e-fu))
- **Sandbox File Linking**: Symlinked all files and subdirectories in the test root (`test/`) into worker sandboxes when narrowing `--test-paths`, ensuring test modules can access compile-time and runtime fixtures, golden files, and schemas ([#25](https://github.com/Oeditus/muex/issues/25)). (Credit: [@e-fu](https://github.com/e-fu))
- **Invalid Verdict Error Details**: Preserved error details in `classify_test_result` when test runs yield `:invalid` verdicts, preventing `error: null` in output reports ([#25](https://github.com/Oeditus/muex/issues/25)). (Credit: [@e-fu](https://github.com/e-fu))
- **Dotted Exception Name Matching**: Updated `compile_error?` regex pattern to support namespaced Elixir exceptions such as `File.Error` and `Jason.DecodeError` ([#25](https://github.com/Oeditus/muex/issues/25)). (Credit: [@e-fu](https://github.com/e-fu))
- **Accurate Node Replacement Matching**: Matched mutations by their original node AST line (`:original_line`) rather than reported display line ([#27](https://github.com/Oeditus/muex/pull/27)). (Credit: [@e-fu](https://github.com/e-fu))
- **App Detection in Sandbox**: Improved OTP application name detection from project definitions rather than guessing from `_build` markers ([#26](https://github.com/Oeditus/muex/pull/26)). (Credit: [@e-fu](https://github.com/e-fu))
- **Unmeasured Runs Verdict Handling**: Fixed unmeasured test runs from being incorrectly counted as killed mutants ([#20](https://github.com/Oeditus/muex/issues/20) / [#21](https://github.com/Oeditus/muex/pull/21)). (Credit: [@e-fu](https://github.com/e-fu))

### Changed
- **Mutator Type Spec**: Made `:original_ast`, `:original_line`, and `:equivalent` optional keys in `@type Muex.Mutator.mutation()` map spec to prevent type friction for external mutators.

[Unreleased]: https://github.com/iurimadeira/muex/compare/v0.10.0...HEAD
[0.10.0]: https://github.com/iurimadeira/muex/compare/v0.9.1...v0.10.0
[0.9.0]: https://github.com/iurimadeira/muex/compare/v0.8.3...v0.9.0
