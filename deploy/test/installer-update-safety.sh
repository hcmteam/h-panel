#!/usr/bin/env bash
set -euo pipefail
red='' green='' yellow='' plain=''
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
load_function() {
    local file="$1" name="$2" definition
    definition=$(awk -v name="$name" '$0 ~ "^" name "\\(\\) \\{" {copy=1} copy {print} copy && /^}$/ {exit}' "$file")
    [[ -n "$definition" ]] || return 1
    eval "$definition"
}
installer="$repo_root/install.sh"
updater="$repo_root/update.sh"

readlink() {
    local path="${@: -1}"
    case "$path" in
        /usr/local) printf '/usr/local\n' ;;
        /usr/local/link-out|/usr/local/../etc) printf '/etc\n' ;;
        /usr/local/../etc/*) printf '/etc/%s\n' "${path#/usr/local/../etc/}" ;;
        *) printf '%s\n' "$path" ;;
    esac
}
load_function "$installer" validate_xui_main_folder
[[ "$(validate_xui_main_folder /usr/local/x-ui)" == /usr/local/x-ui ]]
[[ "$(validate_xui_main_folder /usr/local/custom/panel)" == /usr/local/custom/panel ]]
for path in / /usr/local /etc/x-ui /usr/local/bin/x-ui /usr/local/link-out /usr/local/../etc; do
    if validate_xui_main_folder "$path" >/dev/null 2>&1; then echo "Unsafe path accepted: $path" >&2; exit 1; fi
done
echo 'PASS path validation'
load_function "$updater" validate_xui_main_folder
[[ "$(validate_xui_main_folder /usr/local/x-ui)" == /usr/local/x-ui ]]
if validate_xui_main_folder /usr/local/../etc/x-ui >/dev/null 2>&1; then exit 1; fi
echo 'PASS updater path validation'

load_function "$installer" verify_release_checksum
curl() {
    local out=""; while (($#)); do if [[ "$1" == -o ]]; then out="$2"; shift 2; else shift; fi; done
    case "${CHECKSUM_MODE:-valid}" in
        valid) printf '%s\n' "$EXPECTED_SHA" > "$out"; printf 200 ;;
        mismatch) printf '%064d\n' 0 > "$out"; printf 200 ;;
        missing) printf 404 ;;
    esac
}
archive="$test_dir/archive"; printf 'fixture' > "$archive"
EXPECTED_SHA=$(sha256sum "$archive" | awk '{print $1}')
CHECKSUM_MODE=valid verify_release_checksum https://fixture.invalid/a "$archive" >/dev/null
for mode in mismatch missing; do
    printf fixture > "$archive"
    if CHECKSUM_MODE="$mode" verify_release_checksum https://fixture.invalid/a "$archive" >/dev/null 2>&1; then exit 1; fi
    [[ ! -e "$archive" ]]
done
echo 'PASS checksum fail-closed cases'
load_function "$updater" verify_release_checksum
curl_bin=curl
printf fixture > "$archive"
EXPECTED_SHA=$(sha256sum "$archive" | awk '{print $1}')
CHECKSUM_MODE=valid verify_release_checksum https://fixture.invalid/a "$archive" >/dev/null
for mode in mismatch missing; do
    printf fixture > "$archive"
    if CHECKSUM_MODE="$mode" verify_release_checksum https://fixture.invalid/a "$archive" >/dev/null 2>&1; then exit 1; fi
    [[ ! -e "$archive" ]]
done
echo 'PASS updater checksum fail-closed cases'

load_function "$installer" validate_release_archive_paths
tar() {
    case "${1:-}" in
        -tzf) printf '%s\n' "${ARCHIVE_MEMBERS:-}" ;;
        -tvzf) printf '%s\n' "${ARCHIVE_TYPES:--rw-r--r--}" ;;
        *) return 97 ;;
    esac
}
ARCHIVE_MEMBERS=$'x-ui/\nx-ui/x-ui\nx-ui/bin/xray-linux-amd64'
validate_release_archive_paths fixture.tar.gz
for members in $'x-ui/\n../outside' $'x-ui/\n/etc/private' $'x-ui/\nother/file'; do
    if ARCHIVE_MEMBERS="$members" validate_release_archive_paths fixture.tar.gz >/dev/null 2>&1; then exit 1; fi
done
if ARCHIVE_TYPES='lrwxrwxrwx x x 0 date x-ui/link -> /etc/passwd' validate_release_archive_paths fixture.tar.gz >/dev/null 2>&1; then exit 1; fi
if ARCHIVE_TYPES='crw-r--r-- x x 1, 3 date x-ui/device' validate_release_archive_paths fixture.tar.gz >/dev/null 2>&1; then exit 1; fi
echo 'PASS archive path cases'

load_function "$updater" run_database_migration
mock_cli="$test_dir/x-ui"
cat > "$mock_cli" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == migrate && "${MIGRATION_RESULT:-ok}" == ok ]]
MOCK
chmod +x "$mock_cli"
run_database_migration "$mock_cli"
if MIGRATION_RESULT=fail run_database_migration "$mock_cli" >/dev/null 2>&1; then exit 1; fi
load_function "$installer" run_database_migration
if MIGRATION_RESULT=fail run_database_migration "$mock_cli" >/dev/null 2>&1; then exit 1; fi
echo 'PASS installer and updater migration failures propagate'

load_function "$updater" discard_incomplete_update_backup
update_backup_dir="$test_dir/partial-backup"
mkdir -p "$update_backup_dir"; printf partial > "$update_backup_dir/fragment"
discard_incomplete_update_backup
[[ ! -e "$test_dir/partial-backup" && -z "$update_backup_dir" ]]
echo 'PASS incomplete update backup cleanup'

load_function "$updater" start_xui_service
release=ubuntu
systemctl() { case "$1" in enable) [[ "${SERVICE_ENABLE_RESULT:-ok}" == ok ]] ;; start) [[ "${SERVICE_START_RESULT:-ok}" == ok ]] ;; is-active) [[ "${SERVICE_ACTIVE_RESULT:-ok}" == ok ]] ;; *) return 0 ;; esac; }
start_xui_service
if SERVICE_ENABLE_RESULT=fail start_xui_service >/dev/null 2>&1; then exit 1; fi
if SERVICE_START_RESULT=fail start_xui_service >/dev/null 2>&1; then exit 1; fi
if SERVICE_ACTIVE_RESULT=fail start_xui_service >/dev/null 2>&1; then exit 1; fi
load_function "$installer" start_xui_service
if SERVICE_ENABLE_RESULT=fail start_xui_service >/dev/null 2>&1; then exit 1; fi
if SERVICE_START_RESULT=fail start_xui_service >/dev/null 2>&1; then exit 1; fi
if SERVICE_ACTIVE_RESULT=fail start_xui_service >/dev/null 2>&1; then exit 1; fi
echo 'PASS installer and updater service failures propagate'

systemctl() {
    case "$1" in
        is-active)
            if [[ "${SERVICE_QUERY_ERROR:-0}" == 1 ]]; then return 1; fi
            if [[ "${SERVICE_STATE:-inactive}" == active ]]; then return 0; else return 3; fi
            ;;
        stop)
            [[ "${SERVICE_STOP_RESULT:-ok}" == ok ]] || return 1
            [[ "${SERVICE_STOP_STUCK:-0}" == 1 ]] || SERVICE_STATE=inactive
            ;;
        *) return 0 ;;
    esac
}
load_function "$updater" stop_xui_service_if_active
release=ubuntu; SERVICE_STATE=active; SERVICE_STOP_RESULT=ok
stop_xui_service_if_active
[[ "$SERVICE_STATE" == inactive ]]
SERVICE_STATE=active; SERVICE_STOP_RESULT=fail
if stop_xui_service_if_active >/dev/null 2>&1; then exit 1; fi
SERVICE_STATE=active; SERVICE_STOP_RESULT=ok; SERVICE_STOP_STUCK=1
if stop_xui_service_if_active >/dev/null 2>&1; then exit 1; fi
SERVICE_STATE=inactive; SERVICE_QUERY_ERROR=1
if stop_xui_service_if_active >/dev/null 2>&1; then exit 1; fi
unset SERVICE_QUERY_ERROR
load_function "$installer" stop_xui_service_if_active
SERVICE_STATE=active; SERVICE_STOP_RESULT=ok; SERVICE_STOP_STUCK=0
stop_xui_service_if_active
[[ "$SERVICE_STATE" == inactive ]]
SERVICE_STATE=inactive; SERVICE_QUERY_ERROR=1
if stop_xui_service_if_active >/dev/null 2>&1; then exit 1; fi
unset SERVICE_QUERY_ERROR
echo 'PASS migration precondition checks service is stopped'

mkdir -p "$test_dir/mock-bin"
cat > "$test_dir/mock-bin/rc-service" <<'MOCK'
#!/usr/bin/env bash
state=$(cat "$RC_STATE_FILE") || exit 1
case "${1:-} ${2:-}" in
    'x-ui status')
        case "$state" in started) exit 0 ;; stopped) exit 3 ;; inactive) exit 16 ;; error) exit 1 ;; *) exit 1 ;; esac
        ;;
    'x-ui stop')
        [[ "${RC_STOP_RESULT:-ok}" == ok ]] || exit 1
        printf 'stopped\n' > "$RC_STATE_FILE"
        ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$test_dir/mock-bin/rc-service"
PATH="$test_dir/mock-bin:$PATH"
export RC_STATE_FILE="$test_dir/openrc-state"
printf 'stopped\n' > "$RC_STATE_FILE"
load_function "$updater" stop_xui_service_if_active
openrc_xui_service_exists() { [[ "${MOCK_OPENRC_SERVICE_EXISTS:-0}" == 1 ]]; }
release=alpine; MOCK_OPENRC_SERVICE_EXISTS=0; stop_xui_service_if_active
MOCK_OPENRC_SERVICE_EXISTS=1; RC_SERVICE_STATE=stopped; stop_xui_service_if_active
printf 'started\n' > "$RC_STATE_FILE"; stop_xui_service_if_active
[[ "$(cat "$RC_STATE_FILE")" == stopped ]]
printf 'error\n' > "$RC_STATE_FILE"; if stop_xui_service_if_active >/dev/null 2>&1; then exit 1; fi
load_function "$installer" stop_xui_service_if_active
release=alpine; MOCK_OPENRC_SERVICE_EXISTS=0; stop_xui_service_if_active
MOCK_OPENRC_SERVICE_EXISTS=1; RC_SERVICE_STATE=stopped; printf 'stopped\n' > "$RC_STATE_FILE"; stop_xui_service_if_active
printf 'started\n' > "$RC_STATE_FILE"; stop_xui_service_if_active
printf 'error\n' > "$RC_STATE_FILE"; if stop_xui_service_if_active >/dev/null 2>&1; then exit 1; fi
echo 'PASS installer and updater OpenRC missing, stopped, active, and query-error handling'

# Service enablement state must distinguish enabled, disabled, missing, and
# manager-query errors before any destructive transaction starts.
for script in "$installer" "$updater"; do
    load_function "$script" query_xui_service_enabled_state
    load_function "$script" set_xui_service_enabled_state
    release=ubuntu; xui_service="$test_dir/no-systemd-unit"
    systemctl() {
        [[ "${1:-}" == is-enabled && "${2:-}" == x-ui ]] || return 98
        printf '%s' "${MOCK_SYSTEMCTL_OUTPUT:-}"
        return "${MOCK_SYSTEMCTL_STATUS:-0}"
    }
    MOCK_SYSTEMCTL_OUTPUT=enabled MOCK_SYSTEMCTL_STATUS=0
    [[ "$(query_xui_service_enabled_state)" == enabled ]]
    MOCK_SYSTEMCTL_OUTPUT=disabled MOCK_SYSTEMCTL_STATUS=1
    [[ "$(query_xui_service_enabled_state)" == disabled ]]
    MOCK_SYSTEMCTL_OUTPUT=not-found MOCK_SYSTEMCTL_STATUS=4
    [[ "$(query_xui_service_enabled_state)" == missing ]]
    mkdir -p "$test_dir/no-systemd-unit"; : > "$test_dir/no-systemd-unit/x-ui.service"
    if query_xui_service_enabled_state >/dev/null 2>&1; then exit 1; fi
    rm -rf "$test_dir/no-systemd-unit"
    MOCK_SYSTEMCTL_OUTPUT='Failed to connect to system bus' MOCK_SYSTEMCTL_STATUS=1
    if query_xui_service_enabled_state >/dev/null 2>&1; then exit 1; fi
    MOCK_SYSTEMCTL_OUTPUT=static MOCK_SYSTEMCTL_STATUS=0
    if query_xui_service_enabled_state >/dev/null 2>&1; then exit 1; fi

    # State restoration must use the requested state and fail if the manager
    # cannot apply it.
    SYSTEMCTL_STATE_ACTION=
    systemctl() { SYSTEMCTL_STATE_ACTION="$*"; [[ "${MOCK_STATE_APPLY_RESULT:-ok}" == ok ]]; }
    set_xui_service_enabled_state enabled; [[ "$SYSTEMCTL_STATE_ACTION" == 'enable x-ui' ]]
    set_xui_service_enabled_state disabled; [[ "$SYSTEMCTL_STATE_ACTION" == 'disable x-ui' ]]
    set_xui_service_enabled_state missing; [[ "$SYSTEMCTL_STATE_ACTION" == 'disable x-ui' ]]
    rm -rf "$test_dir/no-systemd-unit"
    SYSTEMCTL_STATE_ACTION=; set_xui_service_enabled_state missing; [[ -z "$SYSTEMCTL_STATE_ACTION" ]]
    MOCK_STATE_APPLY_RESULT=fail
    if set_xui_service_enabled_state disabled; then exit 1; fi
    unset MOCK_STATE_APPLY_RESULT

    release=alpine
    openrc_xui_service_exists() { [[ "${MOCK_OPENRC_SERVICE_EXISTS:-0}" == 1 ]]; }
    rc-update() {
        case "${1:-} ${2:-} ${3:-}" in
            'show default ')
                [[ "${MOCK_RC_QUERY_RESULT:-ok}" == ok ]] || return 1
                printf '%s' "${MOCK_RC_UPDATE_OUTPUT:-}"
                ;;
            'add x-ui default'|'del x-ui default')
                RC_STATE_ACTION="$*"
                [[ "${MOCK_RC_APPLY_RESULT:-ok}" == ok ]]
                ;;
            *) return 97 ;;
        esac
    }
    MOCK_OPENRC_SERVICE_EXISTS=0
    [[ "$(query_xui_service_enabled_state)" == missing ]]
    MOCK_OPENRC_SERVICE_EXISTS=1; MOCK_RC_UPDATE_OUTPUT=$' x-ui | default\n'; MOCK_RC_QUERY_RESULT=ok
    [[ "$(query_xui_service_enabled_state)" == enabled ]]
    MOCK_RC_UPDATE_OUTPUT=''; [[ "$(query_xui_service_enabled_state)" == disabled ]]
    MOCK_RC_QUERY_RESULT=fail
    if query_xui_service_enabled_state >/dev/null 2>&1; then exit 1; fi
    RC_STATE_ACTION=; MOCK_RC_APPLY_RESULT=ok
    set_xui_service_enabled_state enabled; [[ "$RC_STATE_ACTION" == 'add x-ui default' ]]
    set_xui_service_enabled_state disabled; [[ "$RC_STATE_ACTION" == 'del x-ui default' ]]
    set_xui_service_enabled_state missing; [[ "$RC_STATE_ACTION" == 'del x-ui default' ]]
    MOCK_OPENRC_SERVICE_EXISTS=0; RC_STATE_ACTION=; set_xui_service_enabled_state missing; [[ -z "$RC_STATE_ACTION" ]]
    MOCK_RC_APPLY_RESULT=fail
    if set_xui_service_enabled_state disabled; then exit 1; fi
    unset MOCK_RC_QUERY_RESULT MOCK_RC_APPLY_RESULT MOCK_OPENRC_SERVICE_EXISTS MOCK_RC_UPDATE_OUTPUT
done
echo 'PASS systemd/OpenRC enablement state capture and rollback for installer and updater'

load_function "$updater" rollback_update
rm() {
    local arg
    for arg in "$@"; do
        [[ "$arg" == -* ]] && continue
        if [[ "$arg" == /usr/bin/x-ui ]]; then printf 'mocked removal\n' > "$test_dir/cli-removal"; return 0; fi
        [[ "$arg" == "$test_dir"* ]] || return 0
    done
    command rm "$@"
}
release=ubuntu; update_old_service_active=0; update_old_service_enabled=disabled; update_transaction_active=1
update_backup_dir="$test_dir/backup"; xui_folder="$test_dir/panel/x-ui"; xui_service="$test_dir/systemd"
mkdir -p "$update_backup_dir/app" "$update_backup_dir/system" "$xui_folder" "$xui_service"
printf 'old\n' > "$update_backup_dir/app/version"; printf 'failed\n' > "$xui_folder/version"
printf 'missing\n' > "$update_backup_dir/database.type"
printf '%s\n' "$test_dir/panel/db/x-ui.db" > "$update_backup_dir/database.path"
mkdir -p "$test_dir/panel/db"; printf 'new database' > "$test_dir/panel/db/x-ui.db"; printf wal > "$test_dir/panel/db/x-ui.db-wal"; printf shm > "$test_dir/panel/db/x-ui.db-shm"
systemctl() { return 0; }
rollback_update
[[ "$(cat "$xui_folder/version")" == old && "$update_transaction_active" == 0 ]]
[[ ! -e "$test_dir/panel/db/x-ui.db" && ! -e "$test_dir/panel/db/x-ui.db-wal" && ! -e "$test_dir/panel/db/x-ui.db-shm" ]]
[[ -s "$test_dir/cli-removal" ]]
echo 'PASS update application/database rollback'

update_transaction_active=1; update_backup_dir="$test_dir/invalid-backup"
xui_folder="$test_dir/invalid-panel/x-ui"; xui_service="$test_dir/invalid-systemd"
mkdir -p "$update_backup_dir/app" "$update_backup_dir/system" "$xui_folder" "$xui_service"
printf 'old\n' > "$update_backup_dir/app/version"; printf 'invalid\n' > "$update_backup_dir/database.type"
systemctl() { return 0; }
if rollback_update >/dev/null 2>&1; then exit 1; fi
[[ "$update_transaction_active" == 1 && -d "$update_backup_dir" ]]
echo 'PASS invalid rollback database metadata fails closed and retains backup'

# Exercise the install rollback function with all filesystem paths sandboxed
# under test_dir; system locations are no-op mocked so the host is untouched.
install_rollback_fn=$(awk '$0 ~ /^    _install_rollback\(\) \{$/ {copy=1; sub(/^    /, ""); print; next} copy && /^    \}$/ {print "}"; exit} copy {sub(/^    /, ""); print}' "$installer")
[[ -n "$install_rollback_fn" ]]
eval "$install_rollback_fn"
install_backup_dir="$test_dir/install-backup"; release_stage=""; xui_folder="$test_dir/install/panel"; xui_service="$test_dir/install/systemd"
release=ubuntu; old_service_active=0; old_service_enabled=disabled
mkdir -p "$install_backup_dir/app" "$install_backup_dir/migration-cli" "$xui_folder" "$xui_service"
printf 'prior install\n' > "$install_backup_dir/app/version"; printf 'failed install\n' > "$xui_folder/version"
printf 'missing\n' > "$install_backup_dir/database.type"; printf '%s\n' "$test_dir/install/db/x-ui.db" > "$install_backup_dir/database.path"
systemctl() { return 0; }
( false; _install_rollback ) >/dev/null 2>&1 || [[ $? == 1 ]]
[[ "$(cat "$xui_folder/version")" == 'prior install' ]]
echo 'PASS install application rollback (system paths mocked)'

install_backup_dir="$test_dir/invalid-install-backup"; xui_folder="$test_dir/invalid-install/panel"; xui_service="$test_dir/invalid-install/systemd"
mkdir -p "$install_backup_dir/app" "$install_backup_dir/migration-cli" "$xui_folder" "$xui_service"
printf 'prior install\n' > "$install_backup_dir/app/version"; printf 'invalid\n' > "$install_backup_dir/database.type"
( false; _install_rollback ) >/dev/null 2>&1 || [[ $? == 1 ]]
[[ -d "$install_backup_dir" ]]
echo 'PASS invalid installer rollback metadata fails closed and retains backup'

[[ $(grep -c 'run_database_migration "\${xui_folder}/x-ui"' "$installer") == 1 ]]
[[ $(grep -c 'run_database_migration "\${xui_folder}/x-ui"' "$updater") == 1 ]]
[[ $(grep -n 'stop_xui_service_if_active ||' "$installer" | tail -n1 | cut -d: -f1) -lt $(grep -n 'run_database_migration "\${xui_folder}/x-ui"' "$installer" | cut -d: -f1) ]]
[[ $(grep -n 'stop_xui_service_if_active ||' "$updater" | tail -n1 | cut -d: -f1) -lt $(grep -n 'run_database_migration "\${xui_folder}/x-ui"' "$updater" | cut -d: -f1) ]]
[[ $(grep -Fn 'local script_ref="${tag_version}"' "$installer" | head -n1 | cut -d: -f1) -lt $(grep -Fn 'curl -fLRo "$xui_rc_temp"' "$installer" | head -n1 | cut -d: -f1) ]]
[[ $(grep -n 'if ! old_service_enabled=$(query_xui_service_enabled_state)' "$installer" | cut -d: -f1) -lt $(grep -n 'stop_xui_service_if_active ||' "$installer" | tail -n1 | cut -d: -f1) ]]
[[ $(grep -n 'if ! update_old_service_enabled=$(query_xui_service_enabled_state)' "$updater" | cut -d: -f1) -lt $(grep -n 'stop_xui_service_if_active ||' "$updater" | tail -n1 | cut -d: -f1) ]]
! grep -Eq 'rm -f .*realpath .*\$0|rm -f .*\$\{cur_dir\}/\$\{script_name\}' "$installer" "$updater"
echo 'PASS one migration per flow and unsupported architecture preserves scripts'
