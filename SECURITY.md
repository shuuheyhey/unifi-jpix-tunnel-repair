# Security Policy

## Supported versions

Security updates are provided for the latest release on the `main` branch.

## Security properties

This project must:
- keep credentials and deployment-specific identifiers out of Git;
- read privileged configuration only from root-owned, non-symlink files with restrictive permissions;
- execute installed code only from a root-owned, non-writable deployment tree;
- use encrypted provider transport by default;
- produce share-safe diagnostics by default.

## Reporting a vulnerability

Please use GitHub Private Vulnerability Reporting:
https://github.com/shuuheyhey/unifi-japan-v6plus-fixed-ip/security/advisories/new

Do not include real credentials, public IP addresses, device identifiers, or unredacted diagnostics. Use synthetic values and the smallest reproducible example.

## Scope

Reports about authentication data exposure, command execution, privilege-boundary bypasses, unsafe file handling, firewall or route safety, and sensitive diagnostic disclosure are in scope.

Unsupported UniFi OS versions, upstream ISP/provider behavior, and issues requiring already-authorized root access without crossing another security boundary are generally out of scope.
