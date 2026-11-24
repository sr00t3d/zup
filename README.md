# zup — ZoneUPdater: Safe BIND DNS Zone Batch Updater (`v2.0.0`)

A modern, standalone Bash + Python 3 CLI for safely batch-updating **BIND DNS zone files** (`/var/named/*.db`) across single domains, cPanel users, or entire resellers — replacing legacy 4,217-line Perl `zup` (2012) with automatic `chmod 600` backups, automatic `named-checkzone` rollback, `YYYYMMDDnn` serial bumping, and structured `table` / `json` / `csv` outputs.

## Features

- **Zero Legacy Dependencies**: Replaces Perl `ZUP::RCS`, `/home/hgtransfer/zup-backups`, dead HostGator URLs, and shell-interpolated `tar`/`rndc` calls with pure Python 3.6+ stdlib.
- **Automatic Backup & Rollback**: Every edit writes a `chmod 600` timestamped backup (`--backup-dir`), validates with `named-checkzone` (if installed), and supports instant `--restore <domain>`.
- **Comprehensive Record Updates**: SOA (`--set-soa-ns`, `--set-soa-email`, `-s/--bump-serial`), `--set-ns`, `--set-mx`, `--set-a`, `--replace-ip OLD:NEW`, `--set-cname`, `--set-spf`, and `--set-dkim`.
- **Modern Mail Presets**: `--google-workspace` and `--microsoft365`.
- **Dry-Run & Multi-Format Output**: `--dry-run`, `--reload` (`rndc reload`), and `-o table|json|csv`.

## Usage

```bash
./zup.sh -d example.com [OPTIONS]
```

## Real Output Example

```text
$ ./zup.sh -d example.com --zone-dir /tmp/zup-e2e/named --backup-dir /tmp/zup-e2e/backups --replace-ip 192.0.2.10:198.51.100.25 --google-workspace --no-color
=== zup.sh v2.0.0 | DNS Zone Batch Update Report ===
STATUS       DOMAIN                       SERIAL                  ACTIONS
----------------------------------------------------------------------------------------
OK           example.com                  2026112001->2026112401  preset_google_workspace, replace_ip(192.0.2.10->198.51.100.25 x2)
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
