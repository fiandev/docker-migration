# Docker Migration Manager

A Bash script for backing up and restoring a Docker host: containers, images,
named volumes, bind mounts, Compose projects, server configuration, and
PostgreSQL logical dumps.

Backups are encrypted with 7-Zip, split into chunks, checksummed with SHA-256,
and can be reported or uploaded to Telegram through a bot.

## Features

- Container, image, volume, and network metadata
- Named volume backups
- Bind mount discovery and backups
- Docker Compose project backups
- Server configuration backups (`/etc/nginx`, `/etc/letsencrypt`, `/etc/docker`)
- PostgreSQL logical dumps for the `psql` and `tcs-db` containers
- AES-256 encrypted 7z archive with encrypted headers
- Chunked archive output with `SHA256SUMS`
- Restore with checksum verification and destructive-action confirmation
- Telegram success/failure notifications
- Optional Telegram upload of encrypted chunks
- systemd service and timer for scheduled backups twice a day

## Requirements

- Linux with Bash 4.4+
- Root access
- Docker Engine and the Docker Compose plugin
- `7z` or `7zz`
- `tar`, `split`, `sha256sum`, `base64`, `realpath`, `curl`, `find`, `awk`
- systemd, only for scheduled backups

## Installation

```bash
git clone https://github.com/fiandev/docker-migration docker-migration
cd docker-migration
chmod +x main.sh

cp .env.example .env
chmod 600 .env
nano .env
```

`.env` is loaded automatically from the same directory as `main.sh`.
Variables already exported in the shell take precedence over `.env` values.

## Configuration

| Variable | Description | Default |
| --- | --- | --- |
| `TELEGRAM_BOT_TOKEN` | Bot token from `@BotFather` | empty |
| `TELEGRAM_CHAT_ID` | Target chat, group, or channel ID | empty |
| `TELEGRAM_TOPIC_ID` | Forum topic ID for groups with topics | empty |
| `TELEGRAM_SEND_FILES` | Upload encrypted chunks and `SHA256SUMS` after backup | `false` |
| `TELEGRAM_MAX_FILE_MB` | Maximum file size to upload, in MiB | `49` |
| `TELEGRAM_SILENT` | Send notifications without sound | `false` |
| `TELEGRAM_TIMEOUT` | Telegram HTTP timeout in seconds | `30` |
| `TELEGRAM_UPLOAD_TIMEOUT` | Base timeout for document uploads in seconds; grows with file size | `120` |
| `TELEGRAM_REQUIRED` | Fail when Telegram is not configured | `false` |
| `BACKUP_PASSWORD` | Archive encryption password | empty |
| `DEFAULT_CHUNK_SIZE` | Default chunk size when no CLI argument is given | `50m` |
| `KEEP_ARCHIVE` | Keep the full `.7z` next to the chunks | `false` |
| `CLEANUP_SOURCE` | Delete the unencrypted source folder after the archive is verified | `true` |
| `CLEANUP_AFTER_UPLOAD` | Delete local chunks after Telegram confirms every upload | `false` |
| `RETENTION_COUNT` | Keep only the newest N encrypted backups (`0` = all) | `0` |
| `WORK_DIR` | Working directory for backups | `/root` |
| `ENV_FILE` | Override the `.env` path | `<script-dir>/.env` |

`BACKUP_PASSWORD` is required for non-interactive runs such as the systemd
timer. When it is set, backup and restore use it automatically and do not
prompt.

## Usage

```bash
./main.sh backup [chunk-size]
./main.sh restore /path/to/encrypted-folder
./main.sh telegram-test
./main.sh install-service
./main.sh uninstall-service
./main.sh --help
```

### Backup

```bash
sudo ./main.sh backup 45m
```

The script creates two directories under `WORK_DIR`:

- `docker-migration-YYYYMMDD-HHMMSS` — unencrypted source data
- `docker-migration-YYYYMMDD-HHMMSS-encrypted` — encrypted archive and chunks

The latest source path is written to `${WORK_DIR}/docker-migration-latest`
(`/root/docker-migration-latest` by default).

By default the backup is reduced to the encrypted chunks only:

1. The archive is verified with `7z t`.
2. The archive is split and every chunk is checksummed into `SHA256SUMS`.
3. The chunk sizes are verified against the archive size.
4. The full `.7z` is deleted (`KEEP_ARCHIVE=false`).
5. The unencrypted source folder is deleted (`CLEANUP_SOURCE=true`), and
   `docker-migration-latest` is pointed at the encrypted folder.

Set `CLEANUP_AFTER_UPLOAD=true` to also delete the local chunks once all of
them have been uploaded to Telegram. In that case the Telegram chat is the only
copy. `RETENTION_COUNT` prunes old backup folders after each successful run.

### Restore

```bash
sudo ./main.sh restore /root/docker-migration-YYYYMMDD-HHMMSS-encrypted
```

Restore is destructive. It will:

1. Stop all running containers.
2. Overwrite the original Compose project directories.
3. Delete and restore the contents of named volumes.
4. Overwrite bind mount source directories.
5. Restore server configuration under `/etc`.

You must type `yes` to continue.

If the chunks were downloaded from Telegram, the folder name does not matter.
The archive name is inferred from `SHA256SUMS`.

### Telegram

Create a bot with `@BotFather`, then send a message to the bot and open:

```text
https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
```

Copy `message.chat.id` into `TELEGRAM_CHAT_ID`, then test:

```bash
./main.sh telegram-test
```

To upload the encrypted chunks automatically:

```dotenv
TELEGRAM_SEND_FILES=true
TELEGRAM_MAX_FILE_MB=49
```

The Telegram Bot API allows at most 50 MB per uploaded document. Use a chunk
size below that, for example:

```bash
sudo ./main.sh backup 45m
```

### Scheduled backups

```bash
sudo ./main.sh install-service
```

This installs:

- `/etc/systemd/system/backup.service`
- `/etc/systemd/system/backup.timer`

The timer runs twice daily at **03:00** and **15:00** with `Persistent=true`,
so a missed run is executed after the next boot. The chunk size comes from
`DEFAULT_CHUNK_SIZE` in `.env`.

Check the schedule and logs on the target host:

```bash
systemctl list-timers backup.timer
journalctl -u backup.service
```

Remove the service and timer:

```bash
sudo ./main.sh uninstall-service
```

`install-service` and `uninstall-service` refuse to touch a `backup.service` or
`backup.timer` that was not created by this script.

## How it works

### Backup

1. Collect container, volume, and network metadata.
2. Dump PostgreSQL databases.
3. Save all tagged Docker images.
4. Archive Compose projects and server configuration.
5. Stop running containers.
6. Archive named volumes and bind mounts.
7. Restart the containers that were running before the backup.
8. Generate `SHA256SUMS`.
9. Encrypt the backup with 7-Zip and verify the archive.
10. Split the encrypted archive into chunks and checksum them.
11. Delete the archive and the unencrypted source (`KEEP_ARCHIVE`,
    `CLEANUP_SOURCE`).
12. Send Telegram notifications and, optionally, upload the chunks.
13. Optionally delete the local chunks after a complete upload
    (`CLEANUP_AFTER_UPLOAD`) and prune old backups (`RETENTION_COUNT`).

### Restore

1. Verify chunk checksums.
2. Join the chunks into the encrypted archive.
3. Decrypt the archive.
4. Verify the backup checksums.
5. Ask for confirmation.
6. Stop all containers.
7. Restore server configuration, Compose projects, images, volumes, and bind
   mounts.
8. Start Compose projects and wait for PostgreSQL.
9. Send a Telegram notification.

## Limitations

- PostgreSQL backup is currently limited to containers named `psql` and
  `tcs-db`. Edit the loop in `backup()` to add other container names.
- All tagged Docker images are saved, which can produce a large archive.
- Custom networks and standalone containers are not reconstructed
  automatically.
- Bind mounting `/` is rejected.
- Restore overwrites existing data and server configuration.
- Scheduling requires systemd.

## Security notes

- Run the script as root; it needs access to Docker and `/etc`.
- Keep `.env` readable only by root: `chmod 600 .env`.
- Backups contain secrets such as environment variables, Compose files, and
  TLS private keys. Store the encrypted chunks securely.
- Telegram uploads send the encrypted archive to Telegram. The contents are
  encrypted, but metadata such as file names and timestamps is visible.
- Review the script before running it on a production host.

## License

MIT. See [LICENSE](LICENSE).
