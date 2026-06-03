#!/usr/bin/env bash

###############################################################################
# PostgreSQL 17 - POST UPGRADE MAINTENANCE SCRIPT
#
# WHAT THIS SCRIPT DOES
# 1. Verify PostgreSQL 17 is running
# 2. Apply extension updates
# 3. Run ANALYZE (optimizer stats rebuild)
# 4. Run VACUUM FREEZE
# 5. Validate core settings
# 6. Generate post-upgrade report
###############################################################################

set -e

# =========================
# CONFIGURATION
# =========================
PG_PORT=5433
PG_BINDIR="/usr/lib/postgresql/17/bin"

REPORT_FILE="/tmp/post_upgrade_report_$(date +%F_%H%M).txt"

PSQL="sudo -u postgres $PG_BINDIR/psql -p $PG_PORT"
VACUUMDB="sudo -u postgres $PG_BINDIR/vacuumdb -p $PG_PORT"

# =========================
# HELPERS
# =========================
info(){ echo -e "\e[34m[INFO]\e[0m $*"; }
ok(){ echo -e "\e[32m[OK]\e[0m $*"; }
err(){ echo -e "\e[31m[ERROR]\e[0m $*"; exit 1; }

# =========================
# LOGGING
# =========================
exec > >(tee -a "$REPORT_FILE") 2>&1

echo "================================================="
echo " PostgreSQL 17 POST-UPGRADE MAINTENANCE"
echo "================================================="

# =====================================================
# STEP 1 - VERIFY SERVER
# =====================================================
info "Checking PostgreSQL 17 status..."

$PSQL -c "SELECT version();" >/dev/null || err "PostgreSQL 17 not running"

ok "PostgreSQL 17 is running"

# =====================================================
# STEP 2 - UPDATE EXTENSIONS
# =====================================================
info "Updating extensions (if required)..."

if [[ -f /tmp/pg_upgrade_15_to_17/update_extensions.sql ]]; then
  $PSQL -f /tmp/pg_upgrade_15_to_17/update_extensions.sql || true
  ok "Extension updates applied"
else
  info "No update_extensions.sql found"
fi

# =====================================================
# STEP 3 - ANALYZE (CRITICAL)
# =====================================================
info "Running ANALYZE (optimizer statistics rebuild)..."

$VACUUMDB --all --analyze-in-stages

ok "ANALYZE completed"

# =====================================================
# STEP 4 - VACUUM FREEZE
# =====================================================
info "Running VACUUM FREEZE..."

$VACUUMDB --all --freeze

ok "VACUUM FREEZE completed"

# =====================================================
# STEP 5 - VALIDATION CHECKS
# =====================================================
info "Validating core settings..."

$PSQL -c "SHOW data_directory;"
$PSQL -c "SHOW shared_preload_libraries;"
$PSQL -c "SELECT pg_current_wal_lsn();"

# =====================================================
# STEP 6 - EXTENSION CHECK
# =====================================================
info "Installed extensions:"

$PSQL -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;"

# =====================================================
# SUMMARY
# =====================================================
echo ""
echo "======================================"
echo "✅ PostgreSQL 17 POST-UPGRADE COMPLETE"
echo "======================================"
echo "Report file : $REPORT_FILE"
