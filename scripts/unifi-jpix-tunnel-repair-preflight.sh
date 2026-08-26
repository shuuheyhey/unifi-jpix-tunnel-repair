#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

PROJECT_ROOT=${PREFLIGHT_PROJECT_ROOT:-/data/unifi-jpix-tunnel-repair}
VERSION_FILE=${PREFLIGHT_VERSION_FILE:-/usr/lib/version}

if [ "$#" -ne 0 ]; then
  printf 'usage: %s\n' "${0##*/}" >&2
  printf 'PREFLIGHT_MODE=share-safe\n'
  printf 'RESULT=invalid\n'
  exit 2
fi

readiness=0

dependency_state() {
  if command -v "$1" >/dev/null 2>&1; then
    printf 'present\n'
  else
    printf 'missing\n'
  fi
}

dependency_ip=$(dependency_state ip)
dependency_iptables=$(dependency_state iptables)
dependency_ip6tables=$(dependency_state ip6tables)
dependency_curl=$(dependency_state curl)
dependency_systemctl=$(dependency_state systemctl)
case $dependency_ip:$dependency_iptables:$dependency_ip6tables:$dependency_curl:$dependency_systemctl in
  *missing*) readiness=1 ;;
esac

root_privilege=no
if [ "$(id -u 2>/dev/null || printf unknown)" = 0 ]; then
  root_privilege=yes
else
  readiness=1
fi

unifi_os_candidate=
if command -v ubnt-device-info >/dev/null 2>&1; then
  unifi_os_candidate=$(ubnt-device-info firmware 2>/dev/null | awk 'NR == 1 { print; exit }' || :)
fi
if [ -z "$unifi_os_candidate" ] && [ -r "$VERSION_FILE" ]; then
  IFS= read -r unifi_os_candidate <"$VERSION_FILE" || :
fi
case $unifi_os_candidate in
  5.*) unifi_os_compatibility=target ;;
  '') unifi_os_compatibility=unknown; readiness=1 ;;
  *) unifi_os_compatibility=outside-target; readiness=1 ;;
esac

unifi_network_package=absent
if command -v dpkg-query >/dev/null 2>&1 &&
   dpkg-query -W -f='${Status}\n' unifi >/dev/null 2>&1; then
  unifi_network_package=present
else
  readiness=1
fi

ipv6_default_route=absent
ipv6_global_address=absent
dhcpv6_pd_route=absent
tunnel_candidate_count=0
tunnel_ready_count=0
if [ "$dependency_ip" = present ]; then
  if ip -6 route show default 2>/dev/null | awk 'NF { found = 1 } END { exit !found }'; then
    ipv6_default_route=present
  else
    readiness=1
  fi

  if ip -6 addr show scope global 2>/dev/null | awk '/inet6 / { found = 1 } END { exit !found }'; then
    ipv6_global_address=present
  else
    readiness=1
  fi

  if {
    ip -6 route show table all proto dhcp 2>/dev/null || :
    ip -6 route show table all proto ra 2>/dev/null || :
  } | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i !~ /\//) continue
        split($i, prefix, "/")
        if (prefix[2] ~ /^[0-9]+$/ && prefix[2] >= 48 && prefix[2] <= 63) found = 1
      }
    }
    END { exit !found }
  '; then
    dhcpv6_pd_route=present
  else
    readiness=1
  fi

  tunnel_summary=$(ip -d -6 tunnel show 2>/dev/null | awk '
    BEGIN { candidates = 0; ready = 0 }
    {
      mode = $2
      if (mode != "ipip6" && mode != "ip/ipv6" && mode != "any/ipv6") next
      candidates++
      remote = ""
      local = ""
      for (i = 1; i < NF; i++) {
        if ($i == "remote") remote = $(i + 1)
        if ($i == "local") local = $(i + 1)
      }
      if ((mode == "ipip6" || mode == "ip/ipv6") &&
          remote != "" && remote != "any" && local != "" && local != "any") ready++
    }
    END { print candidates " " ready }
  ' || printf '0 0\n')
  tunnel_candidate_count=${tunnel_summary%% *}
  tunnel_ready_count=${tunnel_summary#* }
  case $tunnel_candidate_count:$tunnel_ready_count in
    *[!0-9:]*|'':*) tunnel_candidate_count=0; tunnel_ready_count=0; readiness=1 ;;
  esac
  [ "$tunnel_ready_count" -gt 0 ] || readiness=1
fi

unifi_nat_user_chain=absent
if [ "$dependency_iptables" = present ] &&
   iptables -t nat -S UBIOS_POSTROUTING_USER_HOOK >/dev/null 2>&1; then
  unifi_nat_user_chain=present
else
  readiness=1
fi

unifi_ipv6_input_user_chain=absent
if [ "$dependency_ip6tables" = present ] &&
   ip6tables -S UBIOS_INPUT_USER_HOOK >/dev/null 2>&1; then
  unifi_ipv6_input_user_chain=present
else
  readiness=1
fi

project_installation=absent
[ ! -d "$PROJECT_ROOT" ] || project_installation=present

if [ "$readiness" -eq 0 ]; then
  result=ready-for-config
else
  result=needs-attention
fi

printf 'PREFLIGHT_MODE=share-safe\n'
printf 'ROOT_PRIVILEGE=%s\n' "$root_privilege"
printf 'DEPENDENCY_ip=%s\n' "$dependency_ip"
printf 'DEPENDENCY_iptables=%s\n' "$dependency_iptables"
printf 'DEPENDENCY_ip6tables=%s\n' "$dependency_ip6tables"
printf 'DEPENDENCY_curl=%s\n' "$dependency_curl"
printf 'DEPENDENCY_systemctl=%s\n' "$dependency_systemctl"
printf 'UNIFI_OS_COMPATIBILITY=%s\n' "$unifi_os_compatibility"
printf 'UNIFI_NETWORK_PACKAGE=%s\n' "$unifi_network_package"
printf 'IPV6_DEFAULT_ROUTE=%s\n' "$ipv6_default_route"
printf 'IPV6_GLOBAL_ADDRESS=%s\n' "$ipv6_global_address"
printf 'DHCPV6_PD_ROUTE=%s\n' "$dhcpv6_pd_route"
printf 'IPIP6_TUNNEL_CANDIDATE_COUNT=%s\n' "$tunnel_candidate_count"
printf 'IPIP6_TUNNEL_READY_COUNT=%s\n' "$tunnel_ready_count"
printf 'UNIFI_NAT_USER_CHAIN=%s\n' "$unifi_nat_user_chain"
printf 'UNIFI_IPV6_INPUT_USER_CHAIN=%s\n' "$unifi_ipv6_input_user_chain"
printf 'PROJECT_INSTALLATION=%s\n' "$project_installation"
printf 'RESULT=%s\n' "$result"
exit "$readiness"
