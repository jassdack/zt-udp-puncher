#!/bin/bash
set -e

# ==========================================
# ZeroTier UDP Hole Puncher Installer (Split-Service Architecture)
# Copyright (c) 2026 PhotoGuild Inc.
# Released under the MIT license
# https://opensource.org/licenses/MIT
# ==========================================

echo "🔧 Starting installation..."

# 1. Check and install dependencies
echo "📦 Checking for ipset..."
if ! command -v ipset &> /dev/null;
then
    apt-get update && apt-get install -y ipset
    echo "✅ ipset installed"
else
    echo "✅ ipset is already installed"
fi

# 2. Create Python script
SCRIPT_PATH="/usr/local/bin/update-zt-firewall.py"
echo "🐍 Writing Python script to $SCRIPT_PATH..."

# Python script using quoted heredoc to prevent expansion
cat << 'EOF' > "$SCRIPT_PATH"
#!/usr/bin/env python3
"""Sync (peer IP, ZeroTier UDP port) pairs from the local ZeroTier API into ipset.

Requires Python 3.7 or later.
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import logging
import os
import subprocess
import sys
import urllib.request
from typing import Any, Dict, List, Optional, Set, Tuple

# ==========================================
# Configuration (Environment Variables)
# ==========================================
ZT_HOME = os.getenv("ZT_HOME", "/var/lib/zerotier-one")
TOKEN_PATH = os.getenv("ZT_TOKEN_PATH", os.path.join(ZT_HOME, "authtoken.secret"))
# Base URL of the local ZeroTier API; "/status" and "/peer" are appended.
# ZT_API_URL (used by older versions) pointed at /peer and is still accepted.
API_BASE = (os.getenv("ZT_API_BASE") or os.getenv("ZT_API_URL", "http://localhost:9993")).rstrip("/")
if API_BASE.endswith("/peer"):
    API_BASE = API_BASE[:-len("/peer")]
IPSET_V4_NAME = os.getenv("ZT_IPSET_V4", "zt-peers-v4")
IPSET_V6_NAME = os.getenv("ZT_IPSET_V6", "zt-peers-v6")
TIMEOUT_SEC = int(os.getenv("ZT_TIMEOUT", "10"))
DEFAULT_PORT = 9993

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger("zt-sync")

class ZeroTierClient:
    def __init__(self, token_path: str, api_base: str):
        self.api_base = api_base
        self.token = self._load_token(token_path)

    def _load_token(self, path: str) -> str:
        try:
            with open(path, 'r') as f:
                return f.read().strip()
        except Exception as e:
            logger.error(f"Failed to read auth token at {path}: {e}")
            sys.exit(1)

    def _get(self, endpoint: str) -> Optional[Any]:
        """GET an API endpoint and decode the JSON body. Returns None on any failure."""
        url = f"{self.api_base}{endpoint}"
        req = urllib.request.Request(url)
        req.add_header("X-ZT1-Auth", self.token)
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT_SEC) as res:
                if res.status != 200:
                    logger.error(f"GET {url} returned HTTP {res.status}")
                    return None
                return json.loads(res.read().decode())
        except Exception as e:
            logger.error(f"GET {url} failed: {e}")
            return None

    def get_peers(self) -> Optional[List[Dict[str, Any]]]:
        """Return the list from /peer, or None if it could not be fetched."""
        data = self._get("/peer")
        if data is None: return None
        if not isinstance(data, list):
            logger.error("/peer did not return a list")
            return None
        return data

    def get_listening_ports(self) -> Optional[Set[int]]:
        """Return the UDP ports the local daemon listens on (from /status), or None if it could not be fetched.

        Uses config.settings.listeningOn ("ip/port" strings); falls back to
        primaryPort/secondaryPort/tertiaryPort, then to 9993.
        """
        data = self._get("/status")
        if data is None: return None
        if not isinstance(data, dict):
            logger.error("/status did not return an object")
            return None
        config = data.get('config')
        settings = config.get('settings') if isinstance(config, dict) else None
        if not isinstance(settings, dict): settings = {}

        ports: Set[int] = set()
        listening_on = settings.get('listeningOn')
        if isinstance(listening_on, list):
            for entry in listening_on:
                port = str(entry).rsplit('/', 1)[-1]
                if port.isdigit(): ports.add(int(port))
        if not ports:
            for key in ('primaryPort', 'secondaryPort', 'tertiaryPort'):
                value = settings.get(key)
                if isinstance(value, int) and not isinstance(value, bool): ports.add(value)
        ports = {p for p in ports if 0 < p <= 65535}
        if not ports:
            logger.warning(f"No listening port found in /status; assuming {DEFAULT_PORT}")
            ports = {DEFAULT_PORT}
        return ports

    @staticmethod
    def extract_entries(peers: List[Dict[str, Any]], ports: Set[int]) -> Tuple[Set[str], Set[str]]:
        """Build hash:ip,port entries ("IP,udp:PORT") for every non-expired path of every peer.

        Root servers (PLANET/MOON), private addresses and non-preferred paths are
        kept on purpose: direct paths over a LAN need them, and hole punching must
        let the first packet through, so paths cannot be filtered by activity.
        """
        v4_entries: Set[str] = set()
        v6_entries: Set[str] = set()
        for peer in peers:
            if not isinstance(peer, dict): continue
            for path in peer.get('paths') or []:
                if not isinstance(path, dict): continue
                if path.get('expired'): continue
                addr_full = path.get('address', '')
                if not addr_full: continue
                raw_ip = str(addr_full).split('/')[0]
                try:
                    ip_obj = ipaddress.ip_address(raw_ip)
                except ValueError: continue
                if ip_obj.is_loopback or ip_obj.is_link_local: continue
                target = v6_entries if ip_obj.version == 6 else v4_entries
                for port in ports:
                    target.add(f"{ip_obj},udp:{port}")
        return v4_entries, v6_entries

class IPSetManager:
    @staticmethod
    def get_current_members(ipset_name: str) -> Optional[Set[str]]:
        try:
            res = subprocess.run(
                ['ipset', 'list', ipset_name, '-output', 'plain'],
                capture_output=True, text=True, timeout=TIMEOUT_SEC
            )
            if res.returncode != 0: return None
            members = set()
            in_members = False
            for line in res.stdout.splitlines():
                line = line.strip()
                if line.startswith("Members:"):
                    in_members = True
                    continue
                if in_members and line: members.add(line)
            return members
        except Exception: return None

    @staticmethod
    def sync(ipset_name: str, new_entries: Set[str], family: str, dry_run: bool = False) -> bool:
        """Replace the members of ipset_name with new_entries atomically. Returns False on failure."""
        current_entries = IPSetManager.get_current_members(ipset_name)
        log_message = None
        if current_entries is None:
            log_message = f"Creating new ipset: {ipset_name} with {len(new_entries)} entries"
        elif current_entries != new_entries:
            added = new_entries - current_entries
            removed = current_entries - new_entries
            log_message = f"Updated {ipset_name}: +{len(added)} / -{len(removed)} entries (Total: {len(new_entries)})"

        temp_name = f"{ipset_name}-tmp"
        cmds = [
            f"create {ipset_name} hash:ip,port family {family} hashsize 1024 maxelem 65536 -exist",
            f"create {temp_name} hash:ip,port family {family} hashsize 1024 maxelem 65536 -exist",
            f"flush {temp_name}"
        ]
        for entry in sorted(new_entries): cmds.append(f"add {temp_name} {entry} -exist")
        cmds.append(f"swap {temp_name} {ipset_name}")
        cmds.append(f"destroy {temp_name}")
        restore_content = "\n".join(cmds) + "\n"

        if dry_run:
            print(restore_content, end="")
            return True

        try:
            subprocess.run(['ipset', 'restore'], input=restore_content, text=True, check=True, timeout=TIMEOUT_SEC, stderr=subprocess.PIPE)
            if log_message: logger.info(log_message)
            return True
        except subprocess.CalledProcessError as e:
            err = (e.stderr or "").strip()
            logger.error(f"Failed to update {ipset_name}: {err}")
            if "already exists" in err:
                logger.error(f"{ipset_name} is probably a set of an older type (hash:ip); re-run install_zt_puncher.sh to migrate it")
            return False
        except Exception as e:
            logger.error(f"Failed to update {ipset_name}: {e}")
            return False

def main() -> int:
    parser = argparse.ArgumentParser(description="Sync ZeroTier peers to ipset.")
    parser.add_argument("--dry-run", action="store_true", help="print the ipset restore script instead of applying it")
    args = parser.parse_args()

    client = ZeroTierClient(TOKEN_PATH, API_BASE)

    # If the API cannot be read, keep the existing entries and report failure
    # instead of emptying the sets.
    ports = client.get_listening_ports()
    if ports is None:
        logger.error("Could not read the listening ports from /status; leaving ipsets untouched")
        return 1
    peers = client.get_peers()
    if peers is None:
        logger.error("Could not read the peer list from /peer; leaving ipsets untouched")
        return 1

    v4_entries, v6_entries = client.extract_entries(peers, ports)

    # Always run to ensure ipset exists
    ok_v4 = IPSetManager.sync(IPSET_V4_NAME, v4_entries, "inet", args.dry_run)
    ok_v6 = IPSetManager.sync(IPSET_V6_NAME, v6_entries, "inet6", args.dry_run)
    return 0 if (ok_v4 and ok_v6) else 1

if __name__ == "__main__":
    try: sys.exit(main())
    except KeyboardInterrupt: sys.exit(130)
EOF

chmod +x "$SCRIPT_PATH"
echo "✅ Script placement complete"


# 3. Create Systemd Service (Update Timer Only)
echo "⏱️ Updating Systemd settings..."

# zt-firewall-update.service (Periodic Sync)
# Note: Removed dependency on zt-ipset-prep.service to avoid circular dependency
printf '[Unit]\nDescription=Update ZeroTier Firewall IPSet (Sync)\nAfter=network-online.target zerotier-one.service\nWants=zerotier-one.service\n\n[Service]\nType=oneshot\nExecStart=%s\nUser=root\n\n[Install]\nWantedBy=multi-user.target\n' "$SCRIPT_PATH" > /etc/systemd/system/zt-firewall-update.service

# zt-firewall-update.timer (Every minute)
# AccuracySec=1s: without it systemd adds its default 1min slack, so the interval would be 1-2 minutes
printf "[Unit]\nDescription=Run ZeroTier Firewall Update every minute\n\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=1min\nAccuracySec=1s\nUnit=zt-firewall-update.service\n\n[Install]\nWantedBy=timers.target\n" > /etc/systemd/system/zt-firewall-update.timer

systemctl daemon-reload

# ==========================================
# Definitions shared by the following steps
# ==========================================
UFW_INIT_SCRIPT="/etc/ufw/before.init"
UFW_RULES_V4="/etc/ufw/before.rules"
UFW_RULES_V6="/etc/ufw/before6.rules"
IPSET_TYPE="hash:ip,port"

# ipset create commands (before.init and first run)
IPSET_CREATE_V4="ipset create zt-peers-v4 $IPSET_TYPE family inet hashsize 1024 maxelem 65536 -exist"
IPSET_CREATE_V6="ipset create zt-peers-v6 $IPSET_TYPE family inet6 hashsize 1024 maxelem 65536 -exist"

# Rules: allow UDP from a registered peer IP, but only to a registered (ZeroTier) port
UFW_RULE_V4="-A ufw-before-input -p udp -m set --match-set zt-peers-v4 src,dst -j ACCEPT"
UFW_RULE_V6="-A ufw6-before-input -p udp -m set --match-set zt-peers-v6 src,dst -j ACCEPT"

# Preferred position: right after UFW's INVALID drop (i.e. after loopback / ESTABLISHED / INVALID handling).
# Fallback: right after "# End required lines" (top of the chain), as older versions did.
UFW_ANCHOR_V4='^-A ufw-before-input -m conntrack --ctstate INVALID -j DROP[[:space:]]*$'
UFW_ANCHOR_V6='^-A ufw6-before-input -m conntrack --ctstate INVALID -j DROP[[:space:]]*$'
UFW_ANCHOR_FALLBACK='^# End required lines'

# Print the "Type:" of an existing ipset (empty if the set does not exist)
ipset_type() {
    ipset list -t "$1" 2>/dev/null | awk '/^Type:/ { print $2; exit }'
}

# Remove the lines older versions added to before.init
remove_old_init_lines() {
    if [ -f "$UFW_INIT_SCRIPT" ]; then
        sed -i '/# ZeroTier IPSet Creation/d; /ipset create zt-peers-v4 /d; /ipset create zt-peers-v6 /d' "$UFW_INIT_SCRIPT"
    fi
}

# Remove every rule that references one of our sets (old and new wording alike)
remove_rules() {
    [ -f "$UFW_RULES_V4" ] && sed -i '/--match-set zt-peers-v4 /d' "$UFW_RULES_V4"
    [ -f "$UFW_RULES_V6" ] && sed -i '/--match-set zt-peers-v6 /d' "$UFW_RULES_V6"
    return 0
}

# inject_rule FILE SETNAME RULE ANCHOR_REGEX
# Inserts RULE after the first line matching ANCHOR_REGEX (or after "# End required lines"
# when there is no such line). Idempotent: an identical rule is left alone, a rule from an
# older version (same set, different wording) is replaced.
inject_rule() {
    local file="$1" setname="$2" rule="$3" anchor="$4" tmp
    if [ ! -f "$file" ]; then
        echo "  -> $file not found (Skip)"
        return 0
    fi
    if grep -qxF -- "$rule" "$file"; then
        echo "  -> Rule already exists in $file (Skip)"
        return 0
    fi
    if grep -q -- "--match-set $setname " "$file"; then
        echo "  -> Replacing the rule of an older version in $file"
        sed -i "/--match-set $setname /d" "$file"
    fi
    if ! grep -qE -- "$anchor" "$file"; then
        anchor="$UFW_ANCHOR_FALLBACK"
        if ! grep -qE -- "$anchor" "$file"; then
            echo "❌ No place to insert the rule was found in $file. Add this line by hand:" >&2
            echo "   $rule" >&2
            return 1
        fi
    fi
    echo "  -> Adding rule to $file"
    tmp=$(mktemp)
    awk -v rule="$rule" -v pat="$anchor" '{ print } !done && $0 ~ pat { print rule; done = 1 }' "$file" > "$tmp"
    cat "$tmp" > "$file"   # keep the owner and mode of the original file
    rm -f "$tmp"
}

# 4. Migrate sets created by older versions (hash:ip -> hash:ip,port)
# Older versions allowed every UDP port from a registered IP. ipset cannot change the type of
# a set in place (and "swap" only works between sets of the same type), so the old sets have
# to be destroyed, which in turn requires that no loaded rule references them.
OLD_TYPE=""
for name in zt-peers-v4 zt-peers-v6; do
    t=$(ipset_type "$name")
    if [ -n "$t" ] && [ "$t" != "$IPSET_TYPE" ]; then
        OLD_TYPE="$t"
    fi
done

if [ -n "$OLD_TYPE" ]; then
    echo "♻️ Migrating ipsets of an older version ($OLD_TYPE -> $IPSET_TYPE)..."
    echo "⚠️ UDP from ZeroTier peers will be blocked for a few seconds until the new rules are loaded."
    systemctl stop zt-firewall-update.timer 2>/dev/null || true
    # (a) remove the lines of the older version
    remove_rules
    remove_old_init_lines
    # (b) reload UFW so that no rule references the old sets any more
    ufw reload
    # (c) destroy the old sets (the names are kept; they are re-created with the new type below)
    for name in zt-peers-v4-tmp zt-peers-v6-tmp; do
        ipset destroy "$name" 2>/dev/null || true
    done
    for name in zt-peers-v4 zt-peers-v6; do
        if [ -n "$(ipset_type "$name")" ]; then
            ipset destroy "$name"
        fi
    done
    echo "  -> Old sets removed; continuing with the normal installation"
fi

# 5. Setup UFW initialization script (/etc/ufw/before.init)
# Use UFW hook because creating ipset via Systemd can cause circular dependencies
echo "🛡️ Setting up UFW initialization script..."

if [ ! -f "$UFW_INIT_SCRIPT" ]; then
    touch "$UFW_INIT_SCRIPT"
    chmod +x "$UFW_INIT_SCRIPT"
fi

# Append with idempotency in mind
if grep -qxF -- "$IPSET_CREATE_V4" "$UFW_INIT_SCRIPT" && grep -qxF -- "$IPSET_CREATE_V6" "$UFW_INIT_SCRIPT"; then
    echo "  -> Configuration already exists in before.init (Skip)"
else
    if grep -q "zt-peers-v" "$UFW_INIT_SCRIPT"; then
        echo "  -> Replacing the lines of an older version in before.init"
        remove_old_init_lines
    fi
    echo "  -> Appending ipset creation commands to before.init"
    # Add shebang if missing
    if [ ! -s "$UFW_INIT_SCRIPT" ]; then
        echo "#!/bin/sh" >> "$UFW_INIT_SCRIPT"
    fi

    cat <<EOT >> "$UFW_INIT_SCRIPT"

# ZeroTier IPSet Creation (Added by install_zt_puncher.sh)
$IPSET_CREATE_V4
$IPSET_CREATE_V6
EOT
    chmod +x "$UFW_INIT_SCRIPT"
fi

# Manually run ipset creation (for first run)
ipset create zt-peers-v4 "$IPSET_TYPE" family inet hashsize 1024 maxelem 65536 -exist
ipset create zt-peers-v6 "$IPSET_TYPE" family inet6 hashsize 1024 maxelem 65536 -exist


# Enable Update Service itself (not just the timer)
systemctl enable zt-firewall-update.service

# Enable Timer
echo "⏰ Enabling Update Timer..."
systemctl enable --now zt-firewall-update.timer

# 6. Inject UFW rules (ensure idempotency)
echo "🔥 Checking UFW settings..."

# IPv4
inject_rule "$UFW_RULES_V4" zt-peers-v4 "$UFW_RULE_V4" "$UFW_ANCHOR_V4"

# IPv6
inject_rule "$UFW_RULES_V6" zt-peers-v6 "$UFW_RULE_V6" "$UFW_ANCHOR_V6"

# 7. Finishing up
echo "🔄 Reloading UFW..."
ufw reload

# Try initial update
echo "🚀 Executing initial update..."
if systemctl restart zt-firewall-update.service; then
    echo "✅ Initial update successful"
else
    echo "⚠️ Initial update failed (API might be preparing? Leaving it to the timer in 1 minute)"
fi

echo "🎉 Installation complete!"
echo "---------------------------------------------------"
echo "1. /etc/ufw/before.init: Safely create ipset ($IPSET_TYPE) before UFW loads"
echo "2. zt-firewall-update.timer: Sync (peer IP, ZeroTier UDP port) pairs every minute"
echo "3. $UFW_RULES_V4 / $UFW_RULES_V6: allow UDP from registered IPs to ZeroTier's ports only"
echo "   Check with: iptables -S ufw-before-input | grep zt-peers; ipset list zt-peers-v4"
echo "---------------------------------------------------"