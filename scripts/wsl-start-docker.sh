#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run wsl-start-docker with sudo" >&2
  exit 1
fi

# WSL's init does not perform the normal OpenRC boot sequence.
mkdir -p /run/openrc
if [ ! -e /run/openrc/softlevel ]; then
  printf 'default\n' > /run/openrc/softlevel
fi

exec /sbin/rc-service --ifnotstarted docker start
