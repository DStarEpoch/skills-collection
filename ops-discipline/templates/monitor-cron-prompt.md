# Monitoring scheduled-task prompt template

> Usage: when creating a monitoring task, fill this skeleton into a fully self-contained
> prompt — execution must not rely on memory or session state.
> Every fire must independently know: what am I watching, what does normal look like,
> what escalates, and what the red lines are.

```
Ops monitoring (<phase>, <interval>): <system name> (release <pin>, started <UTC time>, env <path>, evidence <dir>).

Every check:
1) <process/service liveness> (pidfile + kill -0; never pgrep -f)
2) <health endpoints> (exact URLs/commands and expected values)
3) <key metrics> (exact queries and normal ranges)
4) <resources> (atop_watch.sh; df/free; growth-rate thresholds)
5) Triage every alert's reason. Known noise (do not report while the reason is unchanged): <list>.
   New alert name / drops>0 / process exit -> urgent recheck and report.
6) <phase-specific focus> (e.g. exact watch procedure for a close window or upgrade window)

Discipline: no pkill/pgrep -f; never delete locks or steal leases; no foreground sleep waits;
on anomaly run evidence_snapshot before reporting; after N unanswered calls to the owner,
decide on the evidence yourself.
Report briefly after each check; one or two lines when nothing changed.
```

## Phase-transition convention

- Startup (5min) -> after health gates pass -> steady (30min): delete the old task, create
  the new one; self-delete only after the replacement is in place.
- Mission accomplished (e.g. upgrade window closed) -> self-delete.
- Scheduled tasks can be lost to compaction/restarts: write key state into the handoff
  document, and point task prompts at the document, not at memory.
