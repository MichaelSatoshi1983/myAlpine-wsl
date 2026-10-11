#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: wsl-migrate [--dry-run] [--source-user NAME] [--target-user NAME] [--backup-dir PATH] SOURCE_DISTRO

Export SOURCE_DISTRO to a retained backup, then migrate its home files and
Alpine package list into the current WSL distribution.
EOF
}

fail() {
  echo "wsl-migrate: $*" >&2
  exit 1
}

DRY_RUN=0
SOURCE_USER=
TARGET_USER=
BACKUP_DIR=
SOURCE_DISTRO=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --source-user)
      [ "$#" -ge 2 ] || fail "--source-user requires a name"
      SOURCE_USER=$2
      shift 2
      ;;
    --target-user)
      [ "$#" -ge 2 ] || fail "--target-user requires a name"
      TARGET_USER=$2
      shift 2
      ;;
    --backup-dir)
      [ "$#" -ge 2 ] || fail "--backup-dir requires a path"
      BACKUP_DIR=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [ -z "$SOURCE_DISTRO" ] || fail "specify only one source distro"
      SOURCE_DISTRO=$1
      shift
      ;;
  esac
done

[ -n "$SOURCE_DISTRO" ] || {
  usage >&2
  exit 2
}

case "$SOURCE_DISTRO" in
  *[!A-Za-z0-9_.-]*|'') fail "source distro name may contain only letters, digits, dot, underscore, and hyphen" ;;
esac

CURRENT_DISTRO=${WSL_DISTRO_NAME:-}
[ -n "$CURRENT_DISTRO" ] || fail "run this command inside the new WSL distro"
[ "$SOURCE_DISTRO" != "$CURRENT_DISTRO" ] || fail "source and current distro are the same"

if [ -z "${WSL_EXE:-}" ]; then
  for candidate in /mnt/c/Windows/System32/wsl.exe /mnt/c/WINDOWS/System32/wsl.exe; do
    if [ -x "$candidate" ]; then
      WSL_EXE=$candidate
      break
    fi
  done
else
  WSL_EXE=$WSL_EXE
fi
[ -n "${WSL_EXE:-}" ] || fail "cannot find wsl.exe; set WSL_EXE to its mounted Windows path"

WINDOWS_DIR=$(dirname -- "$WSL_EXE")
CMD_EXE=$WINDOWS_DIR/cmd.exe
[ -x "$CMD_EXE" ] || fail "cannot find cmd.exe beside wsl.exe"

WINDOWS_USERPROFILE=$( "$CMD_EXE" /d /c echo %USERPROFILE% | tr -d '\r' )
[ -n "$WINDOWS_USERPROFILE" ] || fail "could not read the Windows user profile"

if [ -z "$BACKUP_DIR" ]; then
  BACKUP_DIR=$(wslpath -u "$WINDOWS_USERPROFILE")/Documents/myAlpine-wsl-backups
fi
if [ -z "$TARGET_USER" ]; then
  TARGET_USER=$(awk '
    /^\[user\][[:space:]]*$/ { in_user=1; next }
    /^\[/ { in_user=0 }
    in_user && /^[[:space:]]*default[[:space:]]*=/ {
      sub(/^[[:space:]]*default[[:space:]]*=[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      print
      exit
    }
  ' /etc/wsl.conf)
fi
[ -n "$TARGET_USER" ] || fail "could not find the current distro default user; pass --target-user"
id "$TARGET_USER" >/dev/null 2>&1 || fail "target user does not exist: $TARGET_USER"

case "$TARGET_USER" in
  *[!a-z0-9_-]*|'') fail "target user name contains unsupported characters" ;;
esac
[ "$(id -un)" = "$TARGET_USER" ] || fail "run as the target user: $TARGET_USER"
TARGET_HOME=$(awk -F: -v user="$TARGET_USER" '$1 == user { print $6; exit }' /etc/passwd)
[ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] || fail "target home directory was not found"

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF
Source distro: $SOURCE_DISTRO
Current distro: $CURRENT_DISTRO
Target user: $TARGET_USER
Backup directory: $BACKUP_DIR

The command will export the source distro, retain the export, copy the source
user's home files into the target user, and try to install packages from
/etc/apk/world. It will not unregister either distro.
EOF
  exit 0
fi

printf 'Close applications in "%s" before continuing. The source distro will remain registered.\n' "$SOURCE_DISTRO"
printf 'A full export will be saved under %s. Continue? [y/N] ' "$BACKUP_DIR"
IFS= read -r answer || answer=
case "$answer" in
  y|Y|yes|YES) ;;
  *) echo "Cancelled."; exit 0 ;;
esac

mkdir -p "$BACKUP_DIR"
BACKUP_DIR=$(CDPATH= cd -- "$BACKUP_DIR" && pwd)
WINDOWS_BACKUP_DIR=$(wslpath -w "$BACKUP_DIR")

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
safe_source=$(printf '%s' "$SOURCE_DISTRO" | tr -c 'A-Za-z0-9_.-' '_')
BACKUP_FILE=$BACKUP_DIR/${safe_source}-${timestamp}.tar
WINDOWS_BACKUP=$WINDOWS_BACKUP_DIR/${safe_source}-${timestamp}.tar
REPORT_DIR=$TARGET_HOME/.wsl-migration/$timestamp
STAGING_DIR=$(mktemp -d)
cleanup() {
  rm -rf -- "$STAGING_DIR"
}
trap cleanup EXIT HUP INT TERM

echo "Exporting $SOURCE_DISTRO to $BACKUP_FILE"
"$WSL_EXE" --export "$SOURCE_DISTRO" "$WINDOWS_BACKUP"
[ -s "$BACKUP_FILE" ] || fail "export did not create a backup"
tar -tf "$BACKUP_FILE" >/dev/null 2>&1 || fail "the exported backup is not a readable tar archive"

if tar -tf "$BACKUP_FILE" | grep -Fxq './etc/wsl.conf'; then
  ARCHIVE_PREFIX=./
elif tar -tf "$BACKUP_FILE" | grep -Fxq 'etc/wsl.conf'; then
  ARCHIVE_PREFIX=
else
  fail "could not find /etc/wsl.conf in the source export"
fi

if [ -z "$SOURCE_USER" ]; then
  SOURCE_USER=$(tar -xOf "$BACKUP_FILE" "${ARCHIVE_PREFIX}etc/wsl.conf" | awk '
    /^\[user\][[:space:]]*$/ { in_user=1; next }
    /^\[/ { in_user=0 }
    in_user && /^[[:space:]]*default[[:space:]]*=/ {
      sub(/^[[:space:]]*default[[:space:]]*=[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      print
      exit
    }
  ' || true)
fi
[ -n "$SOURCE_USER" ] || fail "could not detect the source default user; pass --source-user"
case "$SOURCE_USER" in
  *[!a-z0-9_-]*|'') fail "source user name contains unsupported characters" ;;
esac

SOURCE_HOME_PATH=${ARCHIVE_PREFIX}home/$SOURCE_USER
tar -tf "$BACKUP_FILE" | grep -Fq "$SOURCE_HOME_PATH/" || fail "source home was not found in the export: $SOURCE_USER"
mkdir -p "$STAGING_DIR/home"
tar -xpf "$BACKUP_FILE" -C "$STAGING_DIR" "$SOURCE_HOME_PATH"

SOURCE_HOME=$STAGING_DIR/home/$SOURCE_USER
mkdir -p "$REPORT_DIR"
: > "$REPORT_DIR/packages-installed.txt"
: > "$REPORT_DIR/packages-not-installed.txt"

if [ -f "$SOURCE_HOME/.zshrc" ]; then
  cp -p "$SOURCE_HOME/.zshrc" "$REPORT_DIR/source.zshrc"
fi
if [ -f "$SOURCE_HOME/.zshenv" ]; then
  cp -p "$SOURCE_HOME/.zshenv" "$REPORT_DIR/source.zshenv"
fi
mkdir -p "$TARGET_HOME/.wsl-migration-conflicts/$timestamp"
rsync -a \
  --backup --backup-dir=".wsl-migration-conflicts/$timestamp" \
  --exclude='/.zshrc' \
  --exclude='/.zshenv' \
  --exclude='/.oh-my-zsh/***' \
  --exclude='/.wsl-migration/***' \
  --exclude='/.wsl-migration-conflicts/***' \
  "$SOURCE_HOME/" "$TARGET_HOME/"

if [ -d "$SOURCE_HOME/.oh-my-zsh/custom" ] && [ -d "$TARGET_HOME/.oh-my-zsh/custom" ]; then
  rsync -a \
    --backup --backup-dir=".wsl-migration-conflicts/$timestamp" \
    "$SOURCE_HOME/.oh-my-zsh/custom/" "$TARGET_HOME/.oh-my-zsh/custom/"
fi

if tar -tf "$BACKUP_FILE" | grep -Fxq "${ARCHIVE_PREFIX}etc/apk/world"; then
  tar -xOf "$BACKUP_FILE" "${ARCHIVE_PREFIX}etc/apk/world" > "$STAGING_DIR/apk-world"
  echo "Refreshing Alpine package indexes"
  if sudo apk update >> "$REPORT_DIR/apk.log" 2>&1; then
    while IFS= read -r package || [ -n "$package" ]; do
      if ! printf '%s\n' "$package" | grep -Eq '^[[:alnum:]_.+@=<>~^:-]+
      if sudo apk add "$package" >> "$REPORT_DIR/apk.log" 2>&1; then
        printf '%s\n' "$package" >> "$REPORT_DIR/packages-installed.txt"
      else
        printf '%s\n' "$package" >> "$REPORT_DIR/packages-not-installed.txt"
      fi
    done < "$STAGING_DIR/apk-world"
  else
    echo "apk update failed; no packages were installed" >> "$REPORT_DIR/apk.log"
    cp "$STAGING_DIR/apk-world" "$REPORT_DIR/packages-not-installed.txt"
  fi
fi

cat > "$REPORT_DIR/README.txt" <<EOF
Migration from: $SOURCE_DISTRO
Source user: $SOURCE_USER
Target distro: $CURRENT_DISTRO
Target user: $TARGET_USER
Full source export: $BACKUP_FILE

Home files were copied. Existing target files replaced during the copy are
saved in $TARGET_HOME/.wsl-migration-conflicts/$timestamp.
The release-managed .zshrc, .zshenv, and Oh My Zsh installation were kept.
The source .zshrc and .zshenv, when present, are saved in this report for review.
Package results are listed in packages-installed.txt and
packages-not-installed.txt.

System configuration, custom software outside the home directory, and Docker
images, containers, and volumes were not copied. The source distro was not
unregistered.
EOF

echo "Migration complete."
echo "Full backup: $BACKUP_FILE"
echo "Report: $REPORT_DIR/README.txt"
echo "Review $REPORT_DIR/packages-not-installed.txt and any saved shell configuration."
echo "The source distro remains registered and unchanged."
; then
        printf '%s (unsupported world entry)\n' "$package" >> "$REPORT_DIR/packages-not-installed.txt"
        continue
      fi
      if sudo apk add "$package" >> "$REPORT_DIR/apk.log" 2>&1; then
        printf '%s\n' "$package" >> "$REPORT_DIR/packages-installed.txt"
      else
        printf '%s\n' "$package" >> "$REPORT_DIR/packages-not-installed.txt"
      fi
    done < "$STAGING_DIR/apk-world"
  else
    echo "apk update failed; no packages were installed" >> "$REPORT_DIR/apk.log"
    cp "$STAGING_DIR/apk-world" "$REPORT_DIR/packages-not-installed.txt"
  fi
fi

cat > "$REPORT_DIR/README.txt" <<EOF
Migration from: $SOURCE_DISTRO
Source user: $SOURCE_USER
Target distro: $CURRENT_DISTRO
Target user: $TARGET_USER
Full source export: $BACKUP_FILE

Home files were copied. Existing target files replaced during the copy are
saved in $TARGET_HOME/.wsl-migration-conflicts/$timestamp.
The release-managed .zshrc, .zshenv, and Oh My Zsh installation were kept.
The source .zshrc and .zshenv, when present, are saved in this report for review.
Package results are listed in packages-installed.txt and
packages-not-installed.txt.

System configuration, custom software outside the home directory, and Docker
images, containers, and volumes were not copied. The source distro was not
unregistered.
EOF

echo "Migration complete."
echo "Full backup: $BACKUP_FILE"
echo "Report: $REPORT_DIR/README.txt"
echo "Review $REPORT_DIR/packages-not-installed.txt and any saved shell configuration."
echo "The source distro remains registered and unchanged."
