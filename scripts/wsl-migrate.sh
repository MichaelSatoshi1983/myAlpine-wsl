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

CURRENT_DISTRO=\${WSL_DISTRO_NAME-}
[ -n "$CURRENT_DISTRO" ] || fail "run this command inside the new WSL distro"
[ "$SOURCE_DISTRO" != "$CURRENT_DISTRO" ] || fail "source and current distro are the same"

WSL_EXE=\${WSL_EXE-}
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
  [ -z "$BACKUP_DIR" ] && [ -z "$INSTALL_LOCATION" ] || fail "path options cannot be combined with --rollback"
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

safe_name=$(printf '%s' "$NEW_DISTRO" | tr -c 'A-Za-z0-9_.-' '_')
if [ -z "$BACKUP_DIR" ]; then
  BACKUP_DIR=$(wslpath -u "$WINDOWS_USERPROFILE")/Documents/myAlpine-wsl-backups
fi
if [ -z "$INSTALL_LOCATION" ]; then
  INSTALL_LOCATION=$(wslpath -u "$WINDOWS_LOCALAPPDATA")/AlpineWSL-$safe_name
fi
case "$BACKUP_DIR" in /mnt/[A-Za-z]/*) ;; *) fail "backup directory must be on a mounted Windows drive, such as /mnt/c/Users/...";; esac
case "$INSTALL_LOCATION" in /mnt/[A-Za-z]/*) ;; *) fail "install location must be on a mounted Windows drive, such as /mnt/c/Users/...";; esac
BACKUP_DIR=$(mkdir -p "$BACKUP_DIR" && CDPATH='' cd -- "$BACKUP_DIR" && pwd)
[ ! -e "$INSTALL_LOCATION" ] || fail "install location already exists; choose an empty, unused path: $INSTALL_LOCATION"
WINDOWS_BACKUP_DIR=$(wslpath -w "$BACKUP_DIR")
WINDOWS_INSTALL_LOCATION=$(wslpath -w "$INSTALL_LOCATION")
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_FILE=$BACKUP_DIR/$safe_name-$timestamp.tar
WINDOWS_BACKUP=$WINDOWS_BACKUP_DIR\$safe_name-$timestamp.tar
[ ! -e "$BACKUP_FILE" ] || fail "backup file already exists: $BACKUP_FILE"

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF
Source distro: $SOURCE_DISTRO
Current distro (script host): $CURRENT_DISTRO
New cloned distro: $NEW_DISTRO
Full export: $BACKUP_FILE
New distro install location: $INSTALL_LOCATION
Import version: WSL 2

This creates a full clone of the old distro. It does not upgrade the cloned
Alpine/system packages to the current Release image. Neither distro is removed.
EOF
  exit 0
fi

cat <<EOF

This operation creates a full clone. Review these differences and risks:
  - The clone retains the source distro's OS, packages, /etc configuration,
    user data, and Docker data. It does not become the current Release image.
  - WSL imports the clone as WSL 2. A WSL 1 source can behave differently.
  - WSL will not copy Windows-side .wslconfig, Windows Terminal profiles,
    registration settings, or files stored outside the distro filesystem.
  - The source /etc/wsl.conf is preserved. Boot commands or default-user
    settings may need adjustment for the target Windows/WSL version.
  - Running both copies can start duplicate services and Docker workloads,
    bind the same ports, and expose the same container data. Run one at a time.
  - A full export needs free Windows disk space roughly comparable to the
    source distro. The export is retained as a recovery copy.
  - The source must be stopped for a consistent export; unsaved process state
    is lost when it is terminated.

Source: $SOURCE_DISTRO
New clone: $NEW_DISTRO
Export: $BACKUP_FILE
Install location: $INSTALL_LOCATION

Continue to the stop-source confirmation? [y/N] 
EOF
IFS= read -r answer || answer=
case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0 ;; esac
printf 'Terminate "%s" now, then export its complete filesystem? This closes its WSL processes. [y/N] ' "$SOURCE_DISTRO"
IFS= read -r answer || answer=
case "$answer" in
  y|Y|yes|YES) "$WSL_EXE" --terminate "$SOURCE_DISTRO" ;;
  *) echo "Cancelled. The source was not terminated."; exit 0 ;;
esac

echo "Exporting full distro to $BACKUP_FILE"
"$WSL_EXE" --export "$SOURCE_DISTRO" "$WINDOWS_BACKUP"
[ -s "$BACKUP_FILE" ] || fail "export did not create a non-empty backup"
tar -tf "$BACKUP_FILE" >/dev/null 2>&1 || fail "export is not a readable tar archive"
echo "Importing $NEW_DISTRO as WSL 2"
"$WSL_EXE" --import "$NEW_DISTRO" "$WINDOWS_INSTALL_LOCATION" "$WINDOWS_BACKUP" --version 2

echo "Installing wsl-migrate inside the clone"
if ! cat "$0" | "$WSL_EXE" --distribution "$NEW_DISTRO" --user root --exec sh -c \
  'umask 022; cat > /usr/local/bin/wsl-migrate && chmod 0755 /usr/local/bin/wsl-migrate'; then
  cat >&2 <<EOF
The full clone was imported, but wsl-migrate could not be installed inside it.
The clone and retained export are still available:
  Clone: $NEW_DISTRO
  Export: $BACKUP_FILE
EOF
  exit 1
fi

echo
echo "Full clone created successfully."
echo "Source distro remains registered: $SOURCE_DISTRO"
echo "New distro: $NEW_DISTRO"
echo "Retained export: $BACKUP_FILE"
echo "Install location: $INSTALL_LOCATION"
echo "The cloned /etc/wsl.conf and default user are preserved."
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
