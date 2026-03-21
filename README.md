# db-backup

A Ruby-based database backup utility designed for Docker-based multi-application environments. Runs continuously, automatically discovering and backing up databases from application directories at configurable intervals, with tiered retention policies for efficient storage management.

## Features

- **Continuous operation**: Runs as a long-lived service with configurable backup intervals
- **Multi-database support**: PostgreSQL, MySQL/MariaDB, SQLite, and Qdrant
- **Automatic discovery**: Scans directories for `.env` files with database URLs
- **Parallel backups**: Uses forking for concurrent backup operations
- **Compression**: Automatic bzip2 compression of backup files
- **Tiered retention**: Configurable retention for hourly, daily, weekly, monthly, and yearly backups
- **Slack notifications**: Optional webhook notifications for backup status
- **Docker-ready**: Alpine-based minimal container image

## Quick Start

### Using Docker Compose

Copy the included `docker-compose.example.yml` to `docker-compose.yml` and customize for your environment. The example supports NFS storage for backups:

```yaml
services:
  dbbackup:
    image: ghcr.io/romkey/hackstack-db-backup:latest
    restart: unless-stopped
    volumes:
      - /opt:/opt:ro
      - backup_nfs:/dest
    env_file:
      - .env
    networks:
      - backup-net

volumes:
  backup_nfs:
    driver: local
    driver_opts:
      type: nfs
      o: addr=${NFS_SERVER},${NFS_OPTIONS:-nfsvers=4,soft,rw}
      device: ":${NFS_PATH}"

networks:
  backup-net:
    name: dbbackup-net
```

### Network Configuration

The recommended approach is to create a single backup network (`dbbackup-net`) and add each database container to it. This allows db-backup to work in environments that don't run all supported database types.

In each database's compose file, add the backup network:

```yaml
services:
  postgres:
    # ... other config ...
    networks:
      - default
      - backup-net

networks:
  backup-net:
    external: true
    name: dbbackup-net
```

### Running Manually

```bash
docker run -d \
  -v /opt:/opt:ro \
  -v /backups:/dest \
  -e SOURCE_DIRECTORIES=apps,docker \
  -e DEST_DIR=/dest \
  -e BACKUP_INTERVAL_MINUTES=60 \
  ghcr.io/romkey/hackstack-db-backup:latest
```

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SOURCE_DIRECTORIES` | Yes | - | Comma-separated list of directories to scan (under PARENT_DIR) |
| `PARENT_DIR` | No | `/opt` | Base directory for SOURCE_DIRECTORIES |
| `DEST_DIR` | Yes | - | Destination directory for backup files |
| `BACKUP_INTERVAL_MINUTES` | No | 60 | Minutes between backup cycles |
| `SLACK_WEBHOOK_URL` | No | - | Slack webhook URL for notifications |
| `PG_GLOBALS_URL` | No | - | PostgreSQL superuser URL for pg_dumpall (see below) |
| `BACKUP_RETAIN_HOURLY` | No | 6 | Number of hourly backups to retain |
| `BACKUP_RETAIN_DAILY` | No | 6 | Number of daily backups to retain |
| `BACKUP_RETAIN_WEEKLY` | No | 6 | Number of weekly backups to retain |
| `BACKUP_RETAIN_MONTHLY` | No | 6 | Number of monthly backups to retain |
| `BACKUP_RETAIN_YEARLY` | No | 6 | Number of yearly backups to retain |
| `DEBUG` | No | - | Set to `1` for verbose debug logging |

### Source Directory Scanning

db-backup scans for application `.env` files in subdirectories of each source directory. For example:

```bash
SOURCE_DIRECTORIES=apps,experiments
PARENT_DIR=/opt  # optional, defaults to /opt
```

This configuration scans:
- `/opt/apps/*/.env`
- `/opt/experiments/*/.env`

Each subdirectory containing a `.env` file with `BACKUP_DATABASE_URLS` will have its databases backed up.

### NFS Volume Configuration

The example compose file uses an NFS volume for backup storage. Configure these variables in your `.env` file:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `NFS_SERVER` | Yes | - | NFS server IP address or hostname |
| `NFS_PATH` | Yes | - | Export path on the NFS server |
| `NFS_OPTIONS` | No | `nfsvers=4,soft,rw` | NFS mount options |

Example:
```bash
NFS_SERVER=192.168.1.100
NFS_PATH=/volume1/backups/databases
NFS_OPTIONS=nfsvers=4,soft,rw
```

### Application Configuration

Each application directory under `PARENT_DIR` should contain a `.env` file with:

```bash
BACKUP_DATABASE_URLS="postgresql://user:pass@host:5432/dbname,mysql://user:pass@host:3306/dbname"
```

Multiple database URLs can be specified as a comma-separated list.

Example with all supported databases:
```bash
BACKUP_DATABASE_URLS="postgresql://user:pass@postgres:5432/mydb,mysql://user:pass@mysql:3306/mydb,qdrant://api-key@qdrant:6333/embeddings"
```

### Supported Database URL Formats

- **PostgreSQL**: `postgresql://user:password@host:port/database`
- **MySQL/MariaDB**: `mysql://user:password@host:port/database`
- **SQLite**: `sqlite:///path/to/database.db`
- **Qdrant**: `qdrant://host:port/collection` or `qdrant://api_key@host:port/collection`

**Note:** If your password contains `@`, URL-encode it as `%40` (e.g., `p%40ssword` for `p@ssword`).

#### Qdrant Notes

Qdrant backups use the [snapshot API](https://qdrant.tech/documentation/concepts/snapshots/) to create point-in-time backups of collections. The backup process:

1. Creates a snapshot on the Qdrant server
2. Downloads the snapshot file (tar archive)
3. Compresses it with bzip2
4. Deletes the remote snapshot to free server storage

For authenticated Qdrant instances, include the API key before the host in the URL.

#### PostgreSQL Global Objects

When backing up PostgreSQL databases, db-backup automatically runs `pg_dumpall --globals-only` to capture roles, tablespaces, and other global objects needed for proper database restoration. These backups are stored in a `postgresql` subdirectory under `DEST_DIR`:

```
{DEST_DIR}/postgresql/backup-globals-{host}-{port}-{YYYYMMDDHHMMSS}.sql.bz2
```

This runs once per unique PostgreSQL server after all database backups complete.

**Superuser Required:** The `pg_dumpall --globals-only` command requires PostgreSQL superuser privileges to read role definitions from `pg_authid`. If the configured user lacks these privileges, the globals backup is silently skipped with a warning (individual database backups still proceed normally).

**Configuring the superuser account:**

1. Create a dedicated backup superuser in PostgreSQL:

```sql
CREATE ROLE backup_admin WITH LOGIN PASSWORD 'your-secure-password' SUPERUSER;
```

2. Set the `PG_GLOBALS_URL` environment variable:

```bash
PG_GLOBALS_URL=postgresql://backup_admin:your-secure-password@postgres:5432/postgres
```

If `PG_GLOBALS_URL` is not set, db-backup falls back to using credentials from the first PostgreSQL database URL found in your backup configuration (which typically won't have superuser privileges).

If you cannot use a superuser account, the globals backup will be skipped but all database backups will continue to work normally.

## Tiered Retention

The backup system maintains backups across multiple time tiers to balance storage efficiency with recovery options:

- **Hourly**: Keeps the most recent backup for each of the last N hours
- **Daily**: Keeps the most recent backup for each of the last N days
- **Weekly**: Keeps the most recent backup for each of the last N weeks (ISO weeks)
- **Monthly**: Keeps the most recent backup for each of the last N months
- **Yearly**: Keeps the most recent backup for each of the last N years

Each tier defaults to 6 backups. With default settings, you maintain:
- Fine-grained recovery options for recent hours
- Daily recovery points for the past week
- Weekly recovery points for over a month
- Monthly recovery points for half a year
- Yearly recovery points for long-term archives

## Backup Directory Structure

Backups are organized into tier-specific subdirectories for clarity:

```
{DEST_DIR}/{app_name}/
├── hourly/
│   └── backup-{database_name}-{YYYYMMDDHHMMSS}.{sql|snapshot}.bz2
├── daily/
│   └── ...
├── weekly/
│   └── ...
├── monthly/
│   └── ...
└── yearly/
    └── ...
```

When a backup is created, it is copied to each tier directory where it qualifies as the representative backup for that time bucket. For example, a new backup might be copied to hourly/, daily/, and monthly/ if it's the newest backup for the current hour, day, and month.

### How Time Buckets Work

Each tier uses a different time granularity to determine which "bucket" a backup belongs to:

| Tier | Bucket Key Format | Example |
|------|-------------------|---------|
| hourly | YYYY-MM-DD-HH | 2024-01-15-14 (2pm on Jan 15) |
| daily | YYYY-MM-DD | 2024-01-15 |
| weekly | YYYY-WW (ISO week) | 2024-03 (week 3 of 2024) |
| monthly | YYYY-MM | 2024-01 |
| yearly | YYYY | 2024 |

When a new backup is created:
1. Its timestamp is used to calculate the bucket key for each tier
2. If no backup exists in a tier for that bucket, the new backup is copied there
3. If a backup already exists for that bucket, the tier is skipped

This means a single backup run can populate multiple tiers simultaneously (a backup at 2pm on January 15, 2024 would be the first backup for that hour, that day, possibly that week, etc.).

| Database | Extension |
|----------|-----------|
| PostgreSQL | `.sql.bz2` |
| MySQL/MariaDB | `.sql.bz2` |
| SQLite | `.sql.bz2` |
| Qdrant | `.snapshot.bz2` |

## Command Line Options

| Option | Description |
|--------|-------------|
| `--quiet` | Suppress all output except errors |

## Development

### Building Locally

```bash
docker build -t db-backup .
```

### Running in Foreground

```bash
docker run --rm \
  -e PARENT_DIR=/opt/docker \
  -e DEST_DIR=/dest \
  -e BACKUP_INTERVAL_MINUTES=5 \
  -v /opt/docker:/opt/docker:ro \
  -v /backups:/dest \
  db-backup
```

### Running Tests

Tests use RSpec with WebMock for HTTP mocking, Timecop for time manipulation, and FakeFS for filesystem mocking.

**Using Docker (recommended):**

```bash
docker compose -f docker-compose.test.yml up --build
```

**Using local Ruby:**

```bash
bundle install
bundle exec rspec
```

**Run with verbose output:**

```bash
bundle exec rspec --format documentation
```

### Project Files

| File | Description |
|------|-------------|
| `docker-compose.example.yml` | Example production compose file with NFS storage |
| `docker-compose.test.yml` | Compose file for running tests in Docker |
| `Dockerfile` | Production container image |
| `Dockerfile.test` | Test container image with dev dependencies |

## Troubleshooting

### Enable Debug Mode

Set `DEBUG=1` in your environment for verbose logging that shows:
- All directories being scanned for `.env` files
- All `BACKUP_DATABASE_URLS` found (passwords masked)
- Backup file creation and compression
- Tier distribution decisions (which buckets, why files are copied or skipped)
- Glob patterns used to find backup files

```bash
DEBUG=1
```

### Backups Not Appearing in Tier Directories

If backups are created but not appearing in hourly/, daily/, etc. directories:

1. **Enable debug mode** to see the distribution process
2. **Check the glob pattern match**: Debug output shows the exact pattern used
3. **Verify file exists before distribution**: The backup must complete before distribution runs
4. **Check filename format**: Must match `backup-{name}-{YYYYMMDDHHMMSS}.{sql|snapshot}.bz2`

### SQLite Permission Denied

If SQLite backups fail with permission errors:

1. Set `BACKUP_UID` and `BACKUP_GID` to match the file owner
2. Or run as root with `BACKUP_UID=0` and `BACKUP_GID=0` (default)

### PostgreSQL Globals Not Backing Up

The `pg_dumpall --globals-only` command requires superuser privileges. Either:

1. Set `PG_GLOBALS_URL` to a superuser connection string
2. Or accept that globals backup will be skipped (database backups still work)

## License

MIT
