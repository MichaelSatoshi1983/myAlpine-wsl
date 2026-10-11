#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: wsl-migrate [--dry-run] [--backup-dir WINDOWS_MOUNTED_PATH] [--include DISTRO_PATH] SOURCE_DISTRO
       wsl-migrate --resume BACKUP_TAR SOURCE_DISTRO
       wsl-migrate --rollback [PREVIOUS_DEFAULT]

Migrate data, APK packages, users, and application configuration from SOURCE_DISTRO
into the current new Alpine Release distro. The old distro remains registered.
The old OS binaries and system-owned files are not overlaid onto the new system.
EOF
}
fail() { echo "wsl-migrate: $*" >&2; exit 1; }
warn() { printf '%s\n' "$*" | tee -a "$WARNINGS" >&2; }

DISTRO_LIST=
SOURCE_DISTRO=
BACKUP_DIR=
RESUME_ARCHIVE=
EXTRA_PATHS=
DRY_RUN=0
ROLLBACK=0
SOURCE_STOP_ATTEMPTED=0
TARGET_DOCKER_STOPPED=0
EXPORT_VALID=0
BACKUP_FILE=
TARGET_BACKUP_FILE=
CONTENT_MANIFEST=
PREVIOUS_DEFAULT=
PACKAGE_WARNING=0
CONFIG_CHOICE=keep-new
CONTENT_DIFFERENCES=0
MIGRATION_COMPLETE=0
MIGRATION_PATHS=

load_distro_list() {
  DISTRO_LIST=$(WSL_UTF8=1 "$WSL_EXE" --list --verbose 2>/dev/null | tr -d '\r\000') || return 1
  [ -n "$DISTRO_LIST" ]
}
distro_is_registered() {
  printf '%s\n' "$DISTRO_LIST" | awk -v wanted="$1" '
    { name=$1; if(name=="*") name=$2; sub(/^\*/, "", name); if(name==wanted) found=1 }
    END { exit found ? 0 : 1 }'
}
distro_is_running() {
  printf '%s\n' "$DISTRO_LIST" | awk -v wanted="$1" '
    { if($1=="*"){name=$2; state=$3}else{name=$1; state=$2}; sub(/^\*/, "", name)
      if(name==wanted && state=="Running") found=1 }
    END { exit found ? 0 : 1 }'
}
default_distro() {
  printf '%s\n' "$DISTRO_LIST" | awk '$1=="*" {print $2; exit} $1 ~ /^\*/ {sub(/^\*/, "", $1); print $1; exit}'
}
archive_contains() {
  grep -Fqx "$ARCHIVE_PREFIX$1" "$ARCHIVE_LIST_FILE" || grep -Fq "$ARCHIVE_PREFIX$1/" "$ARCHIVE_LIST_FILE"
}
archive_has() { grep -Fq "$ARCHIVE_PREFIX$1/" "$ARCHIVE_LIST_FILE"; }

make_target_manifest() {
  for rel in $MIGRATION_PATHS; do
    root="/$rel"
    if [ ! -e "$root" ]; then printf 'MISSING %s\n' "$root"; continue; fi
    printf 'ROOT %s\n' "$root"
    find "$root" \( -path /var/lib/apk -o -path /var/lib/openrc -o -path /var/lib/dbus -o -path /var/lib/misc -o -path /var/lib/wsl-migrate -o -path /usr/local/bin/wsl-migrate -o -path /usr/local/sbin/wsl-start-docker -o -path /usr/local/lib/libjbr-musl-shim.so \) -prune -o -type f -exec sha256sum "{}" \;
    find "$root" \( -path /var/lib/apk -o -path /var/lib/openrc -o -path /var/lib/dbus -o -path /var/lib/misc -o -path /var/lib/wsl-migrate -o -path /usr/local/bin/wsl-migrate -o -path /usr/local/sbin/wsl-start-docker -o -path /usr/local/lib/libjbr-musl-shim.so \) -prune -o -type f -exec stat -c 'FILEMETA %a %u %g %n' "{}" \;
    find "$root" \( -path /var/lib/apk -o -path /var/lib/openrc -o -path /var/lib/dbus -o -path /var/lib/misc -o -path /var/lib/wsl-migrate -o -path /usr/local/bin/wsl-migrate -o -path /usr/local/sbin/wsl-start-docker -o -path /usr/local/lib/libjbr-musl-shim.so \) -prune -o -type d -exec stat -c 'DIRMETA %a %u %g %n' "{}" \;
    find "$root" \( -path /var/lib/apk -o -path /var/lib/openrc -o -path /var/lib/dbus -o -path /var/lib/misc -o -path /var/lib/wsl-migrate -o -path /usr/local/bin/wsl-migrate -o -path /usr/local/sbin/wsl-start-docker -o -path /usr/local/lib/libjbr-musl-shim.so \) -prune -o -type l -exec sh -c 'for path do printf "LINK %s -> %s\n" "$path" "$(readlink "$path")"; done' sh "{}" \;
  done
}
manifest_inside_source() {
  "$WSL_EXE" --distribution "$SOURCE_DISTRO" --user root --exec sh -c '
    for rel do
      root="/$rel"
      if [ ! -e "$root" ]; then printf "MISSING %s\n" "$root"; continue; fi
      printf "ROOT %s\n" "$root"
      find "$root" \( -path /var/lib/apk -o -path /var/lib/openrc -o -path /var/lib/dbus -o -path /var/lib/misc -o -path /var/lib/wsl-migrate -o -path /usr/local/bin/wsl-migrate -o -path /usr/local/sbin/wsl-start-docker -o -path /usr/local/lib/libjbr-musl-shim.so \) -prune -o -type f -exec sha256sum "{}" \;
      find "$root" \( -path /var/lib/apk -o -path /var/lib/openrc -o -path /var/lib/dbus -o -path /var/lib/misc -o -path /var/lib/wsl-migrate -o -path /usr/local/bin/wsl-migrate -o -path /usr/local/sbin/wsl-start-docker -o -path /usr/local/lib/libjbr-musl-shim.so \) -prune -o -type f -exec stat -c "FILEMETA %a %u %g %n" "{}" \;
      find "$root" \( -path /var/lib/apk -o -path /var/lib/openrc -o -path /var/lib/dbus -o -path /var/lib/misc -o -path /var/lib/wsl-migrate -o -path /usr/local/bin/wsl-migrate -o -path /usr/local/sbin/wsl-start-docker -o -path /usr/local/lib/libjbr-musl-shim.so \) -prune -o -type d -exec stat -c "DIRMETA %a %u %g %n" "{}" \;
      find "$root" \( -path /var/lib/apk -o -path /var/lib/openrc -o -path /var/lib/dbus -o -path /var/lib/misc -o -path /var/lib/wsl-migrate -o -path /usr/local/bin/wsl-migrate -o -path /usr/local/sbin/wsl-start-docker -o -path /usr/local/lib/libjbr-musl-shim.so \) -prune -o -type l -exec sh -c '\''for path do printf "LINK %s -> %s\n" "$path" "$(readlink "$path")"; done'\'' sh "{}" \;
    done
  ' sh $MIGRATION_PATHS 2>/dev/null
}
protected_config() {
  case "$1" in
    passwd|group|shadow|gshadow|wsl.conf|hostname|hosts|resolv.conf|fstab|machine-id|os-release|alpine-release|inittab|rc.conf|modules|apk/*|init.d/*|runlevels/*|ssh/ssh_host_*|wsl-migrate/*) return 0 ;;
    *) return 1 ;;
  esac
}
copy_config_file() {
  source_file=$1
  relative=$(printf '%s\n' "$source_file" | sed "s|^$SOURCE_ETC/||")
  destination=/etc/$relative
  mkdir -p "$(dirname "$destination")"
  if [ -d "$destination" ] && [ ! -d "$source_file" ]; then rm -rf -- "$destination"; fi
  cp -a "$source_file" "$destination"
}
restore_source_accounts() {
  source_passwd=$SOURCE_ETC/passwd
  source_group=$SOURCE_ETC/group
  source_shadow=$SOURCE_ETC/shadow
  [ -r "$source_passwd" ] && [ -r "$source_group" ] || return 0
  while IFS=: read -r name _ uid gid _ home shell; do
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    [ "$uid" -ge 1000 ] || continue
    case "$name" in *[!A-Za-z0-9_.-]*|'') warn "Skipped user account with unsupported name: $name"; continue ;; esac
    group_name=$(awk -F: -v g="$gid" '$3==g {print $1; exit}' "$source_group")
    [ -n "$group_name" ] || { warn "Could not find old primary group $gid for user $name."; continue; }
    old_uid=$(awk -F: -v n="$name" '$1==n {print $3; exit}' /etc/passwd)
    if [ -n "$old_uid" ] && [ "$old_uid" != "$uid" ]; then
      warn "User $name has conflicting UIDs ($old_uid in new Alpine, $uid in old Alpine); retained both copies for review."
      continue
    fi
    uid_owner=$(awk -F: -v u="$uid" '$3==u {print $1; exit}' /etc/passwd)
    if [ -z "$old_uid" ] && [ -n "$uid_owner" ]; then
      warn "UID $uid belongs to $uid_owner in new Alpine; could not recreate old user $name."
      continue
    fi
    current_gid=$(awk -F: -v n="$group_name" '$1==n {print $3; exit}' /etc/group)
    gid_owner=$(awk -F: -v g="$gid" '$3==g {print $1; exit}' /etc/group)
    if [ -n "$current_gid" ] && [ "$current_gid" != "$gid" ]; then
      warn "Group $group_name has conflicting GIDs; skipped account reconciliation for $name."
      continue
    fi
    if [ -z "$current_gid" ] && [ -n "$gid_owner" ]; then
      warn "GID $gid belongs to $gid_owner in new Alpine; skipped account reconciliation for $name."
      continue
    fi
    if [ -z "$current_gid" ]; then
      addgroup -g "$gid" "$group_name" >/dev/null 2>&1 || { warn "Could not restore primary group $group_name for $name."; continue; }
    fi
    if [ -z "$old_uid" ]; then
      if [ ! -x "$shell" ]; then warn "Shell $shell for $name is unavailable; using /bin/sh."; shell=/bin/sh; fi
      adduser -D -H -u "$uid" -G "$group_name" -s "$shell" -h "$home" "$name" >/dev/null 2>&1 || { warn "Could not recreate user $name."; continue; }
    elif [ -x "$shell" ]; then
      awk -F: -v OFS=: -v n="$name" -v g="$gid" -v s="$shell" '$1==n {$4=g; $7=s} {print}' /etc/passwd > "$STATE_DIR/passwd.tmp"
      cat "$STATE_DIR/passwd.tmp" > /etc/passwd
    else
      warn "Old shell $shell for $name is unavailable; kept the new account shell."
    fi
    if [ -r "$source_shadow" ]; then
      old_shadow=$(awk -F: -v n="$name" '$1==n {print; exit}' "$source_shadow")
      if [ -n "$old_shadow" ]; then
        awk -F: -v n="$name" -v old="$old_shadow" '$1==n {print old; found=1; next} {print} END {if(!found) print old}' /etc/shadow > "$STATE_DIR/shadow.tmp"
        cat "$STATE_DIR/shadow.tmp" > /etc/shadow
        chmod 600 /etc/shadow
      fi
    fi
    while IFS=: read -r extra_group _ extra_gid members; do
      case "$extra_gid" in ''|*[!0-9]*) continue ;; esac
      [ "$extra_gid" -ge 1000 ] || continue
      case ",$members," in
        *,"$name",*)
          existing_group_gid=$(awk -F: -v n="$extra_group" '$1==n {print $3; exit}' /etc/group)
          existing_gid_name=$(awk -F: -v g="$extra_gid" '$3==g {print $1; exit}' /etc/group)
          if [ -n "$existing_group_gid" ] && [ "$existing_group_gid" = "$extra_gid" ]; then
            addgroup "$name" "$extra_group" >/dev/null 2>&1 || :
          elif [ -z "$existing_group_gid" ] && [ -z "$existing_gid_name" ]; then
            addgroup -g "$extra_gid" "$extra_group" >/dev/null 2>&1 && addgroup "$name" "$extra_group" >/dev/null 2>&1 || warn "Could not restore supplementary group $extra_group for $name."
          else
            warn "Could not restore supplementary group $extra_group (GID $extra_gid conflicts in new Alpine)."
          fi ;;
      esac
    done < "$source_group"
  done < "$source_passwd"
}
stop_local_docker() {
  if [ -x /etc/init.d/docker ] && command -v rc-service >/dev/null 2>&1; then
    rc-service --nodeps --ifstarted docker stop || return 1
  elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    systemctl stop docker || return 1
  fi
  sync
}
on_exit() {
  status=$?
  [ "$status" -eq 0 ] && return
  echo >&2
  if [ "$MIGRATION_COMPLETE" -eq 1 ]; then
    echo "The migration completed, but a later optional action failed." >&2
    return
  fi
  echo "Migration stopped. The old distro remains registered and its export is retained." >&2
  if [ "$TARGET_DOCKER_STOPPED" -eq 1 ]; then
    echo "Docker in the new target may be stopped; start it with: sudo wsl-start-docker" >&2
  fi
  if [ "$SOURCE_STOP_ATTEMPTED" -eq 1 ]; then
    echo "Start the old distro from PowerShell with: wsl --distribution $SOURCE_DISTRO" >&2
  fi
  if [ "$EXPORT_VALID" -eq 1 ]; then
    echo "Resume into the current new Alpine distro with: wsl-migrate --resume \"$BACKUP_FILE\" \"$SOURCE_DISTRO\"" >&2
  fi
}
trap on_exit EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --resume) [ "$#" -ge 3 ] || fail "--resume requires BACKUP_TAR and SOURCE_DISTRO"; RESUME_ARCHIVE=$2; SOURCE_DISTRO=$3; shift 3 ;;
    --backup-dir) [ "$#" -ge 2 ] || fail "--backup-dir requires a Windows-mounted path"; BACKUP_DIR=$2; shift 2 ;;
    --include)
      [ "$#" -ge 2 ] || fail "--include requires an absolute path inside the old distro"
      extra=$2
      case "$extra" in /*) extra=$(printf '%s' "$extra" | cut -c 2-) ;; *) fail "--include path must start with /" ;; esac
      case "$extra" in *[!A-Za-z0-9_./-]*|*../*|../*|*/..) fail "custom path contains an unsupported character or '..'" ;; esac
      case "$extra" in etc|etc/*|bin|bin/*|sbin|sbin/*|lib|lib/*|lib64|lib64/*|proc|proc/*|sys|sys/*|dev|dev/*|run|run/*|tmp|tmp/*|mnt|mnt/*|media|media/*|boot|boot/*|usr|usr/*|var/lib/apk|var/lib/apk/*|var/lib/openrc|var/lib/openrc/*|var/lib/dbus|var/lib/dbus/*|var/lib/misc|var/lib/misc/*|var/lib/wsl-migrate|var/lib/wsl-migrate/*)
        fail "this system path cannot be added as user data: /$extra" ;;
      esac
      EXTRA_PATHS="$EXTRA_PATHS $extra"; shift 2 ;;
    --rollback) ROLLBACK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) fail "unknown option: $1" ;;
    *) [ -z "$SOURCE_DISTRO" ] || fail "specify one source distro"; SOURCE_DISTRO=$1; shift ;;
  esac
done

CURRENT_DISTRO=$(printenv WSL_DISTRO_NAME 2>/dev/null || :)
[ -n "$CURRENT_DISTRO" ] || fail "run this command inside the new Alpine Release distro"
WSL_EXE=$(printenv WSL_EXE 2>/dev/null || :)
if [ -z "$WSL_EXE" ]; then
  for candidate in /mnt/c/Windows/System32/wsl.exe /mnt/c/WINDOWS/System32/wsl.exe; do
    if [ -x "$candidate" ]; then WSL_EXE=$candidate; break; fi
  done
fi
[ -n "$WSL_EXE" ] || fail "cannot find wsl.exe; set WSL_EXE to its mounted Windows path"
export WSL_UTF8=1
WINDOWS_DIR=$(dirname -- "$WSL_EXE")
CMD_EXE=$WINDOWS_DIR/cmd.exe
[ -x "$CMD_EXE" ] || fail "cannot find cmd.exe beside wsl.exe"
WINDOWS_USERPROFILE=$(WSL_UTF8=1 "$CMD_EXE" /d /c echo %USERPROFILE% | tr -d '\r\000')
[ -n "$WINDOWS_USERPROFILE" ] || fail "could not read the Windows user profile"

if [ "$ROLLBACK" -eq 1 ]; then
  if [ -z "$SOURCE_DISTRO" ]; then
    [ -r /etc/wsl-migrate/previous-default ] || fail "no previous default was recorded; specify one with --rollback DISTRO"
    SOURCE_DISTRO=$(cat /etc/wsl-migrate/previous-default)
  fi
  load_distro_list || fail "could not read WSL distro list"
  distro_is_registered "$SOURCE_DISTRO" || fail "previous default is not registered: $SOURCE_DISTRO"
  "$WSL_EXE" --set-default "$SOURCE_DISTRO"
  echo "Default WSL distro restored to $SOURCE_DISTRO. The old distro data was not changed."
  exit 0
fi
[ "$(id -u)" -eq 0 ] || fail "run the migration as root with: sudo -E wsl-migrate $SOURCE_DISTRO"
[ -n "$SOURCE_DISTRO" ] || { usage >&2; exit 2; }
case "$SOURCE_DISTRO" in *[!A-Za-z0-9_.-]*|'') fail "distro names may contain only letters, digits, dot, underscore, and hyphen" ;; esac
[ "$SOURCE_DISTRO" != "$CURRENT_DISTRO" ] || fail "source and current target distro are the same"
[ -r /etc/alpine-wsl-build ] || fail "the current distro is not a myAlpine-wsl Release image"
command -v tar >/dev/null 2>&1 || fail "GNU tar is required; install it in the new Alpine distro"
tar --version 2>/dev/null | grep -q 'GNU tar' || fail "GNU tar is required; BusyBox tar is not sufficient"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

load_distro_list || fail "could not read 'wsl --list --verbose'"
distro_is_registered "$SOURCE_DISTRO" || fail "source distro is not registered: $SOURCE_DISTRO"
PREVIOUS_DEFAULT=$(default_distro)
[ -n "$PREVIOUS_DEFAULT" ] || fail "could not detect the current default WSL distro"
SOURCE_ALPINE=$(WSL_UTF8=1 "$WSL_EXE" --distribution "$SOURCE_DISTRO" --user root --exec cat /etc/alpine-release 2>/dev/null | tr -d '\r\000' || echo unknown)
TARGET_ALPINE=$(cat /etc/alpine-release 2>/dev/null || echo unknown)
MIGRATION_PATHS="home root opt srv usr/local var/www var/lib$EXTRA_PATHS"
safe_name=$(printf '%s' "$SOURCE_DISTRO" | tr -c 'A-Za-z0-9_.-' '_')
if [ -z "$BACKUP_DIR" ]; then
  BACKUP_DIR=$(wslpath -u "$WINDOWS_USERPROFILE")/Documents/myAlpine-wsl-backups
fi
case "$BACKUP_DIR" in /mnt/[A-Za-z]/*) ;; *) fail "backup directory must be on a mounted Windows drive";; esac
BACKUP_PARENT=$BACKUP_DIR
while [ ! -d "$BACKUP_PARENT" ]; do
  NEXT_PARENT=$(dirname -- "$BACKUP_PARENT")
  [ "$NEXT_PARENT" != "$BACKUP_PARENT" ] || fail "could not find an existing backup parent"
  BACKUP_PARENT=$NEXT_PARENT
done
[ -w "$BACKUP_PARENT" ] || fail "backup location is not writable"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
if [ -n "$RESUME_ARCHIVE" ]; then
  BACKUP_FILE=$RESUME_ARCHIVE
  case "$BACKUP_FILE" in /mnt/[A-Za-z]/*) ;; *) fail "resume archive must be on a mounted Windows drive";; esac
  [ -s "$BACKUP_FILE" ] || fail "resume archive is missing or empty"
  CONTENT_MANIFEST=$BACKUP_FILE.content-manifest
  CHECKSUM_FILE=$BACKUP_FILE.sha256
  PREVIOUS_DEFAULT_FILE=$BACKUP_FILE.previous-default
  SIZE_FILE=$BACKUP_FILE.sizes
  [ -s "$CONTENT_MANIFEST" ] && [ -r "$CHECKSUM_FILE" ] && [ -r "$PREVIOUS_DEFAULT_FILE" ] && [ -r "$SIZE_FILE" ] || fail "resume archive sidecars are incomplete"
  expected_sha=$(awk 'NR==1 {print $1}' "$CHECKSUM_FILE")
  [ "$(sha256sum "$BACKUP_FILE" | awk '{print $1}')" = "$expected_sha" ] || fail "resume archive checksum does not match"
  EXPORT_VALID=1
  PREVIOUS_DEFAULT=$(cat "$PREVIOUS_DEFAULT_FILE")
  SOURCE_USED_KB=$(awk 'NR==1 {print $1}' "$SIZE_FILE")
  SOURCE_DATA_KB=$(awk 'NR==2 {print $1}' "$SIZE_FILE")
else
  BACKUP_FILE=$BACKUP_DIR/$safe_name-$timestamp.tar
  CONTENT_MANIFEST=$BACKUP_FILE.content-manifest
  CHECKSUM_FILE=$BACKUP_FILE.sha256
  PREVIOUS_DEFAULT_FILE=$BACKUP_FILE.previous-default
  SIZE_FILE=$BACKUP_FILE.sizes
  [ ! -e "$BACKUP_FILE" ] || fail "backup archive already exists"
fi
ARCHIVE_PREFIX=
if tar -tf "$BACKUP_FILE" 2>/dev/null | grep -q '^\./etc/'; then ARCHIVE_PREFIX=./; fi
if [ -n "$RESUME_ARCHIVE" ]; then
  tar -tf "$BACKUP_FILE" >/dev/null 2>&1 || fail "resume archive is not a readable tar"
  if tar -tf "$BACKUP_FILE" | awk 'substr($0,1,1)=="/" || $0 ~ /(^|\/)\.\.(\/|$)/ {bad=1} END {exit bad ? 0 : 1}'; then fail "resume archive contains unsafe paths"; fi
fi

if [ -z "$RESUME_ARCHIVE" ]; then
  SIZE_OUTPUT=$("$WSL_EXE" --distribution "$SOURCE_DISTRO" --user root --exec sh -c '
    du -skx /
    total=0
    for rel do
      path="/$rel"
      [ -e "$path" ] || continue
      size=$(du -skx "$path" | awk "NR==1 {print \$1}")
      case "$size" in *[!0-9]*|"") continue ;; esac
      total=$((total + size))
    done
    printf "%s\n" "$total"
  ' sh $MIGRATION_PATHS 2>/dev/null) || fail "could not estimate source data size"
  SOURCE_USED_KB=$(printf '%s\n' "$SIZE_OUTPUT" | awk 'NR==1 && $1 ~ /^[0-9]+$/ {print $1}')
  SOURCE_DATA_KB=$(printf '%s\n' "$SIZE_OUTPUT" | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}')
fi
case "$SOURCE_USED_KB:$SOURCE_DATA_KB" in *[!0-9:]*|:*) fail "could not calculate source sizes";; esac
TARGET_DU_KB=0
for rel in etc home root opt srv usr/local var/www var/lib; do
  if [ -e "/$rel" ]; then size=$(du -skx "/$rel" | awk 'NR==1 {print $1}'); TARGET_DU_KB=$((TARGET_DU_KB + size)); fi
done
BACKUP_AVAILABLE_KB=$(df -Pk "$BACKUP_PARENT" 2>/dev/null | awk 'END {print $4}')
TARGET_AVAILABLE_KB=$(df -Pk / 2>/dev/null | awk 'END {print $4}')
case "$BACKUP_AVAILABLE_KB:$TARGET_AVAILABLE_KB" in *[!0-9:]*|:*) fail "could not read free space";; esac
BACKUP_REQUIRED_KB=$(awk -v s="$SOURCE_USED_KB" -v t="$TARGET_DU_KB" 'BEGIN {printf "%.0f", (s+t)*1.20+2097152}')
TARGET_REQUIRED_KB=$(awk -v s="$SOURCE_DATA_KB" 'BEGIN {printf "%.0f", s*1.20+1048576}')
[ "$BACKUP_AVAILABLE_KB" -ge "$BACKUP_REQUIRED_KB" ] || fail "not enough backup-drive space; need about $(awk -v k="$BACKUP_REQUIRED_KB" 'BEGIN{printf "%.1f",k/1048576}') GiB"
[ "$TARGET_AVAILABLE_KB" -ge "$TARGET_REQUIRED_KB" ] || fail "not enough space inside the new distro; need about $(awk -v k="$TARGET_REQUIRED_KB" 'BEGIN{printf "%.1f",k/1048576}') GiB"
BACKUP_DIR=$(mkdir -p "$BACKUP_DIR" && CDPATH='' cd -- "$BACKUP_DIR" && pwd)
WINDOWS_BACKUP=$(wslpath -w "$BACKUP_FILE")
TARGET_BACKUP_FILE=$BACKUP_FILE.target-before.tar
STATE_DIR=/var/lib/wsl-migrate/$timestamp
WARNINGS=$STATE_DIR/warnings.txt

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF
Source distro: $SOURCE_DISTRO (Alpine $SOURCE_ALPINE)
New target: $CURRENT_DISTRO (Alpine $TARGET_ALPINE)
Data paths: /home /root /opt /srv /usr/local /var/www /var/lib$EXTRA_PATHS
Full old distro export: $BACKUP_FILE
New target snapshot: $TARGET_BACKUP_FILE
Old /etc/apk/world package list will be resolved against the new Alpine repositories.
Non-system /etc config files migrate; conflicts will be presented for your choice.
Protected new-system files include users, APK state, WSL boot/network config and identity.
EOF
  exit 0
fi

cat <<EOF

==================== Migration processing overview ====================
Source: $SOURCE_DISTRO (Alpine $SOURCE_ALPINE)
Target: $CURRENT_DISTRO (Alpine $TARGET_ALPINE)
The new Release OS files remain in place; old OS binaries are not overlaid.
Will migrate: APK package list, compatible users/groups, /home, /root, /opt,
  /srv, /usr/local, /var/www, /var/lib application data$EXTRA_PATHS
Will merge: non-system /etc configuration; differing files require OLD or NEW choice.
Will retain: complete old distro export, old /etc snapshot, and target snapshot.
Will keep new: package database, WSL boot/network settings, OS files and machine identity.
APK, OpenRC, DBus, and miscellaneous system runtime state is kept from the new Release.
Docker data is copied while stopped; Docker/kernel changes may prevent containers starting.
The old distro remains registered and its data is not deleted.
Backup: $BACKUP_FILE
Target snapshot: $TARGET_BACKUP_FILE
Backup space required: $(awk -v k="$BACKUP_REQUIRED_KB" 'BEGIN{printf "%.1f",k/1048576}') GiB
New distro free space required: $(awk -v k="$TARGET_REQUIRED_KB" 'BEGIN{printf "%.1f",k/1048576}') GiB

No migration data has been copied yet.
=======================================================================
Proceed? [y/N] 
EOF
IFS= read -r answer || answer=
case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled. No source service was stopped."; exit 0 ;; esac
printf 'Stop workloads in both distros, then type READY: '
IFS= read -r answer || answer=
[ "$answer" = READY ] || { echo "Cancelled. No source service was stopped."; exit 0; }

mkdir -p "$STATE_DIR"
: > "$WARNINGS"
stop_local_docker || fail "could not stop Docker in the new target"
TARGET_DOCKER_STOPPED=1
if [ -z "$RESUME_ARCHIVE" ]; then
  "$WSL_EXE" --distribution "$SOURCE_DISTRO" --user root --exec sh -c '
    if [ -x /etc/init.d/docker ] && command -v rc-service >/dev/null 2>&1; then
      rc-service --nodeps --ifstarted docker stop || exit 20
    elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker; then
      systemctl stop docker || exit 21
    fi
    sync
  ' || fail "could not stop Docker or sync the old distro"
  manifest_inside_source > "$CONTENT_MANIFEST.raw" || fail "could not create source data manifest"
  tr -d '\r' < "$CONTENT_MANIFEST.raw" | LC_ALL=C sort > "$CONTENT_MANIFEST"
  rm -f "$CONTENT_MANIFEST.raw"
  printf '%s\n' "$PREVIOUS_DEFAULT" > "$PREVIOUS_DEFAULT_FILE"
  printf '%s\n%s\n' "$SOURCE_USED_KB" "$SOURCE_DATA_KB" > "$SIZE_FILE"
fi

if [ -s "$TARGET_BACKUP_FILE" ]; then
  tar -tf "$TARGET_BACKUP_FILE" >/dev/null 2>&1 || fail "existing target snapshot is incomplete"
else
  TARGET_LIST=$STATE_DIR/target-files.list
  : > "$TARGET_LIST"
  for rel in etc home root opt srv usr/local var/www var/lib; do [ -e "/$rel" ] && printf './%s\n' "$rel" >> "$TARGET_LIST"; done
  tar -cpf "$TARGET_BACKUP_FILE" -C / --numeric-owner --same-owner --same-permissions \
    --exclude='./var/lib/apk' --exclude='./var/lib/openrc' --exclude='./var/lib/dbus' --exclude='./var/lib/misc' --exclude='./var/lib/wsl-migrate' \
    --files-from="$TARGET_LIST" || fail "could not save a target recovery snapshot"
fi
if [ -z "$RESUME_ARCHIVE" ]; then
  SOURCE_STOP_ATTEMPTED=1
  "$WSL_EXE" --distribution "$SOURCE_DISTRO" --user root --exec poweroff >/dev/null 2>&1 || :
  load_distro_list || fail "could not check whether the old distro stopped"
  if distro_is_running "$SOURCE_DISTRO"; then
    printf 'Old distro is still running. Type FORCE to terminate remaining processes: '
    IFS= read -r answer || answer=
    [ "$answer" = FORCE ] || fail "graceful poweroff did not stop the source"
    "$WSL_EXE" --terminate "$SOURCE_DISTRO" || fail "could not terminate old distro"
  fi
  echo "Exporting the complete old distro..."
  "$WSL_EXE" --export "$SOURCE_DISTRO" "$WINDOWS_BACKUP"
  [ -s "$BACKUP_FILE" ] || fail "WSL export is empty"
  tar -tf "$BACKUP_FILE" >/dev/null 2>&1 || fail "export is not a readable tar"
  if tar -tf "$BACKUP_FILE" | awk 'substr($0,1,1)=="/" || $0 ~ /(^|\/)\.\.(\/|$)/ {bad=1} END {exit bad ? 0 : 1}'; then fail "export contains unsafe paths"; fi
  EXPORT_SHA256=$(sha256sum "$BACKUP_FILE" | awk '{print $1}')
  printf '%s  %s\n' "$EXPORT_SHA256" "$(basename -- "$BACKUP_FILE")" > "$CHECKSUM_FILE"
  EXPORT_VALID=1
  if tar -tf "$BACKUP_FILE" | grep -q '^\./etc/'; then ARCHIVE_PREFIX=./; else ARCHIVE_PREFIX=; fi
else
  tar -tf "$BACKUP_FILE" >/dev/null 2>&1 || fail "resume archive is not readable"
  expected_sha=$(awk 'NR==1 {print $1}' "$CHECKSUM_FILE")
  [ "$(sha256sum "$BACKUP_FILE" | awk '{print $1}')" = "$expected_sha" ] || fail "resume archive checksum does not match"
  EXPORT_VALID=1
fi
ARCHIVE_LIST_FILE=$STATE_DIR/archive.list
tar -tf "$BACKUP_FILE" > "$ARCHIVE_LIST_FILE" || fail "could not list the source export"

mkdir -p "$STATE_DIR/source-etc"
  tar -xpf "$BACKUP_FILE" -C "$STATE_DIR/source-etc" --numeric-owner --same-owner --same-permissions --wildcards --wildcards-match-slash -- \
  "$ARCHIVE_PREFIX"etc "$ARCHIVE_PREFIX"'etc/**' "$ARCHIVE_PREFIX"'etc/*' 2>/dev/null || fail "could not extract old /etc for migration"
SOURCE_ETC=$STATE_DIR/source-etc
[ -d "$SOURCE_ETC/etc" ] && SOURCE_ETC=$SOURCE_ETC/etc
[ -d "$SOURCE_ETC" ] || fail "old /etc snapshot was not found"
WORLD_FILE=$STATE_DIR/apk-world
if tar -xOf "$BACKUP_FILE" "$ARCHIVE_PREFIX"etc/apk/world > "$WORLD_FILE" 2>/dev/null; then :; else : > "$WORLD_FILE"; warn "Old APK package list is missing."; fi

if [ -s "$WORLD_FILE" ]; then
  echo "Resolving old packages against current Alpine repositories..."
  apk update > "$STATE_DIR/apk-update.log" 2>&1 || { warn "Could not refresh APK indexes."; PACKAGE_WARNING=1; }
  : > "$STATE_DIR/apk-world-safe"
  while IFS= read -r package; do
    case "$package" in ''|\#*) continue ;; *[!A-Za-z0-9+._:@<>~=,-]*) warn "Skipped unsupported APK entry: $package"; PACKAGE_WARNING=1 ;; *) printf '%s\n' "$package" >> "$STATE_DIR/apk-world-safe" ;; esac
  done < "$WORLD_FILE"
  set --
  while IFS= read -r package; do [ -n "$package" ] && set -- "$@" "$package"; done < "$STATE_DIR/apk-world-safe"
  if [ "$#" -gt 0 ]; then
    if apk add --simulate "$@" > "$STATE_DIR/apk-plan.log" 2>&1; then
      apk add "$@" > "$STATE_DIR/apk-install.log" 2>&1 || { warn "APK install failed; see $STATE_DIR/apk-install.log"; PACKAGE_WARNING=1; }
    else
      sed 's/[<>=~].*$//' "$STATE_DIR/apk-world-safe" | sed '/^$/d' > "$STATE_DIR/apk-world-relaxed"
      set --
      while IFS= read -r package; do [ -n "$package" ] && set -- "$@" "$package"; done < "$STATE_DIR/apk-world-relaxed"
      if [ "$#" -gt 0 ] && apk add --simulate "$@" > "$STATE_DIR/apk-plan-relaxed.log" 2>&1; then
        cat "$STATE_DIR/apk-plan.log" >&2
        printf 'Old version pins are unavailable. Type LATEST to install current package versions: '
        IFS= read -r answer || answer=
        if [ "$answer" = LATEST ]; then
          apk add "$@" > "$STATE_DIR/apk-install.log" 2>&1 || { warn "Some current packages could not be installed; see $STATE_DIR/apk-install.log"; PACKAGE_WARNING=1; }
          warn "Some old package versions were replaced by current repository versions."
        else
          warn "Skipped package restore because the pinned versions were unavailable."
          PACKAGE_WARNING=1
        fi
      else
        cat "$STATE_DIR/apk-plan.log" >&2
        printf 'Some packages cannot be resolved. Type CONTINUE to migrate without them: '
        IFS= read -r answer || answer=
        [ "$answer" = CONTINUE ] || fail "package compatibility needs review"
        warn "Some APK packages were not installed; planning logs are in $STATE_DIR."
        PACKAGE_WARNING=1
      fi
    fi
  fi
fi
echo "Restoring compatible user accounts and groups..."
restore_source_accounts
SOURCE_ROOT_HASH=$(awk -F: '$1=="root" {print $2; exit}' "$SOURCE_ETC/shadow" 2>/dev/null || :)
TARGET_ROOT_HASH=$(awk -F: '$1=="root" {print $2; exit}' /etc/shadow 2>/dev/null || :)
if [ -n "$SOURCE_ROOT_HASH" ] && [ "$SOURCE_ROOT_HASH" != "$TARGET_ROOT_HASH" ]; then
  warn "Root password settings were kept from the new Release; the old entry remains in the source export."
fi
if [ -s "$WARNINGS" ]; then
  echo "Some users, groups, or packages need manual review; details are listed above and in $WARNINGS."
  printf 'Type CONTINUE to proceed with data migration: '
  IFS= read -r answer || answer=
  [ "$answer" = CONTINUE ] || fail "account and package warnings need review"
fi
mkdir -p /var/lib/wsl-migrate "$STATE_DIR"
find "$SOURCE_ETC" \( -type f -o -type l \) -print | LC_ALL=C sort > "$STATE_DIR/etc-files.list"
: > "$STATE_DIR/etc-auto.list"
: > "$STATE_DIR/etc-conflicts.list"
: > "$STATE_DIR/etc-protected.list"
while IFS= read -r source_file; do
  relative=$(printf '%s\n' "$source_file" | sed "s|^$SOURCE_ETC/||")
  if protected_config "$relative"; then printf '%s\n' "$relative" >> "$STATE_DIR/etc-protected.list"; continue; fi
  destination=/etc/$relative
  if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then printf '%s\n' "$relative" >> "$STATE_DIR/etc-auto.list"
  elif [ -L "$source_file" ] && [ -L "$destination" ] && [ "$(readlink "$source_file")" = "$(readlink "$destination")" ]; then :
  elif [ -f "$source_file" ] && [ -f "$destination" ] && cmp -s "$source_file" "$destination"; then :
  else printf '%s\n' "$relative" >> "$STATE_DIR/etc-conflicts.list"; fi
done < "$STATE_DIR/etc-files.list"
if [ -s "$STATE_DIR/etc-conflicts.list" ]; then
  echo "Old configuration files differ from the new Release:"
  sed -n '1,60p' "$STATE_DIR/etc-conflicts.list"
  [ "$(wc -l < "$STATE_DIR/etc-conflicts.list")" -le 60 ] || echo "...more paths are listed in $STATE_DIR/etc-conflicts.list"
  echo "Old configuration remains at $SOURCE_ETC; the target snapshot is $TARGET_BACKUP_FILE."
  printf 'Type OLD to apply the old versions, NEW to keep Release versions, or anything else to cancel: '
  IFS= read -r answer || answer=
  case "$answer" in OLD) CONFIG_CHOICE=use-old ;; NEW) CONFIG_CHOICE=keep-new ;; *) fail "configuration conflicts need review" ;; esac
fi
while IFS= read -r relative; do [ -n "$relative" ] && copy_config_file "$SOURCE_ETC/$relative"; done < "$STATE_DIR/etc-auto.list"
if [ "$CONFIG_CHOICE" = use-old ]; then
  while IFS= read -r relative; do [ -n "$relative" ] && copy_config_file "$SOURCE_ETC/$relative"; done < "$STATE_DIR/etc-conflicts.list"
fi
if [ -s "$STATE_DIR/etc-protected.list" ]; then
  warn "Old system files were kept in the archive, not activated; see $STATE_DIR/etc-protected.list."
  sed -n '1,60p' "$STATE_DIR/etc-protected.list"
  printf 'Type CONTINUE to keep the new Release system files and continue: '
  IFS= read -r answer || answer=
  [ "$answer" = CONTINUE ] || fail "system configuration differences need review"
fi

echo "Restoring users and application data..."
for rel in home root opt srv var/www; do
  if archive_has "$rel"; then mkdir -p "/$rel"; find "/$rel" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || :; fi
done
if archive_has var/lib; then
  for target in /var/lib/* /var/lib/.[!.]*; do
    [ -e "$target" ] || [ -L "$target" ] || continue
    base=$(basename "$target")
    case "$base" in apk|openrc|dbus|misc|wsl-migrate) continue ;; esac
    rm -rf -- "$target"
  done
fi
DATA_PATTERNS=$STATE_DIR/data-patterns.list
: > "$DATA_PATTERNS"
for rel in home root opt srv usr/local var/www var/lib; do
  if archive_contains "$rel"; then printf '%s\n%s\n' "$ARCHIVE_PREFIX$rel" "$ARCHIVE_PREFIX$rel"'/**' >> "$DATA_PATTERNS"; fi
done
for extra in $EXTRA_PATHS; do
  if archive_contains "$extra"; then printf '%s\n%s\n' "$ARCHIVE_PREFIX$extra" "$ARCHIVE_PREFIX$extra"'/**' >> "$DATA_PATTERNS"
  else warn "The old distro did not contain custom path /$extra; it was skipped."; fi
done
for extra in $EXTRA_PATHS; do
  if archive_contains "$extra"; then
    if [ -d "/$extra" ]; then find "/$extra" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || :; else rm -f -- "/$extra"; fi
  fi
done
tar --extract --file="$BACKUP_FILE" --directory=/ --numeric-owner --same-owner --same-permissions --overwrite --wildcards --wildcards-match-slash \
  --exclude="$ARCHIVE_PREFIX"var/lib/apk --exclude="$ARCHIVE_PREFIX"'var/lib/apk/*' --exclude="$ARCHIVE_PREFIX"var/lib/openrc --exclude="$ARCHIVE_PREFIX"'var/lib/openrc/*' \
  --exclude="$ARCHIVE_PREFIX"var/lib/dbus --exclude="$ARCHIVE_PREFIX"'var/lib/dbus/*' --exclude="$ARCHIVE_PREFIX"var/lib/misc --exclude="$ARCHIVE_PREFIX"'var/lib/misc/*' \
  --exclude="$ARCHIVE_PREFIX"var/lib/wsl-migrate --exclude="$ARCHIVE_PREFIX"'var/lib/wsl-migrate/*' \
  --exclude="$ARCHIVE_PREFIX"usr/local/bin/wsl-migrate --exclude="$ARCHIVE_PREFIX"usr/local/sbin/wsl-start-docker --exclude="$ARCHIVE_PREFIX"usr/local/lib/libjbr-musl-shim.so \
  --files-from="$DATA_PATTERNS" 2>/dev/null || fail "could not restore old data from the export"

SOURCE_DEFAULT_USER=$(awk -F= '/^[[:space:]]*default[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$SOURCE_ETC/wsl.conf" 2>/dev/null || :)
SOURCE_DEFAULT_UID=$(awk -F: -v n="$SOURCE_DEFAULT_USER" '$1==n {print $3; exit}' "$SOURCE_ETC/passwd" 2>/dev/null || :)
TARGET_DEFAULT_UID=$(awk -F: -v n="$SOURCE_DEFAULT_USER" '$1==n {print $3; exit}' /etc/passwd)
if [ -n "$SOURCE_DEFAULT_USER" ] && [ -n "$SOURCE_DEFAULT_UID" ] && [ "$SOURCE_DEFAULT_UID" = "$TARGET_DEFAULT_UID" ]; then
  awk -v wanted="$SOURCE_DEFAULT_USER" '
    BEGIN {in_user=0; found=0}
    /^[[:space:]]*\[/ {
      if (in_user && !found) print "default=" wanted
      in_user=($0 ~ /^[[:space:]]*\[user\][[:space:]]*$/)
      if (in_user) user_seen=1
      print; next
    }
    {
      if (in_user && $0 ~ /^[[:space:]]*default[[:space:]]*=/) {print "default=" wanted; found=1; next}
      print
    }
    END {
      if (in_user && !found) print "default=" wanted
      if (!user_seen) {print ""; print "[user]"; print "default=" wanted}
    }' /etc/wsl.conf > "$STATE_DIR/wsl.conf.tmp"
  cat "$STATE_DIR/wsl.conf.tmp" > /etc/wsl.conf
elif [ -n "$SOURCE_DEFAULT_USER" ]; then
  warn "Old default user $SOURCE_DEFAULT_USER could not be restored with the same UID; kept the Release default."
fi
if [ -d "$SOURCE_ETC/runlevels/default" ]; then
  for service_link in "$SOURCE_ETC"/runlevels/default/*; do
    [ -L "$service_link" ] || continue
    service=$(basename "$service_link")
    if [ -x "/etc/init.d/$service" ] && command -v rc-update >/dev/null 2>&1; then rc-update add "$service" default >/dev/null 2>&1 || warn "Could not enable old OpenRC service: $service"
    else warn "Old OpenRC service is not installed in new Alpine: $service"; fi
  done
fi
if command -v ssh-keygen >/dev/null 2>&1; then
  for key in /etc/ssh/ssh_host_*; do [ -e "$key" ] || continue; rm -f -- "$key"; done
  ssh-keygen -A >/dev/null 2>&1 || warn "Could not generate unique SSH host keys in the new distro."
fi

echo "Verifying migrated data, file contents, permissions, owners and symlinks..."
make_target_manifest > "$BACKUP_FILE.target-content-manifest.raw" || fail "could not create target manifest"
tr -d '\r' < "$BACKUP_FILE.target-content-manifest.raw" | LC_ALL=C sort > "$BACKUP_FILE.target-content-manifest"
rm -f "$BACKUP_FILE.target-content-manifest.raw"
if ! cmp -s "$CONTENT_MANIFEST" "$BACKUP_FILE.target-content-manifest"; then
  CONTENT_DIFFERENCES=1
  echo "Differences were found between source and target data:" >&2
  diff -u "$CONTENT_MANIFEST" "$BACKUP_FILE.target-content-manifest" | sed -n '1,80p' >&2 || :
  printf 'Review the differences. Type CONTINUE to accept and finish: '
  IFS= read -r answer || answer=
  [ "$answer" = CONTINUE ] || fail "data differences need review; old distro and backups remain"
fi
sync
load_distro_list || fail "could not verify WSL distro registrations"
distro_is_registered "$SOURCE_DISTRO" || fail "old distro registration changed unexpectedly"
distro_is_registered "$CURRENT_DISTRO" || fail "new target registration changed unexpectedly"
mkdir -p /etc/wsl-migrate
printf '%s\n' "$PREVIOUS_DEFAULT" > /etc/wsl-migrate/previous-default
EXPORT_SHA256=$(sha256sum "$BACKUP_FILE" | awk '{print $1}')
REPORT_FILE=$BACKUP_FILE.migration.txt
{
  printf 'Source distro: %s (Alpine %s)\n' "$SOURCE_DISTRO" "$SOURCE_ALPINE"
  printf 'Target distro: %s (Alpine %s)\n' "$CURRENT_DISTRO" "$TARGET_ALPINE"
  printf 'Previous default: %s\n' "$PREVIOUS_DEFAULT"
  printf 'Completed at (UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Source export: %s\nSource SHA-256: %s\n' "$BACKUP_FILE" "$EXPORT_SHA256"
  printf 'Target snapshot: %s\nMigrated paths: %s\n' "$TARGET_BACKUP_FILE" "$MIGRATION_PATHS"
  printf 'APK package warning: %s\nConfig choice: %s\nData differences accepted: %s\n' "$PACKAGE_WARNING" "$CONFIG_CHOICE" "$CONTENT_DIFFERENCES"
  printf 'Warnings: %s\nOld /etc snapshot: %s\n' "$WARNINGS" "$SOURCE_ETC"
} > "$REPORT_FILE"
MIGRATION_COMPLETE=1
echo
echo "Migration completed into new Alpine Release: $CURRENT_DISTRO"
echo "Old distro remains registered and unchanged: $SOURCE_DISTRO"
echo "Old data, compatible users, package list and selected configuration were migrated."
echo "Old /etc snapshot: $SOURCE_ETC"
echo "Source export: $BACKUP_FILE"
echo "Target snapshot: $TARGET_BACKUP_FILE"
echo "Migration report: $REPORT_FILE"
[ ! -s "$WARNINGS" ] || echo "Review warnings: $WARNINGS"
echo "To restore the previous WSL default ($PREVIOUS_DEFAULT): wsl-migrate --rollback"
printf 'Set the new Alpine distro as WSL default? [y/N] '
IFS= read -r switch_answer || switch_answer=
case "$switch_answer" in
  y|Y|yes|YES) "$WSL_EXE" --set-default "$CURRENT_DISTRO"; echo "Default WSL distro set to $CURRENT_DISTRO." ;;
  *) echo "Default WSL distro was not changed." ;;
esac

