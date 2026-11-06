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
- Config-only restore for one or more host config paths
- PostgreSQL logical dumps for the `psql` and `tcs-db` containers
- AES-256 encrypted 7z archive with encrypted headers
- Chunked archive output with `SHA256SUMS`
- Restore with checksum verification and destructive-action confirmation
- Telegram success/failure notifications
- Optional Telegram upload of encrypted chunks
- Telegram restore manifest (`file_id` per chunk) and automatic download
- systemd service and timer for scheduled backups twice a day

## Requirements

- Linux with Bash 4.4+
- Root access
- Docker Engine and the Docker Compose plugin
- `7z` or `7zz`
- `tar`, `split`, `sha256sum`, `base64`, `realpath`, `curl`
- Standard utilities: `find`, `grep`, `sed`, `awk`, `sort`, `head`, `cut`,
  `stat`, `xargs`, `du`, `wc`, `mktemp`
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
| `TELEGRAM_SEND_FILES` | Upload encrypted chunks, `SHA256SUMS`, and the restore manifest after backup | `false` |
| `TELEGRAM_MAX_FILE_MB` | Maximum file size to upload, in MiB | `19` |
| `TELEGRAM_DOWNLOAD_MAX_MB` | Maximum file size the Bot API can download, in MiB; chunks must stay at or below this | `20` |
| `TELEGRAM_API_BASE` | Bot API base URL; point it at a local Bot API server to lift the 20 MB download cap | `https://api.telegram.org` |
| `TELEGRAM_SILENT` | Send notifications without sound | `false` |
| `TELEGRAM_TIMEOUT` | Telegram HTTP timeout in seconds | `30` |
| `TELEGRAM_UPLOAD_TIMEOUT` | Base timeout for document uploads in seconds; grows with file size | `120` |
| `TELEGRAM_REQUIRED` | Fail when Telegram is not configured | `false` |
| `BACKUP_PASSWORD` | Archive encryption password | empty |
| `DEFAULT_CHUNK_SIZE` | Default chunk size when no CLI argument is given | `19m` |
| `KEEP_ARCHIVE` | Keep the full `.7z` next to the chunks | `false` |
| `CLEANUP_SOURCE` | Delete the unencrypted source folder after the archive is verified | `true` |
| `CLEANUP_AFTER_UPLOAD` | Delete local chunks after Telegram confirms every upload | `false` |
| `RETENTION_COUNT` | Keep only the newest N encrypted backups (`0` = all) | `0` |
| `CONFIG_PATHS` | Space-separated absolute paths included in the config backup and available to `restore-config` | `/etc/nginx /etc/letsencrypt /etc/docker` |
| `WORK_DIR` | Working directory for backups | `/root` |
| `ENV_FILE` | Override the `.env` path | `<script-dir>/.env` |

`BACKUP_PASSWORD` is required for non-interactive runs such as the systemd
timer. When it is set, backup and restore use it automatically and do not
prompt.

## Usage

```bash
./main.sh backup [chunk-size]
./main.sh restore /path/to/encrypted-folder
./main.sh restore-config /path/to/backup [config ...]
./main.sh restore-telegram [manifest.tsv|telegram-file-id]
./main.sh telegram-test
./main.sh install-service
./main.sh uninstall-service
./main.sh --help
```

### Backup

```bash
sudo ./main.sh backup 19m
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

When `TELEGRAM_SEND_FILES=true`, every uploaded file is also recorded in a
restore manifest, and a copy is kept under `WORK_DIR` even if the local chunks
are deleted. See [Restore from Telegram](#restore-from-telegram).

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
5. Restore server configuration from `CONFIG_PATHS`.

You must type `yes` to continue.

If the chunks were downloaded from Telegram, the folder name does not matter.
The archive name is inferred from `SHA256SUMS`.

### Config-only restore

`restore` rebuilds everything. To apply only host configuration — for example
nginx after moving a reverse proxy, without touching containers or volumes — use
`restore-config`:

```bash
# Restore every config path from an encrypted backup.
sudo ./main.sh restore-config /root/docker-migration-YYYYMMDD-HHMMSS-encrypted

# Restore only /etc/nginx.
sudo ./main.sh restore-config /root/docker-migration-YYYYMMDD-HHMMSS-encrypted nginx

# Full paths also work.
sudo ./main.sh restore-config /root/docker-migration-YYYYMMDD-HHMMSS-encrypted /etc/letsencrypt

# An already extracted backup tree works too (no decryption needed).
sudo ./main.sh restore-config /root/docker-restore.XXXXXX/docker-migration-YYYYMMDD-HHMMSS
```

Container, image, volume, bind mount, and Compose data are not touched. The
command lists the matching config paths and asks for confirmation before
overwriting files. When `/etc/nginx` is restored and `nginx` is installed, the
config is validated with `nginx -t` and the service is reloaded. A changed
`/etc/docker` is not restarted automatically; run `systemctl restart docker`
when you are ready.

### Restore from Telegram

When `TELEGRAM_SEND_FILES=true`, the backup also writes and uploads a small
manifest, `docker-migration-YYYYMMDD-HHMMSS-telegram-manifest.tsv`. It records
the Telegram `file_id`, size, and SHA-256 of every uploaded file, plus the
backup name.

A copy is always kept at
`${WORK_DIR}/docker-migration-YYYYMMDD-HHMMSS-telegram-manifest.tsv`, even when
`CLEANUP_AFTER_UPLOAD=true` deletes the local chunks.

`restore-telegram` reads that manifest, downloads every chunk from Telegram,
verifies size and checksum, and then runs the normal restore flow:

```bash
# Same host: pick the newest local manifest automatically.
sudo ./main.sh restore-telegram

# Explicit manifest path.
sudo ./main.sh restore-telegram /root/docker-migration-20260101-000000-telegram-manifest.tsv

# New host: pass the manifest's Telegram file_id instead of downloading it.
sudo ./main.sh restore-telegram BQACAgQAAx...
```

On a new host, download only the tiny manifest from the Telegram chat (or copy
its `file_id`), or keep the manifest copy from the old host. Nothing else needs
to be downloaded by hand. Already-downloaded chunks that match the manifest
checksum are skipped, so an interrupted restore can be resumed. The files are
kept in `${WORK_DIR}/<backup-name>-encrypted`.

To get the manifest's `file_id` on a new host, forward the manifest document to
the bot and read the latest update:

```text
https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
```

The manifest is a tab-separated text file:

```text
# docker-migration telegram manifest v1
name	docker-migration-YYYYMMDD-HHMMSS
host	old-vps
created	2026-01-01T03:00:00+0700
chunk_size	19m
archive_sha256	<hash of the joined archive>
complete	1
file	SHA256SUMS	<size>	<sha256>	<file_id>	<file_unique_id>	<message_id>
file	docker-migration-...part-0000	<size>	<sha256>	<file_id>	<file_unique_id>	<message_id>
```

A manifest with `complete 0` is rejected: it means at least one chunk failed to
upload during backup.

`restore-telegram` still needs `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` in
`.env`, but only the token is used to download files. The `file_id`s are tied
to the bot that uploaded the backup. If you switch bots, the old manifest
cannot be used; keep the current bot token or download the files by hand.

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
TELEGRAM_MAX_FILE_MB=19
```

Two different Bot API limits apply, and they are easy to mix up:

- **Upload** (`sendDocument`) accepts up to 50 MB per file.
- **Download** (`getFile`) only accepts files up to **20 MB**.

A 49 MB chunk therefore uploads fine and then fails on restore with
`Bad Request: file is too big`. Keep chunks at or below the download limit;
`19m` leaves a safety margin:

```bash
sudo ./main.sh backup 19m
```

The backup warns when a chunk exceeds `TELEGRAM_DOWNLOAD_MAX_MB`. To restore a
backup that was already uploaded with larger chunks, either re-upload it with
`19m` chunks or point `TELEGRAM_API_BASE` at a local Bot API server started with
`TELEGRAM_LOCAL=1` (it allows downloads up to 2000 MB and keeps the same
`file_id`s):

```dotenv
TELEGRAM_API_BASE=http://127.0.0.1:8081
TELEGRAM_DOWNLOAD_MAX_MB=2000
```

After the chunks, the script uploads the restore manifest as the last document.
If any chunk is rejected by Telegram (for example because it is larger than
`TELEGRAM_MAX_FILE_MB`), the manifest is marked `complete 0` and
`restore-telegram` refuses to use it. Local chunks are kept in that case, even
with `CLEANUP_AFTER_UPLOAD=true`.

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
12. Send Telegram notifications and, optionally, upload the chunks with a
    restore manifest containing their `file_id`s.
13. Optionally delete the local chunks after a complete upload
    (`CLEANUP_AFTER_UPLOAD`) and prune old backups (`RETENTION_COUNT`).

### Restore

`restore` starts at step 2; `restore-telegram` runs step 1 first and then hands
the downloaded folder to `restore`.

1. (`restore-telegram` only) Read the manifest, download every listed file from
   Telegram, and verify its size and SHA-256.
2. Verify chunk checksums.
3. Join the chunks into the encrypted archive.
4. Decrypt the archive.
5. Verify the backup checksums.
6. Ask for confirmation.
7. Stop all containers.
8. Restore server configuration, Compose projects, images, volumes, and bind
   mounts.
9. Start Compose projects and wait for PostgreSQL.
10. Send a Telegram notification.

## Limitations

- PostgreSQL backup is currently limited to containers named `psql` and
  `tcs-db`. Edit the loop in `backup()` to add other container names.
- All tagged Docker images are saved, which can produce a large archive.
- Custom networks and standalone containers are not reconstructed
  automatically.
- Bind mounting `/` is rejected.
- Restore overwrites existing data and server configuration.
- `restore-telegram` needs the manifest file (or its `file_id`) and the same
  bot token that uploaded the backup; Telegram `file_id`s are bot-specific.
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
