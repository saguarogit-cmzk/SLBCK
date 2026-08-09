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
VERSION="1.1.0"
set -u

CONFIG_DIR="/etc/slbck"
CONFIG="$CONFIG_DIR/slbck.conf"
LOG_FILE="/var/log/slbck.log"
LOCK_FILE="/var/run/slbck.lock"
CRON_FILE="/etc/cron.d/slbck"
SELF="/usr/local/bin/slbck"

# ---------------------------------------------------------------- defaults --
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
SSH_KEY=""                  # optional private key path
MYSQL_USER=""               # empty = socket auth (root)
MYSQL_PASS=""

[ -f "$CONFIG" ] && . "$CONFIG"

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
TODAY="$(date +%F)"
REPORT=""
ERRORS=0

# ---------------------------------------------------------------- helpers ---
log() {
    local line="[$(date '+%F %T')] $*"
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
    echo "$line"
}

report() { REPORT="${REPORT}$*"$'\n'; }

fail() { ERRORS=$((ERRORS+1)); log "ERROR: $*"; report "ERROR: $*"; }

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
        printf '%s\n' "$body" | mailx -s "$subject" "$MAIL_TO"
    elif command -v mail >/dev/null 2>&1; then
        printf '%s\n' "$body" | mail -s "$subject" "$MAIL_TO"
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
    gzip -t "$out.tmp" 2>/dev/null || { rm -f "$out.tmp"; return 1; }
    mv "$out.tmp" "$out"
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
    gzip -t "$out.tmp" 2>/dev/null || { rm -f "$out.tmp"; return 1; }
    mv "$out.tmp" "$out"
}

pg_dump_globals() {
    local out="$1"
    run_as_postgres pg_dumpall --globals-only 2>>"$LOG_FILE" | gzip > "$out.tmp"
    local rc=("${PIPESTATUS[@]}")
    if [ "${rc[0]}" -ne 0 ] || [ "${rc[1]}" -ne 0 ]; then rm -f "$out.tmp"; return 1; fi
    mv "$out.tmp" "$out"
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
            report "Retention: removed old backup $name"
        fi
    done
}

# ------------------------------------------------------------------ remote --
remote_send() {
    [ "$REMOTE_ENABLED" = "yes" ] || return 0
    if [ -z "$REMOTE_HOST" ] || [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_PATH" ]; then
        fail "Remote is enabled but REMOTE_HOST/REMOTE_USER/REMOTE_PATH is not set."
        return 1
    fi
    local ssh_opts="-p $REMOTE_PORT -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    [ -n "$SSH_KEY" ] && ssh_opts="$ssh_opts -i $SSH_KEY"

    case "$REMOTE_METHOD" in
        rsync)
            if ! command -v rsync >/dev/null 2>&1; then fail "rsync is not installed."; return 1; fi
            # Mirror local backup dir (local retention == remote retention)
            if rsync -az --delete -e "ssh $ssh_opts" \
                "$BACKUP_DIR/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/" >>"$LOG_FILE" 2>&1; then
                log "Remote sync OK (rsync -> $REMOTE_HOST:$REMOTE_PATH)"
                report "Remote sync OK (rsync -> $REMOTE_HOST:$REMOTE_PATH)"
            else
                fail "rsync to $REMOTE_HOST failed (see $LOG_FILE)."
                return 1
            fi ;;
        sftp)
            local batch
            batch="$(mktemp /tmp/slbck.XXXXXX.sftp)"
            {
                echo "-mkdir $REMOTE_PATH"
                echo "-mkdir $REMOTE_PATH/$TODAY"
                for f in "$BACKUP_DIR/$TODAY"/*.gz; do
                    [ -f "$f" ] && echo "put $f $REMOTE_PATH/$TODAY/"
                done
            } > "$batch"
            # shellcheck disable=SC2086
            if sftp $ssh_opts -b "$batch" "$REMOTE_USER@$REMOTE_HOST" >>"$LOG_FILE" 2>&1; then
                log "Remote sync OK (sftp -> $REMOTE_HOST:$REMOTE_PATH/$TODAY)"
                report "Remote sync OK (sftp -> $REMOTE_HOST:$REMOTE_PATH/$TODAY)"
                rm -f "$batch"
            else
                rm -f "$batch"
                fail "sftp to $REMOTE_HOST failed (see $LOG_FILE)."
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
    local ssh_opts="-p $REMOTE_PORT -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    [ -n "$SSH_KEY" ] && ssh_opts="$ssh_opts -i $SSH_KEY"
    mkdir -p "$BACKUP_DIR"
    echo "Pulling backups from $REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH ..."
    case "$REMOTE_METHOD" in
        rsync)
            rsync -az -e "ssh $ssh_opts" \
                "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/" "$BACKUP_DIR/" ;;
        sftp)
            local batch
            batch="$(mktemp /tmp/slbck.XXXXXX.sftp)"
            printf 'get -r %s/* %s/\n' "$REMOTE_PATH" "$BACKUP_DIR" > "$batch"
            # shellcheck disable=SC2086
            sftp $ssh_opts -b "$batch" "$REMOTE_USER@$REMOTE_HOST"
            local rc=$?
            rm -f "$batch"
            return $rc ;;
        *)  echo "Unknown REMOTE_METHOD: $REMOTE_METHOD"; return 1 ;;
    esac
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
    for f in "$BACKUP_DIR/$day"/*.sql.gz; do
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
        echo "  $i) ${f%.sql.gz} ($(du -h "$BACKUP_DIR/$day/$f" | cut -f1))"
        i=$((i+1))
    done
    while :; do
        ask "Choose database" ""
        [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#files[@]}" ] && break
        echo "Enter a number 1-${#files[@]}."
    done
    local file="${files[$((REPLY-1))]}"
    local dbname="${file%.sql.gz}"
    local dump="$BACKUP_DIR/$day/$file"

    # 3) verify archive, confirm, restore
    if ! gzip -t "$dump" 2>/dev/null; then
        echo "ERROR: $dump is corrupted (gzip test failed)."
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
            if zcat "$dump" | mysql_cmd; then
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
            zcat "$dump" | run_as_postgres psql -d postgres
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

# ------------------------------------------------------------------ backup --
cmd_backup() {
    need_root
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "Another SLBCK run is in progress, exiting."
        exit 1
    fi

    local start engine dest db size count=0
    start="$(date '+%F %T')"
    log "===== SLBCK backup started on $HOSTNAME_FQDN ====="
    report "SLBCK backup report - $HOSTNAME_FQDN"
    report "Started: $start"
    report ""

    engine="$(detect_engine)"
    if ! service_check "$engine"; then
        finish_backup "$engine"
        return 1
    fi
    report "Engine: $engine (service running)"
    report ""

    dest="$BACKUP_DIR/$TODAY"
    mkdir -p "$dest"
    chmod 700 "$BACKUP_DIR" "$dest"

    local dbs=""
    case "$engine" in
        mysql)
            mysql_auth_setup
            dbs="$(mysql_list_dbs)"
            if [ -z "$dbs" ]; then
                fail "Could not list MySQL databases (check credentials / socket auth)."
            fi
            for db in $dbs; do
                if mysql_dump_db "$db" "$dest/${db}.sql.gz"; then
                    size="$(du -h "$dest/${db}.sql.gz" | cut -f1)"
                    log "Dumped $db ($size)"
                    report "  OK   $db ($size)"
                    count=$((count+1))
                else
                    fail "Dump failed for database: $db"
                fi
            done
            mysql_auth_cleanup ;;
        postgresql)
            dbs="$(pg_list_dbs)"
            if [ -z "$dbs" ]; then
                fail "Could not list PostgreSQL databases."
            fi
            if pg_dump_globals "$dest/_globals.sql.gz"; then
                log "Dumped PostgreSQL globals (roles/tablespaces)"
                report "  OK   _globals (roles/tablespaces)"
            else
                fail "Dump of PostgreSQL globals failed."
            fi
            for db in $dbs; do
                if pg_dump_db "$db" "$dest/${db}.sql.gz"; then
                    size="$(du -h "$dest/${db}.sql.gz" | cut -f1)"
                    log "Dumped $db ($size)"
                    report "  OK   $db ($size)"
                    count=$((count+1))
                else
                    fail "Dump failed for database: $db"
                fi
            done ;;
    esac

    report ""
    report "Databases dumped: $count"
    report "Local folder: $dest ($(du -sh "$dest" 2>/dev/null | cut -f1))"
    report ""

    apply_retention
    remote_send

    finish_backup "$engine"
}

finish_backup() {
    local subject
    report ""
    report "Finished: $(date '+%F %T')"
    if [ "$ERRORS" -eq 0 ]; then
        subject="[SLBCK] OK - backup on $HOSTNAME_FQDN ($TODAY)"
        log "===== SLBCK backup finished OK ====="
        [ "$MAIL_ON" = "always" ] && send_mail "$subject" "$REPORT"
    else
        subject="[SLBCK] ERROR - backup on $HOSTNAME_FQDN ($TODAY) - $ERRORS error(s)"
        log "===== SLBCK backup finished with $ERRORS error(s) ====="
        send_mail "$subject" "$REPORT"
        exit 1
    fi
}

# ------------------------------------------------------------------- setup --
write_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG" <<EOF
# SLBCK - SaguaroLocalBackup configuration
# Generated by 'slbck setup' on $(date '+%F %T')

DB_ENGINE="$DB_ENGINE"
BACKUP_DIR="$BACKUP_DIR"
RETENTION_DAYS="$RETENTION_DAYS"
CRON_HOUR="$CRON_HOUR"

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
SSH_KEY="$SSH_KEY"

# MySQL credentials - leave empty to use socket auth as root (recommended)
MYSQL_USER="$MYSQL_USER"
MYSQL_PASS="$MYSQL_PASS"
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
    ask "Send e-mail notifications? (yes/no)" "$MAIL_ENABLED"
    MAIL_ENABLED="$REPLY"
    if [ "$MAIL_ENABLED" = "yes" ]; then
        ask "Mail to (address)" "$MAIL_TO"
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
        ask "SSH private key (empty = default root key)" "$SSH_KEY"
        SSH_KEY="$REPLY"
        echo "NOTE: key-based SSH auth must already work from this server (ssh-copy-id)."
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

# ------------------------------------------------------------------ status --
cmd_status() {
    echo "SLBCK v$VERSION on $HOSTNAME_FQDN"
    echo "----------------------------------------"
    if [ -f "$CONFIG" ]; then
        echo "Config:     $CONFIG"
        echo "Engine:     $(detect_engine)"
        echo "Backup dir: $BACKUP_DIR ($(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo '-'))"
        echo "Retention:  last $RETENTION_DAYS days"
        echo "Mail:       $MAIL_ENABLED ($MAIL_TO, on=$MAIL_ON)"
        echo "Remote:     $REMOTE_ENABLED ($REMOTE_METHOD $REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH)"
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
        echo "  2) Backup now"
        echo "  3) Restore a database"
        echo "  4) Send backups to remote server"
        echo "  5) Status"
        echo "  6) Service check"
        echo "  7) Test mail"
        echo "  q) Quit"
        read -r -p "Choose: " choice
        case "$choice" in
            1) cmd_setup ;;
            2) cmd_backup ;;
            3) cmd_restore ;;
            4) remote_send; ERRORS=0 ;;
            5) cmd_status ;;
            6) service_check "$(detect_engine)"; ERRORS=0 ;;
            7) send_mail "[SLBCK] Test mail from $HOSTNAME_FQDN" \
                   "This is a SLBCK test mail. If you can read this, mail works." \
                   && echo "Test mail sent to $MAIL_TO" ;;
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
    backup)    cmd_backup ;;
    restore)   cmd_restore ;;
    check)     need_root; service_check "$(detect_engine)" ;;
    send)      need_root; remote_send; [ "$ERRORS" -eq 0 ] || exit 1 ;;
    pull)      need_root; remote_pull ;;
    status)    cmd_status ;;
    test-mail) send_mail "[SLBCK] Test mail from $HOSTNAME_FQDN" \
                  "This is a SLBCK test mail. If you can read this, mail works." \
                  && echo "Test mail sent to $MAIL_TO" ;;
    version)   echo "SLBCK v$VERSION" ;;
    help|*)
        cat <<EOF
SLBCK - SaguaroLocalBackup v$VERSION
Usage: slbck <command>   (no command on a terminal = interactive menu)
       slbck-setup       (opens the interactive menu)

  menu        Interactive menu (setup, backup, restore, send, status...)
  setup       Setup wizard (config + cron, installs mail transport if missing)
  backup      Run backup now (check, dump all DBs, retention, remote, mail)
  restore     Interactive restore of one database (local or pulled from remote)
  check       Database service check only
  send        (Re)send local backups to remote server
  pull        Pull backups from remote server to local backup dir
  status      Show configuration and recent activity
  test-mail   Send a test e-mail
  version     Show version
EOF
        ;;
esac
