# AI Orchestrator

A local review harness for AI-assisted development. It runs independent reviews against a pinned repository state, checks the integrity of the resulting findings, and leaves the final decision with the planner and human owner.

I built it while developing [amulbham.com](https://amulbham.com). Using different AI systems to plan, implement, and review changes made one problem increasingly important: how do you keep the original task, the review evidence, and the decision to accept the work separate?

**This repository implements the review runner and mechanical findings summary, with supporting handoff procedures.** It is not a fully autonomous multi-agent development system or a general-purpose model benchmark. The wider planning, execution, and release process is documented in [cybernetics-mbp](https://github.com/amulbham/cybernetics-mbp).

## The workflow

1. **Product direction:** I set the objective, priorities, constraints, and release boundaries.
2. **Planning:** A planner turns that direction into a ticket covering the starting repository state, authorized changes, exclusions, acceptance criteria, negative tests, and stop conditions. See the [planning protocol](https://github.com/amulbham/cybernetics-mbp/blob/main/site/PLANNING.md).
3. **Independent pre-seal review:** Read-only reviewers inspect the ticket and inherited source material at pinned commits.
4. **Mechanical summary:** The harness validates reviewer output and groups findings without rewriting their meaning or declaring false consensus.
5. **Execution:** Once approved and sealed, a separate executor implements the bounded task in its own worktree.
6. **Verification and release:** The planner checks the actual diff, validators, and deployed result. Material changes and production releases still require my authorization.

The executor's instructions, the reviewers' findings, and the final approval are **distinct artifacts and responsibilities**.

## What the code does

| Component | Role |
|---|---|
| [`review.ps1`](review.ps1) | Invokes read-only Codex reviews, adding Grok for higher-risk R3 reviews; captures model settings, Git commit, run IDs, fallbacks, status, and artifacts |
| [`summarize.ps1`](summarize.ps1) | Verifies manifest hashes, run identity, finding format, and verdict consistency; rejects missing, malformed, or stale records rather than silently scoring them |
| [`briefs/executor-brief.md`](briefs/executor-brief.md) | Self-contained executor handoff template with the ticket, seal commit, and worktree boundaries |
| [`calibration.md`](calibration.md) | Tracks reviewer findings and later outcomes as observations, not automated scores |

R1/R2 use Codex; R3 adds Grok. The summary records finding severity and reviewer disagreements verbatim. The **PLANNER DISPOSITION** field remains blank for a person to resolve; neither the runner nor a SEAL verdict grants permission to merge or deploy.

## An example grounded in tests

The website's [TP2.3 review-tooling record](https://github.com/amulbham/cybernetics-mbp/blob/staging/site/planning/tickets/TP2.3-review-tooling-bindings-and-summary.md) documents live single- and dual-review runs and adversarial cases.

An earlier review summary had reported zero findings because it could not parse the reviewers' free-form responses. The corrected code rejects malformed input instead of reporting misleading counts. Documented tests also cover stale review artifacts, missing records, altered hashes, and inconsistent verdicts.

The linked record notes an unresolved limitation: reviewers may disagree or demand excessive corrections. A second opinion is not itself proof of correctness.

For a worked example of the *larger* ticket-to-release workflow, see [T19.0: publication taxonomy migration](https://github.com/amulbham/cybernetics-mbp/blob/main/site/planning/tickets/T19.0-publication-taxonomy-migration.md) and its [test evidence](https://github.com/amulbham/cybernetics-mbp/blob/main/site/planning/audits/T19.0-taxonomy-migration-evidence.md). This harness did not itself execute that migration.

## Local use

Designed for Windows PowerShell, Git, a separate worktree at the reviewed commit, and the appropriate authenticated model CLIs. Model IDs are explicitly pinned in the script and may require updating for a new environment.

~~~powershell
.\review.ps1 -Id <ticket-id> -TicketPath <repo-relative-ticket> -Worktree <review-worktree> -Tier R1
.\review.ps1 -Id <ticket-id> -TicketPath <repo-relative-ticket> -Worktree <review-worktree> -Tier R3
~~~

The default review prompt lives in the target worktree at `site/planning/templates/pre-seal-review.md`. The full [operating runbook](docs/operating-runbook-2026-10-06.md) preserves the original CLI arguments, fallbacks, output format, security rules, and session handoffs.

## Status and limits

- This is a public snapshot of working **local review tooling**; the full coordination workflow spans other repositories and sessions.
- The October 6 runbook describes unfinished coordinator-relay and workflow-friction validation. Documented procedures do not imply every integration was completed.
- Local `scratch/` fixtures, generated reviews, and raw logs are Git-ignored. The source and linked ticket evidence show specific tests, but this repository alone is not a standalone public test suite.
- No secrets, credentials, or private research should be committed. Reviewers use read-only snapshots; executors work separately. Production authorization remains with the owner.

The [original October 6 README](docs/operating-runbook-2026-10-06.md) is preserved verbatim for continuity.
