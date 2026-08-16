# db-backup

[![CI](https://github.com/romkey/hackstack-db-backup/actions/workflows/ci.yml/badge.svg)](https://github.com/romkey/hackstack-db-backup/actions/workflows/ci.yml)
[![Lint](https://img.shields.io/github/actions/workflow/status/romkey/hackstack-db-backup/ci.yml?branch=main&label=lint&logo=rubocop&logoColor=white)](https://github.com/romkey/hackstack-db-backup/actions/workflows/ci.yml)
[![Docker](https://img.shields.io/github/actions/workflow/status/romkey/hackstack-db-backup/ci.yml?branch=main&label=docker&logo=docker&logoColor=white)](https://github.com/romkey/hackstack-db-backup/pkgs/container/hackstack-db-backup)
[![Ruby](https://img.shields.io/badge/Ruby-3.4-red?logo=ruby&logoColor=white)](.ruby-version)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Ruby-based database backup utility designed for Docker-based multi-application environments. Runs continuously, automatically discovering and backing up databases from application directories at configurable intervals, with tiered retention policies for efficient storage management.

## Features

- **Continuous operation**: Runs as a long-lived service with configurable backup intervals
- **Multi-database support**: PostgreSQL, MySQL/MariaDB, SQLite, and Qdrant
- **Automatic discovery**: Scans directories for `.env` files with database URLs
- **Parallel backups**: Uses forking for concurrent backup operations
- **Compression**: Automatic bzip2 compression of backup files
- **Optional encryption**: Public-key encryption at rest using [age](https://github.com/FiloSottile/age)
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
| `BACKUP_ENCRYPTION_RECIPIENTS` | No | - | Comma-separated age public keys. Setting this enables encryption (see below) |
| `BACKUP_ENCRYPTION_RECIPIENTS_FILE` | No | - | Path to a file with one age public key per line |
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

### Supported Database URL Formats

| Database | URL Format | Notes |
|----------|------------|-------|
| PostgreSQL | `postgresql://user:pass@host/dbname` | Port optional (default: 5432). Also accepts `postgres://` |
| MySQL/MariaDB | `mysql://user:pass@host/dbname` | Port optional (default: 3306). Also accepts `mysql2://` |
| SQLite | `sqlite:///path/to/database.db` | Absolute path required |
| Qdrant | `qdrant://apikey@host:6333/collection` | API key optional |

**Note**: If your password contains special characters like `@`, URL-encode them (e.g., `@` becomes `%40`).

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

## Encryption

Backups can be encrypted at rest with [age](https://github.com/FiloSottile/age). Encryption is **optional and disabled by default** - without `BACKUP_ENCRYPTION_RECIPIENTS` or `BACKUP_ENCRYPTION_RECIPIENTS_FILE`, db-backup behaves exactly as before.

Encryption is **asymmetric**. You configure db-backup with one or more *public keys* (recipients); the matching *private key* (identity) is never needed to make a backup and should never be stored on the backup server. Someone who compromises the backup host gets ciphertext and nothing else.

Encrypted backups gain an `.age` suffix:

```
backup-mydb-20240115143022.sql.bz2.age
```

> **Warning:** the identity file is the only way to read these backups. If you lose it, every encrypted backup is permanently unrecoverable. Store it offline, and keep more than one copy.

### 1. Generate a key pair

Run this somewhere other than the backup server - your workstation, ideally:

```bash
docker run --rm -v "$PWD:/out" --entrypoint ruby \
  ghcr.io/romkey/hackstack-db-backup:latest \
  /app/backup-crypt.rb keygen -o /out/backup-identity.key
```

Or with age installed locally (`apk add age`, `brew install age`, `apt install age`):

```bash
age-keygen -o backup-identity.key
```

Either prints the public key:

```
Public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

Move `backup-identity.key` somewhere safe and offline (password manager, hardware token, printed copy in a safe). Do not leave it on the machine running db-backup.

### 2. Enable encryption

Add the **public** key to the db-backup environment:

```bash
BACKUP_ENCRYPTION_RECIPIENTS=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

List several recipients (comma-separated) so more than one person can restore:

```bash
BACKUP_ENCRYPTION_RECIPIENTS=age1ql3z...,age1lggy...
```

For a longer list, or to use Docker secrets, point at a file with one recipient per line (`#` comments allowed):

```yaml
services:
  dbbackup:
    environment:
      BACKUP_ENCRYPTION_RECIPIENTS_FILE: /run/secrets/age-recipients
    secrets:
      - age-recipients

secrets:
  age-recipients:
    file: ./age-recipients.txt
```

Both variables can be used together; the lists are merged and deduplicated. SSH public keys (`ssh-ed25519 ...`, `ssh-rsa ...`) are also accepted as recipients.

Recipients are validated at startup. A malformed key or an unreadable recipients file makes db-backup exit immediately rather than quietly producing backups you cannot decrypt.

### 3. Verify before you rely on it

Let one backup cycle run, then confirm you can actually read the result **before** encrypting your existing archive:

```bash
docker run --rm -v /backups:/dest -v "$PWD:/keys:ro" --entrypoint ruby \
  ghcr.io/romkey/hackstack-db-backup:latest \
  /app/backup-crypt.rb decrypt -i /keys/backup-identity.key --stdout \
  /dest/myapp/hourly/backup-mydb-20240115143022.sql.bz2.age | bunzip2 -c | head
```

### Encrypting existing backups

`backup-crypt.rb encrypt` walks a directory tree and replaces each unencrypted `.bz2` backup with an encrypted `.bz2.age` one. It skips files that are already encrypted, so it is safe to re-run.

Always preview with `--dry-run` first:

```bash
docker run --rm -v /backups:/dest --entrypoint ruby \
  ghcr.io/romkey/hackstack-db-backup:latest \
  /app/backup-crypt.rb encrypt -r age1ql3z... --dry-run /dest
```

Then run it for real:

```bash
docker run --rm -v /backups:/dest --entrypoint ruby \
  ghcr.io/romkey/hackstack-db-backup:latest \
  /app/backup-crypt.rb encrypt -r age1ql3z... /dest
```

Each file is encrypted to a temporary `.part` file, verified, moved into place, and only then is the plaintext deleted. If age fails, the original is left untouched.

With no path arguments, `encrypt` operates on `DEST_DIR`. With no `-r`/`-R`, it falls back to `BACKUP_ENCRYPTION_RECIPIENTS`.

### Decrypting and restoring

Decryption needs the identity file, so run it on a trusted machine.

Decrypt in place (produces a `.bz2` next to the `.age` file):

```bash
ruby /app/backup-crypt.rb decrypt -i backup-identity.key \
  /backups/myapp/daily/backup-mydb-20240115143022.sql.bz2.age
```

Or stream straight into a restore, without the plaintext ever touching disk:

```bash
# PostgreSQL (dumps are pg_dump custom format, so use pg_restore)
ruby /app/backup-crypt.rb decrypt -i backup-identity.key --stdout \
  backup-mydb-20240115143022.sql.bz2.age \
  | bunzip2 -c | pg_restore -h postgres -U user -d mydb

# MySQL/MariaDB
ruby /app/backup-crypt.rb decrypt -i backup-identity.key --stdout \
  backup-mydb-20240115143022.sql.bz2.age \
  | bunzip2 -c | mysql -h mysql -u user -p mydb

# SQLite
ruby /app/backup-crypt.rb decrypt -i backup-identity.key --stdout \
  backup-mydb-20240115143022.sql.bz2.age \
  | bunzip2 -c | sqlite3 restored.db
```

Plain age works too, if you would rather not use the wrapper:

```bash
age -d -i backup-identity.key backup-mydb-20240115143022.sql.bz2.age | bunzip2 -c
```

### backup-crypt.rb reference

```
Usage: backup-crypt.rb <command> [options] [paths...]
```

| Command | Options | Description |
|---------|---------|-------------|
| `keygen` | `-o, --out PATH`<br>`-f, --force` | Generate an identity and print its public key. Writes the key with mode 0600 |
| `encrypt` | `-r, --recipient KEY`<br>`-R, --recipients-file FILE`<br>`-n, --dry-run` | Encrypt `.bz2` backups in place. `-r` may be repeated |
| `decrypt` | `-i, --identity FILE`<br>`-c, --stdout`<br>`-f, --force`<br>`-n, --dry-run` | Decrypt `.bz2.age` backups. `--identity` is required |

Paths may be individual files or directories (searched recursively). If omitted, `DEST_DIR` is used.

### Mixed archives

Encrypted and unencrypted backups coexist safely. Tier distribution and retention recognise both `.bz2` and `.bz2.age`, so you can enable encryption and migrate the existing archive whenever convenient - retention keeps pruning correctly in the meantime.

### Failure behaviour

If encryption is configured but fails - age missing, an invalid recipient, a full disk - db-backup **fails the backup rather than falling back to writing plaintext**. The partial output and the plaintext dump are both deleted, the failure is logged, and it is reported to Slack if a webhook is configured. A missing backup is a much smaller problem than an unencrypted one you believed was encrypted, so watch for these failures.

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

When encryption is enabled, each of these gains an `.age` suffix (for example `.sql.bz2.age`).

## Command Line Options

| Option | Description |
|--------|-------------|
| `--quiet` | Suppress all output except errors |

See [backup-crypt.rb reference](#backup-cryptrb-reference) for the encryption utility.

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

Requires Ruby 3.4 (see `.ruby-version`). With [rbenv](https://github.com/rbenv/rbenv) or [asdf](https://asdf-vm.com/):

```bash
bundle install
bundle exec rspec
```

**Run with verbose output:**

```bash
bundle exec rspec --format documentation
```

**Run the linter:**

```bash
bundle exec rubocop
```

### Project Files

| File | Description |
|------|-------------|
| `app/backup.rb` | Backup service |
| `app/backup-crypt.rb` | Key generation, encryption, and decryption utility |
| `.rubocop.yml` | RuboCop lint configuration |
| `.ruby-version` | Ruby version for local development (3.4) |
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
2. **Check the glob pattern match**: Debug output shows the exact patterns used
3. **Verify file exists before distribution**: The backup must complete before distribution runs
4. **Check filename format**: Must match `backup-{name}-{YYYYMMDDHHMMSS}.{sql|snapshot}.bz2`, optionally followed by `.age`

### SQLite Permission Denied

If SQLite backups fail with permission errors:

1. Set `BACKUP_UID` and `BACKUP_GID` to match the file owner
2. Or run as root with `BACKUP_UID=0` and `BACKUP_GID=0` (default)

### PostgreSQL Globals Not Backing Up

The `pg_dumpall --globals-only` command requires superuser privileges. Either:

1. Set `PG_GLOBALS_URL` to a superuser connection string
2. Or accept that globals backup will be skipped (database backups still work)

### Encryption Errors

**"Invalid age recipient"** at startup: the key is malformed. An age public key starts with `age1` and is 62 characters long. Make sure you configured the *public* key, not the contents of the identity file.

**"Error compressing/encrypting file"** during a cycle: the backup failed and nothing was written. Check that the image includes `age` (`docker run --rm --entrypoint age <image> --version`) and that `DEST_DIR` has free space. Backups do not silently fall back to plaintext.

**"no identity matched any of the recipients"** when decrypting: the identity does not correspond to any recipient the file was encrypted to. Backups can only be read by the keys configured at the time they were made - re-check which recipients were set then.

## License

[MIT](LICENSE)
