#!/bin/sh
set -eu
usage() {
  cat <<'EOF'
Usage: wsl-migrate [--dry-run] [--backup-dir WINDOWS_MOUNTED_PATH] [--install-location WINDOWS_MOUNTED_PATH] SOURCE_DISTRO [NEW_DISTRO_NAME]
       wsl-migrate --rollback PREVIOUS_DISTRO

Create a full WSL export of SOURCE_DISTRO, then import it as a second distro.
The source remains registered and unchanged. The clone keeps the source OS
version and configuration; this does not upgrade it to the current image.
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
  if [ "$SOURCE_STOPPED" -eq 1 ]; then
    echo "The source remains registered. Start it from PowerShell with: wsl --distribution $SOURCE_DISTRO" >&2
  fi
  if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
    if [ "$EXPORT_VALID" -eq 1 ]; then
      echo "Validated export or recovery copy: $BACKUP_FILE" >&2
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
BACKUP_DIR=
INSTALL_LOCATION=
SOURCE_DISTRO=
NEW_DISTRO=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
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
  fail "new distro name is already registered in WSL: $NEW_DISTRO"
fi
SOURCE_WSL_VERSION=$(distro_wsl_version "$SOURCE_DISTRO")
case "$SOURCE_WSL_VERSION" in 1|2) ;; *) fail "could not detect the source WSL version; no distro was stopped";; esac
TARGET_WSL_VERSION=$SOURCE_WSL_VERSION
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
[ ! -e "$INSTALL_LOCATION" ] || fail "install location already exists; choose an empty, unused path: $INSTALL_LOCATION"
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
WINDOWS_INSTALL_LOCATION=$(wslpath -w "$INSTALL_LOCATION")
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_FILE=$BACKUP_DIR/$safe_name-$timestamp.tar
WINDOWS_BACKUP=$(wslpath -w "$BACKUP_FILE")
[ ! -e "$BACKUP_FILE" ] || fail "backup file already exists: $BACKUP_FILE"

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF
Source distro: $SOURCE_DISTRO
Current distro (script host): $CURRENT_DISTRO
New cloned distro: $NEW_DISTRO
Full export: $BACKUP_FILE
New distro install location: $INSTALL_LOCATION
Import version: WSL $TARGET_WSL_VERSION (preserving the source version)
Free space on backup drive: $AVAILABLE_GB GiB

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
Free space on backup drive: $AVAILABLE_GB GiB

Will be copied as a full distro clone:
  - Alpine/system files, installed packages, users, home directories,
    /etc configuration, and persistent Docker images/containers/volumes.
  - The old distro's /etc/wsl.conf and default-user setting are preserved.

Will not be copied:
  - Windows-side .wslconfig, Windows Terminal profiles, WSL registration
    settings, or files stored outside the distro filesystem.
  - Running process state. The source distro is stopped before export.

Actions after confirmation:
  1. Stop "$SOURCE_DISTRO".
  2. Export it to the retained tar backup shown above and validate the archive.
  3. Import that archive as "$NEW_DISTRO" using WSL 2.
  4. Install wsl-migrate as /usr/local/bin/wsl-migrate inside the clone.
  5. Ask whether to set the clone as the default distro.

Important risks and limitations:
  - This preserves the old distro; it does not upgrade it to the current
    Release image. A WSL 1 source becomes WSL 2 and may behave differently.
  - Preserved boot commands or user settings may need adjustment for this
    Windows/WSL version.
  - Host identity files, including SSH host keys and /etc/machine-id, are copied.
    If both copies provide network services, they may appear as the same host.
    You can optionally regenerate SSH host keys in the clone after import.
  - Running both copies can start duplicate services or Docker workloads,
    compete for ports, and operate on duplicated container data. Prefer
    testing one copy at a time.
  - The export can be large; ensure the Windows drive has enough free space.
    The old distro stays registered and the export remains available for recovery.

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
printf 'Final check: type YES to stop "%s" and begin the export/import. This closes its WSL processes: ' "$SOURCE_DISTRO"
IFS= read -r answer || answer=
case "$answer" in YES) ;; *) echo "Cancelled. The source was not terminated."; exit 0 ;; esac
BACKUP_DIR=$(mkdir -p "$BACKUP_DIR" && CDPATH='' cd -- "$BACKUP_DIR" && pwd)
BACKUP_FILE=$BACKUP_DIR/$safe_name-$timestamp.tar
WINDOWS_BACKUP=$(wslpath -w "$BACKUP_FILE")
SOURCE_STOPPED=1
"$WSL_EXE" --terminate "$SOURCE_DISTRO"

echo "Exporting full distro to $BACKUP_FILE"
"$WSL_EXE" --export "$SOURCE_DISTRO" "$WINDOWS_BACKUP"
[ -s "$BACKUP_FILE" ] || fail "export did not create a non-empty backup"
tar -tf "$BACKUP_FILE" >/dev/null 2>&1 || fail "export is not a readable tar archive"
EXPORT_VALID=1
echo "Importing $NEW_DISTRO as WSL $TARGET_WSL_VERSION"
"$WSL_EXE" --import "$NEW_DISTRO" "$WINDOWS_INSTALL_LOCATION" "$WINDOWS_BACKUP" --version "$TARGET_WSL_VERSION"
CLONE_IMPORTED=1

echo "Installing wsl-migrate inside the clone"
SCRIPT_PATH=$0
case "$SCRIPT_PATH" in */*) ;; *) SCRIPT_PATH=$(command -v "$SCRIPT_PATH") ;; esac
[ -f "$SCRIPT_PATH" ] || fail "cannot locate the running script to install it in the clone"
"$WSL_EXE" --distribution "$NEW_DISTRO" --user root --exec sh -c \
  'umask 022; cat > /usr/local/bin/wsl-migrate && chmod 0755 /usr/local/bin/wsl-migrate' < "$SCRIPT_PATH" || fail "could not install wsl-migrate in the clone; recovery details follow" 
UTILITY_INSTALLED=1

if ! "$WSL_EXE" --distribution "$NEW_DISTRO" --user root --exec sh -c \
  'test -s /etc/passwd && test -x /bin/sh && test -x /usr/local/bin/wsl-migrate'; then
  fail "post-import root filesystem checks failed"
fi
"$WSL_EXE" --distribution "$NEW_DISTRO" --exec id -un >/dev/null || fail "the clone's configured default user could not run a command"

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

EXPORT_SHA256=$(sha256sum "$BACKUP_FILE" | awk '{print $1}')
[ -n "$EXPORT_SHA256" ] || fail "could not calculate the export checksum"
REPORT_FILE=$BACKUP_FILE.migration.txt
{
  printf 'Source distro: %s\n' "$SOURCE_DISTRO"
  printf 'Source WSL version: %s\n' "$SOURCE_WSL_VERSION"
  printf 'Clone distro: %s\n' "$NEW_DISTRO"
  printf 'Clone WSL version: %s\n' "$IMPORTED_WSL_VERSION"
  printf 'Install location: %s\n' "$INSTALL_LOCATION"
  printf 'Completed at (UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Export SHA-256: %s\n' "$EXPORT_SHA256"
  printf 'Tar archive validation: passed\n'
  printf 'Root filesystem and default-user checks: passed\n'
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
echo "SSH host keys regenerated: $REFRESH_SSH_KEYS"
echo "Start the clone with: wsl.exe --distribution $NEW_DISTRO"
printf 'Set the clone as default now? [y/N] '
IFS= read -r switch_answer || switch_answer=
case "$switch_answer" in
  y|Y|yes|YES)
    "$WSL_EXE" --set-default "$NEW_DISTRO"
    echo "Default WSL distro set to $NEW_DISTRO."
    echo "To restore the previous default: wsl-migrate --rollback $CURRENT_DISTRO"
    ;;
  *) echo "Default distro was not changed." ;;
esac
