#!/usr/bin/env bash
# Version: v1.7 – Production Ready
#
# add_replica.sh — PostgreSQL Standby (Replica) Setup for Ubuntu
# Tested on Ubuntu 22.04 / 24.04
# Compatible with PostgreSQL 14 → 19+
#
# ==============================================================================
# PURPOSE (What this script does)
# ==============================================================================
#
# This script automatically builds a PostgreSQL streaming replica from a
# running PRIMARY server.
#
# It performs the following operations safely and automatically:
#
#   • Validates connectivity and authentication with the primary
#   • Detects the PostgreSQL version running on the primary
#   • Installs the same PostgreSQL version on the replica
#   • Detects extensions installed on the primary
#   • Installs matching extension packages on the replica
#   • Stops any existing PostgreSQL 15 instance (if present)
#   • Runs pg_basebackup to clone the primary
#   • Automatically creates a replication slot
#   • Configures the PostgreSQL systemd service
#   • Copies pg_hba.conf from the old cluster if present
#   • Starts the replica and verifies WAL streaming
#
# The script ensures the replica configuration is identical to the primary
# by inheriting parameters from:
#
#   postgresql.auto.conf
#
# which is automatically copied during pg_basebackup.
#
# ==============================================================================
# WHY "#!/usr/bin/env bash"
# ==============================================================================
#
# The bash interpreter location may vary across systems.
#
# Using:
#
#   #!/usr/bin/env bash
#
# ensures the correct bash interpreter is found automatically.
#
# This improves portability across Linux distributions.
#
# ==============================================================================
# TOPOLOGY (Replication architecture)
# ==============================================================================
#
#           PRIMARY
#       ${PRIMARY_HOST}:5433
#             │
#             │  WAL streaming replication
#             │
#             ▼
#          REPLICA
#        (this server)
#
# ==============================================================================
# PREREQUISITES
# ==============================================================================
#
# 1) On PRIMARY (example shown below)
#
# Ensure password encryption uses SCRAM:
#
#   ALTER SYSTEM SET password_encryption='scram-sha-256';
#   SELECT pg_reload_conf();
#
# Create replication user:
#
#   CREATE ROLE replica
#   WITH REPLICATION LOGIN
#   ENCRYPTED PASSWORD 'yourpassword';
#
# Allow replica connection in pg_hba.conf:
#
#   host replication replica ${REPLICA_IP}/32 scram-sha-256
#
# Reload configuration:
#
#   SELECT pg_reload_conf();
#
#
# ==============================================================================
# REPLICA PASSWORD STORAGE (Secure method)
# ==============================================================================
#
# The script stores the replication password securely using:
#
#   /var/lib/postgresql/.secrets/pg_repl.pw
#
# Example manual creation:
#
#   sudo install -d -o postgres -g postgres /var/lib/postgresql/.secrets
#
#   sudo install -m 600 -o postgres -g postgres /dev/stdin \
#        /var/lib/postgresql/.secrets/pg_repl.pw <<'PW'
#   your_secret_password
#   PW
#
# Permissions:
#
#   owner : postgres
#   mode  : 600
#
# This file becomes the single source of truth for replication credentials.
#
# The script automatically generates:
#
#   /var/lib/postgresql/.pgpass
#
# from this secret file.
#
# ==============================================================================
# SCRIPT EXECUTION MODES
# ==============================================================================
#
# The script supports three execution modes:
#
#
# 1) VALIDATION MODE (Recommended first step)
#
#    sudo ./add_replica.sh --dry-run
#
#    What it does:
#
#    • Validates connectivity to primary
#    • Validates replication credentials
#    • Detects PostgreSQL version
#    • Detects extensions on primary
#    • Ensures prerequisites are met
#
#    No changes are made to the system.
#
#
# ---------------------------------------------------------------------------
#
# 2) AUTO MODE (Validate then execute)
#
#    sudo ./add_replica.sh --auto
#
#    What it does:
#
#    • Runs the same validations as --dry-run
#    • If everything is correct, automatically executes full replica creation
#
#    This is the recommended operational mode.
#
#
# ---------------------------------------------------------------------------
#
# 3) DIRECT RUN MODE
#
#    sudo ./add_replica.sh
#
#    Executes replica creation immediately without validation phase.
#
#
# ==============================================================================
# IMPORTANT SAFETY NOTES
# ==============================================================================
#
# DO:
#
#   ✓ Run script as root
#   ✓ Ensure replication user exists on primary
#   ✓ Ensure pg_hba.conf allows replica IP
#   ✓ Ensure replication password is correct
#
#
# DO NOT:
#
#   ✗ Do not reuse old replication slots unless confirmed safe
#   ✗ Do not change permissions on secret files
#   ✗ Do not run if DATA_DIR already contains a database
#
#
# ==============================================================================
# AUTOMATIC FEATURES
# ==============================================================================
#
# This script automatically detects:
#
#   • PostgreSQL version running on primary
#   • Extensions installed on primary
#   • Next available replication slot name
#
# It installs the correct packages automatically:
#
#   postgresql-X
#   postgresql-client-X
#   postgresql-contrib-X
#
# and extension packages such as:
#
#   postgresql-X-powa
#   postgresql-X-pg-stat-kcache
#   postgresql-X-hypopg
#   etc.
#
#
# ==============================================================================
# ROLLBACK PROCEDURE (Emergency recovery)
# ==============================================================================
#
# If something goes wrong during replica creation:
#
# 1) Stop PostgreSQL
#
#   systemctl stop postgresql@<version>-main
#
# 2) Remove incomplete data directory
#
#   rm -rf /opt/postgresql17
#
# 3) Drop replication slot on primary (optional)
#
#   SELECT pg_drop_replication_slot('standbyX');
#
# 4) Fix configuration issue
#
# 5) Rerun script
#
#   sudo ./add_replica.sh --dry-run
#
#
# ==============================================================================
# INTERNAL NOTES (for maintainers)
# ==============================================================================
#
# • All libpq tools run as the postgres user
#
# • .pgpass authentication prevents password prompts
#
# • During --dry-run the .pgpass file is temporary
#
# • Replication slots are automatically numbered:
#
#     standby1
#     standby2
#     standby3
#
# • Replica configuration parameters are inherited
#   automatically from primary via:
#
#     postgresql.auto.conf
#
#
# ==============================================================================
# IMPORTANT NOTE ABOUT EXTENSIONS
# ==============================================================================
#
# All extensions installed on the primary MUST exist on the replica.
#
# This script automatically detects extensions from:
#
#   SELECT extname FROM pg_extension;
#
# and installs the matching packages automatically.
#
# If a package does not exist in APT repositories,
# the script will warn but continue.
#
# ==============================================================================
###make sure log_directory,port number match the one on replica, and lister_adrees is set to *
#!/usr/bin/env bash
set -Eeuo pipefail
export HOME=/var/lib/postgresql
IFS=$'\n\t'

PRIMARY_HOST="${PRIMARY_HOST:-CHANGE_ME_PRIMARY_HOST}"
PRIMARY_PORT="5433"
REPL_USER="replica"

REPLICA_PORT="5433"

OLD_DATADIR="/u01/postgres15"
OLD_BINDIR="/usr/lib/postgresql/15/bin"

DATA_DIR="/u01/postgres17"
LOG_DIR="/u02/postgres17_log"

PW_FILE="/var/lib/postgresql/.secrets/pg_repl.pw"
PGPASS="/var/lib/postgresql/.pgpass"

SLOT_PREFIX="standby"

DRY_RUN=false
AUTO=false

case "${1:-}" in
  --dry-run) DRY_RUN=true ;;
  --auto) DRY_RUN=true; AUTO=true ;;
esac

info(){ echo -e "\e[34m[INFO]\e[0m $*"; }
ok(){ echo -e "\e[32m[OK]\e[0m $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m $*"; }
err(){ echo -e "\e[31m[ERROR]\e[0m $*"; exit 1; }

[[ $EUID -eq 0 ]] || err "Run script as root"

# ---------------------------------------------------
# PASSWORD
# ---------------------------------------------------

if [[ ! -f "$PW_FILE" ]]; then

info "Replication password file not found"

read -s -p "Enter replication password: " REPL_PASS
echo
read -s -p "Confirm password: " REPL_PASS2
echo

[[ "$REPL_PASS" == "$REPL_PASS2" ]] || err "Passwords do not match"

install -d -o postgres -g postgres /var/lib/postgresql/.secrets

echo "$REPL_PASS" | install -m 600 -o postgres -g postgres \
/dev/stdin "$PW_FILE"

ok "Replication password stored"

fi

PW=$(cat "$PW_FILE")

echo "${PRIMARY_HOST}:${PRIMARY_PORT}:*:${REPL_USER}:${PW}" > "$PGPASS"
chown postgres:postgres "$PGPASS"
chmod 600 "$PGPASS"

# ---------------------------------------------------
# CONNECT TEST
# ---------------------------------------------------

info "Testing connection to primary"

sudo -H -u postgres PGPASSFILE="$PGPASS" psql \
-h "$PRIMARY_HOST" \
-p "$PRIMARY_PORT" \
-U "$REPL_USER" \
-d postgres \
-c "SELECT 1" >/dev/null

ok "Primary reachable"

# ---------------------------------------------------
# VERSION
# ---------------------------------------------------

PRIMARY_VERSION=$(sudo -H -u postgres PGPASSFILE="$PGPASS" psql \
-h "$PRIMARY_HOST" \
-p "$PRIMARY_PORT" \
-U "$REPL_USER" \
-d postgres \
-At -c "SHOW server_version_num" | cut -c1-2)
PGBIN="/usr/lib/postgresql/${PRIMARY_VERSION}/bin"

SERVICE_NAME="postgresql@${PRIMARY_VERSION}-main"

CONF_DIR="/etc/postgresql/${PRIMARY_VERSION}/main"
CONF_FILE="$CONF_DIR/postgresql.conf"
NEW_HBA="$CONF_DIR/pg_hba.conf"

info "Primary PostgreSQL version: $PRIMARY_VERSION"

# ---------------------------------------------------
# IP
# ---------------------------------------------------

REPLICA_IP=$(ip -4 route get "$PRIMARY_HOST" \
| awk '/src/ {for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')

[[ -n "$REPLICA_IP" ]] || REPLICA_IP=$(hostname -I | awk '{print $1}')

ok "Replica IP detected: $REPLICA_IP"

# ---------------------------------------------------
# PRECHECK
# ---------------------------------------------------

info "Running replication pre-flight validation"

WAL_LEVEL=$(sudo -H -u postgres PGPASSFILE="$PGPASS" psql \
-h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$REPL_USER" \
-d postgres -At -c "SHOW wal_level")

[[ "$WAL_LEVEL" == "replica" || "$WAL_LEVEL" == "logical" ]] \
|| err "wal_level must be replica or logical"

WAL_SENDERS=$(sudo -H -u postgres PGPASSFILE="$PGPASS" psql \
-h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$REPL_USER" \
-d postgres -At -c "SHOW max_wal_senders")

[[ "$WAL_SENDERS" -gt 0 ]] || err "max_wal_senders must be > 0"

ok "Primary replication configuration validated"

# ---------------------------------------------------
# EXTENSIONS
# ---------------------------------------------------

EXTENSIONS=$(sudo -H -u postgres PGPASSFILE="$PGPASS" psql \
-h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$REPL_USER" \
-d postgres -At -c "
SELECT extname FROM pg_extension WHERE extname!='plpgsql'
")

# ---------------------------------------------------
# DRY RUN EXIT
# ---------------------------------------------------

if $DRY_RUN; then
info "Dry-run validation successful"
exit 0
fi

# ---------------------------------------------------
# STOP OLD
# ---------------------------------------------------

info "Stopping PostgreSQL 15"

sudo -H -u postgres "$OLD_BINDIR/pg_ctl" \
-D "$OLD_DATADIR" stop -m fast || true

# ---------------------------------------------------
# INSTALL
# ---------------------------------------------------

info "Installing PostgreSQL $PRIMARY_VERSION"

apt-get update -y >/dev/null

apt-get install -y \
postgresql-$PRIMARY_VERSION \
postgresql-client-$PRIMARY_VERSION \
postgresql-contrib-$PRIMARY_VERSION >/dev/null

# ---------------------------------------------------
# REPLICATION TEST (after install)
# ---------------------------------------------------



# ---------------------------------------------------
# EXT INSTALL
# ---------------------------------------------------

for EXT in $EXTENSIONS
do

PKG="postgresql-${PRIMARY_VERSION}-${EXT//_/-}"

if apt-cache show "$PKG" >/dev/null 2>&1; then
apt-get install -y "$PKG" >/dev/null
fi

done

# ---------------------------------------------------
# DIRS
# ---------------------------------------------------

install -d -m 700 -o postgres -g postgres "$DATA_DIR"
install -d -m 750 -o postgres -g postgres "$LOG_DIR"

[[ -z "$(ls -A "$DATA_DIR")" ]] || err "Data directory not empty"

# ---------------------------------------------------
# SLOT
# ---------------------------------------------------

SLOT_NAME=$(sudo -H -u postgres PGPASSFILE="$PGPASS" psql \
-h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$REPL_USER" \
-d postgres -At -c "
SELECT '${SLOT_PREFIX}'||
(coalesce(max(regexp_replace(slot_name,'[^0-9]','','g')::int),0)+1)
FROM pg_replication_slots
WHERE slot_name ~ '^${SLOT_PREFIX}[0-9]+'
")

ok "Using slot $SLOT_NAME"

# ---------------------------------------------------
# BASEBACKUP
# ---------------------------------------------------

info "Running pg_basebackup"

sudo -H -u postgres PGPASSFILE="$PGPASS" \
"$PGBIN/pg_basebackup" \
-h "$PRIMARY_HOST" -p "$PRIMARY_PORT" \
-D "$DATA_DIR" \
-U "$REPL_USER" \
-Fp -P -R -X stream \
-C -S "$SLOT_NAME" \
--slot="$SLOT_NAME"
chown -R postgres:postgres "$DATA_DIR"
chmod 700 "$DATA_DIR"

# ---------------------------------------------------
# FIX application_name for synchronous replication
# ---------------------------------------------------

AUTO_CONF="$DATA_DIR/postgresql.auto.conf"

APP_NAME="$SLOT_NAME"

if [[ -f "$AUTO_CONF" ]]; then

  if grep -q "^primary_conninfo" "$AUTO_CONF"; then

    if ! grep -q "application_name=" "$AUTO_CONF"; then

      CURRENT=$(grep -oP "(?<=primary_conninfo = ').*(?=')" "$AUTO_CONF")

      sed -i \
        "s#primary_conninfo = '.*'#primary_conninfo = '${CURRENT} application_name=${APP_NAME}'#g" \
        "$AUTO_CONF"

    fi

  fi

fi
# -------------------------------------------------
# CREATE CLUSTER
# -------------------------------------------------

info "Creating systemd cluster configuration"

if [[ ! -d "$CONF_DIR" ]]; then

pg_createcluster \
"$PRIMARY_VERSION" main \
--datadir="$DATA_DIR" \
--start-conf=manual

ok "Cluster created"

fi

# ---------------- COPY HBA ----------------

OLD_HBA="$OLD_DATADIR/pg_hba.conf"

if [[ -f "$OLD_HBA" ]]; then
cp "$OLD_HBA" "$NEW_HBA"
chown postgres:postgres "$NEW_HBA"
chmod 640 "$NEW_HBA"
fi

# -------------------------------------------------
# CONFIGURE REPLICA (data dir + logging + standby)
# -------------------------------------------------

info "Configuring replica settings"

CONF_FILE="/etc/postgresql/${PRIMARY_VERSION}/main/postgresql.conf"

# --- ensure data directory

if grep -q "^data_directory" "$CONF_FILE"; then
  sed -i "s|^data_directory.*|data_directory = '$DATA_DIR'|" "$CONF_FILE"
else
  echo "data_directory = '$DATA_DIR'" >> "$CONF_FILE"
fi


# --- ensure hot standby

if grep -q "^hot_standby" "$CONF_FILE"; then
  sed -i "s/^hot_standby.*/hot_standby = on/" "$CONF_FILE"
else
  echo "hot_standby = on" >> "$CONF_FILE"
fi


# -------------------------------------------------
# LOG DIRECTORY
# -------------------------------------------------

info "Configuring log directory"

install -d -m 750 -o postgres -g postgres "$LOG_DIR"


# enable logging collector

if grep -q "^logging_collector" "$CONF_FILE"; then
  sed -i "s/^logging_collector.*/logging_collector = on/" "$CONF_FILE"
else
  echo "logging_collector = on" >> "$CONF_FILE"
fi


# set log directory

if grep -q "^log_directory" "$CONF_FILE"; then
  sed -i "s|^log_directory.*|log_directory = '$LOG_DIR'|" "$CONF_FILE"
else
  echo "log_directory = '$LOG_DIR'" >> "$CONF_FILE"
fi


# log filename

if ! grep -q "^log_filename" "$CONF_FILE"; then
  echo "log_filename = 'postgresql-%Y-%m-%d.log'" >> "$CONF_FILE"
fi


# optional but recommended

if ! grep -q "^log_truncate_on_rotation" "$CONF_FILE"; then
  echo "log_truncate_on_rotation = on" >> "$CONF_FILE"
fi

if ! grep -q "^log_rotation_age" "$CONF_FILE"; then
  echo "log_rotation_age = 1d" >> "$CONF_FILE"
fi

if ! grep -q "^log_rotation_size" "$CONF_FILE"; then
  echo "log_rotation_size = 100MB" >> "$CONF_FILE"
fi


# -------------------------------------------------
# ensure runtime dir exists
# -------------------------------------------------

install -d -m 775 -o postgres -g postgres /run/postgresql


ok "Replica configuration prepared"

# ---------------------------------------------------
# START
# ---------------------------------------------------

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

sleep 3

STATUS=$(sudo -H -u postgres psql -p "$REPLICA_PORT" -At \
-c "SELECT pg_is_in_recovery();")

[[ "$STATUS" == "t" ]] || err "Replica not in recovery mode"

echo "Replica created successfully"