# Monitoring scheduled-task prompt template

> Usage: when creating a monitoring task, fill this skeleton into a fully self-contained
> prompt — execution must not rely on memory or session state.

```
Ops monitoring (<phase>, <interval>): <system name> (release <pin>, started <UTC time>, env <env pin path>, evidence <dir>).

Every check:
1) source <env pin> (identity/mounts/thresholds live there; MOUNTS comes from the
   disk layout confirmed with the user in §0.5)
2) <process/service liveness> (pidfile + kill -0, strict pid; never pgrep -f)
3) <health endpoints> (exact specs; note the address when not loopback)
4) <key metrics> (exact queries and normal ranges)
5) <resources> (atop_watch.sh 2 2; disk_watch.sh <mount> <floor-GiB> [rate-GiB/h] [statefile])
6) Triage every alert's reason. Known noise (do not report while the reason is unchanged):
   <list; strong entries carry name+severity+summary[+instance]>.
   New alert name / changed reason / drops>0 / process exit -> urgent recheck and report.
7) Confirm the previous round actually ran (heartbeat file / last-run stamp).
8) <phase-specific focus> (e.g. close or upgrade window procedure)

Exit-code contract (all scripts): 0=OK; 1=tool/environment failure;
2=insufficient evidence (NEVER treat as OK); 3=hard fault -> escalate.
Report exit 1/2/3. On exit 1 fix the tooling (parser/atop/curl); on exit 2 restore
the evidence gap before concluding anything.

Discipline: no pkill/pgrep -f; never delete locks or steal leases; no foreground sleep waits;
on anomaly run evidence_snapshot before reporting.
Autonomy: N unanswered owner calls (default 3) allow decisions ONLY within the
pre-authorized action set and budget. No response never grants new authority; human
gates, irreversible actions and scope expansion stay blocked and keep escalating.
Report briefly after each check; one or two lines when nothing changed.
```
