"""Route project IPv4 traffic through existing UniFi WAN policy chains.

This adapter owns only tagged interface dispatch rules, never the WAN policy
contents. It accepts the observed legacy, interface-based chain graph only.
"""
import re
import shlex

from .core import FIREWALL_TAG, ForeignConflict, PrerequisiteUnavailable

CAPABILITY_VERSION = 2
DNS_CHAIN = 'UBIOS_DNS_PBR_JUMP'

DISPATCH = (
    ('UBIOS_FORWARD_IN_USER', '-i', 'UBIOS_WAN_IN_USER'),
    ('UBIOS_FORWARD_OUT_USER', '-o', 'UBIOS_WAN_OUT_USER'),
    ('UBIOS_INPUT_USER_HOOK', '-i', 'UBIOS_WAN_LOCAL_USER'),
)
GRAPH = {
    'INPUT': ['UBIOS_INPUT_JUMP'],
    'FORWARD': ['UBIOS_FORWARD_JUMP'],
    'UBIOS_INPUT_JUMP': ['UBIOS_DNS_PBR_JUMP', 'UBIOS_INPUT_USER_HOOK'],
    'UBIOS_FORWARD_JUMP': ['UBIOS_FORWARD_USER_HOOK'],
    'UBIOS_FORWARD_USER_HOOK': ['UBIOS_FORWARD_IN_USER', 'UBIOS_FORWARD_OUT_USER'],
}


def rules(tunnel):
    return [(DNS_CHAIN, ('-i', tunnel, '-m', 'comment', '--comment', FIREWALL_TAG, '-j', 'RETURN')),
            *[(chain, (direction, tunnel, '-m', 'comment', '--comment',
                     FIREWALL_TAG, '-j', destination))
              for chain, direction, destination in DISPATCH]]


def _without_comment(tokens):
    values = list(tokens)
    while '-m' in values:
        index = values.index('-m')
        if values[index:index + 3] != ['-m', 'comment', '--comment'] or len(values) <= index + 3:
            break
        del values[index:index + 4]
    return values


def validate(runner, native, tunnel):
    result = runner.run(['iptables', '-w', '5', '-S'], check=False)
    if result.returncode or not result.stdout.strip():
        raise PrerequisiteUnavailable('WAN policy inventory unavailable')
    chains = {}
    try:
        for line in result.stdout.splitlines():
            tokens = shlex.split(line)
            if tokens[:1] in (['-N'], ['-P']):
                chains.setdefault(tokens[1], [])
            elif tokens[:1] == ['-A']:
                chains.setdefault(tokens[1], []).append(tokens[2:])
        for chain, destinations in GRAPH.items():
            # Reject an earlier ACCEPT/RETURN, extra jump, or changed order.
            if [_without_comment(row) for row in chains[chain]] != [['-j', d] for d in destinations]:
                raise ValueError
        # Internal DNS redirect rules precede WAN_LOCAL policy. Mirror the
        # native WAN's early RETURN, so jpix0 cannot take that internal bypass.
        dns_rows = chains[DNS_CHAIN]
        expected_dns = list(dict(rules(tunnel))[DNS_CHAIN])
        while dns_rows and dns_rows[0] == expected_dns:
            dns_rows = dns_rows[1:]
        if not dns_rows or dns_rows[0] != ['-i', native, '-j', 'RETURN']:
            raise ValueError
        if any(tunnel in row for row in dns_rows):
            raise ValueError
        for chain, direction, destination in DISPATCH:
            if destination not in chains or not chains[destination]:
                raise ValueError
            native_count = 0
            for row in chains[chain]:
                normalized = _without_comment(row)
                if len(normalized) != 4 or normalized[0] != direction or normalized[2] != '-j':
                    raise ValueError
                if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', normalized[1]):
                    raise ValueError
                if normalized[3] not in {destination, destination.replace('WAN', 'LAN')}:
                    raise ValueError
                if normalized[1] == native:
                    native_count += 1
                    if normalized[3] != destination:
                        raise ValueError
                if normalized[1] == tunnel:
                    # Foreign rules for our interface are not silently adopted.
                    expected = dict(rules(tunnel))[chain]
                    if tuple(row) != expected:
                        raise ValueError
            if native_count != 1:
                raise ValueError
    except (KeyError, IndexError, ValueError) as exc:
        raise ForeignConflict('UniFi WAN policy graph is unsupported') from exc
    return rules(tunnel)
