# env pin file skeleton — the whole identity of one world in a single source-able file
# Discipline: runs only trust the pins here; never derive identity from branch heads or env residue.

# Identity
export RELEASE_COMMIT=<full-sha>
export RELEASE_DIR=<absolute-path-to-sealed-release>
export EXPECTED_MANIFEST_SHA256=<manifest file SHA-256>

# Locations
export WORK_ROOT=<run root>
export DATA_ROOT=<data root>
export EVIDENCE_ROOT=<evidence root>

# Budgets / thresholds
export DISK_FLOOR_GIB=100
# export BUILD_CPUS=0-3   # bounded builds

# Fixed runtime environment
export PYTHONDONTWRITEBYTECODE=1
# export PYTHONPATH=<checkout>/src:<checkout>
