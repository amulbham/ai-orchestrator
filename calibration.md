# Calibration (observational, not an approval gate)

The Planner appends one row at each ticket closure. Counts are never a score.

| Ticket | Risk | Reviewers | B/R accepted | B/R rejected | Retries or deviations | Amul interventions |
|---|---|---|---|---|---|---|
| TP2.0 to TP2.4 | not recorded | not recorded | not recorded | not recorded | not recorded | not recorded |
| TP2.5 | R1 | Codex gpt-6.1-sol/medium | 1 BLOCKER + 7 REQUIRED | 0 | Fix during testing: `ls-tree` needed `--full-tree`; fresh-Planner drill not run | not recorded |
| TP2.6 | R2 | Codex gpt-6.1-sol/medium | 1 BLOCKER + 9 REQUIRED | 0 | Relative paths resolve against payload `cwd`; an earlier local session did not load the hook (not a fresh session) | not recorded |
