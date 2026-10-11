#!/bin/sh
set -eu
usage() {
  cat <<'EOF'
Usage: wsl-migrate [--dry-run] [--backup-dir WINDOWS_MOUNTED_PATH] [--install-location WINDOWS_MOUNTED_PATH] SOURCE_DISTRO [NEW_DISTRO_NAME]
       wsl-migrate --resume BACKUP_TAR SOURCE_DISTRO [NEW_DISTRO_NAME]
       wsl-migrate --rollback PREVIOUS_DISTRO

Create a full WSL export of SOURCE_DISTRO, then import it as a second distro.
The source remains registered. The clone keeps the source OS version and
configuration; this does not upgrade it to the current image. Use --resume to
continue from an existing export after an interrupted import.
EOF
}
fail() { echo "wsl-migrate: $*" >&2; exit 1; }

DISTRO_LIST=
SOURCE_STOPPED=0
EXPORT_VALID=0
REFRESH_SSH_KEYS=0
CLONE_IMPORTED=0
UTILITY_INSTALLED=0
MIGRATION_COMPLETE=0
BACKUP_FILE=
SCRIPT_PATH=
SOURCE_PREPARED=0
SOURCE_STOP_ATTEMPTED=0
SOURCE_STOPPED=0
CLONE_IMPORTED=0
CONTENT_MANIFEST=
PREVIOUS_DEFAULT=
SOURCE_USED_KB=
CONTENT_DIFFERENCES=0

load_distro_list() {
  if ! DISTRO_LIST=$("$WSL_EXE" --list --verbose 2>/dev/null); then
    return 1
  fi
  DISTRO_LIST=$(printf '%s\n' "$DISTRO_LIST" | tr -d '\r')
  [ -n "$DISTRO_LIST" ]
}

distro_is_registered() {
  printf '%s\n' "$DISTRO_LIST" | awk -v wanted="$1" '
    {
      name = $1
      if (name == "*") name = $2
      sub(/^\*/, "", name)
      if (name == wanted) found = 1
    }
    END { exit found ? 0 : 1 }
  '
}

default_distro() {
  printf '%s\n' "$DISTRO_LIST" | awk '$1 == "*" {print $2; exit}'
}

distro_is_running() {
  printf '%s\n' "$DISTRO_LIST" | awk -v wanted="$1" '
    {
      if ($1 == "*") { name = $2; state = $3 }
      else { name = $1; state = $2 }
      sub(/^\*/, "", name)
      if (name == wanted && state == "Running") found = 1
    }
    END { exit found ? 0 : 1 }
  '
}

distro_wsl_version() {
  printf '%s\n' "$DISTRO_LIST" | awk -v wanted="$1" '
    {
      name = $1
      if (name == "*") name = $2
      sub(/^\*/, "", name)
      if (name == wanted && $NF ~ /^[12]$/) {
        print $NF
        exit
      }
    }
  '
}

migration_exit() {
  exit_status=$?
  if [ "$exit_status" -eq 0 ]; then return; fi
  echo >&2
  if [ "$MIGRATION_COMPLETE" -eq 1 ]; then
    echo "The clone was created and verified, but a later optional action failed." >&2
  else
    echo "Migration stopped before completion. No distro or backup was automatically deleted." >&2
  fi
  if [ "$SOURCE_PREPARED" -eq 1 ] && [ "$SOURCE_STOPPED" -eq 0 ]; then
    echo "The source remains registered. It may be running with Docker stopped; start it from PowerShell with: wsl --distribution $SOURCE_DISTRO" >&2
  fi
  if [ "$SOURCE_STOP_ATTEMPTED" -eq 1 ] && [ "$SOURCE_STOPPED" -eq 1 ]; then
    echo "The source remains registered. Start it from PowerShell with: wsl --distribution $SOURCE_DISTRO" >&2
  fi
  if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
    if [ "$EXPORT_VALID" -eq 1 ]; then
      echo "Validated export or recovery copy: $BACKUP_FILE" >&2
      echo "Continue from this export with: wsl-migrate --resume \"$BACKUP_FILE\" $SOURCE_DISTRO $NEW_DISTRO" >&2
    else
      echo "A partial or unvalidated export may exist at: $BACKUP_FILE" >&2
    fi
  fi
  if [ "$CLONE_IMPORTED" -eq 1 ]; then
    echo "The clone remains registered: $NEW_DISTRO" >&2
  fi
  if [ "$CLONE_IMPORTED" -eq 1 ] && [ "$UTILITY_INSTALLED" -eq 0 ] && [ -n "$SCRIPT_PATH" ]; then
    echo "If the clone is usable, retry command installation from this distro:" >&2
    echo "  cat \"$SCRIPT_PATH\" | \"$WSL_EXE\" --distribution \"$NEW_DISTRO\" --user root --exec sh -c 'umask 022; cat > /usr/local/bin/wsl-migrate && chmod 0755 /usr/local/bin/wsl-migrate'" >&2
  fi
}
trap migration_exit EXIT

DRY_RUN=0
ROLLBACK=0
RESUME=0
RESUME_ARCHIVE=
BACKUP_DIR=
INSTALL_LOCATION=
SOURCE_DISTRO=
NEW_DISTRO=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --resume) [ "$#" -ge 2 ] || fail "--resume requires a backup tar path"; RESUME=1; RESUME_ARCHIVE=$2; shift 2 ;;
    --rollback) ROLLBACK=1; shift ;;
    --backup-dir) [ "$#" -ge 2 ] || fail "--backup-dir requires a Windows-mounted path"; BACKUP_DIR=$2; shift 2 ;;
    --install-location) [ "$#" -ge 2 ] || fail "--install-location requires a Windows-mounted path"; INSTALL_LOCATION=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) fail "unknown option: $1" ;;
    *)
      if [ -z "$SOURCE_DISTRO" ]; then SOURCE_DISTRO=$1
      elif [ -z "$NEW_DISTRO" ]; then NEW_DISTRO=$1
      else fail "specify only a source distro and an optional new distro name"; fi
      shift ;;
  esac
done

if [ "$ROLLBACK" -eq 1 ] && [ -z "$SOURCE_DISTRO" ]; then
  [ -r /etc/wsl-migrate/previous-default ] || fail "no recorded previous default; specify one: wsl-migrate --rollback DISTRO"
  SOURCE_DISTRO=$(cat /etc/wsl-migrate/previous-default)
fi
[ -n "$SOURCE_DISTRO" ] || { usage >&2; exit 2; }
case "$SOURCE_DISTRO" in *[!A-Za-z0-9_.-]*|'') fail "distro names may contain only letters, digits, dot, underscore, and hyphen" ;; esac
if [ -n "$NEW_DISTRO" ]; then
  case "$NEW_DISTRO" in *[!A-Za-z0-9_.-]*|'') fail "distro names may contain only letters, digits, dot, underscore, and hyphen" ;; esac
fi

CURRENT_DISTRO=${WSL_DISTRO_NAME-}
[ -n "$CURRENT_DISTRO" ] || fail "run this command inside the new WSL distro"
[ "$SOURCE_DISTRO" != "$CURRENT_DISTRO" ] || fail "source and current distro are the same"

WSL_EXE=${WSL_EXE-}
if [ -z "$WSL_EXE" ]; then
  for candidate in /mnt/c/Windows/System32/wsl.exe /mnt/c/WINDOWS/System32/wsl.exe; do
    if [ -x "$candidate" ]; then WSL_EXE=$candidate; break; fi
  done
fi
[ -n "$WSL_EXE" ] || fail "cannot find wsl.exe; set WSL_EXE to its mounted Windows path"
WINDOWS_DIR=$(dirname -- "$WSL_EXE")
CMD_EXE=$WINDOWS_DIR/cmd.exe
[ -x "$CMD_EXE" ] || fail "cannot find cmd.exe beside wsl.exe"
WINDOWS_USERPROFILE=$("$CMD_EXE" /d /c echo %USERPROFILE% | tr -d '\r')
WINDOWS_LOCALAPPDATA=$("$CMD_EXE" /d /c echo %LOCALAPPDATA% | tr -d '\r')
[ -n "$WINDOWS_USERPROFILE" ] || fail "could not read the Windows user profile"
[ -n "$WINDOWS_LOCALAPPDATA" ] || fail "could not read Windows LocalAppData"

if [ "$ROLLBACK" -eq 1 ]; then
  [ -z "$NEW_DISTRO" ] || fail "--rollback accepts one distro name"
  [ "$DRY_RUN" -eq 0 ] || fail "--dry-run cannot be combined with --rollback"
  if [ -n "$BACKUP_DIR" ] || [ -n "$INSTALL_LOCATION" ]; then fail "path options cannot be combined with --rollback"; fi
  "$WSL_EXE" --set-default "$SOURCE_DISTRO"
  echo "Default WSL distro set to $SOURCE_DISTRO. No distro data was changed."
  exit 0
fi

if [ -z "$NEW_DISTRO" ]; then
  proposed_name=$SOURCE_DISTRO-migrated
  printf 'New distro name [%s]: ' "$proposed_name"
  IFS= read -r NEW_DISTRO || NEW_DISTRO=
  [ -n "$NEW_DISTRO" ] || NEW_DISTRO=$proposed_name
  case "$NEW_DISTRO" in *[!A-Za-z0-9_.-]*|'') fail "distro names may contain only letters, digits, dot, underscore, and hyphen" ;; esac
fi
[ "$NEW_DISTRO" != "$SOURCE_DISTRO" ] || fail "new distro name must differ from the source"
[ "$NEW_DISTRO" != "$CURRENT_DISTRO" ] || fail "new distro name is already the current distro"

load_distro_list || fail "could not read 'wsl --list --verbose'; no distro was stopped"
distro_is_registered "$SOURCE_DISTRO" || fail "source distro is not registered in WSL: $SOURCE_DISTRO"
if distro_is_registered "$NEW_DISTRO"; then
  if [ "$RESUME" -eq 1 ]; then CLONE_IMPORTED=1
  else fail "new distro name is already registered in WSL: $NEW_DISTRO"; fi
fi
SOURCE_WSL_VERSION=$(distro_wsl_version "$SOURCE_DISTRO")
case "$SOURCE_WSL_VERSION" in 1|2) ;; *) fail "could not detect the source WSL version; no distro was stopped";; esac
TARGET_WSL_VERSION=$SOURCE_WSL_VERSION
PREVIOUS_DEFAULT=$(default_distro)
[ -n "$PREVIOUS_DEFAULT" ] || fail "could not detect the current default WSL distro"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required to record the export checksum"

safe_name=$(printf '%s' "$NEW_DISTRO" | tr -c 'A-Za-z0-9_.-' '_')
if [ -z "$BACKUP_DIR" ]; then
  BACKUP_DIR=$(wslpath -u "$WINDOWS_USERPROFILE")/Documents/myAlpine-wsl-backups
fi
if [ -z "$INSTALL_LOCATION" ]; then
  INSTALL_LOCATION=$(wslpath -u "$WINDOWS_LOCALAPPDATA")/AlpineWSL-$safe_name
fi
case "$BACKUP_DIR" in /mnt/[A-Za-z]/*) ;; *) fail "backup directory must be on a mounted Windows drive, such as /mnt/c/Users/...";; esac
case "$INSTALL_LOCATION" in /mnt/[A-Za-z]/*) ;; *) fail "install location must be on a mounted Windows drive, such as /mnt/c/Users/...";; esac
if [ "$RESUME" -eq 1 ] && [ "$CLONE_IMPORTED" -eq 0 ] && [ -e "$INSTALL_LOCATION" ]; then
  fail "resume install path already exists but target is not registered; choose another --install-location and keep the partial data"
fi
if [ "$RESUME" -eq 0 ]; then
  [ ! -e "$INSTALL_LOCATION" ] || fail "install location already exists; choose an empty, unused path: $INSTALL_LOCATION"
fi
INSTALL_PARENT=$(dirname -- "$INSTALL_LOCATION")
[ -d "$INSTALL_PARENT" ] || fail "parent of install location does not exist: $INSTALL_PARENT"
[ -w "$INSTALL_PARENT" ] || fail "install location parent is not writable: $INSTALL_PARENT"
BACKUP_PARENT=$BACKUP_DIR
while [ ! -d "$BACKUP_PARENT" ]; do
  NEXT_BACKUP_PARENT=$(dirname -- "$BACKUP_PARENT")
  [ "$NEXT_BACKUP_PARENT" != "$BACKUP_PARENT" ] || fail "could not find an existing parent for backup directory"
  BACKUP_PARENT=$NEXT_BACKUP_PARENT
done
[ -w "$BACKUP_PARENT" ] || fail "backup location is not writable: $BACKUP_PARENT"
AVAILABLE_KB=$(df -Pk "$BACKUP_PARENT" 2>/dev/null | awk 'END {print $4}')
case "$AVAILABLE_KB" in *[!0-9]*|'') AVAILABLE_GB=unknown ;; *) AVAILABLE_GB=$(awk -v kb="$AVAILABLE_KB" 'BEGIN {printf "%.1f", kb / 1048576}') ;; esac
INSTALL_AVAILABLE_KB=$(df -Pk "$INSTALL_PARENT" 2>/dev/null | awk 'END {print $4}')
case "$INSTALL_AVAILABLE_KB" in *[!0-9]*|'') INSTALL_AVAILABLE_GB=unknown ;; *) INSTALL_AVAILABLE_GB=$(awk -v kb="$INSTALL_AVAILABLE_KB" 'BEGIN {printf "%.1f", kb / 1048576}') ;; esac
WINDOWS_INSTALL_LOCATION=$(wslpath -w "$INSTALL_LOCATION")
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
if [ "$RESUME" -eq 1 ]; then
  BACKUP_FILE=$RESUME_ARCHIVE
  case "$BACKUP_FILE" in /mnt/[A-Za-z]/*) ;; *) fail "resume archive must be on a mounted Windows drive";; esac
  [ -s "$BACKUP_FILE" ] || fail "resume archive does not exist or is empty: $BACKUP_FILE"
  CONTENT_MANIFEST=$BACKUP_FILE.content-manifest
  CHECKSUM_FILE=$BACKUP_FILE.sha256
  [ -s "$CONTENT_MANIFEST" ] || fail "source content manifest is missing; this archive cannot be resumed safely"
  [ -r "$CHECKSUM_FILE" ] || fail "archive checksum file is missing; this archive cannot be resumed safely"
  EXPORT_SHA256=$(awk 'NR==1 {print $1}' "$CHECKSUM_FILE")
  [ "$(sha256sum "$BACKUP_FILE" | awk '{print $1}')" = "$EXPORT_SHA256" ] || fail "resume archive checksum does not match the saved checksum"
  tar -tf "$BACKUP_FILE" >/dev/null 2>&1 || fail "resume archive is not a readable tar archive"
  EXPORT_VALID=1
else
  BACKUP_FILE=$BACKUP_DIR/$safe_name-$timestamp.tar
  CONTENT_MANIFEST=$BACKUP_FILE.content-manifest
  CHECKSUM_FILE=$BACKUP_FILE.sha256
  [ ! -e "$BACKUP_FILE" ] || fail "backup file already exists: $BACKUP_FILE"
fi
WINDOWS_BACKUP=$(wslpath -w "$BACKUP_FILE")

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF
Source distro: $SOURCE_DISTRO
Current distro (script host): $CURRENT_DISTRO
New cloned distro: $NEW_DISTRO
Full export: $BACKUP_FILE
New distro install location: $INSTALL_LOCATION
Import version: WSL $TARGET_WSL_VERSION (preserving the source version)
Free space: backup drive $AVAILABLE_GB GiB; install drive $INSTALL_AVAILABLE_GB GiB

This creates a full clone of the old distro. It does not upgrade the cloned
Alpine/system packages to the current Release image. Neither distro is removed.
EOF
  exit 0
fi

cat <<EOF

==================== Migration processing overview ====================
Source distro: $SOURCE_DISTRO
New cloned distro: $NEW_DISTRO
Source WSL version: WSL $SOURCE_WSL_VERSION
Clone WSL version: WSL $TARGET_WSL_VERSION (same as source)
Full export backup: $BACKUP_FILE
New install location: $INSTALL_LOCATION
Previous default distro: $PREVIOUS_DEFAULT
Free space: backup drive $AVAILABLE_GB GiB; install drive $INSTALL_AVAILABLE_GB GiB

Will be copied as a full distro clone:
  - Alpine/system files, installed packages, users, home directories,
    /etc configuration, and persistent Docker images/containers/volumes.
  - The old distro's /etc/wsl.conf and default-user setting are preserved.

Will not be copied:
  - Windows-side .wslconfig, Windows Terminal profiles, WSL registration
    settings, or files stored outside the distro filesystem.
  - Running process state. The source distro is stopped before export.

Actions after confirmation:
  1. Stop database and application workloads, then gracefully power off the source.
  2. Export and validate a retained tar backup, or reuse an existing one with --resume.
  3. Check backup and install drive space before importing as "$NEW_DISTRO".
  4. Verify key configuration and compare /home and Docker file contents.
  5. Install wsl-migrate in the clone and ask whether to set it as default.

Important risks and limitations:
  - This preserves the old distro; it does not upgrade it to the current
    Release image. WSL 1 and WSL 2 have different features and behavior; the clone keeps the source version.
  - Preserved boot commands or user settings may need adjustment for this
    Windows/WSL version.
  - Host identity files, including SSH host keys and /etc/machine-id, are copied.
    If both copies provide network services, they may appear as the same host.
    You can optionally regenerate SSH host keys in the clone after import.
  - Running both copies can start duplicate services or Docker workloads,
    compete for ports, and operate on duplicated container data. Prefer
    testing one copy at a time.
  - The export can be large; both backup and install drives need enough space.
    The old distro stays registered and the export remains available for recovery.
  - Stop application and database workloads first. Docker is stopped when
    possible, then the source is synced and gracefully powered off.
  - After import, the script compares important configs and hashes files in
    /home and /var/lib/docker against the source manifest.

No changes have been made yet. Enter y to review the stop confirmation;
anything else cancels.
=======================================================================

Proceed with this migration plan? [y/N] 
EOF
IFS= read -r answer || answer=
case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled. No distro was stopped or imported."; exit 0 ;; esac
printf 'Regenerate SSH host keys in the clone after import? [y/N] '
IFS= read -r answer || answer=
case "$answer" in y|Y|yes|YES) REFRESH_SSH_KEYS=1 ;; *) REFRESH_SSH_KEYS=0 ;; esac
if [ "$RESUME" -eq 0 ]; then
  printf 'Stop app/database workloads in the source, then type READY to continue: '
  IFS= read -r answer || answer=
  [ "$answer" = READY ] || { echo "Cancelled. No source service was stopped."; exit 0; }
  echo "Stopping Docker if configured, syncing, and measuring source size..."
  # shellcheck disable=SC2016
  PREP_OUTPUT=$("$WSL_EXE" --distribution "$SOURCE_DISTRO" --user root --exec sh -c '
    if [ -x /etc/init.d/docker ] && command -v rc-service >/dev/null 2>&1; then
      rc-service --nodeps --ifstarted docker stop || exit 20
    elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker; then
      systemctl stop docker || exit 21
    fi
    sync || exit 22
    du -skx /
  ' 2>/dev/null) || fail "could not stop Docker, sync the source, or measure its used space"
  SOURCE_USED_KB=$(printf '%s\n' "$PREP_OUTPUT" | awk '$1 ~ /^[0-9]+$/ {used=$1} END {print used}' | tr -d '\r')
  case "$SOURCE_USED_KB" in *[!0-9]*|'') fail "could not read the source root filesystem size";; esac
  SOURCE_PREPARED=1
  # shellcheck disable=SC2016
  "$WSL_EXE" --distribution "$SOURCE_DISTRO" --user root --exec sh -c '
    command -v sha256sum >/dev/null 2>&1 || exit 31
    for root in /home /var/lib/docker; do
      if [ -d "$root" ]; then
        printf "DIR %s\n" "$root"
        find "$root" -type f -exec sha256sum "{}" \;
        find "$root" -type l -exec sh -c '\''for path do printf "LINK %s -> %s\n" "$path" "$(readlink "$path")"; done'\'' sh "{}" \;
      else
        printf "MISSING %s\n" "$root"
      fi
    done
  ' > "$CONTENT_MANIFEST.raw" || fail "could not record source home and Docker file hashes"
  tr -d '\r' < "$CONTENT_MANIFEST.raw" | LC_ALL=C sort > "$CONTENT_MANIFEST"
  rm -f -- "$CONTENT_MANIFEST.raw"
  BACKUP_DISK=$(df -Pk "$BACKUP_PARENT" | awk 'END {print $1 "|" $4}')
  INSTALL_DISK=$(df -Pk "$INSTALL_PARENT" | awk 'END {print $1 "|" $4}')
  BACKUP_FS=$(printf '%s\n' "$BACKUP_DISK" | awk -F'|' '{print $1}')
  BACKUP_FREE_KB=$(printf '%s\n' "$BACKUP_DISK" | awk -F'|' '{print $2}')
  INSTALL_FS=$(printf '%s\n' "$INSTALL_DISK" | awk -F'|' '{print $1}')
  INSTALL_FREE_KB=$(printf '%s\n' "$INSTALL_DISK" | awk -F'|' '{print $2}')
  case "$BACKUP_FREE_KB:$INSTALL_FREE_KB" in *[!0-9:]*|:*) fail "could not read free space for both drives";; esac
  BACKUP_REQUIRED_KB=$(awk -v kb="$SOURCE_USED_KB" 'BEGIN {printf "%.0f", kb * 1.20 + 1048576}')
  INSTALL_REQUIRED_KB=$BACKUP_REQUIRED_KB
  if [ "$BACKUP_FS" = "$INSTALL_FS" ]; then
    TOTAL_REQUIRED_KB=$((BACKUP_REQUIRED_KB + INSTALL_REQUIRED_KB))
    [ "$BACKUP_FREE_KB" -ge "$TOTAL_REQUIRED_KB" ] || fail "not enough space on the shared backup/install drive; need about $(awk -v kb="$TOTAL_REQUIRED_KB" 'BEGIN {printf "%.1f", kb/1048576}') GiB"
  else
    [ "$BACKUP_FREE_KB" -ge "$BACKUP_REQUIRED_KB" ] || fail "not enough backup space; need about $(awk -v kb="$BACKUP_REQUIRED_KB" 'BEGIN {printf "%.1f", kb/1048576}') GiB"
    [ "$INSTALL_FREE_KB" -ge "$INSTALL_REQUIRED_KB" ] || fail "not enough install space; need about $(awk -v kb="$INSTALL_REQUIRED_KB" 'BEGIN {printf "%.1f", kb/1048576}') GiB"
  fi
  echo "Source used: $(awk -v kb="$SOURCE_USED_KB" 'BEGIN {printf "%.1f", kb/1048576}') GiB; estimates include 20% plus 1 GiB headroom per copy."
  printf 'Type YES to gracefully power off "%s" and begin export: ' "$SOURCE_DISTRO"
else
  tar -tf "$BACKUP_FILE" >/dev/null 2>&1 || fail "resume archive is not a readable tar archive"
  if [ "$CLONE_IMPORTED" -eq 0 ]; then
    archive_kb=$(du -k "$BACKUP_FILE" | awk 'NR==1 {print $1}')
    INSTALL_REQUIRED_KB=$(awk -v kb="$archive_kb" 'BEGIN {printf "%.0f", kb * 1.30 + 1048576}')
    INSTALL_FREE_KB=$(df -Pk "$INSTALL_PARENT" | awk 'END {print $4}')
    case "$INSTALL_FREE_KB" in *[!0-9]*|'') fail "could not read free space for the install drive";; esac
    [ "$INSTALL_FREE_KB" -ge "$INSTALL_REQUIRED_KB" ] || fail "not enough install space to resume; need about $(awk -v kb="$INSTALL_REQUIRED_KB" 'BEGIN {printf "%.1f", kb/1048576}') GiB"
  fi
  printf 'Type YES to import or verify the existing clone without stopping the source: '
fi
IFS= read -r answer || answer=
case "$answer" in YES) ;; *) echo "Cancelled. No export or import was started."; exit 0 ;; esac
BACKUP_DIR=$(mkdir -p "$BACKUP_DIR" && CDPATH='' cd -- "$BACKUP_DIR" && pwd)
if [ "$RESUME" -eq 0 ]; then
  SOURCE_STOP_ATTEMPTED=1
  # shellcheck disable=SC2016
  "$WSL_EXE" --distribution "$SOURCE_DISTRO" --user root --exec poweroff >/dev/null 2>&1 || :
  load_distro_list || fail "could not check whether the source stopped"
  if distro_is_running "$SOURCE_DISTRO"; then
    printf 'The source is still running. Type FORCE to terminate it; this can interrupt remaining processes: '
    IFS= read -r answer || answer=
    case "$answer" in FORCE) "$WSL_EXE" --terminate "$SOURCE_DISTRO" || fail "could not terminate the source" ;; *) fail "graceful shutdown did not stop the source; export was not started" ;; esac
  fi
  SOURCE_STOPPED=1
  load_distro_list || fail "could not refresh WSL distro state"
  distro_is_running "$SOURCE_DISTRO" && fail "source still appears to be running"
  echo "Exporting full distro to $BACKUP_FILE"
  "$WSL_EXE" --export "$SOURCE_DISTRO" "$WINDOWS_BACKUP"
  [ -s "$BACKUP_FILE" ] || fail "export did not create a non-empty backup"
  tar -tf "$BACKUP_FILE" >/dev/null 2>&1 || fail "export is not a readable tar archive"
  EXPORT_SHA256=$(sha256sum "$BACKUP_FILE" | awk '{print $1}')
  printf '%s  %s\n' "$EXPORT_SHA256" "$(basename -- "$BACKUP_FILE")" > "$CHECKSUM_FILE"
  EXPORT_VALID=1
else
  [ -s "$BACKUP_FILE" ] || fail "resume archive is missing or empty"
  tar -tf "$BACKUP_FILE" >/dev/null 2>&1 || fail "resume archive is not a readable tar archive"
  EXPORT_VALID=1
fi
if [ "$CLONE_IMPORTED" -eq 0 ]; then
  echo "Importing $NEW_DISTRO as WSL $TARGET_WSL_VERSION"
  "$WSL_EXE" --import "$NEW_DISTRO" "$WINDOWS_INSTALL_LOCATION" "$WINDOWS_BACKUP" --version "$TARGET_WSL_VERSION" || fail "WSL import failed; resume from the retained export"
  CLONE_IMPORTED=1
fi

echo "Installing wsl-migrate inside the clone"
SCRIPT_PATH=$0
case "$SCRIPT_PATH" in */*) ;; *) SCRIPT_PATH=$(command -v "$SCRIPT_PATH") ;; esac
[ -f "$SCRIPT_PATH" ] || fail "cannot locate the running script to install it in the clone"
# shellcheck disable=SC2016
"$WSL_EXE" --distribution "$NEW_DISTRO" --user root --exec sh -c \
  'set -e; umask 022; mkdir -p /usr/local/bin /etc/wsl-migrate; tmp=/usr/local/bin/.wsl-migrate.tmp; cat > "$tmp"; chmod 0755 "$tmp"; mv -f "$tmp" /usr/local/bin/wsl-migrate; printf "%s\n" "$1" > /etc/wsl-migrate/previous-default' sh "$PREVIOUS_DEFAULT" < "$SCRIPT_PATH" || fail "could not install wsl-migrate in the clone; recovery details follow"
UTILITY_INSTALLED=1

if ! "$WSL_EXE" --distribution "$NEW_DISTRO" --user root --exec sh -c \
  'test -s /etc/passwd && test -x /bin/sh && test -x /usr/local/bin/wsl-migrate'; then
  fail "post-import root filesystem checks failed"
fi
"$WSL_EXE" --distribution "$NEW_DISTRO" --exec id -un >/dev/null || fail "the clone's configured default user could not run a command"

verify_archive_file() {
  verify_path=$1
  verify_required=$2
  archive_member=$(tar -tf "$BACKUP_FILE" | awk -v p="$verify_path" '$0 == "./" p || $0 == p {print; exit}')
  if [ -z "$archive_member" ]; then
    [ "$verify_required" -eq 0 ] || fail "required source file is missing from export: /$verify_path"
    return
  fi
  archive_hash=$(tar -xOf "$BACKUP_FILE" "$archive_member" | sha256sum | awk '{print $1}')
  clone_hash_line=$("$WSL_EXE" --distribution "$NEW_DISTRO" --user root --exec sha256sum "/$verify_path" 2>/dev/null) || fail "could not hash /$verify_path inside the clone"
  clone_hash=$(printf '%s\n' "$clone_hash_line" | awk 'NR==1 {print $1}' | tr -d '\r')
  if [ -z "$archive_hash" ] || [ "$archive_hash" != "$clone_hash" ]; then
    fail "export and clone differ for /$verify_path"
  fi
}
echo "Comparing important configuration files with the export"
verify_archive_file etc/passwd 1
verify_archive_file etc/group 1
verify_archive_file etc/wsl.conf 1
verify_archive_file etc/shadow 0
verify_archive_file etc/docker/daemon.json 0

echo "Comparing /home and Docker persistent file contents with the source manifest"
# shellcheck disable=SC2016
"$WSL_EXE" --distribution "$NEW_DISTRO" --user root --exec sh -c '
  if [ -x /etc/init.d/docker ] && command -v rc-service >/dev/null 2>&1; then
    rc-service --nodeps --ifstarted docker stop || exit 40
  elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    systemctl stop docker || exit 41
  fi
  command -v sha256sum >/dev/null 2>&1 || exit 42
  for root in /home /var/lib/docker; do
    if [ -d "$root" ]; then
      printf "DIR %s\n" "$root"
      find "$root" -type f -exec sha256sum "{}" \;
      find "$root" -type l -exec sh -c '\''for path do printf "LINK %s -> %s\n" "$path" "$(readlink "$path")"; done'\'' sh "{}" \;
    else
      printf "MISSING %s\n" "$root"
    fi
  done
' > "$BACKUP_FILE.clone-content-manifest.raw" || fail "could not scan clone home and Docker data"
tr -d '\r' < "$BACKUP_FILE.clone-content-manifest.raw" | LC_ALL=C sort > "$BACKUP_FILE.clone-content-manifest"
rm -f -- "$BACKUP_FILE.clone-content-manifest.raw"
if ! cmp -s "$CONTENT_MANIFEST" "$BACKUP_FILE.clone-content-manifest"; then
  CONTENT_DIFFERENCES=1
  echo "Differences were found in /home or Docker persistent data:" >&2
  diff -u "$CONTENT_MANIFEST" "$BACKUP_FILE.clone-content-manifest" | sed -n '1,80p' >&2 || :
  printf 'Review the differences above. Type CONTINUE to keep the clone and record the warning: '
  IFS= read -r answer || answer=
  [ "$answer" = CONTINUE ] || fail "content differences need review; the clone and export have been retained"
fi
rm -f -- "$BACKUP_FILE.clone-content-manifest"

load_distro_list || fail "could not verify imported distro registration"
IMPORTED_WSL_VERSION=$(distro_wsl_version "$NEW_DISTRO")
[ "$IMPORTED_WSL_VERSION" = "$TARGET_WSL_VERSION" ] || fail "imported distro WSL version did not match the source"

if [ "$REFRESH_SSH_KEYS" -eq 1 ]; then
  # shellcheck disable=SC2016
  "$WSL_EXE" --distribution "$NEW_DISTRO" --user root --exec sh -c '
    command -v ssh-keygen >/dev/null 2>&1 || {
      echo "ssh-keygen is not installed; SSH host keys were not changed." >&2
      exit 1
    }
    for key in /etc/ssh/ssh_host_*; do
      [ -e "$key" ] || continue
      rm -f -- "$key"
    done
    ssh-keygen -A
  ' || fail "could not regenerate SSH host keys in the clone"
fi

CALCULATED_EXPORT_SHA256=$(sha256sum "$BACKUP_FILE" | awk '{print $1}')
[ -n "$CALCULATED_EXPORT_SHA256" ] || fail "could not calculate the export checksum"
if [ "$CALCULATED_EXPORT_SHA256" != "$EXPORT_SHA256" ]; then
  fail "export checksum changed during migration"
fi
EXPORT_SHA256=$CALCULATED_EXPORT_SHA256
REPORT_FILE=$BACKUP_FILE.migration.txt
{
  printf 'Source distro: %s\n' "$SOURCE_DISTRO"
  printf 'Source WSL version: %s\n' "$SOURCE_WSL_VERSION"
  printf 'Clone distro: %s\n' "$NEW_DISTRO"
  printf 'Clone WSL version: %s\n' "$IMPORTED_WSL_VERSION"
  printf 'Install location: %s\n' "$INSTALL_LOCATION"
  printf 'Previous default distro: %s\n' "$PREVIOUS_DEFAULT"
  printf 'Completed at (UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Export SHA-256: %s\n' "$EXPORT_SHA256"
  printf 'Tar archive validation: passed\n'
  printf 'Root filesystem, default-user, and key configuration checks: passed\n'
  if [ "$CONTENT_DIFFERENCES" -eq 1 ]; then
    printf 'Home/Docker differences: user reviewed and accepted\n'
  else
    printf 'Home/Docker content checks: passed\n'
  fi
  printf 'SSH host keys regenerated: %s\n' "$REFRESH_SSH_KEYS"
} > "$REPORT_FILE"
MIGRATION_COMPLETE=1

echo
echo "Full clone created successfully."
echo "Source distro remains registered: $SOURCE_DISTRO"
echo "New distro: $NEW_DISTRO"
echo "Retained export: $BACKUP_FILE"
echo "Migration report: $REPORT_FILE"
echo "Export SHA-256: $EXPORT_SHA256"
echo "Install location: $INSTALL_LOCATION"
echo "The cloned /etc/wsl.conf and default user are preserved."
echo "The actual previous default distro was: $PREVIOUS_DEFAULT"
echo "The export checksum is retained at: $CHECKSUM_FILE"
if [ "$CONTENT_DIFFERENCES" -eq 1 ]; then
  echo "Home/Docker differences were reviewed and recorded in the report."
else
  echo "Regular file contents under /home and /var/lib/docker match the source manifest."
fi
echo "SSH host keys regenerated: $REFRESH_SSH_KEYS"
echo "Start the clone with: wsl.exe --distribution $NEW_DISTRO"
printf 'Set the clone as default now? [y/N] '
IFS= read -r switch_answer || switch_answer=
case "$switch_answer" in
  y|Y|yes|YES)
    "$WSL_EXE" --set-default "$NEW_DISTRO"
    echo "Default WSL distro set to $NEW_DISTRO."
    echo "To restore the actual previous default: wsl-migrate --rollback"
    ;;
  *) echo "Default distro was not changed." ;;
esac
