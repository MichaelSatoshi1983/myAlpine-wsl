#!/bin/sh
set -eu

REPOSITORY=MichaelSatoshi1983/myAlpine-wsl
RELEASES_API='https://api.github.com/repos/MichaelSatoshi1983/myAlpine-wsl/releases?per_page=100'
ASSET_NAME=alpine-wsl.tar.gz
CHECKSUM_NAME=alpine-wsl.tar.gz.sha256
METADATA=/etc/alpine-wsl-build
MODE=prompt

usage() {
  cat <<'EOF'
Usage: wsl-update [--check|--auto|--manual]

  --check   Check for a matching Release without downloading it.
  --auto    Download, import the new distro side by side, then start migration.
  --manual  Download the image and print the PowerShell import/migration steps.
  (default) Download a verified update, then ask which update method to use.
EOF
}

fail() {
  printf 'wsl-update: %s\n' "$*" >&2
  exit 1
}

case "$#" in
  0) ;;
  1)
    case "$1" in
      --check) MODE=check ;;
      --auto) MODE=auto ;;
      --manual) MODE=manual ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  *) usage >&2; exit 2 ;;
esac

for tool in curl jq sha256sum tar sed grep awk tr cut wslpath; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
done

[ -r "$METADATA" ] || fail "build metadata is missing: $METADATA"
WINDOWS_TARGET=$(sed -n 's/^Windows target: //p' "$METADATA")
CURRENT_RELEASE=$(sed -n 's/^Release tag: //p' "$METADATA")
BUILT_AT=$(sed -n 's/^Built at (UTC): //p' "$METADATA")
CURRENT_DISTRO=$(printenv WSL_DISTRO_NAME 2>/dev/null || true)

case "$WINDOWS_TARGET" in
  windows10) PLATFORM=win10x64 ;;
  windows11) PLATFORM=win11x64 ;;
  *) fail "unsupported Windows target in build metadata: $WINDOWS_TARGET" ;;
esac

LOCK_DIR=${TMPDIR:-/tmp}/wsl-update-$PLATFORM.lock
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another wsl-update operation is already running for $PLATFORM"
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || :' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ -n "$CURRENT_DISTRO" ] || fail "WSL_DISTRO_NAME is unavailable; run this command inside the registered distro"
[ -n "$BUILT_AT" ] || fail "build timestamp is missing from $METADATA"
case "$CURRENT_DISTRO" in *[!A-Za-z0-9_.-]*|'') fail "this source distro name contains characters unsupported by wsl-migrate: $CURRENT_DISTRO" ;; esac

TAG_PATTERN=$(printf '^Alpine_[0-9]{6}_%s_[0-9a-f]{12}$' "$PLATFORM")
printf 'Checking the latest %s Release...\n' "$PLATFORM"
RELEASES_JSON=$(curl -fsSL \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$RELEASES_API") || fail "could not reach the GitHub Releases API"

# The jq program uses jq's $pattern variable, not shell expansion.
# shellcheck disable=SC2016
LATEST_RELEASE=$(printf '%s\n' "$RELEASES_JSON" | jq -c --arg pattern "$TAG_PATTERN" \
  '[.[] | select(.draft == false and .prerelease == false) | select(.tag_name | test($pattern))] | first // empty' 2>/dev/null || true)
[ -n "$LATEST_RELEASE" ] || fail "no published Release found for $PLATFORM"

LATEST_TAG=$(printf '%s\n' "$LATEST_RELEASE" | jq -r '.tag_name')
PUBLISHED_AT=$(printf '%s\n' "$LATEST_RELEASE" | jq -r '.published_at // "unknown"')
# The jq program uses jq's $name variable, not shell expansion.
# shellcheck disable=SC2016
ASSET_DIGEST=$(printf '%s\n' "$LATEST_RELEASE" | jq -r --arg name "$ASSET_NAME" \
  '[.assets[]? | select(.name == $name) | .digest] | first // empty')
printf 'Installed Release: '
if [ -n "$CURRENT_RELEASE" ]; then
  printf '%s\n' "$CURRENT_RELEASE"
else
  printf 'legacy/local build\n'
fi
printf 'Latest Release:    %s\n' "$LATEST_TAG"
printf 'Published:         %s\n' "$PUBLISHED_AT"

if [ "$LATEST_TAG" = "$CURRENT_RELEASE" ]; then
  printf 'This distro is already on the latest matching Release.\n'
  exit 0
fi

LATEST_DATE_PART=$(printf '%s\n' "$LATEST_TAG" | cut -d '_' -f 2)
LATEST_DATE=$(printf '%s\n' "$LATEST_DATE_PART" | awk '{ print "20" substr($0, 5, 2) substr($0, 3, 2) substr($0, 1, 2) }')
if printf '%s\n' "$CURRENT_RELEASE" | grep -Eq "$TAG_PATTERN"; then
  CURRENT_DATE_PART=$(printf '%s\n' "$CURRENT_RELEASE" | cut -d '_' -f 2)
  CURRENT_DATE=$(printf '%s\n' "$CURRENT_DATE_PART" | awk '{ print "20" substr($0, 5, 2) substr($0, 3, 2) substr($0, 1, 2) }')
else
  CURRENT_DATE=$(printf '%s\n' "$BUILT_AT" | cut -c 1-10 | tr -d '-')
fi
printf '%s\n' "$LATEST_DATE" | grep -Eq '^[0-9]{8}$' || fail "could not parse the latest Release date"
printf '%s\n' "$CURRENT_DATE" | grep -Eq '^[0-9]{8}$' || fail "could not parse the installed build date"
if [ "$LATEST_DATE" -lt "$CURRENT_DATE" ]; then
  printf 'The matching Release is older than this image; refusing to offer a downgrade.\n'
  exit 0
fi

if [ "$MODE" = check ]; then
  printf 'An update is available. Run wsl-update to download it and choose an update method.\n'
  exit 0
fi

WINDOWS_ROOT=$(printenv SYSTEMROOT 2>/dev/null || printenv SystemRoot 2>/dev/null || true)
if [ -n "$WINDOWS_ROOT" ]; then
  WINDOWS_ROOT_WSL=$(wslpath -u "$WINDOWS_ROOT") || fail "could not translate the Windows system directory"
else
  WINDOWS_ROOT_WSL=/mnt/c/Windows
fi
CMD_EXE="$WINDOWS_ROOT_WSL/System32/cmd.exe"
WSL_EXE="$WINDOWS_ROOT_WSL/System32/wsl.exe"
[ -f "$CMD_EXE" ] || fail "could not find Windows cmd.exe"
[ -f "$WSL_EXE" ] || fail "could not find Windows wsl.exe"

windows_env() {
  WINDOWS_ENV_KEY=$1
  WINDOWS_ENV_VALUE=$("$CMD_EXE" /d /c "echo %$WINDOWS_ENV_KEY%" 2>/dev/null | tr -d '\r\000')
  case "$WINDOWS_ENV_VALUE" in
    ''|*"%$WINDOWS_ENV_KEY%"*) return 1 ;;
  esac
  printf '%s' "$WINDOWS_ENV_VALUE"
}

USERPROFILE_WIN=$(windows_env USERPROFILE) || fail "could not resolve the Windows user profile"
LOCALAPPDATA_WIN=$(windows_env LOCALAPPDATA) || fail "could not resolve Windows LocalAppData"
DOWNLOAD_DIR_WIN=$(printf '%s\\Documents\\myAlpine-wsl-updates\\%s' "$USERPROFILE_WIN" "$LATEST_TAG")
INSTALL_DIR_WIN=$(printf '%s\\AlpineWSL\\releases\\%s' "$LOCALAPPDATA_WIN" "$LATEST_TAG")
ARCHIVE_WIN=$(printf '%s\\%s' "$DOWNLOAD_DIR_WIN" "$ASSET_NAME")
DOWNLOAD_DIR=$(wslpath -u "$DOWNLOAD_DIR_WIN") || fail "could not translate the download directory"
mkdir -p "$DOWNLOAD_DIR"

ASSET_URL="https://github.com/$REPOSITORY/releases/download/$LATEST_TAG/$ASSET_NAME"
CHECKSUM_URL="https://github.com/$REPOSITORY/releases/download/$LATEST_TAG/$CHECKSUM_NAME"
ARCHIVE_TMP="$DOWNLOAD_DIR/$ASSET_NAME.part"
CHECKSUM_TMP="$DOWNLOAD_DIR/$CHECKSUM_NAME.part"
METADATA_TMP="$DOWNLOAD_DIR/build-info-$$.txt"

printf 'Downloading and verifying %s...\n' "$ASSET_NAME"
DOWNLOAD_STATUS=0
curl -fsSL --retry 3 -C - -o "$ARCHIVE_TMP" "$ASSET_URL" || DOWNLOAD_STATUS=$?
if [ "$DOWNLOAD_STATUS" -eq 33 ]; then
  rm -f "$ARCHIVE_TMP"
  curl -fsSL --retry 3 -o "$ARCHIVE_TMP" "$ASSET_URL" || fail "could not download the root filesystem"
elif [ "$DOWNLOAD_STATUS" -ne 0 ]; then
  fail "download interrupted; run wsl-update again to continue from the partial archive"
fi
curl -fsSL --retry 3 -o "$CHECKSUM_TMP" "$CHECKSUM_URL" || fail "could not download the SHA-256 file"
EXPECTED_SHA=$(awk 'NR == 1 { print $1; exit }' "$CHECKSUM_TMP")
printf '%s\n' "$EXPECTED_SHA" | grep -Eq '^[0-9a-f]{64}$' || fail "the Release SHA-256 file is invalid"
ACTUAL_SHA=$(sha256sum "$ARCHIVE_TMP" | awk '{ print $1 }')
if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
  rm -f "$ARCHIVE_TMP"
  fail "the downloaded archive did not match its SHA-256 file; the incomplete copy was removed, so run wsl-update again"
fi
case "$ASSET_DIGEST" in
  sha256:*)
    API_SHA=$(printf '%s\n' "$ASSET_DIGEST" | cut -d ':' -f 2)
    if [ "$API_SHA" != "$ACTUAL_SHA" ]; then
      rm -f "$ARCHIVE_TMP"
      fail "the downloaded archive did not match GitHub's asset digest; the copy was removed, so run wsl-update again"
    fi
    ;;
esac
tar -tzf "$ARCHIVE_TMP" >/dev/null 2>&1 || fail "the downloaded archive is not a valid gzip tar file"
tar -xOzf "$ARCHIVE_TMP" ./etc/alpine-wsl-build > "$METADATA_TMP" 2>/dev/null || fail "the archive does not contain Alpine build metadata"
grep -Fx "Release tag: $LATEST_TAG" "$METADATA_TMP" >/dev/null || fail "the archive metadata does not match the Release tag"
grep -Fx "Windows target: $WINDOWS_TARGET" "$METADATA_TMP" >/dev/null || fail "the archive targets a different Windows version"
EXPECTED_COMMIT=$(printf '%s\n' "$LATEST_TAG" | cut -d '_' -f 4)
SOURCE_COMMIT=$(sed -n 's/^Source commit: //p' "$METADATA_TMP")
case "$SOURCE_COMMIT" in
  "$EXPECTED_COMMIT"*) ;;
  *) fail "the archive source commit does not match the Release tag" ;;
esac
mv "$ARCHIVE_TMP" "$DOWNLOAD_DIR/$ASSET_NAME"
mv "$CHECKSUM_TMP" "$DOWNLOAD_DIR/$CHECKSUM_NAME"
rm -f "$METADATA_TMP"
printf 'Verified archive saved to: %s\n' "$ARCHIVE_WIN"

show_manual_steps() {
  printf '\nRun these commands in PowerShell to import the new distro and migrate from the current one:\n'
  printf '  wsl --import "%s" "%s" "%s" --version 2\n' "$LATEST_TAG" "$INSTALL_DIR_WIN" "$ARCHIVE_WIN"
  printf '  wsl -d "%s" -u root --exec /usr/local/bin/wsl-migrate "%s"\n' "$LATEST_TAG" "$CURRENT_DISTRO"
  printf '\nThe old distro remains registered. The migration script will show its overview and ask before changing data.\n'
}

case "$MODE" in
  manual)
    show_manual_steps
    exit 0
    ;;
  prompt)
    while :; do
      printf '\nChoose update method: [A] automatic import + migration, [M] manual PowerShell steps, [N] skip: '
      IFS= read -r ANSWER || ANSWER=n
      case "$ANSWER" in
        A|a) MODE=auto; break ;;
        M|m) MODE=manual; break ;;
        N|n|'') printf 'Update skipped. The verified archive remains available.\n'; exit 0 ;;
        *) printf 'Enter A, M, or N.\n' ;;
      esac
    done
    ;;
esac

if [ "$MODE" = manual ]; then
  show_manual_steps
  exit 0
fi

POWERSHELL_EXE="$WINDOWS_ROOT_WSL/System32/WindowsPowerShell/v1.0/powershell.exe"
[ -f "$POWERSHELL_EXE" ] || fail "could not find Windows PowerShell"

PS_HELPER="$DOWNLOAD_DIR/wsl-update.ps1"
PS_STATE="$DOWNLOAD_DIR/update-state.json"
tar -xOzf "$DOWNLOAD_DIR/$ASSET_NAME" ./usr/local/lib/wsl-update.ps1 > "$PS_HELPER" || fail "the archive does not contain the Windows update coordinator"
jq -n \
  --arg tag "$LATEST_TAG" \
  --arg sourceDistro "$CURRENT_DISTRO" \
  --arg installPath "$INSTALL_DIR_WIN" \
  --arg archivePath "$ARCHIVE_WIN" \
  --arg sha256 "$ACTUAL_SHA" \
  '{tag:$tag,sourceDistro:$sourceDistro,installPath:$installPath,archivePath:$archivePath,sha256:$sha256}' > "$PS_STATE"
PS_HELPER_WIN=$(wslpath -w "$PS_HELPER") || fail "could not translate the coordinator path"
PS_STATE_WIN=$(wslpath -w "$PS_STATE") || fail "could not translate the update state path"

printf '\nHanding the update to a separate PowerShell window. The source distro can now stop safely during migration.\n'
"$POWERSHELL_EXE" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$PS_HELPER_WIN" -StateFile "$PS_STATE_WIN" || fail "could not start the Windows update coordinator"
printf 'The coordinator will import %s, run migration, restart the new distro, and check its core commands.\n' "$LATEST_TAG"
