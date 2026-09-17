#!/bin/bash

# Auto-scale Docker Compose memory limits based on total system memory.
# CPU is deliberately NOT capped: these are single-tenant hosts, so hard CPU
# quotas only stop a container from bursting into idle cores (a 0.3-cpu cap
# on postgrest stalled requests under load while the host sat at load 0.01).
# Under contention the kernel's default equal cpu.weight arbitrates.

set -e

# Current memory configuration (in MB). POSTGREST_BASE is tier-dependent and
# set once total memory is known.
POSTGRES_BASE=150
INSFORGE_BASE=150

# Get total system memory (in MB) and CPU core count
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux - get total memory
    TOTAL_MEM=$(free -m | awk 'NR==2 {print $2}')
    TOTAL_CPUS=$(nproc)
    echo "Total system memory on Linux: ${TOTAL_MEM}MB, CPUs: ${TOTAL_CPUS}"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS - get total memory
    TOTAL_MEM=$(sysctl -n hw.memsize | awk '{print $1/1024/1024}')
    TOTAL_CPUS=$(sysctl -n hw.ncpu)
    echo "Total system memory on macOS: ${TOTAL_MEM}MB, CPUs: ${TOTAL_CPUS}"
else
    echo "Unsupported OS: $OSTYPE"
    exit 1
fi

# PostgREST's share: an equal third on instances with room for it. The legacy
# 150:50:150 split starved postgrest exactly where load is highest — a 4GB
# medium gave it 544MB against a 90-connection pool, with its heap grazing the
# cap after days of uptime. Below ~2GB there is little absolute slack — an
# equal third would shrink postgres/insforge caps on boxes where they are
# already tight — so tiny instances keep the legacy base.
if [ "$TOTAL_MEM" -ge 1800 ]; then
    POSTGREST_BASE=150
else
    POSTGREST_BASE=50
fi

# Total base memory
TOTAL_BASE=$(( POSTGRES_BASE + POSTGREST_BASE + INSFORGE_BASE ))
echo "Base total memory: ${TOTAL_BASE}MB"

# Set AVAILABLE_MEM to TOTAL_MEM for calculation
AVAILABLE_MEM=$TOTAL_MEM

# Reserve 30MB for system overhead
RESERVED_MEM=30
USABLE_MEM=$(( AVAILABLE_MEM - RESERVED_MEM ))

if [ "$USABLE_MEM" -lt "$TOTAL_BASE" ]; then
    echo "ERROR: Not enough memory available. Need at least $((TOTAL_BASE + RESERVED_MEM))MB (${TOTAL_BASE}MB usable + ${RESERVED_MEM}MB reserved)"
    echo "Available: ${AVAILABLE_MEM}MB, Usable after reservation: ${USABLE_MEM}MB"
    exit 1
fi

echo "Usable memory after reservation: ${USABLE_MEM}MB (reserved ${RESERVED_MEM}MB for system)"

# Calculate scaling factor
SCALE_FACTOR=$(awk "BEGIN {printf \"%.4f\", $USABLE_MEM / $TOTAL_BASE}")

# Ensure minimum scale factor of 1.0 to guarantee base configuration can run
if (( $(awk "BEGIN {print ($SCALE_FACTOR < 1.0)}") )); then
    echo "WARNING: Calculated scale factor ${SCALE_FACTOR} is less than 1.0"
    echo "Setting scale factor to 1.0 to ensure base configuration can run"
    SCALE_FACTOR=1.0000
fi

echo "Scaling factor: ${SCALE_FACTOR}"

# Calculate new memory limits (rounded to nearest MB)
POSTGRES_MEM=$(awk "BEGIN {printf \"%.0f\", $POSTGRES_BASE * $SCALE_FACTOR}")
INSFORGE_MEM=$(awk "BEGIN {printf \"%.0f\", $INSFORGE_BASE * $SCALE_FACTOR}")
POSTGREST_MEM=$(awk "BEGIN {printf \"%.0f\", $POSTGREST_BASE * $SCALE_FACTOR}")
# GHC heap cap for postgrest. Leave ~20MB for non-heap (binary, RTS internals,
# thread stacks); floor at 20M to avoid pathological values on tiny instances.
POSTGREST_RTS_HEAP=$(( POSTGREST_MEM - 20 ))
if [ "$POSTGREST_RTS_HEAP" -lt 20 ]; then POSTGREST_RTS_HEAP=20; fi

# --- Scale PostgREST pool + Postgres max_connections with instance RAM ----------
# Each Postgres backend costs ~5-10MB, so these are BOUNDED per RAM tier (NOT scaled
# linearly with the memory factor, which would OOM Postgres on large instances).
# PGRST_DB_POOL is kept at ~55-60% of max_connections, leaving headroom for the app,
# admin, and direct DB connections. Fixes both nano over-pooling (OOM risk) and
# medium/xl under-pooling (PGRST003 "timed out acquiring connection from pool").
if   [ "$TOTAL_MEM" -ge 30000 ]; then PG_MAX_CONNECTIONS=700; PGRST_DB_POOL=450   # 2xl ~32G
elif [ "$TOTAL_MEM" -ge 15000 ]; then PG_MAX_CONNECTIONS=400; PGRST_DB_POOL=250   # xl ~16G
elif [ "$TOTAL_MEM" -ge 7500  ]; then PG_MAX_CONNECTIONS=250; PGRST_DB_POOL=150   # large ~8G
elif [ "$TOTAL_MEM" -ge 3500  ]; then PG_MAX_CONNECTIONS=150; PGRST_DB_POOL=90    # medium ~4G
elif [ "$TOTAL_MEM" -ge 1800  ]; then PG_MAX_CONNECTIONS=80;  PGRST_DB_POOL=45    # small ~2G
elif [ "$TOTAL_MEM" -ge 900   ]; then PG_MAX_CONNECTIONS=50;  PGRST_DB_POOL=25    # micro ~1G
else                                  PG_MAX_CONNECTIONS=30;  PGRST_DB_POOL=15    # nano ~0.5G
fi

# Backend (insforge) pg pool. The OSS default of 20 does not fit the small tiers:
# backend pool + PGRST_DB_POOL + direct client connections must stay under
# max_connections minus the 3 superuser-reserved slots. On a nano (27 usable) the
# default 20 plus PostgREST's 15 already exceeds the budget, and a burst of API
# requests ends in "sorry, too many clients already". Small and up keep 20.
# Needs an insforge-oss image that reads POSTGRES_POOL_MAX (InsForge/InsForge#2070);
# older images ignore the variable and keep their built-in 20.
if   [ "$TOTAL_MEM" -ge 1800 ]; then POSTGRES_POOL_MAX=20   # small and up: OSS default
elif [ "$TOTAL_MEM" -ge 900  ]; then POSTGRES_POOL_MAX=12   # micro: 50 max, 25 PostgREST
else                                 POSTGRES_POOL_MAX=8    # nano: 30 max, 15 PostgREST
fi
echo "Connection scaling: PGRST_DB_POOL=${PGRST_DB_POOL}, PG_MAX_CONNECTIONS=${PG_MAX_CONNECTIONS}, POSTGRES_POOL_MAX=${POSTGRES_POOL_MAX} (RAM ${TOTAL_MEM}MB)"

# Verify total doesn't exceed usable memory. Per-service rounding can land
# up to 2MB over budget (e.g. three .5 round-ups near the 1800MB cutoff);
# shave any excess off insforge, the least memory-sensitive service.
TOTAL_ALLOCATED=$(( POSTGRES_MEM + POSTGREST_MEM + INSFORGE_MEM ))
if [ "$TOTAL_ALLOCATED" -gt "$USABLE_MEM" ]; then
    INSFORGE_MEM=$(( INSFORGE_MEM - (TOTAL_ALLOCATED - USABLE_MEM) ))
    TOTAL_ALLOCATED=$USABLE_MEM
fi

echo ""
echo "=== Calculated Resource Allocation ==="
echo "postgres:      ${POSTGRES_MEM}MB (base: ${POSTGRES_BASE}MB)"
echo "postgrest:     ${POSTGREST_MEM}MB (base: ${POSTGREST_BASE}MB, GHC heap cap: ${POSTGREST_RTS_HEAP}M)"
echo "insforge:      ${INSFORGE_MEM}MB (base: ${INSFORGE_BASE}MB)"
echo "---"
echo "Total allocated: ${TOTAL_ALLOCATED}MB / ${USABLE_MEM}MB usable"
echo ""

# Update .env file with memory settings
ENV_FILE=".env"

# Create backup of .env
cp "$ENV_FILE" "${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

# Remove existing memory settings if present
sed -i.tmp '/^POSTGRES_MEMORY=/d; /^POSTGREST_MEMORY=/d; /^PGRST_DB_POOL=/d; /^PG_MAX_CONNECTIONS=/d; /^POSTGRES_POOL_MAX=/d; /^POSTGREST_RTS_HEAP=/d; /^INSFORGE_MEMORY=/d; /^POSTGRES_CPUS=/d; /^POSTGREST_CPUS=/d; /^INSFORGE_CPUS=/d; /^DENO_CPUS=/d; /^VECTOR_CPUS=/d; /^NODE_EXPORTER_CPUS=/d; /^DENO_MEMORY=/d; /^VECTOR_MEMORY=/d; /^NODE_EXPORTER_MEMORY=/d; /^# Auto-generated memory limits/d; /^# Auto-generated resource limits/d; /^# Total system memory:/d; /^# Total CPUs:/d; /^# Usable memory:/d; /^# Scaling factor:/d; /^# CPU scaling factor:/d' "$ENV_FILE"
rm -f "${ENV_FILE}.tmp"

# Append new resource settings
cat >> "$ENV_FILE" << EOF

# Auto-generated resource limits - $(date)
# Total system memory: ${AVAILABLE_MEM}MB
# Usable memory: ${USABLE_MEM}MB (after ${RESERVED_MEM}MB system reservation)
# Scaling factor: ${SCALE_FACTOR}
POSTGRES_MEMORY=${POSTGRES_MEM}M
POSTGREST_MEMORY=${POSTGREST_MEM}M
POSTGREST_RTS_HEAP=${POSTGREST_RTS_HEAP}M
INSFORGE_MEMORY=${INSFORGE_MEM}M
PGRST_DB_POOL=${PGRST_DB_POOL}
PG_MAX_CONNECTIONS=${PG_MAX_CONNECTIONS}
POSTGRES_POOL_MAX=${POSTGRES_POOL_MAX}
EOF

echo "Resource configuration updated in ${ENV_FILE}"
echo "Backup saved to ${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
echo ""
echo "To apply these settings, restart services:"
echo "   docker-compose down && docker-compose up -d"
