#!/usr/bin/env bash
#
# SLBCK - SaguaroLocalBackup
# Simple, robust, per-database MySQL/MariaDB & PostgreSQL backup tool.
#
# Run 'slbck-setup' (or 'slbck' with no arguments) for the interactive menu.
#
# Commands:
#   slbck setup    - interactive configuration wizard (writes config + cron)
#   slbck backup   - run full backup now (service check, dump, retention, remote, mail)
#   slbck restore  - interactive restore of one database (local or remote backups)
#   slbck check    - database service check only
#   slbck send     - (re)send local backups to remote (rsync/sftp)
#   slbck status   - show config, cron, disk usage, last log lines
#   slbck test-mail- send a test e-mail
#
VERSION="1.9.0"
set -u

CONFIG_DIR="/etc/slbck"
CONFIG="$CONFIG_DIR/slbck.conf"
LOG_FILE="/var/log/slbck.log"
LOCK_FILE="/var/run/slbck.lock"
CRON_FILE="/etc/cron.d/slbck"
SELF="/usr/local/bin/slbck"

# ---------------------------------------------------------------- defaults --
OWNER=""                    # customer/owner name, shown as "Klijent:" in mail
DB_ENGINE="auto"            # auto | mysql | mariadb | postgresql
BACKUP_DIR="/var/backups/slbck"
RETENTION_DAYS="3"          # keep last N daily backup folders locally
CRON_HOUR="3"               # 1..6 (backup runs at HH:00)
MAIL_ENABLED="no"           # yes | no
MAIL_TO=""
MAIL_FROM=""                # empty = slbck@<hostname>
MAIL_ON="always"            # always | error
REMOTE_ENABLED="no"         # yes | no
REMOTE_METHOD="rsync"       # rsync | sftp
REMOTE_HOST=""
REMOTE_PORT="22"
REMOTE_USER=""
REMOTE_PATH=""
# Subfolder on the remote. Built-in default is EMPTY (none) so configs from
# older versions keep their remote path unchanged; the setup wizard suggests
# "auto" (= short hostname) for new setups so servers can share one target.
REMOTE_SUBDIR=""
SSH_KEY=""                  # optional private key path
MYSQL_USER=""               # empty = socket auth (root)
MYSQL_PASS=""

# Secondary target (Phase 2): local NAS via rsync/SSH. Receives the daily
# dump folders (DBs + config archives); with SCOPE=all also the data folders.
SECONDARY_ENABLED="no"
SECONDARY_HOST=""
SECONDARY_PORT="22"
SECONDARY_USER=""
SECONDARY_PATH=""           # e.g. /volume1/backup/slbck (must exist on NAS)
SECONDARY_SUBDIR="auto"     # auto = short hostname, empty = none, or custom
SECONDARY_SSH_KEY=""
SECONDARY_SCOPE="db"        # db = dumps+archives only | all = + data folders
MIN_FREE_MB="500"           # abort backup if less than this (or 2x last backup) free
ENCRYPT_ENABLED="no"        # yes = gpg AES256 symmetric encryption of dumps
ENCRYPT_PASSPHRASE=""       # min 12 chars; ALSO STORE IT IN YOUR PASSWORD MANAGER
VERIFY_ENABLED="yes"        # weekly automatic restore test
VERIFY_DAY="7"              # 1=Mon .. 7=Sun (day when restore test runs)

# Folder backup:
# - ARCHIVE (small folders, e.g. /etc): daily tar.gz stored WITH the DB dumps,
#   so it gets the same retention, mirror, encryption and verify.
# - MIRROR (big folders, e.g. /var/www): rsynced DIRECTLY to the remote server,
#   never stored locally. History comes from Storage Box snapshots.
# Health check after each backup: DB + web services running, app URLs alive
HEALTH_ENABLED="yes"
HEALTH_SERVICES="auto"      # auto = detect apache2/nginx/httpd, or explicit list
HEALTH_URLS=""              # space separated URLs, expect HTTP 2xx/3xx

# Extra options appended to every remote rsync (tuning per server, optional)
RSYNC_EXTRA_OPTS=""

ARCHIVE_DIRS=""             # space separated, e.g. "/etc /root"
# Patterns excluded from ARCHIVE tars (caches would bloat daily archives)
ARCHIVE_EXCLUDES=".cache .nvm .npm .composer node_modules"
FOLDERS_ENABLED="no"        # yes = mirror folders from folders.conf to remote
FOLDERS_MAX_GB="50"         # warn in mail when a mirrored folder exceeds this
FOLDERS_DELETE="no"         # no  = SAFE sync: only add/update on remote, never delete
                            # yes = true mirror: files deleted locally are
                            #       deleted on remote too (snapshots keep history)
FOLDERS_FILE="$CONFIG_DIR/folders.conf"
FOLDER_EXCLUDES_FILE="$CONFIG_DIR/folder-excludes.conf"
# Folders too big for the cloud: synced ONLY to the secondary NAS
FOLDERS_NAS_FILE="$CONFIG_DIR/folders-nas.conf"

[ -f "$CONFIG" ] && . "$CONFIG"

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
TODAY="$(date +%F)"
REPORT=""
ERRORS=0
WARNINGS=0
START_EPOCH=0
REMOTE_RESULT=""
SECONDARY_RESULT=""

# ---------------------------------------------------------------- helpers ---
log() {
    local line="[$(date '+%F %T')] $*"
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
    echo "$line"
}

report() { REPORT="${REPORT}$*"$'\n'; }

fail() { ERRORS=$((ERRORS+1)); log "ERROR: $*"; report "GREŠKA: $*"; }

warn() { WARNINGS=$((WARNINGS+1)); log "WARNING: $*"; report "UPOZORENJE: $*"; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "SLBCK must run as root." >&2
        exit 1
    fi
}

run_as_postgres() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u postgres -- "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u postgres "$@"
    else
        su -s /bin/sh postgres -c "$(printf '%q ' "$@")"
    fi
}

send_mail() {
    local subject="$1" body="$2"
    [ "$MAIL_ENABLED" = "yes" ] || return 0
    [ -n "$MAIL_TO" ] || { log "Mail enabled but MAIL_TO is empty."; return 1; }
    local from="${MAIL_FROM:-slbck@$HOSTNAME_FQDN}"
    if [ -x /usr/sbin/sendmail ] || command -v msmtp >/dev/null 2>&1; then
        local mta="/usr/sbin/sendmail"
        command -v msmtp >/dev/null 2>&1 && [ ! -x /usr/sbin/sendmail ] && mta="msmtp"
        printf 'From: %s\nTo: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
            "$from" "$MAIL_TO" "$subject" "$body" | $mta -t
    elif command -v mailx >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        printf '%s\n' "$body" | mailx -s "$subject" ${MAIL_TO//,/ }
    elif command -v mail >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        printf '%s\n' "$body" | mail -s "$subject" ${MAIL_TO//,/ }
    else
        log "No mail transport found - run 'slbck setup' to install one (msmtp)."
        return 1
    fi
}

has_mail_transport() {
    [ -x /usr/sbin/sendmail ] && return 0
    command -v msmtp >/dev/null 2>&1 && return 0
    command -v mailx >/dev/null 2>&1 && return 0
    command -v mail  >/dev/null 2>&1 && return 0
    return 1
}

pkg_install() {
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@"
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y "$@"
    else
        echo "No supported package manager found (apt/dnf/yum/zypper)." >&2
        return 1
    fi
}

# Install and configure msmtp as a lightweight SMTP-relay mail transport.
mail_install_wizard() {
    echo
    echo "No mail transport found on this server."
    ask "Install and configure msmtp (SMTP relay)? (yes/no)" "yes"
    [ "$REPLY" = "yes" ] || { echo "Skipped - mail will NOT work until an MTA is installed."; return 1; }

    local smtp_host smtp_port smtp_user smtp_pass
    ask "SMTP relay host (e.g. smtp.gmail.com or your relay)" ""
    smtp_host="$REPLY"
    ask "SMTP port" "587"
    smtp_port="$REPLY"
    ask "SMTP username (empty = no auth)" ""
    smtp_user="$REPLY"
    smtp_pass=""
    if [ -n "$smtp_user" ]; then
        read -r -s -p "SMTP password: " smtp_pass; echo
    fi
    ask "Mail FROM address" "${MAIL_FROM:-slbck@$HOSTNAME_FQDN}"
    MAIL_FROM="$REPLY"

    echo "Installing msmtp..."
    if command -v apt-get >/dev/null 2>&1; then
        pkg_install msmtp msmtp-mta || return 1
    else
        # RHEL family: msmtp comes from EPEL
        pkg_install msmtp || { echo "Install failed - on RHEL/Alma enable EPEL first (dnf install epel-release)."; return 1; }
    fi

    local trust_file="/etc/ssl/certs/ca-certificates.crt"
    [ -f "$trust_file" ] || trust_file="/etc/pki/tls/certs/ca-bundle.crt"

    cat > /etc/msmtprc <<EOF
# Written by SLBCK setup $(date '+%F %T')
defaults
tls on
tls_trust_file $trust_file
logfile /var/log/msmtp.log

account slbck
host $smtp_host
port $smtp_port
from $MAIL_FROM
EOF
    if [ -n "$smtp_user" ]; then
        cat >> /etc/msmtprc <<EOF
auth on
user $smtp_user
password $smtp_pass
EOF
    fi
    echo "account default : slbck" >> /etc/msmtprc
    chmod 600 /etc/msmtprc
    echo "msmtp configured (/etc/msmtprc). Test with: slbck test-mail"
}

# --------------------------------------------------------- engine handling --
detect_engine() {
    # 'mariadb' is a first-class alias - MariaDB uses the mysql toolchain
    case "$DB_ENGINE" in
        mysql|mariadb) echo "mysql"; return ;;
        postgresql)    echo "postgresql"; return ;;
    esac
    local svc
    for svc in mysql mysqld mariadb; do
        systemctl is-active --quiet "$svc" 2>/dev/null && { echo "mysql"; return; }
    done
    if systemctl is-active --quiet postgresql 2>/dev/null \
       || systemctl list-units --type=service --state=active 2>/dev/null | grep -q 'postgresql'; then
        echo "postgresql"; return
    fi
    command -v mysqldump >/dev/null 2>&1 && { echo "mysql"; return; }
    command -v pg_dump   >/dev/null 2>&1 && { echo "postgresql"; return; }
    echo "none"
}

service_check() {
    local engine="$1" svc
    case "$engine" in
        mysql)
            for svc in mysql mysqld mariadb; do
                systemctl is-active --quiet "$svc" 2>/dev/null && { log "Service check OK: $svc is active."; return 0; }
            done
            fail "MySQL/MariaDB service is NOT running."  # covers mysql, mysqld, mariadb units
            return 1 ;;
        postgresql)
            if systemctl is-active --quiet postgresql 2>/dev/null \
               || systemctl list-units --type=service --state=active 2>/dev/null | grep -q 'postgresql'; then
                log "Service check OK: postgresql is active."; return 0
            fi
            fail "PostgreSQL service is NOT running."
            return 1 ;;
        *)  fail "No supported database engine found on this server."
            return 1 ;;
    esac
}

# ------------------------------------------------------- encryption layer ---
# Dumps are always plain gzipped SQL first; with ENCRYPT_ENABLED=yes the
# verified gzip is additionally wrapped in gpg AES256 (file ext .sql.gz.gpg).
dump_ext() {
    if [ "$ENCRYPT_ENABLED" = "yes" ]; then echo "sql.gz.gpg"; else echo "sql.gz"; fi
}

gpg_check() {
    [ "$ENCRYPT_ENABLED" = "yes" ] || return 0
    if ! command -v gpg >/dev/null 2>&1; then
        fail "Encryption is enabled but gpg is not installed (apt-get install gnupg)."
        return 1
    fi
    if [ "${#ENCRYPT_PASSPHRASE}" -lt 12 ]; then
        fail "ENCRYPT_PASSPHRASE is shorter than 12 characters."
        return 1
    fi
}

# finalize_dump <tmp-gzip-file> <final-file>: gzip integrity test, then
# encrypt or rename. Never leaves a half-written file under the final name.
finalize_dump() {
    local tmp="$1" out="$2"
    gzip -t "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    if [ "$ENCRYPT_ENABLED" = "yes" ]; then
        if gpg --batch --yes --quiet --symmetric --cipher-algo AES256 \
               --pinentry-mode loopback \
               --passphrase-file <(printf '%s' "$ENCRYPT_PASSPHRASE") \
               -o "$out" "$tmp" 2>>"$LOG_FILE"; then
            rm -f "$tmp"
        else
            rm -f "$tmp" "$out"
            return 1
        fi
    else
        mv "$tmp" "$out"
    fi
}

# decrypt_stream <file>: plain SQL on stdout, whatever the file format is
decrypt_stream() {
    case "$1" in
        *.gpg)
            gpg --batch --quiet --decrypt --pinentry-mode loopback \
                --passphrase-file <(printf '%s' "$ENCRYPT_PASSPHRASE") \
                "$1" 2>>"$LOG_FILE" | gunzip -c ;;
        *)  gunzip -c "$1" ;;
    esac
}

# integrity_test <file>: verify archive (and decryption) without restoring
integrity_test() {
    case "$1" in
        *.gpg)
            ( set -o pipefail
              gpg --batch --quiet --decrypt --pinentry-mode loopback \
                  --passphrase-file <(printf '%s' "$ENCRYPT_PASSPHRASE") \
                  "$1" 2>/dev/null | gzip -t 2>/dev/null ) ;;
        *)  gzip -t "$1" 2>/dev/null ;;
    esac
}

# ------------------------------------------------------------ mysql layer ---
MYSQL_CNF=""
mysql_auth_setup() {
    MYSQL_CNF=""
    if [ -n "$MYSQL_USER" ]; then
        MYSQL_CNF="$(mktemp /tmp/slbck.XXXXXX.cnf)"
        chmod 600 "$MYSQL_CNF"
        printf '[client]\nuser=%s\npassword=%s\n' "$MYSQL_USER" "$MYSQL_PASS" > "$MYSQL_CNF"
    fi
}
mysql_auth_cleanup() { [ -n "$MYSQL_CNF" ] && rm -f "$MYSQL_CNF"; MYSQL_CNF=""; }
mysql_cmd()     { if [ -n "$MYSQL_CNF" ]; then mysql --defaults-extra-file="$MYSQL_CNF" "$@"; else mysql "$@"; fi; }
mysqldump_cmd() { if [ -n "$MYSQL_CNF" ]; then mysqldump --defaults-extra-file="$MYSQL_CNF" "$@"; else mysqldump "$@"; fi; }

mysql_list_dbs() {
    mysql_cmd --skip-column-names -e 'SHOW DATABASES' 2>/dev/null \
        | grep -Ev '^(information_schema|performance_schema|sys)$'
}

mysql_dump_db() {
    local db="$1" out="$2"
    mysqldump_cmd --single-transaction --quick --routines --triggers --events \
        --databases "$db" 2>>"$LOG_FILE" | gzip > "$out.tmp"
    local rc=("${PIPESTATUS[@]}")
    if [ "${rc[0]}" -ne 0 ] || [ "${rc[1]}" -ne 0 ]; then rm -f "$out.tmp"; return 1; fi
    finalize_dump "$out.tmp" "$out"
}

# ------------------------------------------------------- postgresql layer ---
pg_list_dbs() {
    run_as_postgres psql -At -c "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname" 2>/dev/null
}

pg_dump_db() {
    local db="$1" out="$2"
    run_as_postgres pg_dump --create --clean --if-exists "$db" 2>>"$LOG_FILE" | gzip > "$out.tmp"
    local rc=("${PIPESTATUS[@]}")
    if [ "${rc[0]}" -ne 0 ] || [ "${rc[1]}" -ne 0 ]; then rm -f "$out.tmp"; return 1; fi
    finalize_dump "$out.tmp" "$out"
}

pg_dump_globals() {
    local out="$1"
    run_as_postgres pg_dumpall --globals-only 2>>"$LOG_FILE" | gzip > "$out.tmp"
    local rc=("${PIPESTATUS[@]}")
    if [ "${rc[0]}" -ne 0 ] || [ "${rc[1]}" -ne 0 ]; then rm -f "$out.tmp"; return 1; fi
    finalize_dump "$out.tmp" "$out"
}

# ------------------------------------------------------------ safety checks -
# Abort early if the disk can't hold another backup: require at least
# 2x the size of the last backup day, and never less than MIN_FREE_MB.
check_disk_space() {
    local free_mb last_dir last_mb=0 req_mb
    free_mb="$(df -Pm "$BACKUP_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
    [ -n "$free_mb" ] || { warn "Could not determine free disk space."; return 0; }
    last_dir="$(ls -1d "$BACKUP_DIR"/????-??-?? 2>/dev/null | tail -1)"
    [ -n "$last_dir" ] && last_mb="$(du -sm "$last_dir" 2>/dev/null | cut -f1)"
    req_mb=$(( last_mb * 2 ))
    [ "$req_mb" -lt "$MIN_FREE_MB" ] && req_mb="$MIN_FREE_MB"
    if [ "$free_mb" -lt "$req_mb" ]; then
        fail "Nedovoljno prostora na disku: ${free_mb} MB slobodno, potrebno ${req_mb} MB. Backup prekinut."
        return 1
    fi
    log "Disk space OK: ${free_mb} MB free (required: ${req_mb} MB)"
}

# Warn if a dump is suspiciously small: near-empty, or <50% of the same
# database's dump from the previous backup day (catches silent failures).
PREV_DIR=""
sanity_check_size() {
    local db="$1" f="$2" new_b prev_f prev_b
    new_b="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    if [ "$new_b" -lt 200 ]; then
        warn "Dump baze '$db' je sumnjivo malen (${new_b} B)."
        return 0
    fi
    [ -n "$PREV_DIR" ] || return 0
    prev_f="$(ls -1 "$PREV_DIR/$db".sql.gz* 2>/dev/null | head -1)"
    [ -n "$prev_f" ] || return 0
    prev_b="$(stat -c %s "$prev_f" 2>/dev/null || echo 0)"
    if [ "$prev_b" -gt 0 ] && [ "$new_b" -lt $((prev_b / 2)) ]; then
        warn "Dump baze '$db' je manji od 50% jučerašnjeg (${new_b} vs ${prev_b} B) - provjeriti."
    fi
}

# --------------------------------------------------------------- retention --
apply_retention() {
    local cutoff dir name
    cutoff="$(date -d "-$((RETENTION_DAYS - 1)) days" +%F)"
    for dir in "$BACKUP_DIR"/????-??-??; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        if [[ "$name" < "$cutoff" ]]; then
            rm -rf "$dir"
            log "Retention: removed old backup $name"
        fi
    done
}

# ------------------------------------------------------------------ remote --
# Shared SSH options for all remote transfers. aes128-gcm is the fastest
# cipher on AES-NI CPUs; the comma list keeps fallbacks for older sshd.
ssh_base_opts() {
    local o="-p $REMOTE_PORT -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    o="$o -c aes128-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-ctr"
    [ -n "$SSH_KEY" ] && o="$o -i $SSH_KEY"
    echo "$o"
}

# Effective remote path: REMOTE_SUBDIR keeps each server in its own folder
# when multiple servers share one target (e.g. one Hetzner Storage Box).
remote_full_path() {
    case "$REMOTE_SUBDIR" in
        auto) echo "$REMOTE_PATH/$(hostname -s)" ;;
        "")   echo "$REMOTE_PATH" ;;
        *)    echo "$REMOTE_PATH/$REMOTE_SUBDIR" ;;
    esac
}

remote_send() {
    [ "$REMOTE_ENABLED" = "yes" ] || return 0
    REMOTE_RESULT="GREŠKA"
    if [ -z "$REMOTE_HOST" ] || [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_PATH" ]; then
        fail "Vanjski backup server je uključen, ali nije konfiguriran (host/user/path)."
        return 1
    fi
    local ssh_opts
    ssh_opts="$(ssh_base_opts)"
    local rpath
    rpath="$(remote_full_path)"

    case "$REMOTE_METHOD" in
        rsync)
            if ! command -v rsync >/dev/null 2>&1; then fail "rsync is not installed."; return 1; fi
            # Mirror local backup dir (local retention == remote retention).
            # Protect from --delete: /folders (belongs to folders_mirror) and
            # /.ssh + /.zfs - when REMOTE_PATH is the login home (e.g. Hetzner
            # subaccount base dir), deleting .ssh would wipe authorized_keys
            # and lock us out.
            # shellcheck disable=SC2086
            if rsync -az --delete --exclude='/folders' --exclude='/.ssh' --exclude='/.zfs' \
                $RSYNC_EXTRA_OPTS -e "ssh $ssh_opts" \
                "$BACKUP_DIR/" "$REMOTE_USER@$REMOTE_HOST:$rpath/" >>"$LOG_FILE" 2>&1; then
                log "Remote sync OK (rsync -> $REMOTE_HOST:$rpath)"
                REMOTE_RESULT="OK"
            else
                fail "Slanje na vanjski backup server nije uspjelo (detalji: $LOG_FILE)."
                return 1
            fi ;;
        sftp)
            local batch
            batch="$(mktemp /tmp/slbck.XXXXXX.sftp)"
            {
                echo "-mkdir $REMOTE_PATH"
                echo "-mkdir $rpath"
                echo "-mkdir $rpath/$TODAY"
                for f in "$BACKUP_DIR/$TODAY"/*; do
                    [ -f "$f" ] && echo "put $f $rpath/$TODAY/"
                done
            } > "$batch"
            # shellcheck disable=SC2086
            if sftp $ssh_opts -b "$batch" "$REMOTE_USER@$REMOTE_HOST" >>"$LOG_FILE" 2>&1; then
                log "Remote sync OK (sftp -> $REMOTE_HOST:$rpath/$TODAY)"
                REMOTE_RESULT="OK"
                rm -f "$batch"
            else
                rm -f "$batch"
                fail "Slanje na vanjski backup server nije uspjelo (detalji: $LOG_FILE)."
                return 1
            fi ;;
        *)  fail "Unknown REMOTE_METHOD: $REMOTE_METHOD" ; return 1 ;;
    esac
}

# Pull backups FROM the remote server into the local backup dir (for restore).
remote_pull() {
    if [ "$REMOTE_ENABLED" != "yes" ] || [ -z "$REMOTE_HOST" ]; then
        echo "Remote is not configured - nothing to pull."
        return 1
    fi
    local ssh_opts
    ssh_opts="$(ssh_base_opts)"
    local rpath
    rpath="$(remote_full_path)"
    mkdir -p "$BACKUP_DIR"
    echo "Pulling backups from $REMOTE_USER@$REMOTE_HOST:$rpath ..."
    case "$REMOTE_METHOD" in
        rsync)
            rsync -az -e "ssh $ssh_opts" \
                "$REMOTE_USER@$REMOTE_HOST:$rpath/" "$BACKUP_DIR/" ;;
        sftp)
            local batch
            batch="$(mktemp /tmp/slbck.XXXXXX.sftp)"
            printf 'get -r %s/* %s/\n' "$rpath" "$BACKUP_DIR" > "$batch"
            # shellcheck disable=SC2086
            sftp $ssh_opts -b "$batch" "$REMOTE_USER@$REMOTE_HOST"
            local rc=$?
            rm -f "$batch"
            return $rc ;;
        *)  echo "Unknown REMOTE_METHOD: $REMOTE_METHOD"; return 1 ;;
    esac
}

# ----------------------------------------------------------------- folders --
# ARCHIVE mode: small folders (e.g. /etc) tar-gzipped daily into the same
# dated dir as the DB dumps - inherits retention, mirror, encryption, verify.
archive_folders() {
    local dest="$1" d name out aext rc
    [ -n "$ARCHIVE_DIRS" ] || return 0
    aext="tar.gz"
    [ "$ENCRYPT_ENABLED" = "yes" ] && aext="tar.gz.gpg"
    for d in $ARCHIVE_DIRS; do
        if [ ! -d "$d" ]; then
            warn "Folder za arhivu '$d' ne postoji - preskočen."
            continue
        fi
        name="$(echo "${d#/}" | tr '/' '-')"
        out="$dest/_files-${name}.${aext}"
        local exargs=() p
        for p in $ARCHIVE_EXCLUDES; do exargs+=(--exclude="$p"); done
        tar -C / "${exargs[@]}" -czf "$out.tmp" "${d#/}" 2>>"$LOG_FILE"
        rc=$?
        # tar exit 1 = "file changed while reading" - acceptable for live dirs
        if [ "$rc" -le 1 ] && finalize_dump "$out.tmp" "$out"; then
            log "Folder archive OK: $d -> $(basename "$out")"
            report "  OK   $d ($(du -h "$out" | cut -f1))"
        else
            rm -f "$out.tmp"
            fail "Arhiva foldera '$d' nije uspjela."
        fi
    done
}

# MIRROR mode: big folders rsynced DIRECTLY to the remote (never stored
# locally). Point-in-time history comes from Storage Box snapshots.
folders_mirror() {
    [ "$FOLDERS_ENABLED" = "yes" ] || return 0
    if [ "$REMOTE_ENABLED" != "yes" ] || [ "$REMOTE_METHOD" != "rsync" ]; then
        warn "Sync foldera zahtijeva remote rsync - preskočen."
        return 1
    fi
    if [ ! -f "$FOLDERS_FILE" ]; then
        warn "Sync foldera je uključen, ali $FOLDERS_FILE ne postoji."
        return 1
    fi
    local ssh_opts rbase dirs=() dir name size_mb ex_opt=() scaffold
    ssh_opts="$(ssh_base_opts)"
    rbase="$(remote_full_path)"

    while IFS= read -r dir; do
        case "$dir" in ""|\#*) continue ;; esac
        dirs+=("$dir")
    done < "$FOLDERS_FILE"
    if [ "${#dirs[@]}" -eq 0 ]; then
        warn "Sync foldera je uključen, ali $FOLDERS_FILE nema niti jedan folder."
        return 1
    fi
    [ -f "$FOLDER_EXCLUDES_FILE" ] && ex_opt=(--exclude-from="$FOLDER_EXCLUDES_FILE")

    # pre-create the remote dir tree via an empty local scaffold (works on
    # restricted shells like Hetzner Storage Box)
    scaffold="$(mktemp -d /tmp/slbck.XXXXXX)"
    for dir in "${dirs[@]}"; do
        mkdir -p "$scaffold/folders/$(echo "${dir#/}" | tr '/' '-')"
    done
    rsync -a -e "ssh $ssh_opts" "$scaffold/" \
        "$REMOTE_USER@$REMOTE_HOST:$rbase/" >>"$LOG_FILE" 2>&1
    rm -rf "$scaffold"

    # Source folders are only ever READ. Remote deletion happens only with
    # the explicit FOLDERS_DELETE=yes opt-in; default is add/update only.
    local del_opt=()
    [ "$FOLDERS_DELETE" = "yes" ] && del_opt=(--delete)
    report "Podaci (sync na vanjski backup server, bez brisanja):"
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            warn "Folder za sync '$dir' ne postoji - preskočen."
            continue
        fi
        name="$(echo "${dir#/}" | tr '/' '-')"
        size_mb="$(du -sm "$dir" 2>/dev/null | cut -f1)"
        if [ "${size_mb:-0}" -gt $((FOLDERS_MAX_GB * 1024)) ]; then
            warn "Folder '$dir' ima ${size_mb} MB (limit ${FOLDERS_MAX_GB} GB) - provjeriti što je naraslo."
        fi
        # shellcheck disable=SC2086
        if rsync -az "${del_opt[@]}" "${ex_opt[@]}" $RSYNC_EXTRA_OPTS -e "ssh $ssh_opts" \
            "$dir/" "$REMOTE_USER@$REMOTE_HOST:$rbase/folders/$name/" >>"$LOG_FILE" 2>&1; then
            log "Folder mirror OK: $dir (${size_mb} MB)"
            if [ "$size_mb" -ge 1024 ]; then
                report "  OK   $dir ($((size_mb / 1024)).$(( (size_mb % 1024) * 10 / 1024 )) GB)"
            else
                report "  OK   $dir (${size_mb} MB)"
            fi
        else
            fail "Sync foldera '$dir' nije uspio (detalji: $LOG_FILE)."
        fi
    done
}

# --------------------------------------------------------------- secondary --
# Phase 2: local NAS as a second copy (3-2-1). Mirrors the daily dump dirs;
# with SECONDARY_SCOPE=all also syncs the data folders from folders.conf.
secondary_ssh_opts() {
    local o="-p $SECONDARY_PORT -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    o="$o -c aes128-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-ctr"
    [ -n "$SECONDARY_SSH_KEY" ] && o="$o -i $SECONDARY_SSH_KEY"
    echo "$o"
}

secondary_full_path() {
    case "$SECONDARY_SUBDIR" in
        auto) echo "$SECONDARY_PATH/$(hostname -s)" ;;
        "")   echo "$SECONDARY_PATH" ;;
        *)    echo "$SECONDARY_PATH/$SECONDARY_SUBDIR" ;;
    esac
}

secondary_send() {
    [ "$SECONDARY_ENABLED" = "yes" ] || return 0
    SECONDARY_RESULT="GREŠKA"
    if [ -z "$SECONDARY_HOST" ] || [ -z "$SECONDARY_USER" ] || [ -z "$SECONDARY_PATH" ]; then
        fail "Sekundarni backup je uključen, ali nije konfiguriran (host/user/path)."
        return 1
    fi
    local ssh_opts spath
    ssh_opts="$(secondary_ssh_opts)"
    spath="$(secondary_full_path)"
    # shellcheck disable=SC2086
    if rsync -az --delete --exclude='/folders' --exclude='/.ssh' --exclude='/.zfs' \
        $RSYNC_EXTRA_OPTS -e "ssh $ssh_opts" \
        "$BACKUP_DIR/" "$SECONDARY_USER@$SECONDARY_HOST:$spath/" >>"$LOG_FILE" 2>&1; then
        log "Secondary sync OK (rsync -> $SECONDARY_HOST:$spath)"
        SECONDARY_RESULT="OK"
    else
        fail "Slanje na sekundarni backup (NAS) nije uspjelo (detalji: $LOG_FILE)."
        return 1
    fi

    if [ "$SECONDARY_SCOPE" = "all" ] && [ "$FOLDERS_ENABLED" = "yes" ] && [ -f "$FOLDERS_FILE" ]; then
        local dir name ex_opt=() del_opt=() scaffold dirs=()
        [ -f "$FOLDER_EXCLUDES_FILE" ] && ex_opt=(--exclude-from="$FOLDER_EXCLUDES_FILE")
        [ "$FOLDERS_DELETE" = "yes" ] && del_opt=(--delete)
        while IFS= read -r dir; do
            case "$dir" in ""|\#*) continue ;; esac
            [ -d "$dir" ] && dirs+=("$dir")
        done < "$FOLDERS_FILE"
        [ "${#dirs[@]}" -gt 0 ] || return 0
        scaffold="$(mktemp -d /tmp/slbck.XXXXXX)"
        for dir in "${dirs[@]}"; do
            mkdir -p "$scaffold/folders/$(echo "${dir#/}" | tr '/' '-')"
        done
        rsync -a -e "ssh $ssh_opts" "$scaffold/" \
            "$SECONDARY_USER@$SECONDARY_HOST:$spath/" >>"$LOG_FILE" 2>&1
        rm -rf "$scaffold"
        for dir in "${dirs[@]}"; do
            name="$(echo "${dir#/}" | tr '/' '-')"
            # shellcheck disable=SC2086
            if rsync -az "${del_opt[@]}" "${ex_opt[@]}" $RSYNC_EXTRA_OPTS -e "ssh $ssh_opts" \
                "$dir/" "$SECONDARY_USER@$SECONDARY_HOST:$spath/folders/$name/" >>"$LOG_FILE" 2>&1; then
                log "Secondary folder sync OK: $dir"
            else
                warn "Sekundarni sync foldera '$dir' nije uspio (detalji: $LOG_FILE)."
            fi
        done
    fi

    # NAS-only folders (too big for the cloud) - from folders-nas.conf,
    # synced whenever the secondary target is enabled
    if [ -f "$FOLDERS_NAS_FILE" ]; then
        local ndir nname nsize ndirs=() nex=() ndel=() nscaffold
        [ -f "$FOLDER_EXCLUDES_FILE" ] && nex=(--exclude-from="$FOLDER_EXCLUDES_FILE")
        [ "$FOLDERS_DELETE" = "yes" ] && ndel=(--delete)
        while IFS= read -r ndir; do
            case "$ndir" in ""|\#*) continue ;; esac
            if [ ! -d "$ndir" ]; then
                warn "NAS-only folder '$ndir' ne postoji - preskočen."
                continue
            fi
            ndirs+=("$ndir")
        done < "$FOLDERS_NAS_FILE"
        if [ "${#ndirs[@]}" -gt 0 ]; then
            nscaffold="$(mktemp -d /tmp/slbck.XXXXXX)"
            for ndir in "${ndirs[@]}"; do
                mkdir -p "$nscaffold/folders/$(echo "${ndir#/}" | tr '/' '-')"
            done
            rsync -a -e "ssh $ssh_opts" "$nscaffold/" \
                "$SECONDARY_USER@$SECONDARY_HOST:$spath/" >>"$LOG_FILE" 2>&1
            rm -rf "$nscaffold"
            report ""
            report "Podaci (samo NAS, preveliki za cloud):"
            for ndir in "${ndirs[@]}"; do
                nname="$(echo "${ndir#/}" | tr '/' '-')"
                nsize="$(du -sm "$ndir" 2>/dev/null | cut -f1)"
                # shellcheck disable=SC2086
                if rsync -az "${ndel[@]}" "${nex[@]}" $RSYNC_EXTRA_OPTS -e "ssh $ssh_opts" \
                    "$ndir/" "$SECONDARY_USER@$SECONDARY_HOST:$spath/folders/$nname/" >>"$LOG_FILE" 2>&1; then
                    log "NAS-only folder sync OK: $ndir (${nsize} MB)"
                    report "  OK   $ndir (${nsize} MB)"
                else
                    fail "NAS-only sync foldera '$ndir' nije uspio (detalji: $LOG_FILE)."
                fi
            done
        fi
    fi
}

# ----------------------------------------------------------------- restore --
cmd_restore() {
    need_root
    local engine
    engine="$(detect_engine)"

    echo "=============================================="
    echo " SLBCK restore - $HOSTNAME_FQDN (engine: $engine)"
    echo "=============================================="

    if [ "$REMOTE_ENABLED" = "yes" ]; then
        ask "Pull latest backups from remote server first? (yes/no)" "no"
        if [ "$REPLY" = "yes" ]; then
            remote_pull || { echo "Remote pull failed."; return 1; }
        fi
    fi

    # 1) pick a day
    local days=()
    local d
    for d in "$BACKUP_DIR"/????-??-??; do
        [ -d "$d" ] && days+=("$(basename "$d")")
    done
    if [ "${#days[@]}" -eq 0 ]; then
        echo "No backups found in $BACKUP_DIR."
        return 1
    fi
    echo
    echo "Available backup days:"
    local i=1
    for d in "${days[@]}"; do echo "  $i) $d"; i=$((i+1)); done
    while :; do
        ask "Choose day" "${#days[@]}"
        [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#days[@]}" ] && break
        echo "Enter a number 1-${#days[@]}."
    done
    local day="${days[$((REPLY-1))]}"

    # 2) pick a database file
    local files=()
    local f
    for f in "$BACKUP_DIR/$day"/*.sql.gz*; do
        [ -f "$f" ] && files+=("$(basename "$f")")
    done
    if [ "${#files[@]}" -eq 0 ]; then
        echo "No dumps found in $BACKUP_DIR/$day."
        return 1
    fi
    echo
    echo "Databases in $day:"
    i=1
    for f in "${files[@]}"; do
        echo "  $i) ${f%%.sql.gz*} ($(du -h "$BACKUP_DIR/$day/$f" | cut -f1))"
        i=$((i+1))
    done
    while :; do
        ask "Choose database" ""
        [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#files[@]}" ] && break
        echo "Enter a number 1-${#files[@]}."
    done
    local file="${files[$((REPLY-1))]}"
    local dbname="${file%%.sql.gz*}"
    local dump="$BACKUP_DIR/$day/$file"

    # 3) verify archive (and decryption), confirm, restore
    case "$dump" in *.gpg)
        if [ -z "$ENCRYPT_PASSPHRASE" ]; then
            echo "ERROR: dump is GPG-encrypted but ENCRYPT_PASSPHRASE is not set in $CONFIG."
            return 1
        fi ;;
    esac
    if ! integrity_test "$dump"; then
        echo "ERROR: $dump is corrupted (integrity test failed)."
        return 1
    fi

    echo
    echo "!!! WARNING: this will OVERWRITE database '$dbname' with the $day backup."
    read -r -p "Type the database name to confirm: " confirm
    if [ "$confirm" != "$dbname" ]; then
        echo "Confirmation does not match - restore cancelled."
        return 1
    fi

    log "RESTORE started: $dbname from $day (by $(logname 2>/dev/null || echo root))"
    case "$engine" in
        mysql)
            mysql_auth_setup
            if decrypt_stream "$dump" | mysql_cmd; then
                log "RESTORE OK: $dbname from $day"
                echo "Restore finished OK: $dbname"
            else
                log "RESTORE FAILED: $dbname from $day"
                echo "Restore FAILED - see $LOG_FILE"
                mysql_auth_cleanup
                return 1
            fi
            mysql_auth_cleanup ;;
        postgresql)
            # Dumps are made with --create --clean --if-exists: the DB is dropped
            # and recreated. Active connections must be closed first.
            if [ "$dbname" != "_globals" ]; then
                run_as_postgres psql -d postgres -c \
                    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$dbname' AND pid <> pg_backend_pid();" >/dev/null 2>&1
            fi
            decrypt_stream "$dump" | run_as_postgres psql -d postgres
            local prc=("${PIPESTATUS[@]}")
            if [ "${prc[0]}" -eq 0 ] && [ "${prc[1]}" -eq 0 ]; then
                log "RESTORE OK: $dbname from $day"
                echo "Restore finished OK: $dbname"
            else
                log "RESTORE FAILED: $dbname from $day"
                echo "Restore FAILED - see $LOG_FILE"
                return 1
            fi ;;
        *)  echo "No supported database engine found."; return 1 ;;
    esac
}

# ------------------------------------------------------------------ health --
# After the backup: are the services this server exists for still running?
# DB engine + web server (auto-detected or HEALTH_SERVICES list) + optional
# application URLs (HEALTH_URLS, expect HTTP 2xx/3xx). Failures are ERRORS -
# the morning mail doubles as a monitoring report.
health_check() {
    [ "$HEALTH_ENABLED" = "yes" ] || return 0
    report "Provjera servisa:"
    local engine svc ok services="" url code
    engine="$(detect_engine)"

    case "$engine" in
        mysql)
            ok=no
            for svc in mysql mysqld mariadb; do
                systemctl is-active --quiet "$svc" 2>/dev/null && { ok=yes; break; }
            done
            if [ "$ok" = "yes" ]; then report "  OK   baza podataka ($svc)"
            else fail "Servis baze (MySQL/MariaDB) NE RADI!"; fi ;;
        postgresql)
            if systemctl is-active --quiet postgresql 2>/dev/null; then
                report "  OK   baza podataka (postgresql)"
            else fail "Servis baze (PostgreSQL) NE RADI!"; fi ;;
    esac

    if [ "$HEALTH_SERVICES" = "auto" ]; then
        for svc in apache2 nginx httpd; do
            systemctl is-enabled --quiet "$svc" 2>/dev/null && services="$services $svc"
        done
    else
        services="$HEALTH_SERVICES"
    fi
    for svc in $services; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            report "  OK   $svc"
        else
            fail "Servis '$svc' NE RADI!"
        fi
    done

    for url in $HEALTH_URLS; do
        code="$(curl -ksL -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null)"
        case "$code" in
            2*|3*) report "  OK   $url (HTTP $code)" ;;
            *)     fail "Stranica $url vratila HTTP ${code:-000}!" ;;
        esac
    done
}

# Standalone 'slbck health' - prints the result, mails only on failure
cmd_health() {
    need_root
    REPORT="SLBCK provjera servisa - $HOST_SHORT ($(date '+%F %T'))"$'\n\n'
    ERRORS=0; WARNINGS=0
    HEALTH_ENABLED="yes"
    health_check
    printf '%s\n' "$REPORT"
    if [ "$ERRORS" -gt 0 ]; then
        send_mail "[SLBCK] $HOST_SHORT HEALTH ERROR - $(date '+%F %H:%M')" "$REPORT"
        return 1
    fi
}

# ------------------------------------------------------------------ verify --
# Restore test with confirmation: checks archive integrity of every dump in
# the newest backup day, then REALLY restores one database into a temporary
# DB (slbck_verify), counts the tables and drops it again. The result goes
# into the report/mail - proof that backups are actually restorable.
verify_run() {
    local engine day dir f files=() bad=0
    engine="$(detect_engine)"
    dir="$(ls -1d "$BACKUP_DIR"/????-??-?? 2>/dev/null | tail -1)"
    if [ -z "$dir" ]; then
        fail "Restore test: nema backupa u $BACKUP_DIR."
        return 1
    fi
    day="$(basename "$dir")"
    report "Restore test (backup: $day):"
    gpg_check || return 1

    for f in "$dir"/*.sql.gz* "$dir"/*.tar.gz*; do
        [ -f "$f" ] || continue
        files+=("$f")
        if ! integrity_test "$f"; then
            fail "Restore test: arhiva $(basename "$f") NE PROLAZI provjeru integriteta!"
            bad=$((bad+1))
        fi
    done
    if [ "${#files[@]}" -eq 0 ]; then
        fail "Restore test: nema dump datoteka u $dir."
        return 1
    fi
    report "  Integritet arhiva: $(( ${#files[@]} - bad ))/${#files[@]} OK"

    # pick the smallest real dump for the restore test (fast); skip _globals
    # and the system 'mysql' DB - prefer an application database
    local pick="" pick_b=0 b
    for f in "${files[@]}"; do
        case "$(basename "$f")" in _globals.*|_files-*|mysql.sql.gz*) continue ;; esac
        b="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        if [ "$b" -ge 5120 ] && { [ -z "$pick" ] || [ "$b" -lt "$pick_b" ]; }; then
            pick="$f"; pick_b="$b"
        fi
    done
    if [ -z "$pick" ]; then
        for f in "${files[@]}"; do
            case "$(basename "$f")" in _globals.*|_files-*) continue ;; esac
            b="$(stat -c %s "$f" 2>/dev/null || echo 0)"
            if [ "$b" -gt "$pick_b" ]; then pick="$f"; pick_b="$b"; fi
        done
    fi
    if [ -z "$pick" ]; then
        warn "Restore test: nema prikladne baze za test."
        return 1
    fi

    local vdb="slbck_verify" dbname tables=""
    dbname="$(basename "$pick")"; dbname="${dbname%%.sql.gz*}"
    log "Verify: restore test of '$dbname' into temporary DB '$vdb'..."

    case "$engine" in
        mysql)
            mysql_auth_setup
            mysql_cmd -e "DROP DATABASE IF EXISTS \`$vdb\`; CREATE DATABASE \`$vdb\`" 2>>"$LOG_FILE"
            decrypt_stream "$pick" | sed -E '/^CREATE DATABASE /d; /^USE /d' | mysql_cmd "$vdb" 2>>"$LOG_FILE"
            local rc=("${PIPESTATUS[@]}")
            tables="$(mysql_cmd --skip-column-names -e \
                "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$vdb'" 2>/dev/null)"
            mysql_cmd -e "DROP DATABASE IF EXISTS \`$vdb\`" 2>>"$LOG_FILE"
            mysql_auth_cleanup
            if [ "${rc[0]}" -ne 0 ] || [ "${rc[2]}" -ne 0 ] || [ -z "$tables" ] || [ "$tables" -eq 0 ]; then
                fail "Restore test baze '$dbname' NIJE USPIO (vraćeno tablica: ${tables:-0})."
                return 1
            fi ;;
        postgresql)
            run_as_postgres psql -d postgres -c "DROP DATABASE IF EXISTS $vdb" >/dev/null 2>>"$LOG_FILE"
            run_as_postgres psql -d postgres -c "CREATE DATABASE $vdb" >/dev/null 2>>"$LOG_FILE"
            decrypt_stream "$pick" \
                | sed -E "/^DROP DATABASE /d; /^CREATE DATABASE /d; /^ALTER DATABASE /d; s/^\\\\connect .*/\\\\connect $vdb/" \
                | run_as_postgres psql -d postgres >/dev/null 2>>"$LOG_FILE"
            local prc=("${PIPESTATUS[@]}")
            tables="$(run_as_postgres psql -d "$vdb" -At -c \
                "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')" 2>/dev/null)"
            run_as_postgres psql -d postgres -c "DROP DATABASE IF EXISTS $vdb" >/dev/null 2>>"$LOG_FILE"
            if [ "${prc[0]}" -ne 0 ] || [ "${prc[2]}" -ne 0 ] || [ -z "$tables" ] || [ "$tables" -eq 0 ]; then
                fail "Restore test baze '$dbname' NIJE USPIO (vraćeno tablica: ${tables:-0})."
                return 1
            fi ;;
        *)  fail "Restore test: nema podržanog database enginea."; return 1 ;;
    esac

    log "Verify OK: '$dbname' restored into temp DB, $tables tables."
    report "  OK   baza '$dbname' vraćena u testnu bazu ($tables tablica), testna baza obrisana"
    [ "$bad" -eq 0 ]
}

# Standalone 'slbck verify' - always sends a confirmation mail
cmd_verify() {
    need_root
    REPORT="SLBCK restore test - $HOST_SHORT ($(date '+%F %T'))"$'\n\n'
    ERRORS=0; WARNINGS=0
    verify_run
    local subject
    if [ "$ERRORS" -eq 0 ]; then
        subject="[SLBCK] $HOST_SHORT restore test OK - $(date '+%F %H:%M')"
    else
        subject="[SLBCK] $HOST_SHORT restore test ERROR - $(date '+%F %H:%M')"
    fi
    REPORT="${REPORT}"$'\n'"--"$'\n'"Backup by Saguaro :)"
    send_mail "$subject" "$REPORT"
    echo "----------------------------------------"
    printf '%s\n' "$REPORT"
    [ "$ERRORS" -eq 0 ]
}

# ------------------------------------------------------------------ update --
cmd_update() {
    need_root
    local src=""
    [ -f "$CONFIG_DIR/source_dir" ] && src="$(cat "$CONFIG_DIR/source_dir")"
    if [ -z "$src" ] || [ ! -d "$src/.git" ]; then
        echo "Source repo not found. Clone and reinstall:"
        echo "  git clone https://github.com/saguarogit-cmzk/SLBCK.git && cd SLBCK && sudo ./install.sh"
        return 1
    fi
    echo "Installed version: v$VERSION"
    git -C "$src" pull --ff-only || { echo "git pull failed - fix manually in $src"; return 1; }
    bash "$src/install.sh"
    echo "Now installed: $("$SELF" version)"
}

# ------------------------------------------------------------------ backup --
cmd_backup() {
    need_root
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "Another SLBCK run is in progress, exiting."
        exit 1
    fi

    local start engine dest db size ext count=0 engine_label
    ext="$(dump_ext)"
    START_EPOCH="$(date +%s)"
    start="$(date '+%F %T')"
    log "===== SLBCK backup started on $HOSTNAME_FQDN ====="

    engine="$(detect_engine)"
    if ! service_check "$engine"; then
        finish_backup "$engine"
        return 1
    fi
    case "$engine" in
        mysql) engine_label="MySQL/MariaDB" ;;
        *)     engine_label="PostgreSQL" ;;
    esac

    if ! gpg_check; then
        finish_backup "$engine"
        return 1
    fi

    mkdir -p "$BACKUP_DIR"
    if ! check_disk_space; then
        finish_backup "$engine"
        return 1
    fi

    # remember the newest previous day for size sanity checks
    PREV_DIR="$(ls -1d "$BACKUP_DIR"/????-??-?? 2>/dev/null | grep -v "/$TODAY\$" | tail -1)"

    dest="$BACKUP_DIR/$TODAY"
    mkdir -p "$dest"
    chmod 700 "$BACKUP_DIR" "$dest"

    report "Baze ($engine_label):"
    local dbs=""
    case "$engine" in
        mysql)
            mysql_auth_setup
            dbs="$(mysql_list_dbs)"
            if [ -z "$dbs" ]; then
                fail "Ne mogu dohvatiti popis baza (provjeriti pristup/socket auth)."
            fi
            for db in $dbs; do
                if mysql_dump_db "$db" "$dest/${db}.${ext}"; then
                    size="$(du -h "$dest/${db}.${ext}" | cut -f1)"
                    log "Dumped $db ($size)"
                    report "  OK   $db ($size)"
                    sanity_check_size "$db" "$dest/${db}.${ext}"
                    count=$((count+1))
                else
                    fail "Dump baze '$db' nije uspio."
                fi
            done
            mysql_auth_cleanup ;;
        postgresql)
            dbs="$(pg_list_dbs)"
            if [ -z "$dbs" ]; then
                fail "Ne mogu dohvatiti popis PostgreSQL baza."
            fi
            if pg_dump_globals "$dest/_globals.${ext}"; then
                log "Dumped PostgreSQL globals (roles/tablespaces)"
                report "  OK   _globals (role/tablespaceovi)"
            else
                fail "Dump PostgreSQL globals nije uspio."
            fi
            for db in $dbs; do
                if pg_dump_db "$db" "$dest/${db}.${ext}"; then
                    size="$(du -h "$dest/${db}.${ext}" | cut -f1)"
                    log "Dumped $db ($size)"
                    report "  OK   $db ($size)"
                    sanity_check_size "$db" "$dest/${db}.${ext}"
                    count=$((count+1))
                else
                    fail "Dump baze '$db' nije uspio."
                fi
            done ;;
    esac
    report "  Ukupno: $count baza ($(du -ch "$dest"/*.sql.gz* 2>/dev/null | tail -1 | cut -f1))"

    if [ -n "$ARCHIVE_DIRS" ]; then
        report ""
        report "Konfiguracija (dnevna arhiva uz baze):"
        archive_folders "$dest"
    fi

    # weekly automatic restore test (result goes into the same mail)
    if [ "$VERIFY_ENABLED" = "yes" ] && [ "$(date +%u)" = "$VERIFY_DAY" ] && [ "$count" -gt 0 ]; then
        report ""
        verify_run
    fi

    apply_retention
    remote_send
    if [ "$FOLDERS_ENABLED" = "yes" ]; then
        report ""
        folders_mirror
    fi
    secondary_send

    report ""
    report "Pohrana:"
    report "  Lokalno:  $dest (čuva se zadnjih $RETENTION_DAYS dana)"
    if [ "$REMOTE_ENABLED" = "yes" ]; then
        report "  Vanjski backup server: ${REMOTE_RESULT:-GREŠKA}"
    else
        report "  Vanjski backup server: NIJE KONFIGURIRAN - backup postoji samo na ovom serveru!"
    fi
    if [ "$SECONDARY_ENABLED" = "yes" ]; then
        report "  Sekundarni backup (NAS): ${SECONDARY_RESULT:-GREŠKA}"
    fi

    if [ "$HEALTH_ENABLED" = "yes" ]; then
        report ""
        health_check
    fi

    finish_backup "$engine"
}

finish_backup() {
    local subject status_line header dur dur_str end_hm start_hm
    dur=$(( $(date +%s) - START_EPOCH ))
    dur_str="$((dur / 60))m $((dur % 60))s"
    start_hm="$(date -d "@$START_EPOCH" '+%H:%M' 2>/dev/null || echo '?')"
    end_hm="$(date '+%H:%M')"

    if [ "$ERRORS" -eq 0 ]; then
        status_line="STATUS: OK ($ERRORS grešaka, $WARNINGS upozorenja)"
        if [ "$WARNINGS" -gt 0 ]; then
            subject="[SLBCK] $HOST_SHORT backup OK ($WARNINGS upozorenja) - $(date '+%F %H:%M')"
        else
            subject="[SLBCK] $HOST_SHORT backup OK - $(date '+%F %H:%M')"
        fi
    else
        status_line="STATUS: GREŠKA ($ERRORS grešaka, $WARNINGS upozorenja)"
        subject="[SLBCK] $HOST_SHORT backup ERROR - $(date '+%F %H:%M')"
    fi

    header="SLBCK backup izvještaj"$'\n'
    header+="======================================"$'\n'
    [ -n "$OWNER" ] && header+="Klijent: $OWNER"$'\n'
    header+="Server:  $HOST_SHORT"$'\n'
    header+="Datum:   $TODAY $start_hm -> $end_hm (trajanje: $dur_str)"$'\n\n'
    header+="$status_line"$'\n\n'

    REPORT="${header}${REPORT}"$'\n'"Log: $LOG_FILE"$'\n'"--"$'\n'"Backup by Saguaro :)"

    if [ "$ERRORS" -eq 0 ]; then
        log "===== SLBCK backup finished OK ($WARNINGS warnings) ====="
        # warnings are always mailed, even with MAIL_ON=error
        if [ "$MAIL_ON" = "always" ] || [ "$WARNINGS" -gt 0 ]; then
            send_mail "$subject" "$REPORT"
        fi
    else
        log "===== SLBCK backup finished with $ERRORS error(s) ====="
        send_mail "$subject" "$REPORT"
        exit 1
    fi
}

# ------------------------------------------------------------------- setup --
write_folder_templates() {
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$FOLDERS_FILE" ]; then
        cat > "$FOLDERS_FILE" <<'EOF'
# SLBCK - folders to MIRROR directly to the remote server (rsync, no local
# copy). One ABSOLUTE path per line. Lines starting with # are ignored.
# After editing, test with: slbck backup
#
# Examples:
#/var/www
#/home/data/dokumenti
EOF
        chmod 600 "$FOLDERS_FILE"
        echo "Created $FOLDERS_FILE"
    fi
    if [ ! -f "$FOLDER_EXCLUDES_FILE" ]; then
        cat > "$FOLDER_EXCLUDES_FILE" <<'EOF'
# SLBCK - rsync exclude patterns for folder mirror (one per line).
# Applied to every mirrored folder.
node_modules/
vendor/
sql_dump/
.cache/
cache/
*.tmp
*.swp
storage/logs/
storage/framework/cache/
storage/framework/sessions/
storage/framework/views/
EOF
        chmod 600 "$FOLDER_EXCLUDES_FILE"
        echo "Created $FOLDER_EXCLUDES_FILE"
    fi
}

write_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG" <<EOF
# SLBCK - SaguaroLocalBackup configuration
# Generated by 'slbck setup' on $(date '+%F %T')

# Customer/owner name - shown as "Klijent:" in the mail report
OWNER="$OWNER"

DB_ENGINE="$DB_ENGINE"
BACKUP_DIR="$BACKUP_DIR"
RETENTION_DAYS="$RETENTION_DAYS"
CRON_HOUR="$CRON_HOUR"
MIN_FREE_MB="$MIN_FREE_MB"

# GPG AES256 encryption of dumps - passphrase MUST also live in your
# password manager: without it there is no restore!
ENCRYPT_ENABLED="$ENCRYPT_ENABLED"
ENCRYPT_PASSPHRASE='$ENCRYPT_PASSPHRASE'

# Weekly restore test (1=Mon..7=Sun)
VERIFY_ENABLED="$VERIFY_ENABLED"
VERIFY_DAY="$VERIFY_DAY"

# Health check after each backup (services + application URLs)
HEALTH_ENABLED="$HEALTH_ENABLED"
HEALTH_SERVICES="$HEALTH_SERVICES"
HEALTH_URLS="$HEALTH_URLS"

# Extra rsync options for remote transfers (tuning, optional)
RSYNC_EXTRA_OPTS="$RSYNC_EXTRA_OPTS"

# Folder backup: archive = daily tar.gz with the DB dumps;
# mirror = folders from $FOLDERS_FILE rsynced directly to remote
ARCHIVE_DIRS="$ARCHIVE_DIRS"
ARCHIVE_EXCLUDES="$ARCHIVE_EXCLUDES"
FOLDERS_ENABLED="$FOLDERS_ENABLED"
FOLDERS_MAX_GB="$FOLDERS_MAX_GB"
# no = safe sync (only add/update on remote), yes = true mirror with deletes
FOLDERS_DELETE="$FOLDERS_DELETE"

MAIL_ENABLED="$MAIL_ENABLED"
MAIL_TO="$MAIL_TO"
MAIL_FROM="$MAIL_FROM"
MAIL_ON="$MAIL_ON"

REMOTE_ENABLED="$REMOTE_ENABLED"
REMOTE_METHOD="$REMOTE_METHOD"
REMOTE_HOST="$REMOTE_HOST"
REMOTE_PORT="$REMOTE_PORT"
REMOTE_USER="$REMOTE_USER"
REMOTE_PATH="$REMOTE_PATH"
REMOTE_SUBDIR="$REMOTE_SUBDIR"
SSH_KEY="$SSH_KEY"

# MySQL credentials - leave empty to use socket auth as root (recommended)
MYSQL_USER="$MYSQL_USER"
MYSQL_PASS="$MYSQL_PASS"

# Secondary target (local NAS via rsync/SSH)
SECONDARY_ENABLED="$SECONDARY_ENABLED"
SECONDARY_HOST="$SECONDARY_HOST"
SECONDARY_PORT="$SECONDARY_PORT"
SECONDARY_USER="$SECONDARY_USER"
SECONDARY_PATH="$SECONDARY_PATH"
SECONDARY_SUBDIR="$SECONDARY_SUBDIR"
SECONDARY_SSH_KEY="$SECONDARY_SSH_KEY"
SECONDARY_SCOPE="$SECONDARY_SCOPE"
EOF
    chmod 600 "$CONFIG"
    echo "Config written to $CONFIG"
}

write_cron() {
    cat > "$CRON_FILE" <<EOF
# SLBCK - SaguaroLocalBackup daily database backup
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 $CRON_HOUR * * * root $SELF backup >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
    echo "Cron installed: $CRON_FILE (daily at 0$CRON_HOUR:00)"
}

ask() {  # ask "Question" "default" -> REPLY
    local q="$1" def="$2"
    read -r -p "$q [$def]: " REPLY
    REPLY="${REPLY:-$def}"
}

cmd_setup() {
    need_root
    echo "=============================================="
    echo " SLBCK - SaguaroLocalBackup setup (v$VERSION)"
    echo "=============================================="
    echo

    ask "Owner/klijent (prikazuje se u mail izvještaju)" "$OWNER"
    OWNER="$REPLY"

    local detected
    detected="$(detect_engine)"
    echo "Detected database engine: $detected"
    ask "Database engine (auto/mysql/postgresql)" "auto"
    DB_ENGINE="$REPLY"

    if [ "$detected" = "mysql" ] || [ "$DB_ENGINE" = "mysql" ]; then
        echo
        echo "MySQL auth: leave user EMPTY to use socket auth as root (recommended"
        echo "on Debian/Ubuntu/MariaDB). Otherwise enter a backup user."
        ask "MySQL user (empty = socket auth)" "$MYSQL_USER"
        MYSQL_USER="$REPLY"
        if [ -n "$MYSQL_USER" ]; then
            read -r -s -p "MySQL password: " MYSQL_PASS; echo
        fi
    fi

    echo
    echo "Backup hour (server local time) - backup runs once daily:"
    echo "  1) 01:00   2) 02:00   3) 03:00   4) 04:00   5) 05:00   6) 06:00"
    while :; do
        ask "Choose 1-6" "$CRON_HOUR"
        case "$REPLY" in [1-6]) CRON_HOUR="$REPLY"; break ;; *) echo "Enter a number 1-6." ;; esac
    done

    ask "Local retention - keep last N days" "$RETENTION_DAYS"
    RETENTION_DAYS="$REPLY"
    ask "Local backup directory" "$BACKUP_DIR"
    BACKUP_DIR="$REPLY"

    echo
    echo "GPG encryption (AES256): dumps are encrypted at rest, locally and on"
    echo "the remote server. WITHOUT the passphrase there is NO restore - store"
    echo "it in your password manager as well!"
    ask "Encrypt dumps with GPG? (yes/no)" "$ENCRYPT_ENABLED"
    ENCRYPT_ENABLED="$REPLY"
    if [ "$ENCRYPT_ENABLED" = "yes" ]; then
        if ! command -v gpg >/dev/null 2>&1; then
            echo "Installing gnupg..."
            pkg_install gnupg || { echo "gnupg install failed - encryption disabled."; ENCRYPT_ENABLED="no"; }
        fi
    fi
    if [ "$ENCRYPT_ENABLED" = "yes" ]; then
        local p1 p2
        while :; do
            read -r -s -p "Passphrase (min 12 chars, no single quotes): " p1; echo
            if [ "${#p1}" -lt 12 ]; then echo "Too short - minimum 12 characters."; continue; fi
            case "$p1" in *"'"*) echo "Single quotes are not allowed."; continue ;; esac
            read -r -s -p "Repeat passphrase: " p2; echo
            [ "$p1" = "$p2" ] && { ENCRYPT_PASSPHRASE="$p1"; break; }
            echo "Passphrases do not match, try again."
        done
    fi

    echo
    echo "Health check after each backup: verifies DB and web server services"
    echo "are running; optionally checks application URLs (expects HTTP 2xx/3xx)."
    ask "Health check enabled? (yes/no)" "$HEALTH_ENABLED"
    HEALTH_ENABLED="$REPLY"
    if [ "$HEALTH_ENABLED" = "yes" ]; then
        ask "URLs to check (space separated, empty = none)" "$HEALTH_URLS"
        HEALTH_URLS="$REPLY"
    fi

    echo
    echo "Weekly restore test: SLBCK restores one database into a temporary DB,"
    echo "counts the tables and drops it - proof that backups are restorable."
    while :; do
        ask "Restore test day (1=Mon..7=Sun, 0=off)" "$VERIFY_DAY"
        case "$REPLY" in
            0) VERIFY_ENABLED="no"; break ;;
            [1-7]) VERIFY_ENABLED="yes"; VERIFY_DAY="$REPLY"; break ;;
            *) echo "Enter 0-7." ;;
        esac
    done

    echo
    ask "Send e-mail notifications? (yes/no)" "$MAIL_ENABLED"
    MAIL_ENABLED="$REPLY"
    if [ "$MAIL_ENABLED" = "yes" ]; then
        ask "Mail to (one or more addresses, comma separated)" "$MAIL_TO"
        MAIL_TO="$REPLY"
        ask "Mail from (empty = slbck@$HOSTNAME_FQDN)" "$MAIL_FROM"
        MAIL_FROM="$REPLY"
        ask "Mail on (always/error)" "$MAIL_ON"
        MAIL_ON="$REPLY"
        if ! has_mail_transport; then
            mail_install_wizard || true
        fi
    fi

    echo
    ask "Send backups to a remote server? (yes/no)" "$REMOTE_ENABLED"
    REMOTE_ENABLED="$REPLY"
    if [ "$REMOTE_ENABLED" = "yes" ]; then
        ask "Method (rsync/sftp)" "$REMOTE_METHOD";  REMOTE_METHOD="$REPLY"
        ask "Remote host" "$REMOTE_HOST";            REMOTE_HOST="$REPLY"
        ask "Remote SSH port" "$REMOTE_PORT";        REMOTE_PORT="$REPLY"
        ask "Remote user" "$REMOTE_USER";            REMOTE_USER="$REPLY"
        ask "Remote path" "$REMOTE_PATH";            REMOTE_PATH="$REPLY"
        ask "Subfolder per server (auto = hostname '$(hostname -s)', none = no subfolder)" "${REMOTE_SUBDIR:-auto}"
        REMOTE_SUBDIR="$REPLY"
        [ "$REMOTE_SUBDIR" = "none" ] && REMOTE_SUBDIR=""
        ask "SSH private key (empty = default root key)" "$SSH_KEY"
        SSH_KEY="$REPLY"
        echo "NOTE: key-based SSH auth must already work from this server (ssh-copy-id)."
    fi

    echo
    echo "Sekundarni backup (lokalni NAS preko rsync/SSH) - druga kopija dumpova:"
    ask "Secondary NAS target? (yes/no)" "$SECONDARY_ENABLED"
    SECONDARY_ENABLED="$REPLY"
    if [ "$SECONDARY_ENABLED" = "yes" ]; then
        ask "NAS host/IP" "$SECONDARY_HOST";              SECONDARY_HOST="$REPLY"
        ask "NAS SSH port" "$SECONDARY_PORT";             SECONDARY_PORT="$REPLY"
        ask "NAS user" "$SECONDARY_USER";                 SECONDARY_USER="$REPLY"
        ask "NAS path (mora postojati)" "$SECONDARY_PATH"; SECONDARY_PATH="$REPLY"
        ask "Scope (db = samo dumpovi / all = + data folderi)" "$SECONDARY_SCOPE"
        SECONDARY_SCOPE="$REPLY"
        if [ ! -f "$FOLDERS_NAS_FILE" ]; then
            cat > "$FOLDERS_NAS_FILE" <<'EOF'
# SLBCK - folderi PREVELIKI za cloud: syncaju se SAMO na sekundarni NAS.
# Jedan apsolutni path po retku. Restore: rsync natrag s NAS-a.
#/home/data/veliki-arhiv
EOF
            chmod 600 "$FOLDERS_NAS_FILE"
            echo "Kreiran $FOLDERS_NAS_FILE (za foldere prevelike za cloud)."
        fi
        echo "NOTE: SSH key auth prema NAS-u mora raditi (ssh-copy-id na NAS user)."
    fi

    echo
    echo "Folder backup:"
    echo " - ARCHIVE: small folders (e.g. /etc) get a daily tar.gz stored with"
    echo "   the DB dumps - same retention, mirror, encryption and verify."
    ask "Folders to archive daily (space separated, none = off)" "${ARCHIVE_DIRS:-/etc}"
    ARCHIVE_DIRS="$REPLY"
    [ "$ARCHIVE_DIRS" = "none" ] && ARCHIVE_DIRS=""

    if [ "$REMOTE_ENABLED" = "yes" ] && [ "$REMOTE_METHOD" = "rsync" ]; then
        echo " - MIRROR: big folders (e.g. /var/www) are rsynced DIRECTLY to the"
        echo "   remote server, never stored locally. History = remote snapshots."
        ask "Mirror folders to remote? (yes/no)" "$FOLDERS_ENABLED"
        FOLDERS_ENABLED="$REPLY"
        if [ "$FOLDERS_ENABLED" = "yes" ]; then
            write_folder_templates
            ask "Warn in mail when a folder exceeds N GB" "$FOLDERS_MAX_GB"
            FOLDERS_MAX_GB="$REPLY"
            echo "==> Now list your folders in: $FOLDERS_FILE (one path per line)"
        fi
    fi

    echo
    write_config
    write_cron
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    echo
    echo "Setup done. Test now with:  slbck backup"
    [ "$MAIL_ENABLED" = "yes" ] && echo "Test mail with:             slbck test-mail"
}

# ------------------------------------------------------------- quick setup --
# CLOUD profile for mass rollout: fleet standards are fixed, only the
# per-server answers are asked (~6 questions, 2 minutes per server).
cmd_quick() {
    need_root
    echo "=============================================="
    echo " SLBCK quick setup - CLOUD profil (v$VERSION)"
    echo " Backup ide na Hetzner Storage Box (rsync, port 23)."
    echo "=============================================="
    echo "Standardi flote (fiksno): backup 02:00, retencija $RETENTION_DAYS dana,"
    echo "arhiva /etc + cron + /usr/local/bin, sync foldera bez brisanja,"
    echo "restore test nedjeljom, health check ukljucen, bez enkripcije."
    echo

    ask "Owner/klijent" "$OWNER";                                OWNER="$REPLY"
    ask "Storage Box host (uXXXXXX.your-storagebox.de)" "$REMOTE_HOST"
    REMOTE_HOST="$REPLY"
    ask "Subaccount user (uXXXXXX-subN)" "$REMOTE_USER";         REMOTE_USER="$REPLY"
    ask "Mail za izvjestaje (zarez za vise adresa)" "$MAIL_TO";  MAIL_TO="$REPLY"
    ask "Health URL-ovi (razmak, prazno = bez)" "$HEALTH_URLS";  HEALTH_URLS="$REPLY"
    ask "Folderi za sync na box (razmak, prazno = bez)" "/var/www"
    local sync_dirs="$REPLY"
    [ "$sync_dirs" = "none" ] && sync_dirs=""

    # fleet standards - CLOUD profile
    DB_ENGINE="auto"; CRON_HOUR="2"
    ARCHIVE_DIRS="/etc /var/spool/cron /usr/local/bin"
    MAIL_ENABLED="yes"; MAIL_ON="always"
    VERIFY_ENABLED="yes"; VERIFY_DAY="7"
    HEALTH_ENABLED="yes"; HEALTH_SERVICES="auto"
    REMOTE_ENABLED="yes"; REMOTE_METHOD="rsync"; REMOTE_PORT="23"
    REMOTE_PATH="."; REMOTE_SUBDIR=""; SSH_KEY=""
    ENCRYPT_ENABLED="no"; ENCRYPT_PASSPHRASE=""
    FOLDERS_DELETE="no"

    if [ -n "$sync_dirs" ]; then
        FOLDERS_ENABLED="yes"
        {
            echo "# SLBCK - folderi koji se syncaju na Storage Box (bez brisanja)"
            local d
            for d in $sync_dirs; do echo "$d"; done
        } > "$FOLDERS_FILE"
        chmod 600 "$FOLDERS_FILE"
    else
        FOLDERS_ENABLED="no"
    fi
    write_folder_templates >/dev/null
    write_config
    write_cron
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"

    # SSH key server -> box
    if [ ! -f /root/.ssh/id_ed25519 ]; then
        ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "root@$HOST_SHORT" >/dev/null
        echo "Generiran SSH kljuc /root/.ssh/id_ed25519"
    fi
    echo
    while :; do
        if printf 'pwd\n' | sftp -P "$REMOTE_PORT" -o BatchMode=yes \
             -o StrictHostKeyChecking=accept-new -b - \
             "$REMOTE_USER@$REMOTE_HOST" >/dev/null 2>&1; then
            echo "Veza na Storage Box: OK (kljuc radi)."
            break
        fi
        echo "Kljuc jos NE radi na boxu. Instaliraj ga (treba lozinka subaccounta):"
        echo
        echo "  ssh-copy-id -p $REMOTE_PORT -s -i /root/.ssh/id_ed25519.pub $REMOTE_USER@$REMOTE_HOST"
        echo
        echo "Stariji ssh-copy-id (bez -s opcije, npr. Ubuntu 20.04):"
        echo "  printf 'mkdir .ssh\\nput /root/.ssh/id_ed25519.pub .ssh/authorized_keys\\nchmod 600 .ssh/authorized_keys\\n' | sftp -P $REMOTE_PORT $REMOTE_USER@$REMOTE_HOST"
        echo
        read -r -p "Enter za ponovni test veze, 's' za preskoci: " a
        [ "$a" = "s" ] && break
    done

    echo
    echo "Quick setup gotov. Provjera:  slbck status"
    ask "Pokrenuti prvi backup sada? (yes/no)" "yes"
    [ "$REPLY" = "yes" ] && cmd_backup
}

# ------------------------------------------------------------------ status --
cmd_status() {
    echo "SLBCK v$VERSION on $HOSTNAME_FQDN"
    echo "----------------------------------------"
    if [ -f "$CONFIG" ]; then
        echo "Config:     $CONFIG"
        echo "Owner:      ${OWNER:--}"
        echo "Engine:     $(detect_engine)"
        echo "Backup dir: $BACKUP_DIR ($(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo '-'))"
        echo "Retention:  last $RETENTION_DAYS days"
        echo "Mail:       $MAIL_ENABLED ($MAIL_TO, on=$MAIL_ON)"
        echo "Encryption: $ENCRYPT_ENABLED"
        echo "Verify:     $VERIFY_ENABLED (restore test day: $VERIFY_DAY, 1=Mon..7=Sun)"
        echo "Health:     $HEALTH_ENABLED (services: $HEALTH_SERVICES; urls: ${HEALTH_URLS:-none})"
        echo "Archives:   ${ARCHIVE_DIRS:-none}"
        echo "Mirror:     $FOLDERS_ENABLED ($FOLDERS_FILE, warn > ${FOLDERS_MAX_GB} GB)"
        echo "Remote:     $REMOTE_ENABLED ($REMOTE_METHOD $REMOTE_USER@$REMOTE_HOST:$(remote_full_path))"
        echo "Secondary:  $SECONDARY_ENABLED ($SECONDARY_USER@$SECONDARY_HOST:$(secondary_full_path 2>/dev/null), scope=$SECONDARY_SCOPE)"
    else
        echo "Not configured yet - run: slbck setup"
    fi
    if [ -f "$CRON_FILE" ]; then
        echo "Cron:       $(grep -E '^[0-9]' "$CRON_FILE" | head -1)"
    else
        echo "Cron:       not installed"
    fi
    echo "----------------------------------------"
    echo "Local backups:"
    ls -1 "$BACKUP_DIR" 2>/dev/null | tail -5 | sed 's/^/  /' || echo "  (none)"
    echo "----------------------------------------"
    echo "Last log lines ($LOG_FILE):"
    tail -10 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' || echo "  (no log yet)"
}

# ------------------------------------------------------------------- guide --
cmd_guide() {
    cat <<'EOF'
==========================================================================
 SLBCK - Upute za instalaciju i postavljanje (Ubuntu)
==========================================================================

1) INSTALACIJA (na svakom serveru)
   git clone https://github.com/saguarogit-cmzk/SLBCK.git
   cd SLBCK && sudo ./install.sh
   sudo slbck quick            # CLOUD profil: ~6 pitanja, ostalo automatski
   (sudo slbck-setup = puni izbornik; slbck setup = detaljni wizard)
   Puna dokumentacija: docs/INSTALACIJA.md, docs/RESTORE.md u repou

2) POSTAVLJANJE (izbornik -> 1 Setup)
   Carobnjak pita redom:
   - Engine: ostavi "auto" (sam prepozna MySQL/MariaDB/PostgreSQL)
   - MySQL/MariaDB auth: na Ubuntuu ostavi PRAZNO (socket auth kao root)
   - Sat backupa: 1-6 (01:00-06:00), backup se vrti svaki dan
   - Retencija: koliko dana ostaje lokalno (default 3)
   - GPG enkripcija: opcionalno; passphrase min 12 znakova.
     OBAVEZNO je spremi i u password manager - bez nje nema restora!
   - Restore test: dan u tjednu kad SLBCK sam testira restore
     (default nedjelja); rucno bilo kada: slbck verify
   - Mail: jedna ili vise adresa (zarez); ako server nema mail sustav, setup sam
     instalira i podesi msmtp (treba ti SMTP relay: host/port/user/pass)
   - Remote: yes/no. Ako NEMAS vanjsku lokaciju, backup ostaje samo
     lokalno i mail ce to jasno pisati: [local-only].
   Setup sam zapise /etc/slbck/slbck.conf i cron /etc/cron.d/slbck.

3) VANJSKA LOKACIJA (kad je budes imao)
   Na backup serveru napravi usera i folder, pa s ovog servera:
     sudo ssh-copy-id -i /root/.ssh/id_ed25519 user@backupserver
     (ako root nema kljuc: sudo ssh-keygen -t ed25519)
   Zatim: slbck-setup -> 1 Setup -> Remote: yes (rsync preporuceno).
   rsync mirrora lokalni folder pa remote ima istu retenciju.
   Subfolder "auto" = svaki server pise u svoj hostname folder.

   HETZNER STORAGE BOX: u Robot panelu ukljuci "SSH support" i
   snapshotove, pa: rsync, host uXXXXX.your-storagebox.de, PORT 23,
   user uXXXXX (najbolje sub-account po serveru), path /home/backup.
   Kljuc: ssh-copy-id -p 23 uXXXXX@uXXXXX.your-storagebox.de

4) PRVI TEST (obavezno nakon setupa)
   sudo slbck backup           # rucni backup odmah
   sudo slbck test-mail        # provjeri da mail stize
   sudo slbck status           # config, cron, zadnji logovi

5) RESTORE
   sudo slbck restore          # ili izbornik -> 3
   Bira se dan pa baza; prije prepisivanja moras utipkati ime baze.
   Ako je remote konfiguriran, nudi povlacenje backupa s remote servera.

6) BACKUP FOLDERA (uz baze)
   Dva nacina, biras u setupu:

   a) ARCHIVE - mali folderi (npr. /etc, configi):
      U setupu upisi popis, npr: /etc /root
      Svaki dan nastaje _files-etc.tar.gz u dnevnom folderu uz baze -
      ista retencija, isti mirror na remote, ista enkripcija i verify.
      Restore:  tar xzf _files-etc.tar.gz -C /tmp/restore-etc

   b) MIRROR - veliki folderi (npr. /var/www, dokumenti):
      NIKAD se ne spremaju lokalno - rsync ide direktno na remote u
      <path>/<server>/folders/var-www/. Povijest = snapshotovi
      Storage Boxa (ukljuci ih u Robot panelu!).
      Popis foldera:   /etc/slbck/folders.conf  (jedan path po retku)
      Excludovi:       /etc/slbck/folder-excludes.conf (rsync patterni)
      SIGURNO: izvorni folderi se samo CITAJU; na remoteu se default
      nista ne brise (FOLDERS_DELETE=no) - samo dodaje i azurira.
      Nakon uredivanja testiraj:  slbck backup
      Mail javlja velicinu svakog foldera i WARNING preko FOLDERS_MAX_GB.
      Restore foldera (rucno, natrag s remotea):
        rsync -az -e "ssh -p23" user@host:<path>/<server>/folders/var-www/ /var/www/

7) GDJE JE STO
   Backup:  /var/backups/slbck/YYYY-MM-DD/baza.sql.gz (+ _files-*.tar.gz)
   Folderi: /etc/slbck/folders.conf + folder-excludes.conf (mirror popis)
   Config:  /etc/slbck/slbck.conf   (chmod 600)
   Cron:    /etc/cron.d/slbck
   Log:     /var/log/slbck.log
   Mail:    /etc/msmtprc (ako ga je setup instalirao)
==========================================================================
EOF
}

# -------------------------------------------------------------------- menu --
cmd_menu() {
    need_root
    while :; do
        echo
        echo "=============================================="
        echo " SLBCK - SaguaroLocalBackup v$VERSION"
        echo " $HOSTNAME_FQDN | engine: $(detect_engine)"
        echo "=============================================="
        echo "  1) Setup / configuration (config + cron)"
        echo "  c) Quick setup - CLOUD profil (novi server, ~6 pitanja)"
        echo "  2) Backup now"
        echo "  3) Restore a database"
        echo "  4) Send backups to remote server"
        echo "  5) Status"
        echo "  6) Health check (services + URLs)"
        echo "  7) Test mail"
        echo "  8) Verify / restore test now"
        echo "  9) Update SLBCK from git"
        echo " 10) Upute / install & setup guide"
        echo "  q) Quit"
        read -r -p "Choose: " choice
        case "$choice" in
            1) cmd_setup ;;
            c|C) cmd_quick ;;
            2) cmd_backup ;;
            3) cmd_restore ;;
            4) remote_send; ERRORS=0 ;;
            5) cmd_status ;;
            6) cmd_health; ERRORS=0; WARNINGS=0 ;;
            7) send_mail "[SLBCK] $HOST_SHORT test mail" \
                   "Ovo je SLBCK testna poruka. Ako je čitaš, mail radi."$'\n'"--"$'\n'"Backup by Saguaro :)" \
                   && echo "Test mail sent to $MAIL_TO" ;;
            8) cmd_verify; ERRORS=0; WARNINGS=0 ;;
            9) cmd_update ;;
            10) cmd_guide ;;
            q|Q) exit 0 ;;
            *) echo "Unknown option." ;;
        esac
    done
}

# -------------------------------------------------------------------- main --
# 'slbck-setup' symlink (or plain 'slbck' on a terminal) opens the menu
CMD="${1:-}"
if [ -z "$CMD" ]; then
    case "$(basename "$0")" in
        slbck-setup) CMD="menu" ;;
        *) if [ -t 0 ]; then CMD="menu"; else CMD="help"; fi ;;
    esac
fi

case "$CMD" in
    menu)      cmd_menu ;;
    setup)     cmd_setup ;;
    quick)     cmd_quick ;;
    backup)    cmd_backup ;;
    restore)   cmd_restore ;;
    check)     need_root; service_check "$(detect_engine)" ;;
    health)    cmd_health ;;
    send)      need_root; remote_send; secondary_send; [ "$ERRORS" -eq 0 ] || exit 1 ;;
    pull)      need_root; remote_pull ;;
    status)    cmd_status ;;
    verify)    cmd_verify ;;
    update)    cmd_update ;;
    guide|upute) cmd_guide ;;
    test-mail) send_mail "[SLBCK] $HOST_SHORT test mail" \
                  "Ovo je SLBCK testna poruka. Ako je čitaš, mail radi."$'\n'"--"$'\n'"Backup by Saguaro :)" \
                  && echo "Test mail sent to $MAIL_TO" ;;
    version)   echo "SLBCK v$VERSION" ;;
    help|*)
        cat <<EOF
SLBCK - SaguaroLocalBackup v$VERSION
Usage: slbck <command>   (no command on a terminal = interactive menu)
       slbck-setup       (opens the interactive menu)

  menu        Interactive menu (setup, backup, restore, send, status...)
  quick       Quick setup - CLOUD profil: fleet standards, ~6 questions
  setup       Setup wizard (config + cron, installs mail transport if missing)
  backup      Run backup now (check, dump all DBs, retention, remote, mail)
  restore     Interactive restore of one database (local or pulled from remote)
  verify      Restore test now: integrity of all dumps + real restore of one
              database into a temp DB, with confirmation mail
  update      Update SLBCK from git and reinstall
  health      Health check now: DB + web services + application URLs
  check       Database service check only
  send        (Re)send local backups to remote server
  pull        Pull backups from remote server to local backup dir
  status      Show configuration and recent activity
  guide       Install & setup instructions (hrvatski / step-by-step)
  test-mail   Send a test e-mail
  version     Show version
EOF
        ;;
esac
