# AI-Orchestrator (local exchange folder, versioned in amulbham/ai-orchestrator; not part of cybernetics-mbp)
Models exchange artifacts here. They never share a writable checkout. Put no secrets, keys, .env or CLI credential files here, and never edit ~/.codex/config.toml or ~/.grok/.

inbox/     draft tickets and prompts
reviews/   default -OutDir: <Id>-codex.md, <Id>-grok.md, <Id>-manifest.txt, <Id>-summary.md
scratch/   run-log.md, raw/ (raw CLI output), wt-<name> (detached read-only worktrees at the commit under review), fixtures/, tests/, validation/<run>/, pre-TP2.3/ (rollback copies)
review.ps1     runner
summarize.ps1  mechanical summary (called by review.ps1)
planner-handoff.md, executor-handoff.md  blank handoff templates (see Session rotation)

No final/ folder: a sealed ticket's authority is its seal commit in the repo, not a file here.
Executors work in their own git worktrees outside this folder, never in wt-* (reviewer snapshot).

## Bindings (constants at the top of review.ps1; every call passes them explicitly, nothing relies on CLI config defaults)
- Codex: -m gpt-6.1-sol, -c model_reasoning_effort=medium. Fallback model: gpt-5.6-sol (same effort), used only if the primary is reported unavailable. Default reviewer.
- Grok: -m grok-4.7, --effort high. Second reviewer for R3.
- Planner (Claude): medium by default, low for mechanical work, high only on escalation.
- Executor (Claude): medium by default, low only for genuinely mechanical work, high after failed verification or material ambiguity.
- List available models: `codex debug models`, `grok models`.

## Review runner
  .\review.ps1 -Id <Id> -TicketPath <repo-relative ticket> -Worktree <path> [-Tier R1|R2|R3] [-Elevate] [-PromptPath <file>] [-OutDir <dir>] [-Extra <file>,...]
- -Tier R1 and R2 run Codex only. R3 runs Codex and Grok. -Elevate runs both for a lower tier and writes ELEVATED in the summary. (Standard and Full no longer exist.)
- -Worktree: detached worktree at the commit under review (relative to this folder, or absolute).
- -PromptPath: override the prompt; default is site\planning\templates\pre-seal-review.md in the worktree. An override is recorded in each review header.
- -OutDir: where review files, manifest and summary go (default reviews). Only <Id>-<reviewer>.md, <Id>-manifest.txt, <Id>-summary.md are written there. Raw logs go to scratch\raw\.
- -Extra: extra files the reviewer should read; they are included in the stdin bundle.
- Each review file starts with a header (RunId, Pinned, ModelReported, EffortReported, Commit, Prompt, Mode, Fallbacks, Attempts, DurationSecs, ExitCode, Status), then a line `=== REVIEW ===`, then the reviewer's output.
- A review with no VERDICT line is retried once. A second miss is recorded as Status: FAILED and the run exits non-zero. Failures are never hidden.

Exact CLI forms used by the script:
  codex exec -s read-only -m gpt-6.1-sol -c model_reasoning_effort=medium -C <wt> --skip-git-repo-check -o <last.md> -     (prompt on stdin)
  grok -p "<prompt + BUDGET>" -m grok-4.7 --effort high --output-format json --max-turns 12 --permission-mode dontAsk --sandbox read-only --disable-web-search
Grok's answer is .text in the JSON; it does not report its effort, so the header records the flag passed.

Fallbacks (recorded in the header):
- Model: if Codex reports the pinned model unavailable, rerun with gpt-5.6-sol.
- Sandbox: if the read-only live run is unusable (e.g. 'setup refresh had errors'), rerun with a stdin bundle containing the ticket, every `Inherits:` source at its pinned commit (git show <rev>:<path>), and each -Extra file, all line-numbered. If any source cannot be resolved the run fails visibly; no partial bundle is sent.

## Finding format (required of reviewers; defined in pre-seal-review.md)
  FINDING | <BLOCKER|REQUIRED|OPTIONAL> | <ticket section> | <path:line> | <problem> | <minimal fix>
  NEW | <path:line> | <out-of-scope issue>
  VERDICT: SEAL | REVISE
Fields contain no `|`. The 30-word limits are a prompt instruction, not checked by the parser.

## Summary (summarize.ps1 -Id <Id> -OutDir <dir>)
Fail-closed and mechanical. Reads only reviewers named in <Id>-manifest.txt and verifies each file's SHA-256 and RunId, so files from other runs are never read. Reads only text after `=== REVIEW ===`; any line with a FINDING/NEW/VERDICT prefix must be valid. It writes `UNPARSED: <reviewer>` with line numbers, no counts, and exits non-zero when a reserved line is malformed, there is not exactly one VERDICT as the last non-blank line, REVISE has no BLOCKER/REQUIRED record, SEAL has one, the file is missing or stale, or the reviewer Status is FAILED.
Groups (key = path ignoring line + section): CONSENSUS (one finding each, same severity), SEVERITY-SPLIT (one each, different severity), AMBIGUOUS (a reviewer has several on a shared key; all listed unpaired), SINGLE-REVIEWER: CODEX-ONLY / GROK-ONLY, NEW FINDINGS (NOT AUTHORIZED), PLANNER DISPOSITION (blank). Text is verbatim, never merged. Do not rank reviewers by counts. The planner decides; Claude never writes summary.md.

## Reviewer calibration (observational, not an approval gate)
Canonical log: `calibration.md` at the root of this repo (scratch\ stays unversioned). The Planner appends one row at each ticket closure, columns `Ticket | Risk | Reviewers | B/R accepted | B/R rejected | Retries or deviations | Amul interventions`. Questions to keep asking: did reviewers tell a known-good ticket from a defective one, did REQUIRED findings predict later problems, does either reviewer systematically overreach. Counts are never a score.

## Executor start and Coordinator relay
- `briefs/executor-brief.md` is the one template for starting an Executor.
- After Amul approves a seal on a decision card, the Planner sends the Coordinator a self-sufficient request (the brief filled in) through the Planner's cross-session message to the coordinator session. The Coordinator starts the fresh Executor without a second approval.
- Briefs must stand alone: only Amul's typed messages reach a machine session.
- Proof is one bounded relay in the end-to-end run: an Executor must start from a Planner message. If the relay cannot be delivered, stop and report; never fall back to an improvised brief.
- Push permission reduces interruption, not the boundary: `main` is always denied and production promotion keeps Amul's typed go.

## Where we left it (2026-10-06, orchestrator work paused for website work)
- TP0 to TP2.6: closed. TP2.7 (workflow friction): edits, 14/14 guard unit tests and local live proofs done; branch `claude/execute-TP2.7` in cybernetics-mbp. Closure still needs Amul's typed go to fast-forward `staging` and a green staging build.
- Carried forward from TP2.7: relay proof (a Planner message must start an Executor; no improvised fallback), permission-prompt outcome (local not observed, cloud not run), and the calibration row at closure. Stray remote branch `claude/x` in cybernetics-mbp may need deleting.
- Known issue: the push guard reads a trailing redirect such as `2>&1` as a branch name and can warn spuriously (warning only).
- Stopping rule: infrastructure is frozen. No new TP ticket without a named real failure. Next work is the website, tracked in the Sprint 18 contract.
- To resume: read the TP2.7 ticket's completion report, run `npm run project:status` in `site/`, then do the carried-forward items above.

## Tests
  powershell -NoProfile -File scratch\tests\run-tests.ps1   # fixtures: grouping, fail-closed, stale-file and manifest checks

## Session rotation
Planner and Executor are logical roles; a physical session is disposable. Continuity comes from repository/worktree state plus a bounded handoff (planner-handoff.md, executor-handoff.md; blank templates, ephemeral when filled, outside the repo, overridden by repository truth). Reviewers are one-shot and get no handoff.

Rotation policy (share of context used):
- Below 50%: normal operation.
- 50-60%: finish the current bounded step; do not begin another major phase.
- At 60%: write the role handoff, stop, and start a fresh role session.
- Rotate earlier at clean natural boundaries (ticket sealed, review returned, completion commit made).

Measurement source per role:
- CLI session: `/context` works (Planner-run check, TP2.1 closure).
- Remote Control session: no context readout was available to the Executor session in TP2.4; `/context` could not be confirmed there. Not built or worked around.
- Projects thread session: no way to read its own context was found; none documented.
- Fallback where nothing can be measured: rotate at natural boundaries. A warning-based trigger (first compaction warning) is allowed only if a test shows the warning leaves room to write a handoff. No such test has been run, so it is NOT adopted.

After an automatic compaction has already happened: the session treats its own recollection as non-authoritative, writes the handoff only from repo-verified state, and rotates.

Pre-handoff classification:
- Planner: durable project truth goes to its canonical repo owner; authorization or evidence goes to the ticket or closure record; only transient continuation state goes in the handoff.
- Executor: durable implementation truth must already exist in the worktree, diff or execution evidence. The handoff never substitutes for source state.

Size target: each live handoff <= 2,000 tokens (characters / 4), preferably much less. The old session stops after writing it. Drills fill copies under scratch\drill-<ticket>\, never the live templates.

### a. Fresh Planner recovery
1. Read the handoff.
2. `git fetch`.
3. Verify the refs independently.
4. Run `npm run project:status -- --check <handoff>` from `site/`. It checks only the handoff's `claims` block (`ref`, `ancestor`, `status` lines) against the repository. Exit 1 means stop and report; do not proceed. Claims written as prose are not checked by the script and remain a manual check against the repository.
5. Do the repository-mandated boot reads (root `CLAUDE.md`: `ROADMAP.md`, the active sprint contract, the active ticket) and the handoff's named sources, and nothing else.
6. Report staging SHA, main SHA, primary intent, active ticket and state, next action, and discrepancies.
7. Continue only after a clean recovery. Any failed check or unresolved discrepancy means stop and report to Product Authority.

Deliberate deviation: a cloud Planner cannot write this local folder, so its live handoff is `handoffs/planner-handoff.md` in the shared project folder, not here. The template here stays the format source.

### b. Fresh Executor recovery
1. Read the handoff.
2. Verify the ticket and seal commit.
3. `git merge-base --is-ancestor <seal> HEAD`.
4. Verify branch, worktree and working-tree state.
5. Read the sealed ticket.
6. Check each handoff claim against its own evidence: committed and working changes (`git diff <seal>`, `git status`), untracked file contents, local artifacts by hash, and verification results by re-running or by the cited output.
7. Report seal verified, branch/worktree verified, HEAD, changed files, remaining scope, next action, and discrepancies.
8. Continue only within the sealed authorization. A failed seal, identity or worktree check, or an unresolved progress mismatch, means stop and report to the Planner. Staying inside Authorized paths doesn't resolve it.