#!/usr/bin/env bash
# ==============================================================================
# zup.sh — ZoneUPdater: Safe BIND DNS Zone Batch Updater CLI (v2.0.0)
# Modernized clean-room implementation inspired by legacy zup (2012).
# Copyright (c) 2026 Percio Castelo — Apache-2.0 License
# ==============================================================================
set -euo pipefail

VERSION="2.0.0"

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required (3.6+)." >&2
    exit 1
fi

read -r -d '' PY_SCRIPT << 'EOF' || true
import argparse
import csv
import datetime
import glob
import io
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys

VERSION = "2.0.0"


class Colors:
    def __init__(self, enabled=True):
        self.RESET = "\033[0m" if enabled else ""
        self.BOLD = "\033[1m" if enabled else ""
        self.CYAN = "\033[36m" if enabled else ""
        self.GREEN = "\033[32m" if enabled else ""
        self.YELLOW = "\033[33m" if enabled else ""
        self.RED = "\033[31m" if enabled else ""
        self.DIM = "\033[2m" if enabled else ""


def ensure_dot(name):
    name = name.strip()
    if name and not name.endswith("."):
        return name + "."
    return name


def valid_ip(ip_str):
    try:
        ipaddress.ip_address(ip_str)
        return True
    except ValueError:
        return False


def get_domains_for_users(users, etc_root):
    domains = []
    ud_file = os.path.join(etc_root, "userdomains")
    if not os.path.isfile(ud_file):
        return domains
    target_set = set(users)
    try:
        with open(ud_file, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if ":" not in line:
                    continue
                dom, usr = line.split(":", 1)
                if usr.strip() in target_set:
                    domains.append(dom.strip())
    except OSError:
        pass
    return domains


def get_reseller_users(reseller, etc_root):
    users = []
    fpath = os.path.join(etc_root, "trueuserowners")
    if not os.path.isfile(fpath):
        return users
    try:
        with open(fpath, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if ":" in line:
                    u, owner = line.split(":", 1)
                    if owner.strip() == reseller:
                        users.append(u.strip())
    except OSError:
        pass
    return users


def bump_soa_serial(lines):
    today_prefix = datetime.datetime.now().strftime("%Y%m%d")
    new_lines = list(lines)
    old_serial = None
    new_serial = None

    soa_idx = None
    for i, line in enumerate(new_lines):
        if re.search(r"\bIN\s+SOA\b", line):
            soa_idx = i
            break

    if soa_idx is None:
        return new_lines, old_serial, new_serial

    # Single-line or multi-line SOA
    for j in range(soa_idx, min(soa_idx + 8, len(new_lines))):
        m = re.search(r"(\b\d{10}\b)", new_lines[j])
        if m:
            old_serial = m.group(1)
            if old_serial.startswith(today_prefix):
                seq = int(old_serial[8:]) + 1
                new_serial = f"{today_prefix}{seq:02d}"
            else:
                cand = int(f"{today_prefix}01")
                old_int = int(old_serial)
                new_serial = str(cand if cand > old_int else old_int + 1)
            new_lines[j] = new_lines[j][:m.start(1)] + new_serial + new_lines[j][m.end(1):]
            break
    return new_lines, old_serial, new_serial


def update_soa_field(lines, ns=None, email=None):
    new_lines = list(lines)
    for i, line in enumerate(new_lines):
        m = re.match(r"^(\s*\S+\s+(?:\d+\s+)?(?:IN\s+)?SOA\s+)(\S+)(\s+)(\S+)(.*)$", line)
        if m:
            cur_ns = ensure_dot(ns) if ns else m.group(2)
            cur_email = m.group(4)
            if email:
                em = email.strip()
                if "@" in em:
                    local, dom = em.split("@", 1)
                    em = f"{local.replace('.', r'\.')}.{dom}"
                cur_email = ensure_dot(em)
            new_lines[i] = f"{m.group(1)}{cur_ns}{m.group(3)}{cur_email}{m.group(5)}\n"
            break
    return new_lines


def replace_record_type(lines, rtype, new_records):
    """Removes existing records of rtype (e.g., NS or MX at apex) and inserts new_records."""
    out = []
    inserted = False
    rx = re.compile(rf"^\s*(?:@|\S+\.)?\s+(?:\d+\s+)?IN\s+{rtype}\b", re.IGNORECASE)
    for line in lines:
        if rx.match(line):
            if not inserted:
                out.extend(new_records)
                inserted = True
            continue
        out.append(line)
    if not inserted:
        out.extend(new_records)
    return out


def upsert_named_record(lines, name, rtype, value, ttl="14400"):
    out = []
    updated = False
    esc_name = re.escape(name)
    rx = re.compile(rf"^{esc_name}\s+(?:\d+\s+)?IN\s+{rtype}\b", re.IGNORECASE)
    new_line = f"{name}\t{ttl}\tIN\t{rtype}\t{value}\n"
    for line in lines:
        if rx.match(line):
            if not updated:
                out.append(new_line)
                updated = True
            continue
        out.append(line)
    if not updated:
        out.append(new_line)
    return out


def replace_ip_in_a_records(lines, old_ip, new_ip):
    out = []
    count = 0
    rx = re.compile(rf"^(\s*\S+\s+(?:\d+\s+)?IN\s+A\s+){re.escape(old_ip)}(\s*(?:;.*)?)$", re.IGNORECASE)
    for line in lines:
        m = rx.match(line.rstrip("\r\n"))
        if m:
            out.append(f"{m.group(1)}{new_ip}{m.group(2)}\n")
            count += 1
        else:
            out.append(line)
    return out, count


def backup_zone(zone_file, domain, backup_dir):
    os.makedirs(backup_dir, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    bpath = os.path.join(backup_dir, f"{domain}.{ts}.db.bak")
    shutil.copy2(zone_file, bpath)
    os.chmod(bpath, 0o600)
    return bpath


def restore_latest_backup(domain, zone_dir, backup_dir):
    pattern = os.path.join(backup_dir, f"{domain}.*.db.bak")
    matches = sorted(glob.glob(pattern))
    if not matches:
        return None, f"No backups found for {domain} in {backup_dir}"
    latest = matches[-1]
    dest = os.path.join(zone_dir, f"{domain}.db")
    shutil.copy2(latest, dest)
    return latest, None


def validate_zone_file(domain, zone_file):
    checker = shutil.which("named-checkzone")
    if not checker:
        return True, "named-checkzone not installed (skipped)"
    res = subprocess.run(
        [checker, domain, zone_file],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=10,
    )
    return res.returncode == 0, res.stdout.strip()


def reload_zone(domain):
    rndc = shutil.which("rndc")
    if not rndc:
        return False, "rndc not installed"
    res = subprocess.run(
        [rndc, "reload", domain],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=10,
    )
    return res.returncode == 0, res.stdout.strip()


def process_domain(domain, args):
    zone_file = os.path.join(args.zone_dir, f"{domain}.db")
    result = {
        "domain": domain,
        "zone_file": zone_file,
        "status": "OK",
        "actions": [],
        "backup": "",
        "serial": "",
        "error": "",
    }

    if not os.path.isfile(zone_file):
        result["status"] = "ERROR"
        result["error"] = f"Zone file not found: {zone_file}"
        return result

    with open(zone_file, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()

    modified = False

    if args.set_soa_ns or args.set_soa_email:
        lines = update_soa_field(lines, ns=args.set_soa_ns, email=args.set_soa_email)
        result["actions"].append("update_soa")
        modified = True

    if args.set_ns:
        ns_list = [ensure_dot(x) for x in args.set_ns.split(",") if x.strip()]
        ns_lines = [f"{domain}.\t86400\tIN\tNS\t{ns}\n" for ns in ns_list]
        lines = replace_record_type(lines, "NS", ns_lines)
        result["actions"].append(f"set_ns({len(ns_list)})")
        modified = True

    mx_entries = []
    if args.google_workspace:
        mx_entries = [
            ("1", "ASPMX.L.GOOGLE.COM."),
            ("5", "ALT1.ASPMX.L.GOOGLE.COM."),
            ("5", "ALT2.ASPMX.L.GOOGLE.COM."),
            ("10", "ALT3.ASPMX.L.GOOGLE.COM."),
            ("10", "ALT4.ASPMX.L.GOOGLE.COM."),
        ]
        result["actions"].append("preset_google_workspace")
    elif args.microsoft365:
        slug = domain.replace(".", "-")
        mx_entries = [("0", f"{slug}.mail.protection.outlook.com.")]
        result["actions"].append("preset_microsoft365")
    elif args.set_mx:
        for item in args.set_mx.split(","):
            if ":" in item:
                prio, host = item.split(":", 1)
                mx_entries.append((prio.strip(), ensure_dot(host.strip())))
        result["actions"].append(f"set_mx({len(mx_entries)})")

    if mx_entries:
        mx_lines = [f"{domain}.\t14400\tIN\tMX\t{prio}\t{host}\n" for prio, host in mx_entries]
        lines = replace_record_type(lines, "MX", mx_lines)
        modified = True

    if args.set_a:
        for item in args.set_a.split(","):
            if ":" in item:
                name, ip = item.split(":", 1)
                name, ip = name.strip(), ip.strip()
                if not valid_ip(ip):
                    result["status"] = "ERROR"
                    result["error"] = f"Invalid IP in --set-a: {ip}"
                    return result
                lines = upsert_named_record(lines, name, "A", ip)
                result["actions"].append(f"set_a({name}={ip})")
                modified = True

    if args.replace_ip:
        if ":" not in args.replace_ip:
            result["status"] = "ERROR"
            result["error"] = "--replace-ip must be OLD_IP:NEW_IP"
            return result
        old_ip, new_ip = [x.strip() for x in args.replace_ip.split(":", 1)]
        if not (valid_ip(old_ip) and valid_ip(new_ip)):
            result["status"] = "ERROR"
            result["error"] = f"Invalid IP in --replace-ip: {old_ip} -> {new_ip}"
            return result
        lines, cnt = replace_ip_in_a_records(lines, old_ip, new_ip)
        result["actions"].append(f"replace_ip({old_ip}->{new_ip} x{cnt})")
        if cnt > 0:
            modified = True

    if args.set_cname:
        for item in args.set_cname.split(","):
            if ":" in item:
                name, target = [x.strip() for x in item.split(":", 1)]
                lines = upsert_named_record(lines, name, "CNAME", ensure_dot(target))
                result["actions"].append(f"set_cname({name})")
                modified = True

    if args.set_spf:
        spf_val = args.set_spf.strip().strip('"')
        lines = upsert_named_record(lines, f"{domain}.", "TXT", f'"{spf_val}"')
        result["actions"].append("set_spf")
        modified = True

    if args.set_dkim:
        if ":" not in args.set_dkim:
            result["status"] = "ERROR"
            result["error"] = "--set-dkim must be SELECTOR:VALUE"
            return result
        sel, val = [x.strip() for x in args.set_dkim.split(":", 1)]
        lines = upsert_named_record(lines, f"{sel}._domainkey", "TXT", f'"{val.strip(chr(34))}"')
        result["actions"].append(f"set_dkim({sel})")
        modified = True

    if args.bump_serial or modified:
        lines, old_s, new_s = bump_soa_serial(lines)
        if new_s:
            result["serial"] = f"{old_s}->{new_s}"
            if args.bump_serial and "bump_serial" not in result["actions"]:
                result["actions"].append("bump_serial")
            modified = True

    if args.dry_run:
        result["status"] = "DRY_RUN"
        return result

    if modified:
        bpath = backup_zone(zone_file, domain, args.backup_dir)
        result["backup"] = bpath
        with open(zone_file, "w", encoding="utf-8") as fh:
            fh.writelines(lines)
        ok, msg = validate_zone_file(domain, zone_file)
        if not ok:
            shutil.copy2(bpath, zone_file)
            result["status"] = "ROLLED_BACK"
            result["error"] = f"named-checkzone failed: {msg}"
            return result
        if args.reload:
            rok, rmsg = reload_zone(domain)
            result["actions"].append("rndc_reload:ok" if rok else f"rndc_reload:warn({rmsg})")

    return result


def render_table(results, c):
    print(f"{c.BOLD}{c.CYAN}=== zup.sh v{VERSION} | DNS Zone Batch Update Report ==={c.RESET}")
    if not results:
        print("  No domains processed.")
        return
    print(f"{c.BOLD}{'STATUS':<12} {'DOMAIN':<28} {'SERIAL':<23} ACTIONS{c.RESET}")
    print("-" * 88)
    for r in results:
        st = r["status"]
        if st == "OK":
            sc = f"{c.GREEN}{st:<12}{c.RESET}"
        elif st == "DRY_RUN":
            sc = f"{c.YELLOW}{st:<12}{c.RESET}"
        else:
            sc = f"{c.RED}{st:<12}{c.RESET}"
        acts = ", ".join(r["actions"]) if r["actions"] else r.get("error", "-")
        print(f"{sc} {r['domain']:<28} {r['serial'] or '-':<23} {acts}")
        if r.get("error") and r["actions"]:
            print(f"  {c.RED}Error:{c.RESET} {r['error']}")


def render_csv(results):
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(["status", "domain", "serial", "actions", "backup", "error"])
    for r in results:
        writer.writerow([
            r["status"], r["domain"], r["serial"],
            ";".join(r["actions"]), r["backup"], r["error"],
        ])
    sys.stdout.write(buf.getvalue())


def main():
    parser = argparse.ArgumentParser(
        prog="zup.sh",
        description="ZoneUPdater — Safe BIND DNS Zone Batch Updater CLI (v2.0.0)",
    )
    parser.add_argument("-d", "--domain", help="Comma-separated domains to update")
    parser.add_argument("-dl", "--domain-list", help="File with one domain per line")
    parser.add_argument("-u", "--user", help="Comma-separated cPanel usernames")
    parser.add_argument("-ul", "--user-list", help="File with one username per line")
    parser.add_argument("-r", "--reseller", help="Reseller username (/etc/trueuserowners)")
    parser.add_argument("--restore", help="Restore latest chmod 600 backup for domain")

    parser.add_argument("-s", "--bump-serial", action="store_true", help="Bump SOA serial (YYYYMMDDnn)")
    parser.add_argument("--set-soa-ns", help="Set SOA primary nameserver")
    parser.add_argument("--set-soa-email", help="Set SOA admin email")
    parser.add_argument("--set-ns", help="Comma-separated NS records")
    parser.add_argument("--set-mx", help="Comma-separated PRIO:HOST MX records")
    parser.add_argument("--set-a", help="Comma-separated NAME:IP A records")
    parser.add_argument("--replace-ip", help="Replace IP in A records (OLD_IP:NEW_IP)")
    parser.add_argument("--set-cname", help="Comma-separated NAME:TARGET CNAME records")
    parser.add_argument("--set-spf", help="Set root SPF TXT record")
    parser.add_argument("--set-dkim", help="Set DKIM TXT record (SELECTOR:VALUE)")
    parser.add_argument("--google-workspace", action="store_true", help="Apply Google Workspace MX preset")
    parser.add_argument("--microsoft365", action="store_true", help="Apply Microsoft 365 MX preset")

    parser.add_argument("--reload", action="store_true", help="Run rndc reload after update")
    parser.add_argument("--dry-run", action="store_true", help="Preview updates without writing files")
    parser.add_argument("--zone-dir", default="/var/named", help="BIND zone directory (default: /var/named)")
    parser.add_argument("--etc-root", default="/etc", help="Custom /etc root (default: /etc)")
    parser.add_argument("--backup-dir", default="/var/backups/zup", help="Backup directory (default: /var/backups/zup)")
    parser.add_argument("-o", "--output", choices=["table", "json", "csv"], default="table", help="Output format")
    parser.add_argument("--no-color", action="store_true", help="Disable ANSI colors")
    parser.add_argument("-v", "--version", action="version", version=f"zup.sh {VERSION}")
    args = parser.parse_args()

    if args.restore:
        restored, err = restore_latest_backup(args.restore, args.zone_dir, args.backup_dir)
        if err:
            sys.stderr.write(f"Error: {err}\n")
            sys.exit(1)
        print(f"Restored {args.restore} from {restored}")
        return

    domains = []
    if args.domain:
        domains.extend(x.strip() for x in args.domain.split(",") if x.strip())
    if args.domain_list and os.path.isfile(args.domain_list):
        with open(args.domain_list, "r", encoding="utf-8", errors="replace") as fh:
            domains.extend(line.strip() for line in fh if line.strip() and not line.startswith("#"))

    users = []
    if args.user:
        users.extend(x.strip() for x in args.user.split(",") if x.strip())
    if args.user_list and os.path.isfile(args.user_list):
        with open(args.user_list, "r", encoding="utf-8", errors="replace") as fh:
            users.extend(line.strip() for line in fh if line.strip() and not line.startswith("#"))
    if args.reseller:
        users.extend(get_reseller_users(args.reseller, args.etc_root))
    if users:
        domains.extend(get_domains_for_users(users, args.etc_root))

    domains = sorted(set(domains))
    if not domains:
        parser.print_help()
        sys.exit(1)

    results = [process_domain(d, args) for d in domains]
    if args.output == "json":
        print(json.dumps(results, indent=2))
    elif args.output == "csv":
        render_csv(results)
    else:
        use_color = sys.stdout.isatty() and not args.no_color
        render_table(results, Colors(enabled=use_color))

    if any(r["status"] in ("ERROR", "ROLLED_BACK") for r in results):
        sys.exit(1)


if __name__ == "__main__":
    main()
EOF

python3 -c "$PY_SCRIPT" "$@"
