# env pin file skeleton — the whole identity of one world in a single source-able file
# TRUST BOUNDARY: this file is shell code. Keep it root-owned, not world-writable, and only
# source paths you trust. Never generate it from untrusted material and source it directly.
# Discipline: runs only trust the pins here; never derive identity from branch heads or env residue.

# Disk layout and working locations (§0.5 human gate: confirm with the user first, never guess)
export SYSTEM_MOUNT="<confirm-with-user>"   # system disk mountpoint, e.g. /
export DATA_MOUNTS="<confirm-with-user>"    # data disk mountpoint(s), space separated
export WORK_ROOT="<run-root>"
export EVIDENCE_ROOT="<evidence-root>"
# health_snapshot.sh reads MOUNTS; falls back to "$SYSTEM_MOUNT $DATA_MOUNTS"
export MOUNTS="$SYSTEM_MOUNT $DATA_MOUNTS"

# Identity (verify the manifest SHA against the release dir before trusting it)
export RELEASE_COMMIT="<full-sha>"
export RELEASE_DIR="<absolute-path-to-sealed-release>"
export EXPECTED_MANIFEST_SHA256="<manifest-sha256>"

# Observation scope (pin explicitly; inherited env must not change what is watched)
# Clear inherited values first so a stale shell cannot silently redirect observation.
unset PIDDIR WATCH_PIDS CGROUP
# export PIDDIR="<pidfile-dir>"       # preferred process set
# export WATCH_PIDS="<pid list>"      # used only when PIDDIR is unset
# export CGROUP="<cgroup-path>"       # for cgroup-limit judgment

# Budgets / thresholds (confirm or override script fallback defaults per host)
export DISK_FLOOR_GIB="<confirm-with-user>"
export OPS_STATE_DIR="$HOME/.local/state/ops-skill"
# export BUILD_CPUS=0-3   # bounded builds

# Fixed runtime environment
export PYTHONDONTWRITEBYTECODE=1
# export PYTHONPATH="<checkout>/src:<checkout>"
