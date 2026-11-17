#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# The updater runs as root and replaces files beneath this directory. Resolve
# symlinks first and keep the target below the dedicated /usr/local install root.
validate_xui_main_folder() {
    local requested="${1:-/usr/local/x-ui}" resolved allowed first_component probe suffix base parent
    [[ "$requested" == /* ]] || { echo "XUI_MAIN_FOLDER must be an absolute path." >&2; return 1; }
    [[ "$requested" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "XUI_MAIN_FOLDER contains unsupported characters." >&2; return 1; }
    [[ ! "$requested" =~ (^|/)\.\.?(/|$) ]] || { echo "XUI_MAIN_FOLDER cannot contain '.' or '..' path components." >&2; return 1; }
    command -v readlink >/dev/null 2>&1 || { echo "readlink is required to validate XUI_MAIN_FOLDER." >&2; return 1; }
    allowed=$(readlink -f /usr/local 2>/dev/null) || { echo "Cannot resolve permitted install root /usr/local." >&2; return 1; }
    requested="${requested%/}"
    [[ -n "$requested" ]] || requested="/"
    resolved=$(readlink -f "$requested" 2>/dev/null) || {
        # Resolve the
        # deepest existing ancestor, then append the already-validated missing
        # components without following a path that has not been created yet.
        probe="$requested"
        suffix=""
        while [[ ! -e "$probe" && ! -L "$probe" ]]; do
            base="${probe##*/}"
            parent="${probe%/*}"
            [[ -n "$base" && "$base" != "." && "$base" != ".." ]] || { echo "Cannot canonicalize XUI_MAIN_FOLDER." >&2; return 1; }
            suffix="/$base$suffix"
            probe="${parent:-/}"
        done
        [[ -d "$probe" ]] || { echo "The existing XUI_MAIN_FOLDER path must be a directory." >&2; return 1; }
        parent=$(readlink -f "$probe" 2>/dev/null) || { echo "Cannot canonicalize XUI_MAIN_FOLDER." >&2; return 1; }
        resolved="${parent%/}${suffix}"
    }
    if [[ -e "$requested" || -L "$requested" ]]; then
        [[ -d "$resolved" ]] || { echo "XUI_MAIN_FOLDER must be a directory path." >&2; return 1; }
    fi
    [[ "$resolved" == "$allowed/"* ]] || { echo "XUI_MAIN_FOLDER must resolve beneath /usr/local." >&2; return 1; }
    [[ "$resolved" != "$allowed" ]] || { echo "XUI_MAIN_FOLDER cannot be /usr/local itself." >&2; return 1; }
    first_component="${resolved#"$allowed"/}"
    first_component="${first_component%%/*}"
    case "$first_component" in
        bin|sbin|lib|lib64|libexec|share|etc|include|src|games|man|opt|var|Cellar)
            echo "XUI_MAIN_FOLDER cannot be inside the system-managed /usr/local/$first_component tree." >&2
            return 1
            ;;
    esac
    printf '%s\n' "$resolved"
}

xui_folder=$(validate_xui_main_folder "$xui_folder") || exit 1

# Don't edit this config
b_source="${BASH_SOURCE[0]}"
while [ -h "$b_source" ]; do
    b_dir="$(cd -P "$(dirname "$b_source")" > /dev/null 2>&1 && pwd || pwd -P)"
    b_source="$(readlink "$b_source")"
    [[ $b_source != /* ]] && b_source="$b_dir/$b_source"
done
cur_dir="$(cd -P "$(dirname "$b_source")" > /dev/null 2>&1 && pwd || pwd -P)"
script_name=$(basename "$0")

# Check command exist function
_command_exists() {
    type "$1" &> /dev/null
}

# Fail, log and exit script function
_fail() {
    local msg=${1}
    echo -e "${red}${msg}${plain}"
    exit 2
}

# Records this run's outcome for the panel's web updater to poll, since it
# launches this script detached and has no other way to learn whether it
# finished. Written to a fixed path outside XUI_MAIN_FOLDER so it survives
# the update regardless of what happens to that folder. The EXIT trap below
# covers every exit path in this file, including the bare `exit 1`/`exit 2`
# calls that don't go through _fail.
xui_update_run_id="${XUI_UPDATE_RUN_ID:-0}"
[[ "${xui_update_run_id}" =~ ^[0-9]+$ ]] || xui_update_run_id="0"
xui_update_status_file="${XUI_UPDATE_STATUS_FILE:-/etc/x-ui/update-status.json}"

_write_update_status() {
    local state="$1"
    local exit_code="$2"
    local status_dir
    status_dir="$(dirname "${xui_update_status_file}")"
    mkdir -p "${status_dir}" > /dev/null 2>&1
    local tmp_file="${xui_update_status_file}.tmp.$$"
    printf '{"runId":"%s","state":"%s","exitCode":%s,"finishedAt":%s}\n' \
        "${xui_update_run_id}" "${state}" "${exit_code}" "$(date +%s)" > "${tmp_file}" 2> /dev/null
    mv -f "${tmp_file}" "${xui_update_status_file}" > /dev/null 2>&1
}

update_stage_dir=""
update_backup_dir=""
update_transaction_active=0
update_old_service_active=0
update_old_service_enabled=missing
update_service_stopped=0

create_update_backup() {
    local parent="${xui_folder%/*}" env_file db_path service_path rc_path
    update_backup_dir=$(mktemp -d "${parent}/.x-ui-backup.XXXXXX") || return 1
    chmod 700 "$update_backup_dir" || return 1
    mkdir -p "$update_backup_dir/system" || return 1
    cp -a -- "$xui_folder" "$update_backup_dir/app" || return 1
    [[ ! -f /usr/bin/x-ui ]] || cp -a /usr/bin/x-ui "$update_backup_dir/system/x-ui-cli" || return 1
    service_path="${xui_service}/x-ui.service"
    rc_path=/etc/init.d/x-ui
    [[ ! -f "$service_path" ]] || cp -a "$service_path" "$update_backup_dir/system/x-ui.service" || return 1
    [[ ! -f "$rc_path" ]] || cp -a "$rc_path" "$update_backup_dir/system/x-ui.rc" || return 1
    [[ ! -d "${xui_service}/x-ui.service.d" ]] || cp -a "${xui_service}/x-ui.service.d" "$update_backup_dir/system/" || return 1

    if [[ "${XUI_DB_TYPE:-sqlite}" == "postgres" ]]; then
        command -v pg_dump >/dev/null 2>&1 && command -v pg_restore >/dev/null 2>&1 || {
            echo "pg_dump and pg_restore are required to make a rollback-safe PostgreSQL backup." >&2
            return 1
        }
        [[ -n "${XUI_DB_DSN:-}" ]] || { echo "XUI_DB_DSN is required for PostgreSQL rollback backup." >&2; return 1; }
        pg_dump --format=custom --no-owner --file="$update_backup_dir/database.dump" "$XUI_DB_DSN" || return 1
        printf 'postgres\n' > "$update_backup_dir/database.type" || return 1
    else
        db_path="${XUI_DB_FOLDER:-/etc/x-ui}"
        [[ "$db_path" == /* ]] || db_path="${xui_folder%/}/$db_path"
        db_path="${db_path%/}/x-ui.db"
            printf '%s\n' "$db_path" > "$update_backup_dir/database.path" || return 1
        if [[ -f "$db_path" ]]; then
            "${xui_folder}/x-ui" migrate-db --src "$db_path" --dump "$update_backup_dir/database.dump" || return 1
            printf 'sqlite\n' > "$update_backup_dir/database.type" || return 1
        else
            printf 'missing\n' > "$update_backup_dir/database.type" || return 1
        fi
    fi
    chmod 700 "$update_backup_dir" || return 1
    update_transaction_active=1
}

discard_incomplete_update_backup() {
    [[ -z "$update_backup_dir" || ! -d "$update_backup_dir" ]] || rm -rf -- "$update_backup_dir" || return 1
    update_backup_dir=""
}

rollback_update() {
    local db_type db_path failed_db
    [[ "$update_transaction_active" == 1 && -d "$update_backup_dir" ]] || return 0
    echo "Update failed; restoring the previous application and database." >&2
    if [[ "$release" == "alpine" ]]; then
        rc-service x-ui stop >/dev/null 2>&1 || true
    else
        systemctl stop x-ui >/dev/null 2>&1 || true
    fi
    if [[ "$update_old_service_enabled" == missing ]]; then set_xui_service_enabled_state missing || return 1; fi
    rm -rf -- "$xui_folder" || return 1
    mkdir -p "${xui_folder%/*}" || return 1
    cp -a -- "$update_backup_dir/app" "$xui_folder" || return 1
    if [[ -f "$update_backup_dir/system/x-ui-cli" ]]; then
        cp -a "$update_backup_dir/system/x-ui-cli" /usr/bin/x-ui || return 1
    else
        rm -f -- /usr/bin/x-ui || return 1
    fi
    if [[ -f "$update_backup_dir/system/x-ui.service" ]]; then cp -a "$update_backup_dir/system/x-ui.service" "${xui_service}/x-ui.service" || return 1; else rm -f -- "${xui_service}/x-ui.service"; fi
    if [[ -f "$update_backup_dir/system/x-ui.rc" ]]; then cp -a "$update_backup_dir/system/x-ui.rc" /etc/init.d/x-ui || return 1; else rm -f -- /etc/init.d/x-ui; fi
    if [[ -d "$update_backup_dir/system/x-ui.service.d" ]]; then
        rm -rf -- "${xui_service}/x-ui.service.d"
        cp -a "$update_backup_dir/system/x-ui.service.d" "${xui_service}/" || return 1
    else
        rm -rf -- "${xui_service}/x-ui.service.d"
    fi
    db_type="$(cat "$update_backup_dir/database.type" 2>/dev/null || true)"
    case "$db_type" in
        sqlite)
            db_path="$(cat "$update_backup_dir/database.path")"
            [[ -n "$db_path" && -s "$update_backup_dir/database.dump" ]] || return 1
            failed_db="${db_path}.failed.$$"
            if [[ -e "$db_path" ]]; then mv -- "$db_path" "$failed_db" || return 1; fi
            if ! "${xui_folder}/x-ui" migrate-db --restore "$update_backup_dir/database.dump" --out "$db_path"; then
                [[ ! -e "$failed_db" ]] || mv -- "$failed_db" "$db_path"
                return 1
            fi
            rm -f -- "$failed_db"
            ;;
        missing)
            db_path="$(cat "$update_backup_dir/database.path" 2>/dev/null || true)"
            [[ -n "$db_path" ]] || return 1
            rm -f -- "$db_path" "${db_path}-wal" "${db_path}-shm" || return 1
            ;;
        postgres)
            [[ -n "${XUI_DB_DSN:-}" && -s "$update_backup_dir/database.dump" ]] || return 1
            # Object-level rollback only: this dump excludes cluster-global roles and
            # --no-owner does not restore original ownership. --clean only removes
            # objects present in the dump; migration-created extras may remain.
            pg_restore --clean --if-exists --no-owner --single-transaction --dbname="$XUI_DB_DSN" "$update_backup_dir/database.dump" || return 1
            ;;
        *)
            echo "Rollback database metadata is missing or invalid; preserve recovery data at ${update_backup_dir}." >&2
            return 1
            ;;
    esac
    if [[ "$release" == "alpine" ]]; then
        [[ "$update_old_service_enabled" == missing ]] || set_xui_service_enabled_state "$update_old_service_enabled" || return 1
        [[ "$update_old_service_active" != 1 ]] || rc-service x-ui start >/dev/null 2>&1 || return 1
        [[ "$update_old_service_active" != 1 ]] || rc-service x-ui status >/dev/null 2>&1 || return 1
    else
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        [[ "$update_old_service_enabled" == missing ]] || set_xui_service_enabled_state "$update_old_service_enabled" || return 1
        [[ "$update_old_service_active" != 1 ]] || systemctl start x-ui >/dev/null 2>&1 || return 1
        [[ "$update_old_service_active" != 1 ]] || systemctl is-active --quiet x-ui || return 1
    fi
    update_transaction_active=0
    echo "Previous application and database restored." >&2
}

_report_update_exit() {
    local code=$?
    if [[ "$code" -ne 0 && "$update_transaction_active" == 1 ]]; then
        rollback_update || echo "Automatic rollback failed; preserve recovery data at ${update_backup_dir}." >&2
    elif [[ "$code" -ne 0 && "$update_service_stopped" == 1 && "$update_old_service_active" == 1 ]]; then
        if [[ "$release" == "alpine" ]]; then
            rc-service x-ui start >/dev/null 2>&1 || echo "Could not restart the previous x-ui service after pre-replacement failure." >&2
        else
            systemctl start x-ui >/dev/null 2>&1 || echo "Could not restart the previous x-ui service after pre-replacement failure." >&2
        fi
    fi
    if [[ -n "${update_stage_dir}" && -d "${update_stage_dir}" ]]; then
        rm -rf -- "${update_stage_dir}"
    fi
    if [[ "$code" -eq 0 && -n "$update_backup_dir" && -d "$update_backup_dir" ]]; then
        rm -rf -- "$update_backup_dir"
    fi
    if [[ "${code}" -eq 0 ]]; then
        _write_update_status "success" "0"
    else
        _write_update_status "failed" "${code}"
    fi
}
trap _report_update_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# check root
[[ $EUID -ne 0 ]] && _fail "FATAL ERROR: Please run this script with root privilege."

if _command_exists curl; then
    curl_bin=$(which curl)
else
    _fail "ERROR: Command 'curl' not found."
fi
# The panel sets XUI_UPDATE_PROXY to its egress bridge's socks5h URL for the GitHub downloads.
# The IP lookups use plain curl so they still report this server's own address.
[[ -n "${XUI_UPDATE_PROXY}" ]] && curl_bin="${curl_bin} --proxy ${XUI_UPDATE_PROXY}"

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    _fail "Failed to check the system OS, please contact the author!"
fi
echo "The OS release is: $release"

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${red}Unsupported CPU architecture: $(uname -m). The updater was not removed.${plain}" >&2; exit 2 ;;
    esac
}

echo "Arch: $(arch)"

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

xui_env_file_path() {
    case "${release}" in
    ubuntu | debian | armbian | linuxmint | pop | elementary | kali | raspbian)
            echo "/etc/default/x-ui"
            ;;
        arch | manjaro | parch | alpine)
            echo "/etc/conf.d/x-ui"
            ;;
        *)
            echo "/etc/sysconfig/x-ui"
            ;;
    esac
}

load_xui_env() {
    local env_file
    env_file="$(xui_env_file_path)"
    if [[ -r "$env_file" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
    fi
}

run_database_migration() {
    local cli="$1"
    "$cli" migrate || { echo "Database migration failed." >&2; return 1; }
}

openrc_xui_service_exists() {
    [[ -f /etc/init.d/x-ui ]]
}

query_xui_service_enabled_state() {
    local output status
    if [[ "$release" == "alpine" ]]; then
        openrc_xui_service_exists || { printf 'missing\n'; return 0; }
        output=$(rc-update show default 2>/dev/null) || return 1
        if grep -Eq '(^|[[:space:]])x-ui([[:space:]]|$)' <<< "$output"; then
            printf 'enabled\n'
        else
            printf 'disabled\n'
        fi
        return 0
    fi

    if output=$(systemctl is-enabled x-ui 2>/dev/null); then status=0; else status=$?; fi
    case "${status}:${output}" in
        0:enabled) printf 'enabled\n' ;;
        1:disabled) printf 'disabled\n' ;;
        4:not-found)
            [[ ! -e "${xui_service}/x-ui.service" ]] || return 1
            printf 'missing\n'
            ;;
        *) return 1 ;;
    esac
}

set_xui_service_enabled_state() {
    case "$1" in
        enabled)
            if [[ "$release" == "alpine" ]]; then rc-update add x-ui default >/dev/null 2>&1; else systemctl enable x-ui >/dev/null 2>&1; fi
            ;;
        disabled)
            if [[ "$release" == "alpine" ]]; then rc-update del x-ui default >/dev/null 2>&1; else systemctl disable x-ui >/dev/null 2>&1; fi
            ;;
        missing)
            if [[ "$release" == "alpine" ]]; then
                openrc_xui_service_exists || return 0
                rc-update del x-ui default >/dev/null 2>&1
            else
                [[ -e "${xui_service}/x-ui.service" ]] || return 0
                systemctl disable x-ui >/dev/null 2>&1
            fi
            ;;
        *) return 1 ;;
    esac
}

stop_xui_service_if_active() {
    local status
    if [[ "${release}" == "alpine" ]]; then
        openrc_xui_service_exists || return 0
        if rc-service x-ui status >/dev/null 2>&1; then status=0; else status=$?; fi
        case "$status" in
            0) rc-service x-ui stop >/dev/null 2>&1 || return 1 ;;
            3|16) return 0 ;;
            *) return 1 ;;
        esac
        if rc-service x-ui status >/dev/null 2>&1; then status=0; else status=$?; fi
        case "$status" in 3|16) return 0 ;; *) return 1 ;; esac
    else
        if systemctl is-active --quiet x-ui >/dev/null 2>&1; then status=0; else status=$?; fi
        case "$status" in
            0) systemctl stop x-ui >/dev/null 2>&1 || return 1 ;;
            3|4) return 0 ;;
            *) return 1 ;;
        esac
        if systemctl is-active --quiet x-ui >/dev/null 2>&1; then status=0; else status=$?; fi
        case "$status" in 3|4) return 0 ;; *) return 1 ;; esac
    fi
}

start_xui_service() {
    if [[ "${release}" == "alpine" ]]; then
        rc-update add x-ui default || return 1
        rc-service x-ui start || return 1
        rc-service x-ui status >/dev/null 2>&1 || return 1
    else
        systemctl daemon-reload || return 1
        systemctl enable x-ui || return 1
        systemctl start x-ui || return 1
        systemctl is-active --quiet x-ui || return 1
    fi
}

install_base() {
    echo -e "${green}Updating and install dependency packages...${plain}"
    case "${release}" in
        ubuntu | debian | armbian | linuxmint | pop | elementary | kali | raspbian)
            command -v apt-get >/dev/null 2>&1 || _fail "Unsupported package manager: apt-get is required for ${release}."
            apt-get update > /dev/null 2>&1 && apt-get install -y -q cron curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            command -v dnf >/dev/null 2>&1 || _fail "Unsupported package manager: dnf is required for ${release}."
            dnf makecache -y > /dev/null 2>&1 && dnf install -y -q cronie curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                command -v yum >/dev/null 2>&1 || _fail "Unsupported package manager: yum is required for CentOS 7."
                yum makecache -y > /dev/null 2>&1 && yum install -y -q cronie curl tar tzdata socat openssl > /dev/null 2>&1
            else
                command -v dnf >/dev/null 2>&1 || _fail "Unsupported package manager: dnf is required for CentOS."
                dnf makecache -y > /dev/null 2>&1 && dnf install -y -q cronie curl tar tzdata socat openssl > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            command -v pacman >/dev/null 2>&1 || _fail "Unsupported package manager: pacman is required for ${release}."
            pacman -Sy --noconfirm cronie curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            command -v zypper >/dev/null 2>&1 || _fail "Unsupported package manager: zypper is required for ${release}."
            zypper refresh > /dev/null 2>&1 && zypper -q install -y cron curl tar timezone socat openssl > /dev/null 2>&1
            ;;
        alpine)
            command -v apk >/dev/null 2>&1 || _fail "Unsupported package manager: apk is required for Alpine."
            apk update > /dev/null 2>&1 && apk add dcron curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        *)
            _fail "Unsupported operating system: ${release:-unknown}. Supported systems: Debian/Ubuntu, RHEL-family, Arch, openSUSE, Alpine."
            ;;
    esac
}

config_after_update() {
    local panel_needs_restart=0

    echo -e "${yellow}x-ui settings:${plain}"
    ${xui_folder}/x-ui setting -show true
    # Properly detect empty cert by checking if cert: line exists and has content after it
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true 2> /dev/null | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local settings existing_webBasePath
    if ! settings=$("${xui_folder}/x-ui" setting -show true) ||
        ! existing_webBasePath=$(printf '%s\n' "$settings" | awk '
            /^get .* failed, error info:/ { failed = 1 }
            /^hasDefaultCredential: (true|false)$/ { credentials++ }
            /^port: [0-9]+$/ { ports++ }
            /^webBasePath:/ { paths++; sub(/^webBasePath: ?/, ""); path = $0 }
            END {
                if (failed || credentials != 1 || ports != 1 || paths != 1 || (path != "" && path !~ /^\//)) exit 1
                print path
            }'); then
        echo -e "${red}Unable to read webBasePath; leaving existing settings unchanged.${plain}" >&2
        return 1
    fi
    existing_webBasePath=${existing_webBasePath#/}
    local existing_port=$(printf '%s\n' "$settings" | awk '/^port: / {print $2}')

    # Get server IP
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    # Only used to print the access URL; never prompt, the web updater has no TTY.
    if [[ -z "$server_ip" ]]; then
        server_ip=$(hostname -I 2> /dev/null | awk '{print $1}')
        server_ip="${server_ip:-<server-ip>}"
    fi

    # Only an unset or default root path needs initialization.
    if [[ -z "$existing_webBasePath" ]]; then
        echo -e "${yellow}WebBasePath is missing or set to root. Generating a new one...${plain}"
        local config_webBasePath=$(gen_random_string 18)
        ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}"
        existing_webBasePath="${config_webBasePath}"
        panel_needs_restart=1
        echo -e "${green}New WebBasePath: ${config_webBasePath}${plain}"
    fi

    # An update only updates the panel: TLS stays exactly as configured. Set it up
    # explicitly from the x-ui menu (SSL Certificate Management).
    local access_scheme="http" access_host="${server_ip}"
    if [[ -n "$existing_cert" ]]; then
        access_scheme="https"
        access_host=$(basename "$(dirname "$existing_cert")")
    fi
    echo ""
    echo -e "${green}═══════════════════════════════════════════${plain}"
    echo -e "${green}     Panel Access Information              ${plain}"
    echo -e "${green}═══════════════════════════════════════════${plain}"
    echo -e "${green}Access URL: ${access_scheme}://${access_host}:${existing_port}/${existing_webBasePath}${plain}"
    echo -e "${green}═══════════════════════════════════════════${plain}"
    if [[ -z "$existing_cert" ]]; then
        echo -e "${yellow}No SSL certificate is configured; the panel is served over HTTP.${plain}"
        echo -e "${yellow}Run 'x-ui' and choose SSL Certificate Management to set one up.${plain}"
    fi

    if [[ "$panel_needs_restart" -eq 1 ]]; then
        echo -e "${yellow}Restarting panel to apply the new web base path...${plain}"
        systemctl restart x-ui 2> /dev/null || rc-service x-ui restart 2> /dev/null
    fi
}

# setup_fail2ban auto-installs and configures fail2ban for the IP Limit feature
# by invoking the freshly downloaded x-ui CLI. IP Limit is load-bearing on
# fail2ban (without it the panel disables the limitIp field and zeroes existing
# limits), so updating an older install should make it work without a manual
# trip through the IP Limit menu. Non-fatal: a fail2ban failure must never abort
# the update. XUI_ENABLE_FAIL2BAN is honored (load_xui_env exports it from the
# persisted env file, so a deliberate opt-out survives updates).
setup_fail2ban() {
    if [[ -n "${XUI_ENABLE_FAIL2BAN+x}" && "${XUI_ENABLE_FAIL2BAN}" != "true" ]]; then
        echo -e "${yellow}XUI_ENABLE_FAIL2BAN=${XUI_ENABLE_FAIL2BAN}, skipping Fail2ban auto-setup.${plain}"
        return 0
    fi

    if [[ ! -x /usr/bin/x-ui ]]; then
        echo -e "${yellow}x-ui CLI not found; skipping Fail2ban auto-setup.${plain}"
        return 0
    fi

    # Scripts older than v3.4.0 have no setup-fail2ban and exit 0 from the
    # usage banner, which would read as success here.
    if ! grep -q '"setup-fail2ban")' /usr/bin/x-ui; then
        echo -e "${yellow}This x-ui.sh predates 'x-ui setup-fail2ban'; skipping Fail2ban auto-setup.${plain}"
        return 0
    fi

    echo -e "${green}Setting up Fail2ban for the IP Limit feature...${plain}"
    if /usr/bin/x-ui setup-fail2ban; then
        echo -e "${green}Fail2ban setup complete.${plain}"
    else
        echo -e "${yellow}Fail2ban setup did not finish; IP Limit stays disabled until you run 'x-ui' and open the IP Limit menu. Continuing.${plain}"
    fi
    return 0
}

# The hardened unit makes /usr, /boot, /efi and /etc read-only. The panel's own
# updater is expected to escape that sandbox by running this script through a
# transient systemd-run unit; when systemd-run is unavailable it starts this
# script as a plain child instead, and that child inherits the sandbox and then
# cannot write anything this update needs. Say so once, up front, instead of
# dying partway through with "Failed to download x-ui".
require_writable_update_paths() {
    local dir probe
    for dir in "${xui_folder%/*}" "/usr/bin"; do
        [[ -n "$dir" && -d "$dir" ]] || continue
        probe="${dir}/.x-ui-write-test.$$"
        # A real write test rather than [[ -w ]]: this runs as root, where a
        # permission bit means little and the test only reflects the file mode
        # and the mount flags, not an immutable attribute or a full filesystem.
        if ! : > "$probe" 2> /dev/null; then
            _fail "ERROR: ${dir} is not writable for this process (read-only mount, attribute or full filesystem). The panel's fallback updater cannot run inside the hardened systemd sandbox; update from the panel UI (which uses systemd-run) or run 'x-ui update' in a shell."
        fi
        rm -f "$probe"
    done
}

# Major version of the local systemd, 0 when it cannot be determined. The
# SystemCallFilter=@system-service group only exists from systemd 239 on (other
# @-named groups exist since 231); on older versions an unknown group is not
# ignored safely, the filter stays in force and leaves a whitelist the panel
# cannot run under.
_xui_systemd_major_version() {
    local version=""
    if command -v systemctl > /dev/null 2>&1; then
        version="$(systemctl --version 2>/dev/null | awk 'NR == 1 {print $2}')"
    fi
    if [[ ! "$version" =~ ^[0-9]+$ ]]; then
        echo 0
        return 0
    fi
    echo "$version"
}

# The shipped units list hardening that older systemd does not know: the
# directive is logged and ignored at load time rather than rejected, so the
# panel still starts, only without that protection. Each entry is the systemd
# release that introduced the directive (systemd.exec(5)); everything else in
# the unit predates the oldest systemd install.sh supports (CentOS 7 has 219).
# SystemCallFilter= is listed because the drop-in only writes it from 239 on.
_xui_warn_unsupported_hardening() {
    local version entry missing=""
    version="$(_xui_systemd_major_version)"
    [[ "$version" -gt 0 ]] || return 0
    for entry in RestrictRealtime:231 ReadWritePaths:231 ProtectKernelTunables:232 \
        ProtectKernelModules:232 RestrictNamespaces:233 LockPersonality:235 \
        SystemCallFilter:239 ProtectHostname:242 RestrictSUIDSGID:242 \
        ProtectKernelLogs:244 ProtectClock:245; do
        if [[ "$version" -lt "${entry##*:}" ]]; then
            missing="${missing:+$missing, }${entry%%:*} (${entry##*:})"
        fi
    done
    [[ -n "$missing" ]] || return 0
    echo -e "${yellow}Note: systemd ${version} ignores part of the hardening in x-ui.service; the panel still starts.${plain}"
    echo "      Not applied, needs a newer systemd: ${missing}."
    if [[ "$version" -lt 231 ]]; then
        echo "      The panel's folders stay writable through ReadWriteDirectories=, the alias this script installs."
    fi
    echo "      The rest of the hardening is in force. Upgrade systemd to apply the above."
    return 0
}

# ProtectSystem=full makes /usr, /boot, /efi and /etc read-only. ProtectSystem=
# strict would make the whole hierarchy read-only (only the kernel API
# filesystems stay as they are), and that would break the panel's own use of
# /tmp. The panel's stores are configurable (XUI_DB_FOLDER, XUI_LOG_FOLDER,
# XUI_BIN_FOLDER), and XUI_MAIN_FOLDER is the folder install.sh/update.sh place
# the files in -- the unit's WorkingDirectory on a stock install, and what a
# relative XUI_BIN_FOLDER is resolved against. So a hard-coded list in the unit
# either misses a relocated store -- the panel then cannot write its own SQLite
# database and sits in a Restart=on-failure loop -- or forces the operator to
# edit a file that every install/update overwrites from the release tarball.
# install.sh and update.sh therefore regenerate the drop-in from the folders
# actually in use, and the unit's own ReadWritePaths only carry the
# plain-install defaults. A relocated store means re-running install or update:
# the drop-in is only written here.
_xui_service_write_paths_dropin() {
    # $1 is the env file to resolve the XUI_* folders from; callers pass nothing
    # and get the OS-specific path the unit itself uses.
    local env_file="${1:-}"
    local dropin_dir dropin temp_file
    local db_folder log_folder bin_folder main_folder
    local path line="" whitespace_paths="" seen_paths="" escaped_path

    if [[ -z "$env_file" ]]; then
        env_file="$(xui_env_file_path)"
    fi
    if [[ -r "$env_file" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
    fi

    # XUI_* wins over the script's own default: the unit hands that same env
    # file to the panel through EnvironmentFile=, so these are the folders it
    # will actually use.
    main_folder="${XUI_MAIN_FOLDER:-${xui_folder}}"
    db_folder="${XUI_DB_FOLDER:-/etc/x-ui}"
    log_folder="${XUI_LOG_FOLDER:-/var/log/x-ui}"
    # An empty XUI_BIN_FOLDER resolves to "bin" relative to the panel's working
    # directory, which the unit sets to the main folder.
    bin_folder="${XUI_BIN_FOLDER:-bin}"
    if [[ "$bin_folder" != /* ]]; then
        bin_folder="${main_folder%/}/${bin_folder#./}"
    fi

    for path in "$db_folder" "$log_folder" "$bin_folder" "$main_folder"; do
        [[ "$path" == /* ]] || continue
        # ReadWritePaths= is a whitespace-separated list, and a folder whose
        # name contains whitespace cannot be written into it without relying on
        # quoting. A wrong entry makes systemd reject the whole drop-in and the
        # panel would not start, so leave such a folder out and say so instead.
        if [[ "$path" != "${path//[[:space:]]/}" ]]; then
            whitespace_paths="${whitespace_paths:+$whitespace_paths }$path"
            continue
        fi
        case " $seen_paths " in
            *" $path "*) continue ;;
        esac
        seen_paths="${seen_paths}${seen_paths:+ }$path"
        # systemd expands %-specifiers in unit files, so a folder name carrying
        # a literal % has to be written as %%, or the entry stops naming the
        # folder systemd is meant to keep writable.
        escaped_path="${path//%/%%}"
        line="${line} -${escaped_path}"
    done
    if [[ -n "$whitespace_paths" ]]; then
        echo "Warning: these folders contain whitespace and were left out of" >&2
        echo "         10-xui-sandbox.conf: $whitespace_paths" >&2
        echo "         The panel cannot write to them under the unit's sandbox." >&2
    fi
    line="${line# }"
    [[ -n "$line" ]] || return 1

    dropin_dir="${xui_service}/x-ui.service.d"
    dropin="${dropin_dir}/10-xui-sandbox.conf"
    temp_file="${dropin}.tmp.$$"

    mkdir -p "$dropin_dir" || return 1
    cat > "$temp_file" << EOF
# Regenerated by install.sh/update.sh on every install and update: edits here
# are lost, and the list only reflects the XUI_* variables read from
# ${env_file} at that moment. Re-run install/update after moving a store.
# It lists the folders the panel writes to. Put local additions in their own
# drop-in, for example 20-x-ui-local.conf, which nothing here touches.
[Service]
ReadWritePaths=${line}
ReadWriteDirectories=${line}
EOF
    if [[ "$(_xui_systemd_major_version)" -ge 239 ]]; then
        cat >> "$temp_file" << 'EOF'
# @system-service needs systemd >= 239; on older versions the unknown group
# would leave the panel with a filter it cannot start under (x-ui.service.*).
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
EOF
    fi
    if [[ ! -s "$temp_file" ]]; then
        rm -f "$temp_file"
        return 1
    fi
    chmod 644 "$temp_file"
    mv -f "$temp_file" "$dropin" || { rm -f "$temp_file"; return 1; }
    if command -v systemctl > /dev/null 2>&1; then
        systemctl daemon-reload > /dev/null 2>&1 || true
    fi
    return 0
}

# Lands a systemd unit file at ${xui_service}/x-ui.service via a temp file +
# atomic mv, so a failed cp/curl or an interrupted mv never leaves a
# truncated unit file at the live path -- systemd would then fail to parse
# it on the next daemon-reload/start. Same pattern already used for
# /usr/bin/x-ui elsewhere in this script. source_is_url picks cp (from a
# file already extracted from the release tarball) vs curl (GitHub fallback).
_install_xui_service_unit() {
    local source="$1"
    local source_is_url="$2"
    local dest="${xui_service}/x-ui.service"
    local temp_file="${dest}.tmp.$$"

    rm -f "$temp_file"
    if [[ "$source_is_url" == "true" ]]; then
        ${curl_bin} -fLRo "$temp_file" "$source" > /dev/null 2>&1
    else
        cp -f "$source" "$temp_file" > /dev/null 2>&1
    fi
    if [[ $? -ne 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi
    if [[ ! -s "$temp_file" ]]; then
        rm -f "$temp_file"
        return 1
    fi
    mv -f "$temp_file" "$dest"
    if [[ $? -ne 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi
    if ! _xui_service_write_paths_dropin; then
        echo -e "${yellow}Warning: could not refresh ${xui_service}/x-ui.service.d/10-xui-sandbox.conf.${plain}"
        echo -e "${yellow}If XUI_DB_FOLDER or XUI_LOG_FOLDER points outside /etc/x-ui and /var/log/x-ui, the panel may not be able to write to it under ProtectSystem=full.${plain}"
    fi
    _xui_warn_unsupported_hardening
    return 0
}

# Older tags predate some of these files (x-ui.rc arrived in v2.8.4). Serving
# main's copy against an old binary is the mismatch this pinning exists to
# prevent, so probe before the old install is removed and refuse the tag.
require_repo_files() {
    local ref="$1" name status
    shift
    [[ "${ref}" == "main" ]] && return 0
    for name in "$@"; do
        status=$(${curl_bin} -sIL --retry 3 --connect-timeout 15 -o /dev/null -w '%{http_code}' "https://raw.githubusercontent.com/hcmteam/H-Panel/${ref}/${name}")
        if [[ "${status}" != "200" ]]; then
            _fail "ERROR: ${name} is not available for ${ref} (HTTP ${status}). Update to a release that ships it, or to 'dev-latest'. The current installation is untouched."
        fi
    done
}

# Keep updater release selection aligned with install.sh: use the H-Panel
# repository, prefer the latest stable release only when this architecture's
# archive exists, then fall back to the rolling dev-latest asset.
release_asset_available() {
    local status
    status=$(${curl_bin} -sSLI -o /dev/null -w '%{http_code}' --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 "$1" 2>/dev/null) || return 1
    [[ "$status" == "200" ]]
}

verify_release_checksum() {
    local url="$1" file="$2" sums="${2}.sha256" code expected actual
    rm -f -- "$sums"
    code=$(${curl_bin} -sL --retry 3 --retry-delay 3 --connect-timeout 15 --max-time 60 -o "$sums" -w '%{http_code}' "${url}.sha256" 2>/dev/null)
    if [[ "$code" != 200 ]]; then
        rm -f -- "$sums" "$file"
        echo "ERROR: Could not verify release checksum (HTTP ${code:-unknown}); refusing the archive." >&2
        return 1
    fi
    expected=$(awk 'NR == 1 {print $1}' "$sums")
    actual=$(sha256sum "$file" | awk '{print $1}')
    rm -f -- "$sums"
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ || "$expected" != "$actual" ]]; then
        rm -f -- "$file"
        echo "ERROR: Release checksum is invalid or does not match the archive." >&2
        return 1
    fi
    echo "Checksum verified: ${actual}"
}

resolve_latest_tag() {
    local url tag stable_asset dev_asset
    stable_asset="https://github.com/hcmteam/H-Panel/releases/download"
    dev_asset="${stable_asset}/dev-latest/x-ui-linux-$(arch).tar.gz"

    url=$(${curl_bin} -sSLI -o /dev/null -w '%{url_effective}' --retry 5 --retry-delay 3 --connect-timeout 15 --max-time 60 "https://github.com/hcmteam/H-Panel/releases/latest" 2>/dev/null)
    tag=${url##*/tag/}
    if [[ "$tag" == "$url" || -z "$tag" || "$tag" == "latest" ]]; then
        tag=$(${curl_bin} -Ls --retry 5 --retry-delay 3 --connect-timeout 15 --max-time 60 "https://api.github.com/repos/hcmteam/H-Panel/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi

    if [[ -n "$tag" && "$tag" != "latest" ]] && release_asset_available "${stable_asset}/${tag}/x-ui-linux-$(arch).tar.gz"; then
        echo "$tag"
        return 0
    fi
    if release_asset_available "$dev_asset"; then
        echo "dev-latest"
        return 0
    fi
    return 1
}

update_x-ui() {
    cd ${xui_folder%/x-ui}/

    load_xui_env

    if [ -f "${xui_folder}/x-ui" ]; then
        current_xui_version=$(${xui_folder}/x-ui -v)
        echo -e "${green}Current x-ui version: ${current_xui_version}${plain}"
    else
        _fail "ERROR: Current x-ui version: unknown"
    fi

    echo -e "${green}Downloading new x-ui version...${plain}"

    # XUI_UPDATE_TAG lets the panel target a specific release tag (e.g. the
    # rolling dev-latest pre-release). Empty keeps the default latest-stable flow.
    if [[ -n "${XUI_UPDATE_TAG}" ]]; then
        tag_version="${XUI_UPDATE_TAG}"
        echo -e "${green}Using update tag: ${tag_version}${plain}"
    else
        tag_version=$(resolve_latest_tag) || _fail "ERROR: No installable H-Panel release was found for $(arch)"
    fi
    echo -e "Got x-ui latest version: ${tag_version}, beginning the installation..."
    # x-ui.rc and the unit files must come from the binary's own release; only the
    # rolling dev build tracks main. x-ui.sh ships in the archive and needs no GitHub check.
    script_ref="${tag_version}"
    if [[ "${tag_version}" == "dev-latest" ]]; then
        script_ref="main"
    fi
    # The unit files are only fetched when the release tarball lacks them, so
    # they are checked at that point instead of here.
    [[ $release == "alpine" ]] && require_repo_files "${script_ref}" "x-ui.rc"
    ${curl_bin} -fLRo ${xui_folder}-linux-$(arch).tar.gz https://github.com/hcmteam/H-Panel/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz 2> /dev/null
    if [[ $? -ne 0 ]]; then
        _fail "ERROR: Failed to download x-ui, please be sure that your server can access GitHub"
    fi
    if [[ ! -s ${xui_folder}-linux-$(arch).tar.gz ]]; then
        rm ${xui_folder}-linux-$(arch).tar.gz -f > /dev/null 2>&1
        _fail "ERROR: Downloaded x-ui release archive is empty, please be sure that your server can access GitHub"
    fi
    archive="${xui_folder}-linux-$(arch).tar.gz"
    verify_release_checksum "https://github.com/hcmteam/H-Panel/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz" "$archive" \
        || _fail "ERROR: No valid checksum is available for this release; refusing to update."

    local listing member verbose
    listing=$(tar -tzf "${archive}") || _fail "ERROR: Cannot list the H-Panel release archive"
    [[ -n "${listing}" ]] || _fail "ERROR: H-Panel release archive is empty"
    verbose=$(tar -tvzf "${archive}") || _fail "ERROR: Cannot inspect release archive entry types"
    if printf '%s\n' "$verbose" | awk '$1 !~ /^[-d]/ { found=1 } END { exit !found }'; then
        _fail "ERROR: Release archives may contain only regular files and directories"
    fi
    while IFS= read -r member; do
        [[ -n "${member}" ]] || continue
        [[ "${member}" != /* ]] || _fail "ERROR: Release archive contains an absolute path"
        [[ ! "${member}" =~ (^|/)\.\.(/|$) ]] || _fail "ERROR: Release archive contains a parent traversal path"
        [[ "${member}" == x-ui || "${member}" == x-ui/* ]] || _fail "ERROR: Release archive contains files outside x-ui/"
    done <<< "${listing}"

    # Extract and validate the release while the current panel is still running.
    # This catches corrupt or incomplete archives before service downtime.
    update_stage_dir=$(mktemp -d "${xui_folder%/x-ui}/.x-ui-update.XXXXXX") || {
        rm -f -- "${archive}"
        _fail "ERROR: Could not create a temporary directory to validate the H-Panel release"
    }
    if ! tar -xzf "${archive}" -C "${update_stage_dir}" > /dev/null 2>&1; then
        rm -f -- "${archive}"
        _fail "ERROR: Failed to extract the H-Panel release archive; the current installation is untouched"
    fi
    staged_xui_dir="${update_stage_dir}/x-ui"
    if [[ ! -s "${staged_xui_dir}/x-ui" || ! -s "${staged_xui_dir}/x-ui.sh" || ! -s "${staged_xui_dir}/bin/xray-linux-$(arch)" ]]; then
        rm -f -- "${archive}"
        _fail "ERROR: H-Panel release archive is missing required files for $(arch); the current installation is untouched"
    fi
    if [[ "$release" != "alpine" && ! -f "$staged_xui_dir/x-ui.service" ]]; then
        case "$release" in
            ubuntu|debian|armbian|linuxmint|pop|elementary|kali|raspbian) service_file=x-ui.service.debian ;;
            arch|manjaro|parch) service_file=x-ui.service.arch ;;
            *) service_file=x-ui.service.rhel ;;
        esac
        if [[ ! -f "$staged_xui_dir/$service_file" ]]; then
            ${curl_bin} -fLRo "$staged_xui_dir/$service_file" "https://raw.githubusercontent.com/hcmteam/H-Panel/${script_ref}/${service_file}" >/dev/null 2>&1 \
                || _fail "ERROR: Could not download the required service unit; the current installation is untouched"
            [[ -s "$staged_xui_dir/$service_file" ]] || _fail "ERROR: Downloaded service unit is empty; the current installation is untouched"
        fi
    fi

    if ! update_old_service_enabled=$(query_xui_service_enabled_state); then
        _fail "ERROR: Could not reliably determine whether the existing x-ui service is enabled; aborting before service or application changes"
    fi
    if [[ "$release" == "alpine" ]]; then
        rc-service x-ui status >/dev/null 2>&1 && update_old_service_active=1 || true
    else
        systemctl is-active --quiet x-ui && update_old_service_active=1 || true
    fi
    update_service_stopped=1
    stop_xui_service_if_active || _fail "ERROR: Could not stop x-ui before backup"
    if ! create_update_backup; then
        if [[ "$update_old_service_active" == 1 ]]; then
            if [[ "$release" == "alpine" ]]; then rc-service x-ui start >/dev/null 2>&1 || true; else systemctl start x-ui >/dev/null 2>&1 || true; fi
        fi
        if ! discard_incomplete_update_backup; then
            echo "Could not remove the incomplete rollback backup; preserve it for inspection at ${update_backup_dir}." >&2
        fi
        _fail "ERROR: Could not create a complete rollback backup; update was stopped before replacement"
    fi
    update_transaction_active=1

    # Download everything before x-ui stops, because its Xray and any panel egress bridge
    # stop with it. Alpine's init script is the only file the archive lacks.
    if [[ $release == "alpine" ]]; then
        echo -e "${green}Downloading startup unit x-ui.rc...${plain}"
        xui_rc_temp="/etc/init.d/x-ui.tmp.$$"
        rm -f "${xui_rc_temp}"
        ${curl_bin} -fLRo "${xui_rc_temp}" "https://raw.githubusercontent.com/hcmteam/H-Panel/${script_ref}/x-ui.rc" > /dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            rm -f "${xui_rc_temp}" "${archive}"
            _fail "ERROR: Failed to download startup unit x-ui.rc, please be sure that your server can access GitHub"
        fi
        if [[ ! -s "${xui_rc_temp}" ]]; then
            rm -f "${xui_rc_temp}" "${archive}"
            _fail "ERROR: Downloaded startup unit x-ui.rc is empty, please be sure that your server can access GitHub"
        fi
    fi

    if [[ -e ${xui_folder}/ ]]; then
        echo -e "${green}Stopping x-ui...${plain}"
        if [[ $release == "alpine" ]]; then
            if [ -f "/etc/init.d/x-ui" ]; then
                echo -e "${green}Keeping existing OpenRC service enabled during replacement...${plain}"
            else
                rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
                _fail "ERROR: x-ui service unit not installed."
            fi
        else
            if [ -f "${xui_service}/x-ui.service" ]; then
                echo -e "${green}Keeping existing systemd service enabled during replacement...${plain}"
            else
                rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
                _fail "ERROR: x-ui systemd unit not installed."
            fi
        fi
        # Kill any leftover mtg (MTProto) sidecars. x-ui runs them outside its own
        # lifecycle, so on Linux a stale one can survive the stop and keep holding
        # an inbound port with an outdated secret, silently breaking new clients.
        # The new panel respawns a clean mtg per inbound on next start.
        pkill -f 'mtg-linux-[^ ]* run ' > /dev/null 2>&1 || true
        pkill -f 'tuic-server.*-c .*bin/tuic/tuic_[0-9]+\.json' > /dev/null 2>&1 || true
        echo -e "${green}Removing old x-ui version...${plain}"
        rm ${xui_folder} -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service.debian -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service.arch -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service.rhel -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.sh -f > /dev/null 2>&1
        echo -e "${green}Removing old mtg version...${plain}"
        rm ${xui_folder}/bin/mtg-linux-$(arch) -f > /dev/null 2>&1
        echo -e "${green}Removing old xray version...${plain}"
        rm ${xui_folder}/bin/xray-linux-$(arch) -f > /dev/null 2>&1
        echo -e "${green}Removing old README and LICENSE file...${plain}"
        rm ${xui_folder}/bin/README.md -f > /dev/null 2>&1
        rm ${xui_folder}/bin/LICENSE -f > /dev/null 2>&1
        rm ${xui_folder}/bin/tuic-server -f > /dev/null 2>&1
        rm ${xui_folder}/bin/tuic -rf > /dev/null 2>&1
    else
        rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
        _fail "ERROR: x-ui not installed."
    fi

    echo -e "${green}Installing new x-ui version...${plain}"
    rm -f -- "${archive}"
    if ! cp -a "${staged_xui_dir}/." "${xui_folder}/"; then
        _fail "ERROR: Failed to copy the validated H-Panel release into place; the service may need to be restored from backup"
    fi
    cd "${xui_folder}" > /dev/null 2>&1 || _fail "ERROR: Could not enter the H-Panel installation directory"
    if [[ ! -s x-ui ]]; then
        _fail "ERROR: Installed H-Panel archive is missing the x-ui binary"
    fi
    chmod +x x-ui > /dev/null 2>&1

    # Check the system's architecture and rename the file accordingly.
    # The panel binary maps GOARCH=arm to "arm32" (internal/xray/process.go),
    # so the Xray binary must be named xray-linux-arm32; mtg keeps plain "arm".
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm32 > /dev/null 2>&1
        chmod +x bin/xray-linux-arm32 > /dev/null 2>&1
        if [[ -f bin/mtg-linux-$(arch) ]]; then
            mv bin/mtg-linux-$(arch) bin/mtg-linux-arm > /dev/null 2>&1
            chmod +x bin/mtg-linux-arm > /dev/null 2>&1
        fi
    fi

    chmod +x x-ui bin/xray-linux-$(arch) > /dev/null 2>&1
    if [[ -f bin/mtg-linux-arm ]]; then
        chmod +x bin/mtg-linux-arm > /dev/null 2>&1
    elif [[ -f bin/mtg-linux-$(arch) ]]; then
        chmod +x bin/mtg-linux-$(arch) > /dev/null 2>&1
    fi

    # The archive's x-ui.sh is built from the same commit as the binary.
    echo -e "${green}Installing x-ui.sh script...${plain}"
    local xui_script_temp="/usr/bin/x-ui-temp.$$"
    if ! cp -f x-ui.sh "${xui_script_temp}" || ! mv -f "${xui_script_temp}" /usr/bin/x-ui; then
        rm -f "${xui_script_temp}"
        _fail "ERROR: Failed to install x-ui.sh script"
    fi

    chmod +x ${xui_folder}/x-ui.sh > /dev/null 2>&1
    chmod +x /usr/bin/x-ui > /dev/null 2>&1
    mkdir -p /var/log/x-ui > /dev/null 2>&1

    echo -e "${green}Changing owner...${plain}"
    chown -R root:root ${xui_folder} > /dev/null 2>&1

    if [ -f "${xui_folder}/bin/config.json" ]; then
        echo -e "${green}Changing on config file permissions...${plain}"
        chmod 640 ${xui_folder}/bin/config.json > /dev/null 2>&1
    fi

    # Finish the schema/data migrations before the service starts, so the service and
    # config_after_update's CLI calls never run them on the same database at once (#6728).
    echo -e "${green}Migrating database...${plain}"
    stop_xui_service_if_active || _fail "ERROR: Could not ensure x-ui is stopped before database migration."
    run_database_migration "${xui_folder}/x-ui" || _fail "ERROR: Database migration failed; rolling back the application and database."

    if [[ $release == "alpine" ]]; then
        echo -e "${green}Installing startup unit x-ui.rc...${plain}"
        mv -f "${xui_rc_temp}" /etc/init.d/x-ui
        if [[ $? -ne 0 ]]; then
            rm -f "${xui_rc_temp}"
            _fail "ERROR: Failed to install startup unit x-ui.rc"
        fi
        chmod +x /etc/init.d/x-ui > /dev/null 2>&1
        chown root:root /etc/init.d/x-ui > /dev/null 2>&1
        start_xui_service || _fail "ERROR: Could not enable/start x-ui or verify that it is active"
    else
        if [ -f "x-ui.service" ]; then
            echo -e "${green}Installing systemd unit...${plain}"
            if ! _install_xui_service_unit "x-ui.service" "false"; then
                echo -e "${red}Failed to copy x-ui.service${plain}"
                exit 1
            fi
        else
            service_installed=false
            case "${release}" in
                ubuntu | debian | armbian)
                    if [ -f "x-ui.service.debian" ]; then
                        echo -e "${green}Installing debian-like systemd unit...${plain}"
                        if _install_xui_service_unit "x-ui.service.debian" "false"; then
                            service_installed=true
                        fi
                    fi
                    ;;
                arch | manjaro | parch)
                    if [ -f "x-ui.service.arch" ]; then
                        echo -e "${green}Installing arch-like systemd unit...${plain}"
                        if _install_xui_service_unit "x-ui.service.arch" "false"; then
                            service_installed=true
                        fi
                    fi
                    ;;
                *)
                    if [ -f "x-ui.service.rhel" ]; then
                        echo -e "${green}Installing rhel-like systemd unit...${plain}"
                        if _install_xui_service_unit "x-ui.service.rhel" "false"; then
                            service_installed=true
                        fi
                    fi
                    ;;
            esac

            # If service file not found in tar.gz, download from GitHub
            if [ "$service_installed" = false ]; then
                echo -e "${yellow}Service files not found in tar.gz, downloading from GitHub...${plain}"
                case "${release}" in
                    ubuntu | debian | armbian)
                        service_unit_url="https://raw.githubusercontent.com/hcmteam/H-Panel/${script_ref}/x-ui.service.debian"
                        ;;
                    arch | manjaro | parch)
                        service_unit_url="https://raw.githubusercontent.com/hcmteam/H-Panel/${script_ref}/x-ui.service.arch"
                        ;;
                    *)
                        service_unit_url="https://raw.githubusercontent.com/hcmteam/H-Panel/${script_ref}/x-ui.service.rhel"
                        ;;
                esac

                if ! _install_xui_service_unit "$service_unit_url" "true"; then
                    echo -e "${red}Failed to install x-ui.service from GitHub (${script_ref}) -- the release tarball did not ship one either${plain}"
                    exit 1
                fi
            fi
        fi
        chown root:root ${xui_service}/x-ui.service > /dev/null 2>&1
        chmod 644 ${xui_service}/x-ui.service > /dev/null 2>&1
        start_xui_service || _fail "ERROR: Could not enable/start x-ui or verify that it is active"
    fi

    config_after_update || _fail "ERROR: Could not apply existing panel settings after update"
    if [[ "$release" == "alpine" ]]; then
        rc-service x-ui status >/dev/null 2>&1 || _fail "ERROR: x-ui is not active after post-update configuration"
    else
        systemctl is-active --quiet x-ui || _fail "ERROR: x-ui is not active after post-update configuration"
    fi

    # IP Limit relies on fail2ban; install + configure it now so the feature
    # works out of the box on update too (no-op when XUI_ENABLE_FAIL2BAN=false).
    # Never fatal.
    setup_fail2ban
    if [[ "$release" == "alpine" ]]; then
        rc-service x-ui status >/dev/null 2>&1 || _fail "ERROR: x-ui is not active after setup"
    else
        systemctl is-active --quiet x-ui || _fail "ERROR: x-ui is not active after setup"
    fi

    update_transaction_active=0
    echo -e "${green}x-ui ${tag_version}${plain} updating finished, it is running now..."
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}x-ui control menu usages (subcommands):${plain}              │
│                                                       │
│  ${blue}x-ui${plain}              - Admin Management Script          │
│  ${blue}x-ui start${plain}        - Start                            │
│  ${blue}x-ui stop${plain}         - Stop                             │
│  ${blue}x-ui restart${plain}      - Restart                          │
│  ${blue}x-ui status${plain}       - Current Status                   │
│  ${blue}x-ui settings${plain}     - Current Settings                 │
│  ${blue}x-ui enable${plain}       - Enable Autostart on OS Startup   │
│  ${blue}x-ui disable${plain}      - Disable Autostart on OS Startup  │
│  ${blue}x-ui log${plain}          - Check logs                       │
│  ${blue}x-ui banlog${plain}       - Check Fail2ban ban logs          │
│  ${blue}x-ui update${plain}       - Update                           │
│  ${blue}x-ui legacy${plain}       - Legacy version                   │
│  ${blue}x-ui install${plain}      - Install                          │
│  ${blue}x-ui uninstall${plain}    - Uninstall                        │
└───────────────────────────────────────────────────────┘"
}

echo -e "${green}Running...${plain}"
load_xui_env
xui_folder=$(validate_xui_main_folder "${XUI_MAIN_FOLDER:-/usr/local/x-ui}") || _fail "FATAL ERROR: unsafe XUI_MAIN_FOLDER"
require_writable_update_paths
install_base || _fail "ERROR: failed to install required packages"
update_x-ui $1
