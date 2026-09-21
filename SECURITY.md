# Security Policy

## Supported versions

Security fixes target the latest commit on the `main` branch. Older commits, forks, and modified deployment trees may not receive fixes. This is an experimental integration, not a supported appliance firmware. An unfamiliar UniFi version is not rejected solely by its version string; operations require recognized capabilities and ownership boundaries.

## Security properties

Changes to this project must preserve these design requirements:

- keep credentials and deployment-specific identifiers out of Git, stdout, logs, Issues, and test artifacts;
- parse configuration and state as data instead of sourcing them as shell code;
- read privileged configuration only from root-owned, non-symlink files with restrictive permissions;
- execute installed code only from a root-owned deployment tree that non-root users cannot modify;
- fail closed before mutation when configuration, ownership, current state, or reserved ranges are unsafe;
- attempt to reverse invocation-owned mutations after apply failures or handled signals;
- modify and remove only state whose ownership can be proven;
- use encrypted provider transport by default;
- keep status and reason-code payloads minimal, and document outputs requiring redaction;
- collect raw diagnostics only with explicit operator intent and keep them in private storage.

## Implemented boundaries and limits

Configuration, credential, and state readers reject symlinks and group/other permissions; when run as root, they require root ownership. The deployment tree and source used by the installer must also be trusted and protected by the operator. Do not treat checksum validation as proof of source authenticity.

Provider transport uses HTTPS unless HTTP is explicitly authorized for the exact configured hostname. HTTP exposes credentials in transit. Webhook URLs can themselves contain secrets and must remain private, even though webhook payloads omit addresses and credentials.

Discovery without a configuration prints real interface names and firmware metadata. Status and doctor can include version or timing information. Review all output before public sharing. Config, runtime state, migration records, raw system logs, and provider responses are not share-safe artifacts. There is no public full-diagnostics export command.

The transaction journal contains progress and reason codes, not a durable inverse-operation log. Rollback is attempted for ordinary failures and SIGINT/SIGTERM; recovery after SIGKILL or power loss is not guaranteed. Quarantine does not permanently disable future reconciles. Installed bootstrap loss, unverified previous releases, and partial release failures require operator checks. See [rollback](docs/rollback.md) and [architecture](docs/architecture.md) for the exact boundaries.

Signed upgrades require a separately trusted public key. Source installs do not authenticate that source using a release signature. Never enroll a key obtained solely from the same untrusted location as an archive and assume the signature establishes trust.

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

- compatibility failures on unrecognized capabilities without a security-boundary impact
- upstream ISP, JPIX, provider, ONU, or firmware behavior outside this repository
- availability issues requiring already-authorized root access without crossing another security boundary
- requests to support services or mechanisms outside the documented service boundary

Operational failures can still be reported as share-safe regular Issues when they are not vulnerabilities.
