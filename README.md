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
      - postgres-net
      - mariadb-net

volumes:
  backup_nfs:
    driver: local
    driver_opts:
      type: nfs
      o: addr=${NFS_SERVER},${NFS_OPTIONS:-nfsvers=4,soft,rw}
      device: ":${NFS_PATH}"
```

### Running Manually

```bash
docker run -d \
  -v /opt/docker:/opt/docker:ro \
  -v /backups:/dest \
  -e PARENT_DIR=/opt/docker \
  -e DEST_DIR=/dest \
  -e BACKUP_INTERVAL_MINUTES=60 \
  ghcr.io/romkey/hackstack-db-backup:latest
```

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PARENT_DIR` | Yes | - | Directory to scan for application subdirectories |
| `DEST_DIR` | Yes | - | Destination directory for backup files |
| `BACKUP_INTERVAL_MINUTES` | No | 60 | Minutes between backup cycles |
| `SLACK_WEBHOOK_URL` | No | - | Slack webhook URL for notifications |
| `BACKUP_RETAIN_HOURLY` | No | 6 | Number of hourly backups to retain |
| `BACKUP_RETAIN_DAILY` | No | 6 | Number of daily backups to retain |
| `BACKUP_RETAIN_WEEKLY` | No | 6 | Number of weekly backups to retain |
| `BACKUP_RETAIN_MONTHLY` | No | 6 | Number of monthly backups to retain |
| `BACKUP_RETAIN_YEARLY` | No | 6 | Number of yearly backups to retain |

### NFS Volume Configuration (Docker Compose)

The example `docker-compose.example.yml` uses an NFS volume for backup storage. Configure these variables in your `.env` file:

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

Backups are deduplicated across tiers - a single backup file may satisfy multiple retention requirements.

## Backup File Format

Backup files are stored as:
```
{DEST_DIR}/{app_name}/backup-{database_name}-{YYYYMMDDHHMMSS}.{sql|snapshot}.bz2
```

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

## License

MIT
