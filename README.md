# PostgreSQL Upgrade Toolkit

Automated and documented **PostgreSQL major version upgrades** (15 → 17), including `pg_upgrade`, post-upgrade validation, replica re-attachment, and pre-upgrade checklists.

**Author:** [Achille Cesar Ntwali](https://github.com/achille250) · Kigali, Rwanda

---

## Overview

Production-grade upgrade path using **COPY mode** `pg_upgrade` (not `--link`), tuned parameter migration, WAL/archive directory setup, and safety guards. Test fully on UAT before production.

Supported target versions in scripts: **PostgreSQL 15 → 17** (patterns adaptable for 14–16).

---

## Repository structure

```
postgresql-upgrade-toolkit/
├── scripts/
│   ├── 1.POSTGRES_UPGRADE_15_T0_17_final.sh   # Full automated upgrade (root)
│   ├── 2.post_upgrade_pg17.sh                 # Post-upgrade checks & housekeeping
│   ├── 3.add_replica.sh                       # Re-attach replica after upgrade
│   ├── upgrade_pg15_to_pg17.sh                # Alternate upgrade script
│   └── upgrade_pg15_to_pg17_simple.sh         # Simplified upgrade flow
└── runbooks/
    ├── pre-upgrade-checklist-pg15-to-pg17.txt
    ├── POSTGRES UPGRADE 15 T0 17 V2.txt
    └── PostgreSQL 15 → PostgreSQL 17 Upgrade.txt
```

---

## Recommended upgrade flow

| Step | Action |
|------|--------|
| 1 | Complete `runbooks/pre-upgrade-checklist-pg15-to-pg17.txt` |
| 2 | Full backup + verify restore procedure |
| 3 | Run `scripts/1.POSTGRES_UPGRADE_15_T0_17_final.sh` on UAT |
| 4 | Run `scripts/2.post_upgrade_pg17.sh` |
| 5 | Rebuild replicas: `scripts/3.add_replica.sh` or [HA repo](https://github.com/achille250/postgresql-ha-replication) |
| 6 | `ANALYZE` / `VACUUM FREEZE` as documented in script output |

```bash
chmod +x scripts/1.POSTGRES_UPGRADE_15_T0_17_final.sh
sudo ./scripts/1.POSTGRES_UPGRADE_15_T0_17_final.sh
```

**Edit configuration block** at top of each script: `OLD_DATADIR`, `NEW_DATADIR`, `PG_PORT`, paths.

---

## Safety notes

- Scripts **block** `pg_upgrade --link` in production configuration
- Requires root (systemd, package install, directory creation)
- Ensure internet access for PostgreSQL 17 package install (Ubuntu)
- Plan maintenance window and application downtime

---

## Related repositories

| Repo | Focus |
|------|--------|
| [postgresql-ha-replication](https://github.com/achille250/postgresql-ha-replication) | Replica setup & failover |
| [postgresql-data-migration](https://github.com/achille250/postgresql-data-migration) | Data migration after upgrade |
| [postgresql-performance-tuning](https://github.com/achille250/postgresql-performance-tuning) | Post-upgrade tuning |