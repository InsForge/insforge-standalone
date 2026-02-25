#!/bin/bash

# Auto-scale Docker Compose memory limits based on total system memory
# This script maintains the current memory ratio between services

set -e

# Current memory configuration (in MB)
POSTGRES_BASE=150
POSTGREST_BASE=50
INSFORGE_BASE=150
DENO_BASE=60
VECTOR_BASE=50
NODE_EXPORTER_BASE=20

# Total base memory
TOTAL_BASE=$(( POSTGRES_BASE + POSTGREST_BASE + INSFORGE_BASE + DENO_BASE + VECTOR_BASE + NODE_EXPORTER_BASE ))
echo "Base total memory: ${TOTAL_BASE}MB"

# Get total system memory (in MB)
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux - get total memory
    TOTAL_MEM=$(free -m | awk 'NR==2 {print $2}')
    echo "Total system memory on Linux: ${TOTAL_MEM}MB"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS - get total memory
    TOTAL_MEM=$(sysctl -n hw.memsize | awk '{print $1/1024/1024}')
    echo "Total system memory on macOS: ${TOTAL_MEM}MB"
else
    echo "Unsupported OS: $OSTYPE"
    exit 1
fi

# Set AVAILABLE_MEM to TOTAL_MEM for calculation
AVAILABLE_MEM=$TOTAL_MEM

# Reserve 30MB for system overhead
RESERVED_MEM=30
USABLE_MEM=$(( AVAILABLE_MEM - RESERVED_MEM ))

if [ "$USABLE_MEM" -lt 300 ]; then
    echo "ERROR: Not enough memory available. Need at least 330MB (300MB usable + 30MB reserved)"
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
DENO_MEM=$(awk "BEGIN {printf \"%.0f\", $DENO_BASE * $SCALE_FACTOR}")
# Fixed memory limits for postgrest and vector and node-exporter
POSTGREST_MEM=$POSTGREST_BASE
VECTOR_MEM=$VECTOR_BASE
NODE_EXPORTER_MEM=$NODE_EXPORTER_BASE

# Verify total doesn't exceed usable memory
TOTAL_ALLOCATED=$(( POSTGRES_MEM + POSTGREST_MEM + INSFORGE_MEM + DENO_MEM + VECTOR_MEM + NODE_EXPORTER_MEM ))

echo ""
echo "=== Calculated Memory Allocation ==="
echo "postgres:      ${POSTGRES_MEM}MB (base: ${POSTGRES_BASE}MB)"
echo "postgrest:     ${POSTGREST_MEM}MB (base: ${POSTGREST_BASE}MB)"
echo "insforge:      ${INSFORGE_MEM}MB (base: ${INSFORGE_BASE}MB)"
echo "deno:          ${DENO_MEM}MB (base: ${DENO_BASE}MB)"
echo "vector:        ${VECTOR_MEM}MB (base: ${VECTOR_BASE}MB)"
echo "node-exporter: ${NODE_EXPORTER_MEM}MB (base: ${NODE_EXPORTER_BASE}MB)"
echo "---"
echo "Total allocated: ${TOTAL_ALLOCATED}MB / ${USABLE_MEM}MB usable"
echo ""

# Update .env file with memory settings
ENV_FILE=".env"

# Create backup of .env
cp "$ENV_FILE" "${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

# Remove existing memory settings if present
sed -i.tmp '/^POSTGRES_MEMORY=/d; /^POSTGREST_MEMORY=/d; /^INSFORGE_MEMORY=/d; /^DENO_MEMORY=/d; /^VECTOR_MEMORY=/d; /^NODE_EXPORTER_MEMORY=/d; /^# Auto-generated memory limits/d; /^# Total system memory:/d; /^# Usable memory:/d; /^# Scaling factor:/d' "$ENV_FILE"
rm -f "${ENV_FILE}.tmp"

# Append new memory settings
cat >> "$ENV_FILE" << EOF

# Auto-generated memory limits - $(date)
# Total system memory: ${AVAILABLE_MEM}MB
# Usable memory: ${USABLE_MEM}MB (after ${RESERVED_MEM}MB system reservation)
# Scaling factor: ${SCALE_FACTOR}
POSTGRES_MEMORY=${POSTGRES_MEM}M
POSTGREST_MEMORY=${POSTGREST_MEM}M
INSFORGE_MEMORY=${INSFORGE_MEM}M
DENO_MEMORY=${DENO_MEM}M
VECTOR_MEMORY=${VECTOR_MEM}M
NODE_EXPORTER_MEMORY=${NODE_EXPORTER_MEM}M
EOF

echo "Memory configuration updated in ${ENV_FILE}"
echo "Backup saved to ${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
echo ""
echo "To apply these settings, restart services:"
echo "   docker-compose down && docker-compose up -d"
