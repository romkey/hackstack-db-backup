# db-backup

A Ruby-based database backup utility designed for Docker-based multi-application environments. Automatically discovers and backs up databases from application directories, with tiered retention policies for efficient storage management.

## Features

- **Multi-database support**: PostgreSQL, MySQL/MariaDB, SQLite, and Redis
- **Automatic discovery**: Scans directories for `.env` files with database URLs
- **Parallel backups**: Uses forking for concurrent backup operations
- **Compression**: Automatic bzip2 compression of backup files
- **Tiered retention**: Configurable retention for hourly, daily, weekly, monthly, and yearly backups
- **Slack notifications**: Optional webhook notifications for backup status
- **Docker-ready**: Alpine-based minimal container image

## Quick Start

### Using Docker Compose

```yaml
services:
  dbbackup:
    image: ghcr.io/romkey/hackstack-db-backup:latest
    volumes:
      - /opt/docker:/opt/docker:ro    # Application directories
      - /backups/databases:/dest       # Backup destination
    environment:
      - PARENT_DIR=/opt/docker
      - DEST_DIR=/dest
      - SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}
    networks:
      - postgres-net
      - mariadb-net
      - redis-net
```

### Running Manually

```bash
docker run --rm \
  -v /opt/docker:/opt/docker:ro \
  -v /backups:/dest \
  -e PARENT_DIR=/opt/docker \
  -e DEST_DIR=/dest \
  ghcr.io/romkey/hackstack-db-backup:latest
```

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PARENT_DIR` | Yes | - | Directory to scan for application subdirectories |
| `DEST_DIR` | Yes | - | Destination directory for backup files |
| `SLACK_WEBHOOK_URL` | No | - | Slack webhook URL for notifications |
| `BACKUP_RETAIN_HOURLY` | No | 6 | Number of hourly backups to retain |
| `BACKUP_RETAIN_DAILY` | No | 6 | Number of daily backups to retain |
| `BACKUP_RETAIN_WEEKLY` | No | 6 | Number of weekly backups to retain |
| `BACKUP_RETAIN_MONTHLY` | No | 6 | Number of monthly backups to retain |
| `BACKUP_RETAIN_YEARLY` | No | 6 | Number of yearly backups to retain |

### Application Configuration

Each application directory under `PARENT_DIR` should contain a `.env` file with:

```bash
BACKUP_DATABASE_URLS="postgresql://user:pass@host:5432/dbname,mysql://user:pass@host:3306/dbname"
```

Multiple database URLs can be specified as a comma-separated list.

### Supported Database URL Formats

- **PostgreSQL**: `postgresql://user:password@host:port/database`
- **MySQL/MariaDB**: `mysql://user:password@host:port/database`
- **SQLite**: `sqlite:///path/to/database.db`
- **Redis**: `redis://:password@host:port/db` or `redis://user:password@host:port/db`

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
{DEST_DIR}/{app_name}/backup-{database_name}-{YYYYMMDDHHMMSS}.{sql|rdb}.bz2
```

## Command Line Options

| Option | Description |
|--------|-------------|
| `--quiet` | Suppress all output (useful for cron jobs) |

## Scheduling

For automated backups, use cron or a container orchestrator's scheduling feature:

```bash
# Run hourly backups via cron
0 * * * * docker run --rm -v /opt:/opt:ro -v /backups:/dest -e PARENT_DIR=/opt/docker -e DEST_DIR=/dest --quiet ghcr.io/romkey/hackstack-db-backup:latest --quiet
```

## Development

### Building Locally

```bash
docker build -t db-backup .
```

### Running Tests

```bash
docker run --rm db-backup --quiet
```

## License

MIT
