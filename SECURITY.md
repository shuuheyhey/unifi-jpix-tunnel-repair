# Security Policy

## Supported versions

Security updates are provided for the latest commit on the `main` branch. Older commits, forks, modified deployment trees, and unsupported UniFi OS versions may not receive fixes.

## Security properties

This project must:

- keep credentials and deployment-specific identifiers out of Git, stdout, logs, Issues, and test artifacts;
- parse configuration and state as data instead of sourcing them as shell code;
- read privileged configuration only from root-owned, non-symlink files with restrictive permissions;
- execute installed code only from a root-owned deployment tree that non-root users cannot modify;
- fail closed before mutation when configuration, ownership, current state, or reserved ranges are unsafe;
- roll back invocation-owned mutations after apply failures or signals;
- modify and remove only state whose ownership can be proven;
- use encrypted provider transport by default;
- produce share-safe preflight and diagnostic stdout by default;
- write full diagnostics only to a new private file explicitly requested by the operator.

## Secret handling

Do not paste API keys, passwords, provider credentials, assigned addresses, config files, state files, full diagnostics, or raw provider responses into an Issue or chat. A secret pasted into a transcript or command log must be treated as compromised and rotated.

Synthetic values must be used in bug reproductions and tests.

## Reporting a vulnerability

Use GitHub Private Vulnerability Reporting:

https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/security/advisories/new

Include the smallest safe reproduction and omit real deployment identifiers. Do not create a public Issue for a vulnerability.

## In scope

- credential or diagnostic disclosure
- command execution or parser injection
- privilege-boundary bypass
- unsafe owner, mode, symlink, canonical-path, or temporary-file handling
- unintended route, policy rule, tunnel, or netfilter modification
- rollback that removes unrelated state or fails open
- provider transport downgrade or unsafe response handling

## Generally out of scope

- unsupported UniFi OS versions without a security-boundary impact
- upstream ISP, JPIX, provider, ONU, or firmware behavior outside this repository
- availability issues requiring already-authorized root access without crossing another security boundary
- requests to support independent replacement tunnels that bypass the UniFi-managed-tunnel design

Operational failures can still be reported as share-safe regular Issues when they are not vulnerabilities.
