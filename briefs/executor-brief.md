# Executor brief (template)

Fill every field. The brief must stand alone: only Amul's typed messages reach a machine session.

- Ticket path: `<repo-relative path>` in `<repo>`
- Seal SHA: `<sha>`; verify with `git merge-base --is-ancestor <seal> HEAD`
- Branch: `claude/execute-<ticket>` (from the seal). Never push `staging` or `main`.
- Completion report: appended to the ticket file on the branch.
- Fresh-session proof: any live or hook proof runs in a fresh session started in a checkout that contains the changed files; state the setup in the report. A stale session can look like a failure.
- Protected files (`.claude/hooks/`, `.claude/settings.json`): an edit needs Amul's `MBP_GUARD_OFF=1`, set outside the session. Without it, stop and report.
- The sealed ticket is the only authority; anything it does not authorize stops and is reported.
