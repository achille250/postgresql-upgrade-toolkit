#!/usr/bin/env bash
# PostgreSQL 15 → 17 Upgrade Script
# Usage: sudo ./upgrade_pg15_to_pg17.sh

set -e  # Exit on any error

# =========================
# CONFIGURATION
# =========================
OLD_VERSION="15"
NEW_VERSION="17"
OLD_DATADIR="/u01/postgres15"
NEW_DATADIR="/u01/postgres17"
OLD_BINDIR="/usr/lib/postgresql/15/bin"
NEW_BINDIR="/usr/lib/postgresql/17/bin"

# Backup settings
BACKUP_DIR="/u02/basebackups"
BACKUP_USER="backup_user"

# =========================
# HELPER FUNCTIONS
# =========================
info()  { echo -e "\e[34m[INFO]\e[0m  $*"; }
ok()    { echo -e "\e[32m[OK]\e[0m    $*"; }
err()   { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }

# Check if running as root
[[ $EUID -eq 0 ]] || err "Please run as root: sudo $0"

# =========================
# MAIN SCRIPT
# =========================
echo "=========================================="
echo "PostgreSQL $OLD_VERSION → $NEW_VERSION Upgrade"
echo "=========================================="
echo

# Step 1: Check if PostgreSQL is already running
info "Step 1: Checking PostgreSQL $OLD_VERSION status..."

PG_RUNNING=false
if sudo -u postgres "$OLD_BINDIR/pg_ctl" -D "$OLD_DATADIR" status >/dev/null 2>&1; then
  PG_RUNNING=true
  ok "PostgreSQL $OLD_VERSION is already running"
else
  info "Starting PostgreSQL $OLD_VERSION..."
  cd /tmp  # Change to a safe directory
  if ! sudo -u postgres "$OLD_BINDIR/pg_ctl" -D "$OLD_DATADIR" start -l /tmp/pg${OLD_VERSION}.log; then
    err "Failed to start PostgreSQL $OLD_VERSION. Check /tmp/pg${OLD_VERSION}.log"
  fi
  sleep 3
  ok "PostgreSQL $OLD_VERSION started"
fi
echo

# Step 2: Take backup
info "Step 2: Creating backup..."
TIMESTAMP=$(date +%Y-%m-%d-%H%M)
BACKUP_PATH="${BACKUP_DIR}/${TIMESTAMP}"

mkdir -p "$BACKUP_DIR"
chown postgres:postgres "$BACKUP_DIR"

info "Running pg_basebackup to $BACKUP_PATH..."
if ! sudo -u postgres "$OLD_BINDIR/pg_basebackup" \
  -D "$BACKUP_PATH" \
  -U "$BACKUP_USER" \
  -X stream \
  -Ft \
  -v \
  -P; then
  err "Backup failed. Check that user '$BACKUP_USER' exists with REPLICATION privilege"
fi

ok "Backup completed: $BACKUP_PATH"
echo

# Step 2: Install PostgreSQL 17
info "Step 3: Installing PostgreSQL $NEW_VERSION..."

if [[ ! -f /etc/apt/trusted.gpg.d/postgresql.asc ]]; then
  wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | tee /etc/apt/trusted.gpg.d/postgresql.asc >/dev/null
fi

if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
  echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    | tee /etc/apt/sources.list.d/pgdg.list >/dev/null
fi

apt-get update -y >/dev/null
apt-get install -y postgresql-${NEW_VERSION} postgresql-client-${NEW_VERSION} postgresql-contrib-${NEW_VERSION} >/dev/null

[[ -d "$NEW_BINDIR" ]] || err "PostgreSQL $NEW_VERSION installation failed"
ok "PostgreSQL $NEW_VERSION installed"
echo

# Step 3: Prepare new cluster
info "Step 4: Preparing new cluster..."

mkdir -p "$NEW_DATADIR"
chown postgres:postgres "$NEW_DATADIR"
chmod 700 "$NEW_DATADIR"

sudo -u postgres "$NEW_BINDIR/initdb" -D "$NEW_DATADIR" >/dev/null
ok "New cluster initialized"

# Stop old cluster before testing new one
info "Stopping PostgreSQL $OLD_VERSION to test new cluster..."
sudo -u postgres "$OLD_BINDIR/pg_ctl" -D "$OLD_DATADIR" stop >/dev/null
ok "PostgreSQL $OLD_VERSION stopped"

# Test new cluster
info "Testing new cluster..."
sudo -u postgres "$NEW_BINDIR/pg_ctl" -D "$NEW_DATADIR" start -l /tmp/pg${NEW_VERSION}_init.log >/dev/null
sleep 2
sudo -u postgres "$NEW_BINDIR/pg_ctl" -D "$NEW_DATADIR" stop >/dev/null
ok "New cluster tested successfully"
echo

# Step 5: Run pg_upgrade
info "Step 6: Running pg_upgrade..."

UPGRADE_DIR="/tmp/pg_upgrade_${OLD_VERSION}_to_${NEW_VERSION}"
mkdir -p "$UPGRADE_DIR"
chown postgres:postgres "$UPGRADE_DIR"
chmod 755 "$UPGRADE_DIR"
cd "$UPGRADE_DIR"

info "Running compatibility check..."
sudo -u postgres "$NEW_BINDIR/pg_upgrade" \
  --old-datadir "$OLD_DATADIR" \
  --new-datadir "$NEW_DATADIR" \
  --old-bindir "$OLD_BINDIR" \
  --new-bindir "$NEW_BINDIR" \
  --check || err "Compatibility check failed"

ok "Compatibility check passed"

info "Running actual upgrade (using --link for speed)..."
sudo -u postgres "$NEW_BINDIR/pg_upgrade" \
  --old-datadir "$OLD_DATADIR" \
  --new-datadir "$NEW_DATADIR" \
  --old-bindir "$OLD_BINDIR" \
  --new-bindir "$NEW_BINDIR" \
  --link || err "Upgrade failed"

ok "Upgrade completed!"
echo

# Step 6: Start new cluster
info "Step 7: Starting PostgreSQL $NEW_VERSION..."
sudo -u postgres "$NEW_BINDIR/pg_ctl" -D "$NEW_DATADIR" start -l /tmp/pg${NEW_VERSION}.log >/dev/null
sleep 3

PG_VERSION=$(sudo -u postgres "$NEW_BINDIR/psql" -d postgres -At -c "SHOW server_version;" 2>/dev/null)
ok "PostgreSQL $NEW_VERSION running: $PG_VERSION"
echo

# Step 7: Run analyze
info "Step 8: Running ANALYZE (background)..."
if [[ -f "$UPGRADE_DIR/analyze_new_cluster.sh" ]]; then
  sudo -u postgres bash "$UPGRADE_DIR/analyze_new_cluster.sh" >/dev/null 2>&1 &
else
  sudo -u postgres "$NEW_BINDIR/vacuumdb" --all --analyze-only >/dev/null 2>&1 &
fi
ok "ANALYZE started in background"
echo

# =========================
# SUMMARY
# =========================
echo "=========================================="
echo "✅ UPGRADE COMPLETED SUCCESSFULLY"
echo "=========================================="
echo
echo "Summary:"
echo "  Old Version : PostgreSQL $OLD_VERSION"
echo "  New Version : PostgreSQL $NEW_VERSION"
echo "  Backup      : $BACKUP_PATH"
echo "  Old Data    : $OLD_DATADIR"
echo "  New Data    : $NEW_DATADIR"
echo
echo "Next Steps:"
echo "  1. Test your applications"
echo "  2. Tune PostgreSQL 17: https://pgtune.leopard.in.ua/"
echo "  3. After testing, delete old cluster:"
echo "     cd $UPGRADE_DIR && sudo -u postgres bash delete_old_cluster.sh"
echo
echo "Rollback (if needed):"
echo "  sudo -u postgres $NEW_BINDIR/pg_ctl -D $NEW_DATADIR stop"
echo "  sudo -u postgres $OLD_BINDIR/pg_ctl -D $OLD_DATADIR start"
echo
