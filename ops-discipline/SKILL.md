---
name: ops-discipline
description: General-purpose Linux operations discipline and tooling. Use when babysitting a running system long-term (daemons/service fleets/batch pipelines), performing releases/upgrades/teardowns/restarts, or autonomously maintaining monitoring while the user is offline. Core ideas: tiered scheduled monitoring, evidence before action, pinned identities, never blocking the conversation, pre-authorized autonomous execution.
---

# Ops discipline skill (any Linux project)

Distilled from real multi-day releases, on-call watches, and incident handling. Written for an agent carrying operational responsibility.
One principle: **keep the machine running untrusted-free for long stretches, and be able to account for its state to a human at any moment.**

## 0. Message source discrimination (do this before every response)

Messages reach you from two sources, and they behave differently:

| Source | Signature | Behavior |
| --- | --- | --- |
| **Scheduled reminder** (cron-fire) | Periodic check wrapped in a task envelope | Run the checklist in the reminder, report briefly; one or two lines when nothing changed, never expand |
| **User instruction** | Typed directly by the user | Highest priority: drop routine monitoring immediately and respond; the instruction may modify or abort the monitoring itself |

Avoid both failure modes: treating a scheduled reminder like a chat prompt and dumping a long report (noise), or treating a user instruction like routine and deferring it (loss of control).

## 0.5 Host preparation at takeover (first thing on a new machine)

1. **Check atop**: `scripts/atop_check.sh`. atop is the infrastructure for all later
   resource monitoring (CPU/memory/disk/network in one tool, plus historical sampling
   for after-the-fact analysis). If missing, the script prints the install command for
   the detected package manager; `--install` installs it; then `--enable-log` turns on
   history sampling (systemd atop.service, samples land in /var/log/atop/) — without
   history, after an incident you can only say "it looks fine now" instead of replaying
   the failure window with `atop_watch.sh --history`.
2. Confirm timezone/clock source (chrony/ntp running), disk floor, log rotation.
3. Create the evidence root and an env pin file (templates/env.sh); every later action references that single identity.

## 1. Tiered monitoring cadence

| Phase | Interval | Trigger |
| --- | --- | --- |
| Emergency | <3 min | Data-loss signal, process exit, unknown alert, upgrade/migration in flight |
| Focused | <10 min | Startup, close/settlement windows, post-deploy observation |
| Steady | ≤30 min | Routine running after all health gates pass |

- Carry monitoring in scheduled tasks (cron-style); **the task prompt must be
  self-contained** (world identity, check commands, known-noise list, escalation
  criteria, red lines) — execution must not depend on memory.
- Shift gears on phase transitions (change interval or recreate the task); a task
  deletes itself once its mission ends.
- Report briefly after each check; one or two lines when nothing changed.

## 2. Never block the conversation

- **No foreground `sleep` waits.** Hard rule: a foreground wait jams the channel with the user.
- To wait, use a **background Bash task** (completion notifies you automatically) or a
  **one-shot/recurring scheduled task**.
- Long tasks always detach: `setsid nohup ... > /path/log 2>&1 < /dev/null &`,
  with the log at a fixed location (see scripts/run_detached.sh).

## 3. Process-handling discipline

- **No `pgrep -f` / `pkill -f`**: pattern matching kills the wrong process (any command
  line that happens to contain the keyword). Liveness checks use **pidfile + `kill -0 <pid>`**
  only; termination goes through the service's own stop channel or an exact PID.
- Never delete lock files or steal leases: fcntl locks bind to open file descriptions,
  so deleting the file does not release the lock — it just creates two writers each
  holding a "lock". The only legal release is the holder finishing.
- Every service has a unique identity (pid + birth); before a restart, prove the old
  instance is exactly dead to prevent double writers.

## 4. Evidence and honesty

- **Preserve the scene before acting**: on anomaly, snapshot logs/state/locks/inventory
  into the evidence directory first, then diagnose, then touch anything.
- **exit 0 ≠ success**: verify the real artifacts (output files, record counts, state
  fields). Process UP ≠ data flowing; alerts silent ≠ healthy (confirm the metrics
  exist and are advancing).
- **Never claim the unverified**: records distinguish "measured" / "inferred" /
  "unverified"; re-verify success claims found in handoffs yourself.
- Evidence layout: `$EVIDENCE_ROOT/<topic>/<UTC timestamp>/`, with an identity file at
  the entry (version/pins/time/operator). See scripts/evidence_snapshot.sh.

## 5. Alerts and known noise

- Check every alert's **reason** individually; reciting names is not triage.
- Maintain a **known-noise list** (each entry with its classification rationale);
  escalate only new alert names or changed reasons on old ones.
- Do not silence alerts because they are noisy — maintaining the silence list itself
  must be recorded.

## 6. Changes and teardown

- **Teardown: inventory first, approval second** — list what gets deleted, what stays,
  and where the evidence is; irreversible actions need explicit authorization.
- Pinned release identity: production runs only the pinned release unit
  (manifest + SHA); never derive identity from a branch head.
- No hot-patching of running code/config; fixes go through an isolated workspace,
  get verified, then get switched in.
- Data-deleting commands report before/after `df`/inventory deltas.

## 7. Autonomy boundaries

- **Pre-authorized execution chains**: once a chain is authorized (e.g.
  upgrade → verify → teardown → restart), carry it to completion without pausing
  for confirmation.
- **Explicit human gates**: points that need human judgment (e.g. "no other writer is
  running") become attestations: you prepare the evidence package, the human confirms.
- **N unanswered calls → decide on the evidence yourself** (default N=3), and record
  the decision honestly afterwards.
- A frozen chain is not forced: when the state machine freezes or evidence mismatches,
  preserve the scene and report; do not retry, bypass, or quietly lower the goal.

## 8. Resources and hygiene

- Disk floor monitoring plus growth-rate alerts (trend beats instantaneous value).
- Bounded builds/batch: `nice -n 19 ionice -c 3 taskset -c <low cores>` — never starve production.
- Secret hygiene: never read, print, or write secrets into evidence/logs/pins.
- Clean temp files regularly; only remove build outputs/worktrees with no uncommitted changes.

## 9. Handoff document (long-term ops memory)

One running handoff document (e.g. AGENTS.local.md), append-only, with anchored
section numbers. Each section: facts (with evidence pointers) → classification →
ruling/action → open items.
Keep a "current scene" summary at the top, updated on every state change. Commit timing
and push authorization are separate decisions.

## 8.5 Resource monitoring baseline: atop is the standard

- For system-level resources (CPU/memory/disk/network) always use `atop_watch.sh`;
  do not cobble together vmstat/iostat/ifstat — one tool, one vocabulary, replayable history.
- Live snapshot: `atop_watch.sh [interval] [samples]`; trend: `atop_watch.sh --history 60`.
- Reading guide: CPU busy >85% or wait persistently >10% signals pressure; disk busy
  persistently >80% means I/O saturation; network should track business rate
  (sudden drop = flow broke, sudden surge = catch-up).
- Per-process detail still uses `mem_watch.sh` (RSS/cgroup) and the Top-processes
  section of atop's screen output.
- Note: atopsar truncates long interface names to column width (e.g. docker0 shows as
  ocker0); when comparing across time, rely on the truncated name being consistent.

## Scripts (scripts/)

| Script | Purpose |
| --- | --- |
| `run_detached.sh` | Start long tasks detached from the session (setsid+nohup+fixed log path) |
| `health_snapshot.sh` | One-shot health snapshot (pidfile liveness/ports/disk/load/memory) |
| `progress_watch.sh` | Watch log keyword progression (with stall detection) |
| `mem_watch.sh` | Process-group RSS/memory monitoring (cgroup aware) |
| `disk_watch.sh` | Disk usage + growth-rate alerting |
| `evidence_snapshot.sh` | One-command anomaly scene preservation |
| `alert_triage.sh` | Alert enumeration + known-noise list comparison |
| `atop_check.sh` | atop detection/install/history-log enablement (run at takeover, see §0.5) |
| `atop_watch.sh` | Combined CPU/memory/disk/network snapshot; `--history N` replays the last N minutes |

## Templates (templates/)

| Template | Purpose |
| --- | --- |
| `monitor-cron-prompt.md` | Self-contained monitoring-task prompt skeleton |
| `env.sh` | Env pin file skeleton (identity/paths/budgets in one place) |
| `handoff-entry.md` | Handoff-document entry skeleton |
