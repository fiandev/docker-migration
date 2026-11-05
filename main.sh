#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ============================================================
# DOCKER MIGRATION MANAGER
# Backup + Encryption + Chunking + Automatic Restore
# + Telegram notifications
#
# Requirements:
#   docker, docker compose, 7z/7zz, tar, split,
#   sha256sum, base64, realpath, curl (Telegram)
#
# Config:
#   cp .env.example .env   (fill in bot token + chat id + password)
#
# Usage:
#   ./main.sh backup [chunk-size]
#   ./main.sh restore /path/to/encrypted-folder
#   ./main.sh restore-telegram [manifest|file-id]
#   ./main.sh telegram-test
#   ./main.sh install-service
#   ./main.sh uninstall-service
# ============================================================

MODE="${1:-}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

# Load .env without executing it. Values already present in the
# environment win over the ones from the file.
load_env() {
    [[ -f "$ENV_FILE" ]] || return 0

    local line key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"

        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" == *=* ]] || continue

        key="${line%%=*}"
        value="${line#*=}"

        # Trim whitespace around the key.
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        key="${key#export }"

        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

        # Strip matching single/double quotes around the value.
        if [[ "$value" =~ ^\"(.*)\"$ ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi

        # Do not override an explicitly exported variable.
        if [[ -z "${!key:-}" ]]; then
            printf -v "$key" '%s' "$value"
        fi

        export "$key"
    done < "$ENV_FILE"
}

load_env

CHUNK_SIZE="${DEFAULT_CHUNK_SIZE:-50m}"

# Storage hygiene.
KEEP_ARCHIVE="${KEEP_ARCHIVE:-false}"
CLEANUP_SOURCE="${CLEANUP_SOURCE:-true}"
CLEANUP_AFTER_UPLOAD="${CLEANUP_AFTER_UPLOAD:-false}"
RETENTION_COUNT="${RETENTION_COUNT:-0}"

WORK_DIR="${WORK_DIR:-/root}"
LATEST_FILE="${LATEST_FILE:-${WORK_DIR}/docker-migration-latest}"

SEVENZIP="$(command -v 7z || command -v 7zz || true)"

# Telegram state (populated by init_telegram).
TELEGRAM_ENABLED=0
TELEGRAM_FAILURE_SENT=0
TELEGRAM_UPLOAD_OK=0
BACKUP_START=0
RESTORE_START=0

# Last Telegram API payload and the file_id of the last uploaded document.
TG_LAST_RESPONSE=""
TG_DOCUMENT_FILE_ID=""
TG_DOCUMENT_UNIQUE_ID=""
TG_DOCUMENT_MESSAGE_ID=""
TG_FILE_PATH=""

# ============================================================
# COMMON FUNCTIONS
# ============================================================

warn() {
    echo "WARNING: $*" >&2
}

die() {
    local message="$*"

    echo "ERROR: $message" >&2
    tg_notify_failure 1 "$message" || true

    exit 1
}

require_root() {
    [[ "$EUID" == 0 ]] || die "Run as root."
}

require_commands() {
    local cmd

    for cmd in docker tar split sha256sum base64 realpath; do
        command -v "$cmd" >/dev/null 2>&1 \
            || die "Command not found: $cmd"
    done

    [[ -n "$SEVENZIP" ]] || die "7z/7zz not found."

    docker info >/dev/null 2>&1 \
        || die "Docker daemon is not available."

    docker compose version >/dev/null 2>&1 \
        || die "Docker Compose plugin is not available."
}

install_service() {
    local service_src="${SCRIPT_DIR}/backup.service"
    local timer_src="${SCRIPT_DIR}/backup.timer"
    local service_dst="/etc/systemd/system/backup.service"
    local timer_dst="/etc/systemd/system/backup.timer"
    local script_path="${SCRIPT_DIR}/$(basename "$0")"

    command -v systemctl >/dev/null 2>&1 \
        || die "systemctl not found."

    [[ -f "$service_src" ]] \
        || die "backup.service not found in $SCRIPT_DIR"

    [[ -f "$timer_src" ]] \
        || die "backup.timer not found in $SCRIPT_DIR"

    if [[ "$SCRIPT_DIR" =~ [[:space:]\&\|] || "$ENV_FILE" =~ [[:space:]\&\|] ]]; then
        die "Script directory and ENV_FILE must not contain whitespace, '&', or '|'."
    fi

    if [[ -e "$service_dst" ]] \
        && ! grep -q '^Description=Docker migration backup$' "$service_dst"; then
        die "$service_dst already exists and is not managed by this script."
    fi

    if [[ -e "$timer_dst" ]] \
        && ! grep -q '^Description=Run Docker migration backup twice daily$' "$timer_dst"; then
        die "$timer_dst already exists and is not managed by this script."
    fi

    chmod +x "$script_path"

    sed \
        -e "s|__SCRIPT_DIR__|${SCRIPT_DIR}|g" \
        -e "s|__SCRIPT_PATH__|${script_path}|g" \
        -e "s|__ENV_FILE__|${ENV_FILE}|g" \
        "$service_src" > "$service_dst"

    sed \
        -e "s|__SCRIPT_DIR__|${SCRIPT_DIR}|g" \
        "$timer_src" > "$timer_dst"

    chmod 644 "$service_dst" "$timer_dst"

    systemctl daemon-reload
    systemctl enable --now backup.timer

    echo "Installed backup.service and backup.timer."
    echo "The timer runs twice daily at 03:00 and 15:00."
}

uninstall_service() {
    local service_dst="/etc/systemd/system/backup.service"
    local timer_dst="/etc/systemd/system/backup.timer"

    command -v systemctl >/dev/null 2>&1 \
        || die "systemctl not found."

    if [[ -e "$service_dst" ]] \
        && ! grep -q '^Description=Docker migration backup$' "$service_dst"; then
        die "$service_dst is not managed by this script."
    fi

    if [[ -e "$timer_dst" ]] \
        && ! grep -q '^Description=Run Docker migration backup twice daily$' "$timer_dst"; then
        die "$timer_dst is not managed by this script."
    fi

    systemctl disable --now backup.timer 2>/dev/null || true

    rm -f "$service_dst" "$timer_dst"

    systemctl daemon-reload

    echo "Removed backup.service and backup.timer."
}

confirm() {
    local answer

    echo
    if ! read -rp "$1 [yes/no]: " answer; then
        echo "Operation cancelled."
        exit 1
    fi

    if [[ "$answer" != "yes" ]]; then
        echo "Operation cancelled."
        exit 1
    fi
}

encode() {
    printf '%s' "$1" | base64 -w 0
}

decode() {
    printf '%s' "$1" | base64 -d
}

# ============================================================
# TELEGRAM NOTIFICATIONS
# ============================================================

TELEGRAM_API_BASE="https://api.telegram.org"

is_true() {
    case "${1,,}" in
        1 | true | yes | on) return 0 ;;
        *) return 1 ;;
    esac
}

format_duration() {
    local total="${1:-0}"

    printf '%02dh%02dm%02ds' \
        $((total / 3600)) \
        $(((total % 3600) / 60)) \
        $((total % 60))
}

# Escape dynamic values before embedding them in an HTML message.
tg_escape() {
    local value="$1"

    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"

    printf '%s' "$value"
}

init_telegram() {
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
    TELEGRAM_TOPIC_ID="${TELEGRAM_TOPIC_ID:-}"
    TELEGRAM_MAX_FILE_MB="${TELEGRAM_MAX_FILE_MB:-49}"
    TELEGRAM_TIMEOUT="${TELEGRAM_TIMEOUT:-30}"
    TELEGRAM_UPLOAD_TIMEOUT="${TELEGRAM_UPLOAD_TIMEOUT:-120}"

    [[ "$TELEGRAM_MAX_FILE_MB" =~ ^[0-9]+$ ]] \
        || TELEGRAM_MAX_FILE_MB=49

    [[ "$TELEGRAM_TIMEOUT" =~ ^[0-9]+$ ]] \
        || TELEGRAM_TIMEOUT=30

    [[ "$TELEGRAM_UPLOAD_TIMEOUT" =~ ^[0-9]+$ ]] \
        || TELEGRAM_UPLOAD_TIMEOUT=120

    if [[ -z "$TELEGRAM_BOT_TOKEN" && -z "$TELEGRAM_CHAT_ID" ]]; then
        if is_true "${TELEGRAM_REQUIRED:-false}"; then
            die "TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are not set in $ENV_FILE"
        fi

        return 0
    fi

    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        warn "Telegram configuration is incomplete in $ENV_FILE; notifications are disabled."
        return 0
    fi

    command -v curl >/dev/null 2>&1 \
        || die "curl is required for Telegram notifications."

    if [[ -f "$ENV_FILE" ]]; then
        local env_mode
        env_mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || true)"

        if [[ -n "$env_mode" && "${env_mode: -2}" != "00" ]]; then
            warn "$ENV_FILE is readable by other users. Run: chmod 600 $ENV_FILE"
        fi
    fi

    TELEGRAM_ENABLED=1
}

# Call a Bot API method. Token is never printed in errors.
tg_api() {
    local method="$1"
    shift

    local response http_code body
    local max_time="${TG_API_MAX_TIME:-$TELEGRAM_TIMEOUT}"
    local retries="${TG_API_RETRIES:-2}"

    local -a retry_args=()
    if ((retries > 0)); then
        retry_args=(--retry "$retries" --retry-delay 2 --retry-connrefused)
    fi

    response="$(curl --silent --show-error \
        --connect-timeout 10 \
        --max-time "$max_time" \
        "${retry_args[@]}" \
        --write-out $'\n%{http_code}' \
        "${TELEGRAM_API_BASE}/bot${TELEGRAM_BOT_TOKEN}/${method}" \
        "$@" 2>&1)" || true

    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    TG_LAST_RESPONSE="$body"

    if [[ "$http_code" == "200" ]]; then
        return 0
    fi

    warn "Telegram ${method} failed (HTTP ${http_code:-?}): ${body:0:300}"
    return 1
}

# Extract the first "$key":"value" from a JSON payload. The Bot API
# responses are compact and the field we need always appears before any
# nested object (thumbnail, etc.), so a regex is enough and avoids a
# hard dependency on jq.
tg_json_string() {
    local key="$1"
    local json="${2:-${TG_LAST_RESPONSE:-}}"

    printf '%s' "$json" \
        | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -n 1 \
        | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//' \
        || true
}

tg_json_number() {
    local key="$1"
    local json="${2:-${TG_LAST_RESPONSE:-}}"

    printf '%s' "$json" \
        | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]+" \
        | head -n 1 \
        | sed -E 's/^[^:]*:[[:space:]]*//' \
        || true
}

# Resolve a Telegram file_id to a temporary download path.
tg_get_file_path() {
    local file_id="$1"

    TG_FILE_PATH=""

    tg_api getFile \
        --data-urlencode "file_id=${file_id}" \
        || return 1

    TG_FILE_PATH="$(tg_json_string file_path)"

    if [[ -z "$TG_FILE_PATH" ]]; then
        warn "Telegram did not return a file path for: $file_id"
        return 1
    fi
}

# $1 = Telegram file_id, $2 = destination path.
tg_download_file() {
    local file_id="$1"
    local dest="$2"

    [[ "$TELEGRAM_ENABLED" == 1 ]] || return 1

    tg_get_file_path "$file_id" || return 1

    local file_size
    file_size="$(tg_json_number file_size)"
    [[ "$file_size" =~ ^[0-9]+$ ]] || file_size=0

    local download_timeout=$((TELEGRAM_UPLOAD_TIMEOUT + file_size / 131072))
    local tmp="${dest}.part"

    mkdir -p -- "$(dirname "$dest")"

    if ! curl --silent --show-error --fail \
        --connect-timeout 10 \
        --max-time "$download_timeout" \
        --retry 2 --retry-delay 2 --retry-connrefused \
        -o "$tmp" \
        "${TELEGRAM_API_BASE}/file/bot${TELEGRAM_BOT_TOKEN}/${TG_FILE_PATH}"; then

        rm -f -- "$tmp"
        warn "Telegram download failed: $file_id"
        return 1
    fi

    mv -f -- "$tmp" "$dest"
}

# $1 = HTML message. Escape dynamic values with tg_escape first.
tg_send_message() {
    local text="$1"

    [[ "$TELEGRAM_ENABLED" == 1 ]] || return 0

    # Bot API hard limit is 4096 characters.
    text="${text:0:4000}"

    local -a args=(
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}"
        --data-urlencode "text=${text}"
        --data-urlencode "parse_mode=HTML"
        --data-urlencode "disable_web_page_preview=true"
    )

    if [[ -n "$TELEGRAM_TOPIC_ID" ]]; then
        args+=(--data-urlencode "message_thread_id=${TELEGRAM_TOPIC_ID}")
    fi

    if is_true "${TELEGRAM_SILENT:-false}"; then
        args+=(--data-urlencode "disable_notification=true")
    fi

    tg_api sendMessage "${args[@]}"
}

# $1 = local file, $2 = HTML caption (optional).
tg_send_document() {
    local file="$1"
    local caption="${2:-}"

    [[ "$TELEGRAM_ENABLED" == 1 ]] || return 0

    if [[ ! -f "$file" ]]; then
        warn "File not found: $file"
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        warn "File not readable: $file"
        return 1
    fi

    local size_bytes max_bytes
    size_bytes="$(wc -c < "$file")"
    max_bytes=$((TELEGRAM_MAX_FILE_MB * 1024 * 1024))

    if ((size_bytes > max_bytes)); then
        warn "Skipping ${file##*/}: $(((size_bytes + 1048575) / 1048576))MB > ${TELEGRAM_MAX_FILE_MB}MB (Bot API limit)."
        return 2
    fi

    caption="${caption:0:1000}"

    # A 49 MB upload can take minutes on a slow VPS: the API timeout is
    # scaled with the file size instead of using the 30s message timeout.
    local upload_timeout=$((TELEGRAM_UPLOAD_TIMEOUT + size_bytes / 131072))

    # Every text field must go through --form-string. With -F, curl treats
    # a value that starts with '@' or '<' as a local file and fails with
    # "curl: (26) Failed to open/read local data" before sending anything.
    # That hit the HTML captions ("<b>...</b>") and chat IDs that start
    # with '@' (channel usernames). Only the document itself uses -F.
    local -a args=(
        --form-string "chat_id=${TELEGRAM_CHAT_ID}"
        -F "document=@${file}"
    )

    if [[ -n "$caption" ]]; then
        args+=(--form-string "caption=${caption}" --form-string "parse_mode=HTML")
    fi

    if [[ -n "$TELEGRAM_TOPIC_ID" ]]; then
        args+=(--form-string "message_thread_id=${TELEGRAM_TOPIC_ID}")
    fi

    if is_true "${TELEGRAM_SILENT:-false}"; then
        args+=(--form-string "disable_notification=true")
    fi

    local rc=0

    TG_DOCUMENT_FILE_ID=""
    TG_DOCUMENT_UNIQUE_ID=""
    TG_DOCUMENT_MESSAGE_ID=""

    TG_API_MAX_TIME="$upload_timeout"
    TG_API_RETRIES=1
    tg_api sendDocument "${args[@]}" || rc=$?
    TG_API_MAX_TIME=""
    TG_API_RETRIES=""

    if ((rc == 0)); then
        TG_DOCUMENT_FILE_ID="$(tg_json_string file_id)"
        TG_DOCUMENT_UNIQUE_ID="$(tg_json_string file_unique_id)"
        TG_DOCUMENT_MESSAGE_ID="$(tg_json_number message_id)"
    fi

    return "$rc"
}

tg_notify_failure() {
    local code="$1"
    local reason="$2"

    [[ "$TELEGRAM_ENABLED" == 1 ]] || return 0
    ((TELEGRAM_FAILURE_SENT == 0)) || return 0

    TELEGRAM_FAILURE_SENT=1

    tg_send_message "$(
        printf '%s\n' \
            "❌ <b>Docker migration failed</b>" \
            "" \
            "<b>Mode:</b> $(tg_escape "${MODE:-unknown}")" \
            "<b>Host:</b> $(tg_escape "$(uname -n)")" \
            "<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            "<b>Exit code:</b> ${code}" \
            "<b>Error:</b> $(tg_escape "$reason")"
    )" || true
}

tg_notify_backup() {
    local backup="$1"
    local output="$2"
    local name="$3"
    local chunks="$4"
    local size="$5"
    local checksum="$6"
    local duration="$7"

    [[ "$TELEGRAM_ENABLED" == 1 ]] || return 0

    tg_send_message "$(
        printf '%s\n' \
            "✅ <b>Docker backup completed</b>" \
            "" \
            "<b>Host:</b> $(tg_escape "$(uname -n)")" \
            "<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            "<b>Duration:</b> $(format_duration "$duration")" \
            "<b>Chunks:</b> ${chunks} x ${CHUNK_SIZE}" \
            "<b>Size:</b> $(tg_escape "$size")" \
            "<b>Backup:</b> <code>$(tg_escape "$backup")</code>" \
            "<b>Encrypted:</b> <code>$(tg_escape "$output")</code>" \
            "<b>SHA256 archive:</b> <code>${checksum:0:16}...</code>"
    )" || true

    is_true "${TELEGRAM_SEND_FILES:-false}" || return 0

    echo
    echo "Sending files to Telegram..."

    local sent=0
    local failed=0
    local complete=1

    local manifest="${output}/${name}-telegram-manifest.tsv"
    local manifest_copy="${WORK_DIR}/${name}-telegram-manifest.tsv"

    local -a file_rows=()

    local file expected_sha
    for file in "${output}/SHA256SUMS" "${output}/${name}.part-"*; do
        [[ -f "$file" ]] || continue

        expected_sha="$(awk -v f="$(basename "$file")" \
            '$2 == f { print $1; exit }' \
            "${output}/SHA256SUMS" 2>/dev/null || true)"

        if [[ -z "$expected_sha" ]]; then
            expected_sha="$(sha256sum "$file" | awk '{print $1}')"
        fi

        if tg_send_document \
            "$file" \
            "<b>$(tg_escape "$(basename "$file")")</b>"; then
            sent=$((sent + 1))

            file_rows+=("$(printf 'file\t%s\t%s\t%s\t%s\t%s\t%s' \
                "$(basename "$file")" \
                "$(stat -c %s "$file")" \
                "$expected_sha" \
                "${TG_DOCUMENT_FILE_ID:-}" \
                "${TG_DOCUMENT_UNIQUE_ID:-}" \
                "${TG_DOCUMENT_MESSAGE_ID:-}")")
        else
            failed=$((failed + 1))
            complete=0
        fi
    done

    # The manifest maps every Telegram file_id back to its chunk, so a
    # restore can fetch the whole backup without downloading it by hand.
    {
        printf '# docker-migration telegram manifest v1\n'
        printf 'name\t%s\n' "$name"
        printf 'host\t%s\n' "$(uname -n)"
        printf 'created\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf 'chunk_size\t%s\n' "$CHUNK_SIZE"
        printf 'archive_sha256\t%s\n' "$checksum"
        printf 'complete\t%s\n' "$complete"

        if ((${#file_rows[@]})); then
            printf '%s\n' "${file_rows[@]}"
        fi
    } > "$manifest"

    chmod 600 "$manifest"
    cp -f -- "$manifest" "$manifest_copy"
    chmod 600 "$manifest_copy"

    if tg_send_document \
        "$manifest" \
        "<b>Restore manifest</b> — $(tg_escape "$name")"; then
        sent=$((sent + 1))
    else
        failed=$((failed + 1))
    fi

    echo "Telegram upload: ${sent} sent, ${failed} failed."
    echo "Restore manifest: $manifest_copy"

    if ((failed > 0)); then
        tg_send_message "$(
            printf '%s\n' \
                "⚠️ <b>Telegram upload incomplete</b>" \
                "" \
                "<b>Sent:</b> ${sent}" \
                "<b>Failed:</b> ${failed}" \
                "<b>Host:</b> $(tg_escape "$(uname -n)")" \
                "<b>Manifest:</b> <code>$(tg_escape "$manifest_copy")</code>"
        )" || true

        return 1
    fi

    TELEGRAM_UPLOAD_OK=1
    return 0
}

tg_notify_restore() {
    local input="$1"
    local duration="$2"

    [[ "$TELEGRAM_ENABLED" == 1 ]] || return 0

    tg_send_message "$(
        printf '%s\n' \
            "✅ <b>Docker restore completed</b>" \
            "" \
            "<b>Host:</b> $(tg_escape "$(uname -n)")" \
            "<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            "<b>Duration:</b> $(format_duration "$duration")" \
            "<b>Input:</b> <code>$(tg_escape "$input")</code>"
    )" || true
}

on_error() {
    local code="$1"
    local line="$2"

    tg_notify_failure "$code" "Command failed at line ${line} (exit ${code})" || true
}

# ============================================================
# BACKUP
# ============================================================

# Keep only the newest $1 encrypted backups (0 disables pruning).
cleanup_old_backups() {
    local keep="${1:-0}"

    [[ "$keep" =~ ^[0-9]+$ ]] || return 0
    ((keep > 0)) || return 0

    local -a old=()
    mapfile -t old < <(
        find "$WORK_DIR" -maxdepth 1 -type d \
            -name 'docker-migration-*-encrypted' -printf '%f\n' \
            | sort -r \
            | tail -n "+$((keep + 1))"
    )

    local dir
    for dir in "${old[@]}"; do
        [[ -n "$dir" ]] || continue

        echo "Pruning old backup: ${WORK_DIR}/${dir}"
        rm -rf -- "${WORK_DIR}/${dir}" "${WORK_DIR}/${dir%-encrypted}"
        rm -f -- "${WORK_DIR}/${dir%-encrypted}-telegram-manifest.tsv"
    done

    # With CLEANUP_AFTER_UPLOAD=true the encrypted folder is gone, so the
    # manifest copies have to be pruned on their own.
    local -a old_manifests=()
    mapfile -t old_manifests < <(
        find "$WORK_DIR" -maxdepth 1 -type f \
            -name 'docker-migration-*-telegram-manifest.tsv' -printf '%f\n' \
            | sort -r \
            | tail -n "+$((keep + 1))"
    )

    local manifest
    for manifest in "${old_manifests[@]}"; do
        [[ -n "$manifest" ]] || continue

        echo "Pruning old manifest: ${WORK_DIR}/${manifest}"
        rm -f -- "${WORK_DIR}/${manifest}"
    done
}

backup() {
    local BACKUP
    BACKUP="${WORK_DIR}/docker-migration-$(date +%Y%m%d-%H%M%S)"

    local NAME
    NAME="$(basename "$BACKUP")"

    local OUTPUT
    OUTPUT="${WORK_DIR}/${NAME}-encrypted"

    local ARCHIVE
    ARCHIVE="${OUTPUT}/${NAME}.7z"

    local RUNNING_FILE
    RUNNING_FILE="${BACKUP}/containers/running-before.txt"

    local RESTART_PENDING=0
    local index=0

    mkdir -p "$BACKUP"/{databases,images,volumes,bind-mounts,compose,config,containers,networks}

    mkdir -p "$OUTPUT"

    chmod 700 "$BACKUP" "$OUTPUT"

    # Capture running containers

    docker ps -q > "$RUNNING_FILE"

    restart_original_containers() {
        if [[ "$RESTART_PENDING" == 1 ]]; then
            echo
            echo "Restoring previously running containers..."

            while IFS= read -r id; do
                [[ -n "$id" ]] || continue
                docker start "$id" >/dev/null 2>&1 || true
            done < "$RUNNING_FILE"
        fi
    }

    trap restart_original_containers EXIT

    echo
    echo "========================================"
    echo " DOCKER MIGRATION BACKUP"
    echo "========================================"
    echo "Backup: $BACKUP"

    # --------------------------------------------------------
    # 1. Container metadata
    # --------------------------------------------------------

    echo
    echo "[1/13] Container metadata..."

    docker ps -a --no-trunc \
        > "$BACKUP/containers/list.txt"

    mapfile -t CONTAINERS < <(docker ps -aq)

    if ((${#CONTAINERS[@]})); then
        docker inspect "${CONTAINERS[@]}" \
            > "$BACKUP/containers/inspect.json"
    else
        echo '[]' > "$BACKUP/containers/inspect.json"
    fi

    # --------------------------------------------------------
    # 2. Docker volumes metadata
    # --------------------------------------------------------

    echo "[2/13] Volume metadata..."

    docker volume ls \
        > "$BACKUP/volumes/list.txt"

    # --------------------------------------------------------
    # 3. Docker networks metadata
    # --------------------------------------------------------

    echo "[3/13] Network metadata..."

    docker network ls \
        > "$BACKUP/networks/list.txt"

    mapfile -t NETWORKS < <(docker network ls -q)

    if ((${#NETWORKS[@]})); then
        docker network inspect "${NETWORKS[@]}" \
            > "$BACKUP/networks/inspect.json"
    else
        echo '[]' > "$BACKUP/networks/inspect.json"
    fi

    # --------------------------------------------------------
    # 4. PostgreSQL logical backup
    # --------------------------------------------------------

    echo "[4/13] PostgreSQL logical backup..."

    : > "$BACKUP/databases/containers.txt"

    for c in psql tcs-db; do

        if ! docker inspect "$c" >/dev/null 2>&1; then
            echo "SKIP: $c not found."
            continue
        fi

        echo "Dump PostgreSQL: $c"

        if ! docker exec "$c" sh -lc \
            'pg_dumpall -U "${POSTGRES_USER:-postgres}"' \
            > "$BACKUP/databases/${c}.sql"; then

            die "PostgreSQL dump failed: $c"
        fi

        grep -q 'PostgreSQL database cluster dump complete' \
            "$BACKUP/databases/${c}.sql" \
            || die "PostgreSQL dump is incomplete: $c"

        echo "$c" >> "$BACKUP/databases/containers.txt"
    done

    # --------------------------------------------------------
    # 5. Docker images
    # --------------------------------------------------------

    echo "[5/13] Docker images..."

    docker image ls --no-trunc \
        > "$BACKUP/images/list.txt"

    docker image ls --format '{{.Repository}}:{{.Tag}}' \
        | grep -v '<none>' \
        | sort -u \
        > "$BACKUP/images/references.txt" || true

    mapfile -t IMAGES < "$BACKUP/images/references.txt"

    if ((${#IMAGES[@]})); then
        docker save \
            -o "$BACKUP/images/all-images.tar" \
            "${IMAGES[@]}"
    fi

    # --------------------------------------------------------
    # 6. Compose projects
    # --------------------------------------------------------

    echo "[6/13] Compose metadata..."

    : > "$BACKUP/compose/projects.tsv"

    mapfile -t PROJECT_DIRS < <(
        for id in "${CONTAINERS[@]}"; do
            docker inspect --format \
                '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' \
                "$id"
        done | grep '^/' | sort -u || true
    )

    index=0

    for dir in "${PROJECT_DIRS[@]}"; do

        [[ -d "$dir" ]] || continue

        local filename
        filename="$(printf 'project-%04d.tar.gz' "$index")"

        local project
        local config_files

        project=""
        config_files=""

        for id in "${CONTAINERS[@]}"; do

            local current_dir
            current_dir="$(docker inspect --format \
                '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' \
                "$id")"

            [[ "$current_dir" == "$dir" ]] || continue

            project="$(docker inspect --format \
                '{{index .Config.Labels "com.docker.compose.project"}}' \
                "$id")"

            config_files="$(docker inspect --format \
                '{{index .Config.Labels "com.docker.compose.project.config_files"}}' \
                "$id")"

            break
        done

        echo "Backup Compose: $dir"

        printf '%s\t%s\t%s\t%s\n' \
            "$(encode "$dir")" \
            "$filename" \
            "$(encode "$config_files")" \
            "$(encode "$project")" \
            >> "$BACKUP/compose/projects.tsv"

        tar -czf "$BACKUP/compose/$filename" \
            -C "$dir" .

        ((index+=1))
    done

    # --------------------------------------------------------
    # 7. Server configurations
    # --------------------------------------------------------

    echo "[7/13] Server configurations..."

    for path in /etc/nginx /etc/letsencrypt /etc/docker; do

        [[ -e "$path" ]] || continue

        local filename
        filename="$(printf '%s' "$path" | sed 's#/#_#g')"

        echo "Backup: $path"

        tar -czf "$BACKUP/config/${filename}.tar.gz" \
            -C "$(dirname "$path")" \
            "$(basename "$path")"
    done

    # --------------------------------------------------------
    # 8. Bind mount discovery
    # --------------------------------------------------------

    echo "[8/13] Bind mount discovery..."

    : > "$BACKUP/bind-mounts/sources.txt"

    for id in "${CONTAINERS[@]}"; do

        docker inspect --format \
            '{{range .Mounts}}{{if eq .Type "bind"}}{{println .Source}}{{end}}{{end}}' \
            "$id"
    done | sort -u > "$BACKUP/bind-mounts/sources.txt"

    : > "$BACKUP/bind-mounts/manifest.tsv"

    # --------------------------------------------------------
    # 9. Stop running containers
    # --------------------------------------------------------

    echo
    echo "[9/13] Stopping containers..."

    RESTART_PENDING=1

    if [[ -s "$RUNNING_FILE" ]]; then
        while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            docker stop -t 60 "$id"
        done < "$RUNNING_FILE"
    fi

    # --------------------------------------------------------
    # 10. Named volumes backup
    # --------------------------------------------------------

    echo "[10/13] Named volumes..."

    while IFS= read -r volume; do

        [[ -n "$volume" ]] || continue

        local mountpoint
        mountpoint="$(docker volume inspect \
            --format '{{.Mountpoint}}' "$volume")"

        [[ -d "$mountpoint" ]] \
            || die "Volume not found: $volume"

        echo "Backup volume: $volume"

        tar -czf "$BACKUP/volumes/${volume}.tar.gz" \
            -C "$mountpoint" .

    done < <(docker volume ls -q)

    # --------------------------------------------------------
    # 11. Bind mounts backup
    # --------------------------------------------------------

    echo "[11/13] Bind mounts..."

    index=0

    while IFS= read -r src; do

        [[ -n "$src" && -e "$src" ]] || continue

        [[ "$src" != "/" ]] \
            || die "Bind mount root is not supported."

        local filename
        filename="$(printf 'bind-%04d.tar.gz' "$index")"

        echo "Backup bind mount: $src"

        printf '%s\t%s\n' \
            "$(encode "$src")" \
            "$filename" \
            >> "$BACKUP/bind-mounts/manifest.tsv"

        tar -czf "$BACKUP/bind-mounts/$filename" \
            -C "$(dirname "$src")" \
            "$(basename "$src")"

        ((index+=1))

    done < "$BACKUP/bind-mounts/sources.txt"

    # --------------------------------------------------------
    # 12. Restart original containers
    # --------------------------------------------------------

    echo
    echo "[12/13] Restarting containers..."

    restart_original_containers

    RESTART_PENDING=0
    trap - EXIT

    # --------------------------------------------------------
    # 13. Checksums
    # --------------------------------------------------------

    echo "[13/13] Generating SHA256..."

    (
        cd "$BACKUP"

        find . -type f ! -name SHA256SUMS -print0 \
            | sort -z \
            | xargs -0 -r sha256sum \
            > SHA256SUMS
    )

    printf '%s\n' "$BACKUP" > "$LATEST_FILE"

    # --------------------------------------------------------
    # Encryption
    # --------------------------------------------------------

    echo
    echo "========================================"
    echo " ENCRYPTION"
    echo "========================================"

    [[ ! -e "$ARCHIVE" ]] \
        || die "Archive already exists: $ARCHIVE"

    local PASSWORD
    local PASSWORD_CONFIRM

    if [[ -n "${BACKUP_PASSWORD:-}" ]]; then
        PASSWORD="$BACKUP_PASSWORD"
        unset BACKUP_PASSWORD
        echo "Using archive password from $ENV_FILE."
    else
        if [[ ! -t 0 ]]; then
            die "BACKUP_PASSWORD is not set and no TTY is available for a password prompt."
        fi

        read -rsp "Enter archive password: " PASSWORD \
            || die "Password input aborted."
        echo

        read -rsp "Repeat archive password: " PASSWORD_CONFIRM \
            || die "Password input aborted."
        echo

        [[ -n "$PASSWORD" ]] \
            || die "Password must not be empty."

        [[ "$PASSWORD" == "$PASSWORD_CONFIRM" ]] \
            || die "Passwords do not match."
    fi

    (
        cd "$WORK_DIR"

        "$SEVENZIP" a -t7z -mhe=on \
            "-p${PASSWORD}" \
            "$ARCHIVE" "$NAME"
    ) || die "Encryption failed."

    echo "Verifying archive..."

    "$SEVENZIP" t "$ARCHIVE" "-p${PASSWORD}" \
        || die "Archive verification failed."

    unset PASSWORD PASSWORD_CONFIRM

    # --------------------------------------------------------
    # Chunking
    # --------------------------------------------------------

    echo
    echo "Splitting archive into chunks: $CHUNK_SIZE"

    split -b "$CHUNK_SIZE" -d -a 4 \
        "$ARCHIVE" \
        "$OUTPUT/${NAME}.part-"

    (
        cd "$OUTPUT"

        sha256sum "${NAME}.part-"* > SHA256SUMS
    )

    # The chunks must rebuild the archive byte for byte before either the
    # archive or the unencrypted source is removed.
    local parts_total=0
    local part

    for part in "$OUTPUT/${NAME}.part-"*; do
        parts_total=$((parts_total + $(stat -c %s "$part")))
    done

    local archive_size
    archive_size="$(stat -c %s "$ARCHIVE")"

    ((parts_total == archive_size)) \
        || die "Chunk size mismatch: ${parts_total} != ${archive_size}"

    local archive_checksum
    archive_checksum="$(sha256sum "$ARCHIVE" | awk '{print $1}')"

    if ! is_true "${KEEP_ARCHIVE:-false}"; then
        rm -f -- "$ARCHIVE"
        echo "Archive removed (the chunks hold the same data): $ARCHIVE"
    fi

    echo
    echo "========================================"
    echo " BACKUP COMPLETE"
    echo "========================================"

    echo "Source:    $BACKUP"
    echo "Encrypted: $OUTPUT"

    if is_true "${CLEANUP_SOURCE:-true}"; then
        echo "Removing unencrypted source: $BACKUP"
        rm -rf -- "$BACKUP"

        # The source path no longer exists, point LATEST_FILE at the
        # encrypted folder instead of leaving a dangling path.
        printf '%s\n' "$OUTPUT" > "$LATEST_FILE"
    fi

    du -sh "$OUTPUT"

    ls -lh "$OUTPUT"

    local total_size
    total_size="$(du -sh "$OUTPUT" | awk '{print $1}')"

    local chunk_count
    chunk_count="$(find "$OUTPUT" -maxdepth 1 -type f \
        -name "${NAME}.part-*" | wc -l)"

    local duration=$((SECONDS - BACKUP_START))

    echo
    echo "Chunks:    $chunk_count"
    echo "Duration:  $(format_duration "$duration")"

    local upload_status=0

    tg_notify_backup \
        "$BACKUP" \
        "$OUTPUT" \
        "$NAME" \
        "$chunk_count" \
        "$total_size" \
        "$archive_checksum" \
        "$duration" || upload_status=$?

    if is_true "${CLEANUP_AFTER_UPLOAD:-false}"; then
        if [[ "$TELEGRAM_UPLOAD_OK" == 1 ]]; then
            echo
            echo "Removing local chunks (already uploaded to Telegram): $OUTPUT"
            rm -rf -- "$OUTPUT"
            rm -f -- "$LATEST_FILE"
        else
            warn "CLEANUP_AFTER_UPLOAD=true but the Telegram upload did not complete; keeping $OUTPUT"
        fi
    fi

    if ((upload_status != 0)); then
        warn "Backup is complete, but not every chunk reached Telegram."
    fi

    cleanup_old_backups "${RETENTION_COUNT:-0}"
}

# ============================================================
# RESTORE
# ============================================================

restore() {
    local INPUT="${2:-}"

    [[ -n "$INPUT" && -d "$INPUT" ]] \
        || die "Usage: $0 restore /path/to/encrypted-folder"

    INPUT="$(realpath "$INPUT")"

    local NAME
    NAME="$(basename "$INPUT" -encrypted)"

    # The folder may have been renamed (for example after downloading
    # the chunks from Telegram). Infer the archive name from SHA256SUMS.
    if [[ -f "$INPUT/SHA256SUMS" ]]; then
        local first_chunk
        first_chunk="$(awk 'NR == 1 { print $2 }' "$INPUT/SHA256SUMS")"

        if [[ "$first_chunk" == *.part-* ]]; then
            NAME="${first_chunk%%.part-*}"
        fi
    fi

    local TEMP
    TEMP="$(mktemp -d "${WORK_DIR}/docker-restore.XXXXXX")"

    local ARCHIVE
    ARCHIVE="$TEMP/${NAME}.7z"

    local BACKUP
    BACKUP="$TEMP/$NAME"

    cleanup() {
        rm -rf -- "$TEMP"
    }

    trap cleanup EXIT

    echo
    echo "========================================"
    echo " DOCKER MIGRATION RESTORE"
    echo "========================================"

    echo "Input: $INPUT"

    # --------------------------------------------------------
    # 1. Verify chunk checksums
    # --------------------------------------------------------

    echo
    echo "[1/10] Verifying chunk checksums..."

    [[ -f "$INPUT/SHA256SUMS" ]] \
        || die "SHA256SUMS not found."

    (
        cd "$INPUT"
        sha256sum -c SHA256SUMS
    ) || die "Chunk checksum is not valid."

    # --------------------------------------------------------
    # 2. Reconstruct archive
    # --------------------------------------------------------

    echo
    echo "[2/10] Joining chunks..."

    mapfile -t CHUNKS < <(
        find "$INPUT" -maxdepth 1 \
            -type f -name "${NAME}.part-*" \
            | sort
    )

    ((${#CHUNKS[@]})) \
        || die "Archive chunks not found."

    cat "${CHUNKS[@]}" > "$ARCHIVE"

    # --------------------------------------------------------
    # 3. Decrypt archive
    # --------------------------------------------------------

    echo
    echo "[3/10] Decrypting archive..."

    local -a sevenzip_args=(x "$ARCHIVE" "-o$TEMP")

    if [[ -n "${BACKUP_PASSWORD:-}" ]]; then
        sevenzip_args+=("-p${BACKUP_PASSWORD}")
        unset BACKUP_PASSWORD
    fi

    "$SEVENZIP" "${sevenzip_args[@]}" \
        || die "Decryption failed."

    [[ -d "$BACKUP" ]] \
        || die "Backup folder not found."

    # --------------------------------------------------------
    # 4. Verify backup content
    # --------------------------------------------------------

    echo
    echo "[4/10] Verifying backup contents..."

    [[ -f "$BACKUP/SHA256SUMS" ]] \
        || die "Backup SHA256SUMS not found."

    (
        cd "$BACKUP"
        sha256sum -c SHA256SUMS
    ) || die "Backup checksum is not valid."

    # --------------------------------------------------------
    # 5. Destructive operation confirmation
    # --------------------------------------------------------

    echo
    echo "========================================"
    echo " RESTORE WARNING"
    echo "========================================"

    echo "The following operations will:"
    echo "1. Stop all running containers."
    echo "2. Overwrite source Compose directories."
    echo "3. Delete the contents of destination named volumes."
    echo "4. Overwrite source bind mount directories."
    echo "5. Restore server configurations."

    echo
    echo "Make sure the destination VPS is prepared."

    confirm "Continue with restore?"

    # --------------------------------------------------------
    # 6. Stop all containers
    # --------------------------------------------------------

    echo
    echo "[5/10] Stopping all containers..."

    docker ps -q | while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        docker stop -t 60 "$id"
    done

    # --------------------------------------------------------
    # 7. Restore configurations
    # --------------------------------------------------------

    echo
    echo "[6/10] Restoring server configurations..."

    for archive in "$BACKUP"/config/*.tar.gz; do

        [[ -f "$archive" ]] || continue

        tar -xzf "$archive" -C /
    done

    # --------------------------------------------------------
    # 8. Restore Compose projects
    # --------------------------------------------------------

    echo
    echo "[7/10] Restore Compose projects..."

    if [[ -f "$BACKUP/compose/projects.tsv" ]]; then

        while IFS=$'\t' read -r encoded filename encoded_config encoded_project; do

            [[ -n "$encoded" && -n "$filename" ]] || continue

            local target
            target="$(decode "$encoded")"

            [[ "$target" == /* && "$target" != "/" ]] \
                || die "Invalid Compose path: $target"

            [[ -f "$BACKUP/compose/$filename" ]] \
                || die "Compose archive not found: $filename"

            echo "Restore Compose: $target"

            mkdir -p "$target"

            find "$target" -mindepth 1 -maxdepth 1 \
                -exec rm -rf -- {} +

            tar -xzf "$BACKUP/compose/$filename" \
                -C "$target"

        done < "$BACKUP/compose/projects.tsv"
    fi

    # --------------------------------------------------------
    # 9. Restore Docker images
    # --------------------------------------------------------

    echo
    echo "[8/10] Restore Docker images..."

    if [[ -f "$BACKUP/images/all-images.tar" ]]; then

        docker load -i "$BACKUP/images/all-images.tar"

    fi

    # --------------------------------------------------------
    # Restore named volumes
    # --------------------------------------------------------

    echo
    echo "Restore named volumes..."

    for archive in "$BACKUP"/volumes/*.tar.gz; do

        [[ -f "$archive" ]] || continue

        local volume
        volume="$(basename "$archive" .tar.gz)"

        if ! docker volume inspect "$volume" >/dev/null 2>&1; then
            docker volume create "$volume" >/dev/null
        fi

        local mountpoint
        mountpoint="$(docker volume inspect \
            --format '{{.Mountpoint}}' "$volume")"

        [[ -n "$mountpoint" && "$mountpoint" != "/" && -d "$mountpoint" ]] \
            || die "Invalid volume mountpoint: $volume"

        echo "Restore volume: $volume"

        find "$mountpoint" -mindepth 1 -maxdepth 1 \
            -exec rm -rf -- {} +

        tar -xzf "$archive" -C "$mountpoint"

    done

    # --------------------------------------------------------
    # Restore bind mounts
    # --------------------------------------------------------

    echo
    echo "Restore bind mounts..."

    if [[ -f "$BACKUP/bind-mounts/manifest.tsv" ]]; then

        while IFS=$'\t' read -r encoded filename; do

            [[ -n "$encoded" && -n "$filename" ]] || continue

            local target
            target="$(decode "$encoded")"

            [[ "$target" == /* && "$target" != "/" ]] \
                || die "Invalid bind mount path: $target"

            [[ -f "$BACKUP/bind-mounts/$filename" ]] \
                || die "Bind mount archive not found: $filename"

            local parent
            parent="$(dirname "$target")"

            mkdir -p "$parent"

            echo "Restore bind mount: $target"

            rm -rf -- "$target"

            tar -xzf "$BACKUP/bind-mounts/$filename" \
                -C "$parent"

        done < "$BACKUP/bind-mounts/manifest.tsv"
    fi

    # --------------------------------------------------------
    # 10. Start Compose projects
    # --------------------------------------------------------

    echo
    echo "[9/10] Starting Compose projects..."

    if [[ -f "$BACKUP/compose/projects.tsv" ]]; then

        while IFS=$'\t' read -r encoded filename encoded_config encoded_project; do

            [[ -n "$encoded" ]] || continue

            local target
            target="$(decode "$encoded")"

            local config_files
            config_files="$(decode "$encoded_config")"

            local project
            project="$(decode "$encoded_project")"

            [[ -d "$target" ]] \
                || die "Compose directory not found: $target"

            local -a compose_args=()

            if [[ -n "$project" && "$project" != "<no value>" ]]; then
                compose_args+=(-p "$project")
            fi

            if [[ -n "$config_files" && "$config_files" != "<no value>" ]]; then

                IFS=',' read -ra CONFIG_ARRAY <<< "$config_files"

                for config in "${CONFIG_ARRAY[@]}"; do

                    [[ -f "$config" ]] \
                        || die "Compose file not found: $config"

                    compose_args+=(-f "$config")
                done
            fi

            echo "Starting Compose: $target"

            (
                cd "$target"
                docker compose "${compose_args[@]}" up -d
            ) || die "Failed to start Compose: $target"

        done < "$BACKUP/compose/projects.tsv"
    fi

    # --------------------------------------------------------
    # PostgreSQL readiness
    # --------------------------------------------------------

    echo
    echo "Waiting for PostgreSQL..."

    if [[ -f "$BACKUP/databases/containers.txt" ]]; then

        while IFS= read -r c; do

            [[ -n "$c" ]] || continue

            local ready=0

            for attempt in $(seq 1 60); do

                if docker inspect "$c" >/dev/null 2>&1 &&
                    docker exec "$c" sh -lc \
                    'pg_isready -U "${POSTGRES_USER:-postgres}"' \
                    >/dev/null 2>&1; then

                    ready=1
                    break
                fi

                sleep 2
            done

            [[ "$ready" == 1 ]] \
                || die "PostgreSQL is not ready: $c"

            echo "PostgreSQL $c: READY"

        done < "$BACKUP/databases/containers.txt"
    fi

    # --------------------------------------------------------
    # Final
    # --------------------------------------------------------

    echo
    echo "[10/10] Restore completed."

    echo
    echo "========================================"
    echo " RESTORE COMPLETE"
    echo "========================================"

    echo
    echo "Containers:"
    docker ps -a

    echo
    echo "Volumes:"
    docker volume ls

    echo
    echo "PostgreSQL SQL fallback:"
    echo "$BACKUP/databases/"

    echo
    echo "Notes:"
    echo "- PostgreSQL is not re-imported."
    echo "- Data is restored through volumes/bind mounts."
    echo "- SQL dump is available as a fallback."
    echo "- Custom networks and standalone containers"
    echo "  require additional reconstruction."

    local duration=$((SECONDS - RESTORE_START))

    echo
    echo "Duration: $(format_duration "$duration")"

    tg_notify_restore "$INPUT" "$duration"
}

# ============================================================
# RESTORE FROM TELEGRAM
# ============================================================

# Download the encrypted chunks listed in a Telegram manifest, then hand
# the folder to the normal restore flow. The manifest is a small tab
# separated file produced by the backup:
#
#   name        docker-migration-YYYYMMDD-HHMMSS
#   complete    1
#   file        <chunk name> <size> <sha256> <file_id> <file_unique_id> <message_id>
restore_telegram() {
    local SOURCE="${2:-}"
    local MANIFEST=""
    local MANIFEST_TMP=""

    [[ "$TELEGRAM_ENABLED" == 1 ]] \
        || die "Telegram is not configured. Fill in ${ENV_FILE} first."

    if [[ -n "$SOURCE" && -f "$SOURCE" ]]; then
        MANIFEST="$SOURCE"
    elif [[ -n "$SOURCE" ]]; then
        MANIFEST_TMP="$(mktemp "${WORK_DIR}/telegram-manifest.XXXXXX")"
        MANIFEST="$MANIFEST_TMP"

        echo "Downloading manifest from Telegram: $SOURCE"
        tg_download_file "$SOURCE" "$MANIFEST" \
            || die "Failed to download the manifest from Telegram."
    else
        MANIFEST="$(find "$WORK_DIR" -maxdepth 1 -type f \
            -name '*-telegram-manifest.tsv' \
            -printf '%T@\t%p\n' 2>/dev/null \
            | sort -nr \
            | head -n 1 \
            | cut -f2- || true)"

        [[ -n "$MANIFEST" ]] \
            || die "Usage: $0 restore-telegram /path/to/manifest.tsv|telegram-file-id"

        echo "Using latest local manifest: $MANIFEST"
    fi

    [[ -r "$MANIFEST" ]] \
        || die "Manifest is not readable: $MANIFEST"

    local NAME=""
    local COMPLETE=""

    local -a F_NAMES=()
    local -a F_SIZES=()
    local -a F_SHAS=()
    local -a F_IDS=()

    local key a b c d e f
    while IFS=$'\t' read -r key a b c d e f || [[ -n "$key" ]]; do
        case "$key" in
            '' | '#'*) continue ;;
            name) NAME="$a" ;;
            complete) COMPLETE="$a" ;;
            file)
                [[ -n "$a" && -n "$d" ]] \
                    || die "Invalid file entry in manifest: $MANIFEST"

                F_NAMES+=("$a")
                F_SIZES+=("$b")
                F_SHAS+=("$c")
                F_IDS+=("$d")
                ;;
        esac
    done < "$MANIFEST"

    if [[ -n "$MANIFEST_TMP" ]]; then
        rm -f -- "$MANIFEST_TMP"
    fi

    [[ -n "$NAME" ]] \
        || die "Invalid manifest: backup name is missing."

    [[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "Invalid backup name in manifest: $NAME"

    [[ -z "$COMPLETE" || "$COMPLETE" == 1 ]] \
        || die "Manifest is incomplete: the Telegram upload did not finish."

    ((${#F_NAMES[@]})) \
        || die "Invalid manifest: no files listed."

    local TARGET_DIR="${WORK_DIR}/${NAME}-encrypted"

    mkdir -p -- "$TARGET_DIR"
    chmod 700 "$TARGET_DIR"

    echo
    echo "Downloading ${#F_NAMES[@]} file(s) from Telegram..."
    echo "Target: $TARGET_DIR"

    local i fname fsize fsha file_id dest actual_size actual_sha
    for i in "${!F_NAMES[@]}"; do
        fname="${F_NAMES[$i]}"
        fsize="${F_SIZES[$i]}"
        fsha="${F_SHAS[$i]}"
        file_id="${F_IDS[$i]}"

        [[ "$fname" == "$(basename "$fname")" &&
            "$fname" != "." && "$fname" != ".." ]] \
            || die "Unsafe file name in manifest: $fname"

        dest="${TARGET_DIR}/${fname}"

        # Allow re-running a partial restore: keep files that already
        # match the checksum from the manifest.
        if [[ -f "$dest" && -n "$fsha" ]]; then
            actual_sha="$(sha256sum "$dest" | awk '{print $1}')"

            if [[ "$actual_sha" == "$fsha" ]]; then
                echo "Skip (already downloaded): $fname"
                continue
            fi
        fi

        echo "Download: $fname"

        tg_download_file "$file_id" "$dest" \
            || die "Failed to download: $fname"

        if [[ -n "$fsize" ]]; then
            actual_size="$(stat -c %s "$dest")"

            ((actual_size == fsize)) \
                || die "Size mismatch for ${fname}: ${actual_size} != ${fsize}"
        fi

        if [[ -n "$fsha" ]]; then
            actual_sha="$(sha256sum "$dest" | awk '{print $1}')"

            [[ "$actual_sha" == "$fsha" ]] \
                || die "Checksum mismatch for: $fname"
        fi
    done

    echo
    echo "All files downloaded and verified."
    echo "Downloaded files are kept in: $TARGET_DIR"

    restore restore "$TARGET_DIR"
}

# ============================================================
# ENTRY POINT
# ============================================================

usage() {
    local script
    script="$(basename "$0")"

    cat <<EOF
Docker Migration Manager

Usage:
  ${script} backup [chunk-size]
  ${script} restore /path/to/encrypted-folder
  ${script} restore-telegram [manifest.tsv|telegram-file-id]
  ${script} telegram-test
  ${script} install-service
  ${script} uninstall-service

Config:
  ${ENV_FILE}

Examples:
  ${script} backup 45m
  ${script} restore /root/docker-migration-xxx-encrypted
  ${script} restore-telegram
  ${script} restore-telegram /root/docker-migration-xxx-telegram-manifest.tsv
EOF
}

init_telegram
trap 'on_error "$?" "$LINENO"' ERR

case "$MODE" in

    backup)
        require_root
        require_commands
        CHUNK_SIZE="${2:-$CHUNK_SIZE}"
        BACKUP_START=$SECONDS
        backup
        ;;

    restore)
        require_root
        require_commands
        RESTORE_START=$SECONDS
        restore "$@"
        ;;

    restore-telegram)
        require_root
        require_commands
        RESTORE_START=$SECONDS
        restore_telegram "$@"
        ;;

    telegram-test)
        [[ "$TELEGRAM_ENABLED" == 1 ]] \
            || die "Telegram is not configured. Fill in ${ENV_FILE} first."

        tg_send_message "$(
            printf '%s\n' \
                "✅ <b>Telegram bot is active</b>" \
                "" \
                "<b>Host:</b> $(tg_escape "$(uname -n)")" \
                "<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S %Z')" \
                "<b>Script:</b> <code>$(tg_escape "${SCRIPT_DIR}/$(basename "$0")")</code>"
        )" || die "Failed to send the test message to Telegram."

        echo "Test message sent to Telegram successfully."
        ;;

    install-service)
        require_root
        install_service
        ;;

    uninstall-service)
        require_root
        uninstall_service
        ;;

    -h | --help | help)
        usage
        ;;

    *)
        usage
        exit 1
        ;;

esac
