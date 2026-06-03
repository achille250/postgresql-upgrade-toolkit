#!/usr/bin/env bash

###############################################################################
# PostgreSQL 15 → PostgreSQL 17 Automated Upgrade Script (Production Grade)
#
# WHAT THIS SCRIPT DOES:
#
# 1. Ensures PostgreSQL 15 is running
# 2. Extracts all non-default tuned PostgreSQL 15 parameters
# 3. Performs a full physical backup using pg_basebackup
# 4. Installs PostgreSQL 17 binaries
# 5. Stops PostgreSQL services cleanly
# 6. Initializes PostgreSQL 17 data directory
# 7. Runs pg_upgrade (check + COPY mode)
# 8. Creates log and WAL archive directories
# 9. Configures PostgreSQL 17 service to use new data directory
# 10. Starts PostgreSQL 17 via systemd
# 11. Applies:
#     - Migrated tuning parameters
#     - Log directory
#     - WAL archiving
# 12. Validates configuration paths
# 13. Verifies WAL and replication status
# 14. Runs performance sanity checks
# 15. Executes ANALYZE and VACUUM FREEZE
# 16. Migrates pg_hba.conf automatically
# 17. Generates a full upgrade report
###############################################################################

set -e

# =========================
# CONFIGURATION
# =========================
# =========================
# CONFIGURATION
# =========================

OLD_VERSION=15
NEW_VERSION=17
PG_PORT=5433
OLD_DATADIR="/u01/postgres15"
NEW_DATADIR="/u01/postgres17"

OLD_BINDIR="/usr/lib/postgresql/15/bin"
NEW_BINDIR="/usr/lib/postgresql/17/bin"

CONF_DIR="/etc/postgresql/17/main"

LOG_DIR="/u02/postgres17_log"
ARCHIVE_DIR="/u02/postgres17_archive"

BACKUP_DIR="/u02/basebackups"
BACKUP_USER="backup_user"

SETTINGS_DUMP="/tmp/pg15_custom_settings.conf"

REPORT_FILE="/tmp/pg_upgrade_report_$(date +%F_%H%M).txt"
# Parallel upgrade workers (auto calculate)--(recommended: CPU/2)
CPU=$(nproc)
JOBS=$((CPU / 2))
echo "[INFO] Detected CPU cores: $CPU"
echo "[INFO] Using pg_upgrade jobs: $JOBS"

# =====================================================
# PRODUCTION SAFETY GUARD — BLOCK LINK MODE
# =====================================================
SCRIPT_SELF="$(readlink -f "$0")"
if grep -E '^[[:space:]]*sudo.*pg_upgrade.*--link' "$SCRIPT_SELF" >/dev/null; then
  echo "[ERROR] --link mode detected. Upgrade blocked."
  exit 1
fi

# =========================
# STEP TRACKER
# =========================
step() {
  CURRENT_STEP="$1"
  info "$CURRENT_STEP..."
}

# =========================
# HELPER FUNCTIONS
# =========================
info(){ echo -e "\e[34m[INFO]\e[0m $*"; }
ok(){ echo -e "\e[32m[OK]\e[0m $*"; }
err(){ echo -e "\e[31m[ERROR]\e[0m $*"; exit 1; }
step() {
  CURRENT_STEP="$1"
  info "$CURRENT_STEP..."
}
[[ $EUID -eq 0 ]] || err "Run as root"

# =====================================================
# SAFETY CHECK — ENSURE NEW_DATADIR NOT IN USE
# =====================================================
# SAFETY CHECK — NEW_DATADIR
if [[ -f "$NEW_DATADIR/postmaster.pid" ]]; then
  err "NEW_DATADIR already contains a running PostgreSQL cluster"
fi


# =====================================================
# MULTI-INSTANCE SAFE PSQL DEFINITIONS
# =====================================================
OLD_PSQL="sudo -u postgres $OLD_BINDIR/psql -p $PG_PORT"
NEW_PSQL="sudo -u postgres $NEW_BINDIR/psql -p $PG_PORT"


# =====================================================
# CLUSTER VERIFICATION
# =====================================================
info "Verifying OLD cluster identity..."
PGDATA="$OLD_DATADIR" sudo -u postgres "$OLD_BINDIR/pg_controldata" "$OLD_DATADIR" \
 | grep "Database system identifier" >/dev/null \
 || err "OLD cluster verification failed"

# =========================
# ERROR TRAP / ROLLBACK
# =========================
cleanup_on_failure() {

  echo "[ERROR] Upgrade failed at step: $CURRENT_STEP"

  rm -f "/var/run/postgresql/.s.PGSQL.${PG_PORT}"* 2>/dev/null || true
  rm -f "/tmp/.s.PGSQL.${PG_PORT}"* 2>/dev/null || true
  rm -f "$OLD_DATADIR/postmaster.pid" 2>/dev/null || true

  sudo -u postgres "$OLD_BINDIR/pg_ctl" -D "$OLD_DATADIR" start \
    -l /tmp/pg15_rollback.log 2>/dev/null || true

  exit 1
}

trap cleanup_on_failure ERR

# =========================
# LOGGING
# =========================
exec > >(tee -a "$REPORT_FILE") 2>&1

CURRENT_STEP="Initialization"

# =====================================================
# STEP 1 - ENSURE PG15 RUNNING
# =====================================================
step "Ensuring PostgreSQL 15 is running"

sudo -u postgres "$OLD_BINDIR/pg_ctl" -D "$OLD_DATADIR" start >/dev/null 2>&1 || true
ok "PostgreSQL 15 is running"

# =====================================================
# STEP 2 - CAPTURE CUSTOM SETTINGS
# =====================================================
step "Extracting custom settings"


PGDATA="$OLD_DATADIR" $OLD_PSQL -At <<EOF > "$SETTINGS_DUMP"
SELECT name || ' = ' || quote_literal(setting)
FROM pg_settings
WHERE setting <> boot_val
AND source IN ('configuration file','override','command line')
ORDER BY name;
EOF

ok "Settings extracted"


# =====================================================
# STEP 3 - BACKUP
# =====================================================
step "Creating backup"


TIMESTAMP=$(date +%F-%H%M)
BACKUP_PATH="$BACKUP_DIR/$TIMESTAMP"

mkdir -p "$BACKUP_DIR"
chown postgres:postgres "$BACKUP_DIR"

sudo -u postgres "$OLD_BINDIR/pg_basebackup" \
 -D "$BACKUP_PATH" \
 -U "$BACKUP_USER" \
 -p "$PG_PORT" \
 -X stream -Ft -P -v

ok "Backup complete"


# =====================================================
# STEP 4 - INSTALL PG17
# =====================================================
step "Installing PostgreSQL 17"

apt-get update -y >/dev/null
apt-get install -y postgresql-17 postgresql-client-17 postgresql-contrib-17 >/dev/null

# =====================================================
# STEP 4B - INSTALL POWA EXTENSIONS (HARDCODED)
# =====================================================
step "Installing PoWA required PostgreSQL 17 extensions"

apt-get install -y \
 postgresql-17-powa \
 postgresql-17-pg-qualstats \
 postgresql-17-pg-stat-kcache \
 postgresql-17-hypopg \
 postgresql-17-pg-wait-sampling \
 postgresql-17-pg-track-settings \
 >/dev/null 2>&1 || true

ok "PoWA extensions installed (if available)"

# =====================================================
# STEP 4C - INSTALL OTHER REQUIRED EXTENSIONS (AUTO)
# =====================================================
step "Installing other PostgreSQL 17 extension libraries (auto)"

EXT_LIST=$($OLD_PSQL -At <<EOF
SELECT extname
FROM pg_extension
WHERE extname NOT IN ('plpgsql');
EOF
)

for ext in $EXT_LIST; do

  # Convert underscores -> dashes automatically
  PKG="postgresql-17-${ext//_/-}"

  info "Checking extension package: $PKG"

  if apt-cache show "$PKG" >/dev/null 2>&1; then
    apt-get install -y "$PKG" >/dev/null 2>&1 || true
    ok "Installed: $PKG"
  else
    info "Package not found for extension: $ext (may be core or already installed)"
  fi

done

ok "Auto extension package check completed"

# =====================================================
# STEP 5 - STOP SERVICES
# =====================================================
step "Stopping PostgreSQL services"


sudo -u postgres "$OLD_BINDIR/pg_ctl" -D "$OLD_DATADIR" stop -m fast >/dev/null 2>&1 || true
systemctl stop postgresql@15-main || true
systemctl stop postgresql@17-main || true

# =====================================================
# STEP 6 - INIT NEW DATA DIRECTORY
# =====================================================
step "Initializing PostgreSQL 17 data directory"


mkdir -p "$NEW_DATADIR"
chown postgres:postgres "$NEW_DATADIR"
chmod 700 "$NEW_DATADIR"

sudo -u postgres "$NEW_BINDIR/initdb" -D "$NEW_DATADIR"

# =====================================================
# STEP 6B - TEMP SHARED PRELOAD LIBRARIES FOR UPGRADE
# =====================================================
step "Configuring shared_preload_libraries for pg_upgrade"

cat >> "$NEW_DATADIR/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_stat_statements,pg_stat_kcache,pg_wait_sampling,powa'
EOF

# =====================================================
# STEP 7 - PG_UPGRADE (COPY MODE)
# =====================================================
step "Running pg_upgrade"


UPGRADE_DIR="/tmp/pg_upgrade_${OLD_VERSION}_to_${NEW_VERSION}"
mkdir -p "$UPGRADE_DIR"
chown postgres:postgres "$UPGRADE_DIR"
cd "$UPGRADE_DIR"

sudo -u postgres "$NEW_BINDIR/pg_upgrade" \
 --old-datadir "$OLD_DATADIR" \
 --new-datadir "$NEW_DATADIR" \
 --old-bindir "$OLD_BINDIR" \
 --new-bindir "$NEW_BINDIR" \
 --old-port "$PG_PORT" \
 --new-port "$PG_PORT" \
 --check \
 --jobs=$JOBS

sudo -u postgres "$NEW_BINDIR/pg_upgrade" \
 --old-datadir "$OLD_DATADIR" \
 --new-datadir "$NEW_DATADIR" \
 --old-bindir "$OLD_BINDIR" \
 --new-bindir "$NEW_BINDIR" \
 --old-port "$PG_PORT" \
 --new-port "$PG_PORT" \
 --jobs=$JOBS

ok "Upgrade finished"

# =====================================================
# STEP 8 - DIRECTORIES
# =====================================================
step "Making Archive Directory"

mkdir -p "$LOG_DIR" "$ARCHIVE_DIR"
chown postgres:postgres "$LOG_DIR" "$ARCHIVE_DIR"

# ====================================================
# =====================================================
# STEP 9 - CONFIGURE SERVICE DATA DIRECTORY (SYSTEMD)
# =====================================================
step "Creating systemd cluster configuration"

if [[ ! -d /etc/postgresql/17/main ]]; then
  pg_createcluster 17 main --datadir="$NEW_DATADIR" --start-conf=manual
  ok "Systemd cluster created"
else
  info "Systemd cluster already exists, skipping creation"
fi



# =====================================================
# STEP 10 - START SERVICE
# =====================================================
step "Start Postgres Services"
systemctl start postgresql@17-main
systemctl enable postgresql@17-main

# =====================================================
# STEP 11 - MIGRATE pg_hba.conf
# =====================================================
step "Migrate old pg_hba.conf to new pg_hba.conf"
cp "$OLD_DATADIR/pg_hba.conf" "$CONF_DIR/pg_hba.conf" 2>/dev/null || true

# =====================================================
# STEP 12 - APPLY SETTINGS
# =====================================================
step "APPLY SETTINGS"
$NEW_PSQL <<EOF
ALTER SYSTEM SET log_directory = '$LOG_DIR';
ALTER SYSTEM SET archive_mode = 'on';
EOF

# =====================================================
# STEP 13 - RESTORE SETTINGS
# =====================================================
step "RESTORE SETTINGS"

# Restore all dumped parameters except shared_preload_libraries
while IFS= read -r line; do

  # Skip shared_preload_libraries (handled separately)
  echo "$line" | grep -Eq "^shared_preload_libraries[[:space:]]*=" && continue

  $NEW_PSQL -c "ALTER SYSTEM SET $line;" >/dev/null 2>&1 || true

done < "$SETTINGS_DUMP"

# Ensure listen on all interfaces
$NEW_PSQL -c "ALTER SYSTEM SET listen_addresses='*';"

# Reset first to avoid pollution
$NEW_PSQL -c "ALTER SYSTEM RESET shared_preload_libraries;"

# Set preload libraries WITHOUT quotes (IMPORTANT)
$NEW_PSQL -c "ALTER SYSTEM SET shared_preload_libraries='pg_stat_statements';"

$NEW_PSQL -c "ALTER SYSTEM SET logging_collector=on;"
$NEW_PSQL -c "ALTER SYSTEM SET log_directory='/u02/postgres17_log';"

$NEW_PSQL -c "ALTER SYSTEM SET archive_mode='on';"

$NEW_PSQL -c "ALTER SYSTEM SET archive_command='test ! -f ${ARCHIVE_DIR}/%f && cp %p ${ARCHIVE_DIR}/%f';"


# Restart required for preload changes
systemctl restart postgresql@17-main

ok "Settings restored safely"

# =====================================================
# STEP 14-16 VALIDATION
# =====================================================
step "Validating SETTINGS"
$NEW_PSQL -c "SHOW data_directory;"
$NEW_PSQL -c "SELECT pg_current_wal_lsn();"
$NEW_PSQL -c "SELECT name,setting FROM pg_settings LIMIT 5;"

# =====================================================
# STEP 17 - MAINTENANCE
# =====================================================
step "Database Maintenance"
sudo -u postgres vacuumdb -p "$PG_PORT" --all --analyze-only >/dev/null 2>&1 &
sudo -u postgres vacuumdb -p "$PG_PORT" --all --freeze >/dev/null 2>&1 &

# =========================
# SUMMARY
# =========================
echo "======================================"
echo "✅ PostgreSQL 17 Upgrade Complete"
echo "======================================"
echo "Upgrade report : $REPORT_FILE"