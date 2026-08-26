#!/bin/sh
set -eu
umask 077

SOURCE_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
DESTDIR=
destdir_seen=0

usage() { printf 'usage: %s [--destdir ABSOLUTE_PATH]\n' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case $1 in
    --destdir)
      [ "$destdir_seen" -eq 0 ] && [ "$#" -ge 2 ] || { usage; exit 2; }
      DESTDIR=$2
      destdir_seen=1
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done

case $DESTDIR in
  '') ;;
  /*) ;;
  *) printf 'destdir must be absolute\n' >&2; exit 2 ;;
esac

if [ "${V6PLUS_ALLOW_NONROOT:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  printf 'installer must run as root\n' >&2
  exit 1
fi

DEPLOY_ROOT=${DESTDIR}/data/unifi-jpix-tunnel-repair
UNIT_ROOT=${DESTDIR}/etc/systemd/system

secure_existing_dir() {
  secure_dir=$1
  [ -d "$secure_dir" ] && [ ! -L "$secure_dir" ] || return 1
  secure_physical=$(CDPATH= cd -- "$secure_dir" && pwd -P) || return 1
  [ "$secure_physical" = "$secure_dir" ] || return 1
  secure_mode=$(stat -c %a "$secure_dir") || return 1
  case $secure_mode in
    [0-7][0-7][0-7]) ;;
    *) return 1 ;;
  esac
  secure_group=${secure_mode#?}; secure_group=${secure_group%?}
  secure_other=${secure_mode#??}
  case $secure_group$secure_other in *[2367]*) return 1 ;; esac
  if [ "${V6PLUS_ALLOW_NONROOT:-0}" = 1 ]; then
    [ "$(stat -c %u "$secure_dir")" = "$(id -u)" ]
  else
    [ "$(stat -c %u "$secure_dir")" = 0 ]
  fi
}

secure_existing_chain() {
  chain_dir=$1
  if [ "${V6PLUS_ALLOW_NONROOT:-0}" = 1 ]; then
    secure_existing_dir "$chain_dir"
    return
  fi
  while :; do
    secure_existing_dir "$chain_dir" || return 1
    [ "$chain_dir" != / ] || break
    chain_parent=${chain_dir%/*}
    [ -n "$chain_parent" ] || chain_parent=/
    chain_dir=$chain_parent
  done
}

secure_existing_file() {
  secure_file=$1
  secure_expected_mode=$2
  [ -f "$secure_file" ] && [ ! -L "$secure_file" ] || return 1
  [ "$(stat -c %a "$secure_file")" = "$secure_expected_mode" ] || return 1
  if [ "${V6PLUS_ALLOW_NONROOT:-0}" = 1 ]; then
    [ "$(stat -c %u "$secure_file")" = "$(id -u)" ]
  else
    [ "$(stat -c %u "$secure_file")" = 0 ]
  fi
}

if [ -n "$DESTDIR" ]; then
  secure_existing_chain "$DESTDIR" || { printf 'unsafe destdir\n' >&2; exit 2; }
fi
for existing_parent in "${DESTDIR}/data" "${DESTDIR}/etc/systemd/system"; do
  secure_existing_chain "$existing_parent" || { printf 'unsafe installation parent\n' >&2; exit 2; }
done

for target in "$DEPLOY_ROOT" "$DEPLOY_ROOT/scripts" "$DEPLOY_ROOT/config" "$DEPLOY_ROOT/state" "$UNIT_ROOT"; do
  [ ! -L "$target" ] || { printf 'symlink installation target rejected\n' >&2; exit 2; }
  if [ -e "$target" ]; then
    secure_existing_chain "$target" || { printf 'unsafe existing installation directory\n' >&2; exit 2; }
  fi
done

install -d -m 755 "$DEPLOY_ROOT" "$DEPLOY_ROOT/scripts"
install -d -m 700 "$DEPLOY_ROOT/config" "$DEPLOY_ROOT/state"
for installed_dir in "$DEPLOY_ROOT" "$DEPLOY_ROOT/scripts" "$DEPLOY_ROOT/config" "$DEPLOY_ROOT/state"; do
  secure_existing_chain "$installed_dir" || { printf 'failed to establish secure installation directory\n' >&2; exit 2; }
done

for source in "$SOURCE_ROOT"/scripts/*.sh; do
  destination=$DEPLOY_ROOT/scripts/${source##*/}
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    secure_existing_file "$destination" 755 || { printf 'unsafe existing script destination\n' >&2; exit 2; }
  fi
  install -m 755 "$source" "$destination"
  secure_existing_file "$destination" 755 || { printf 'failed to secure installed script\n' >&2; exit 2; }
done

for source in "$SOURCE_ROOT"/config/*.example; do
  destination=$DEPLOY_ROOT/config/${source##*/}
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    secure_existing_file "$destination" 600 || { printf 'unsafe existing config destination\n' >&2; exit 2; }
  fi
  install -m 600 "$source" "$destination"
  secure_existing_file "$destination" 600 || { printf 'failed to secure installed config example\n' >&2; exit 2; }
done

platform_matrix=$SOURCE_ROOT/config/verified-platforms.conf
platform_destination=$DEPLOY_ROOT/config/verified-platforms.conf
if [ -e "$platform_destination" ] || [ -L "$platform_destination" ]; then
  secure_existing_file "$platform_destination" 600 || { printf 'unsafe existing platform matrix destination\n' >&2; exit 2; }
fi
install -m 600 "$platform_matrix" "$platform_destination"
secure_existing_file "$platform_destination" 600 || { printf 'failed to secure installed platform matrix\n' >&2; exit 2; }

for source in "$SOURCE_ROOT"/systemd/*; do
  destination=$UNIT_ROOT/${source##*/}
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    secure_existing_file "$destination" 644 || { printf 'unsafe existing unit destination\n' >&2; exit 2; }
  fi
  install -m 644 "$source" "$destination"
  secure_existing_file "$destination" 644 || { printf 'failed to secure installed unit\n' >&2; exit 2; }
done

printf 'installation complete; runtime state was not changed\n'
