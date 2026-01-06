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
import json
import urllib.request
import os
import logging
import ipaddress
import subprocess
import sys
import argparse
from typing import Set, List, Dict, Any, Optional

# ==========================================
# Configuration (Environment Variables)
# ==========================================
ZT_HOME = os.getenv("ZT_HOME", "/var/lib/zerotier-one")
TOKEN_PATH = os.getenv("ZT_TOKEN_PATH", os.path.join(ZT_HOME, "authtoken.secret"))
API_URL = os.getenv("ZT_API_URL", "http://localhost:9993/peer")
IPSET_V4_NAME = os.getenv("ZT_IPSET_V4", "zt-peers-v4")
IPSET_V6_NAME = os.getenv("ZT_IPSET_V6", "zt-peers-v6")
TIMEOUT_SEC = int(os.getenv("ZT_TIMEOUT", "10"))

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger("zt-sync")

class ZeroTierClient:
    def __init__(self, token_path: str, api_url: str):
        self.api_url = api_url
        self.token = self._load_token(token_path)

    def _load_token(self, path: str) -> str:
        try:
            with open(path, 'r') as f:
                return f.read().strip()
        except Exception as e:
            logger.error(f"Failed to read auth token at {path}: {e}")
            sys.exit(1)

    def get_peers(self) -> List[Dict[str, Any]]:
        req = urllib.request.Request(self.api_url)
        req.add_header("X-ZT1-Auth", self.token)
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT_SEC) as res:
                if res.status == 200:
                    data = json.loads(res.read().decode())
                    return data if isinstance(data, list) else []
                return []
        except Exception as e:
            logger.error(f"API connection failed: {e}")
            sys.exit(1)

    def extract_ips(self, peers: List[Dict[str, Any]]) -> tuple[Set[str], Set[str]]:
        v4_ips = set()
        v6_ips = set()
        for peer in peers:
            for path in peer.get('paths', []):
                addr_full = path.get('address', '')
                if not addr_full: continue
                raw_ip = addr_full.split('/')[0]
                try:
                    ip_obj = ipaddress.ip_address(raw_ip)
                    if ip_obj.is_loopback or ip_obj.is_link_local: continue
                    if ip_obj.version == 6: v6_ips.add(str(ip_obj))
                    else: v4_ips.add(str(ip_obj))
                except ValueError: continue
        return v4_ips, v6_ips

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
    def sync(ipset_name: str, new_ips: Set[str], family: str, dry_run: bool = False):
        current_ips = IPSetManager.get_current_members(ipset_name)
        log_message = None
        if current_ips is None:
            log_message = f"Creating new ipset: {ipset_name} with {len(new_ips)} IPs"
        elif current_ips != new_ips:
            added = new_ips - current_ips
            removed = current_ips - new_ips
            log_message = f"Updated {ipset_name}: +{len(added)} / -{len(removed)} IPs (Total: {len(new_ips)})"

        temp_name = f"{ipset_name}-tmp"
        cmds = [
            f"create {ipset_name} hash:ip family {family} hashsize 1024 maxelem 65536 -exist",
            f"create {temp_name} hash:ip family {family} hashsize 1024 maxelem 65536 -exist",
            f"flush {temp_name}"
        ]
        for ip in new_ips: cmds.append(f"add {temp_name} {ip} -exist")
        cmds.append(f"swap {temp_name} {ipset_name}")
        cmds.append(f"destroy {temp_name}")
        restore_content = "\n".join(cmds)

        if dry_run:
            print(restore_content)
            return

        try:
            subprocess.run(['ipset', 'restore'], input=restore_content, text=True, check=True, timeout=TIMEOUT_SEC, stderr=subprocess.PIPE)
            if log_message: logger.info(log_message)
        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to update {ipset_name}: {e.stderr.strip()}")

def main():
    parser = argparse.ArgumentParser(description="Sync ZeroTier peers to ipset.")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    client = ZeroTierClient(TOKEN_PATH, API_URL)
    peers = client.get_peers()
    v4_ips, v6_ips = client.extract_ips(peers)

    # Always run to ensure ipset exists
    IPSetManager.sync(IPSET_V4_NAME, v4_ips, "inet", args.dry_run)
    IPSetManager.sync(IPSET_V6_NAME, v6_ips, "inet6", args.dry_run)

if __name__ == "__main__":
    try: main() 
    except KeyboardInterrupt: pass
EOF

chmod +x "$SCRIPT_PATH"
echo "✅ Script placement complete"


# 3. Create Systemd Service (Update Timer Only)
echo "⏱️ Updating Systemd settings..."

# zt-firewall-update.service (Periodic Sync)
# Note: Removed dependency on zt-ipset-prep.service to avoid circular dependency
printf "[Unit]\nDescription=Update ZeroTier Firewall IPSet (Sync)\nAfter=network-online.target zerotier-one.service\nWants=zerotier-one.service\n\n[Service]\nType=oneshot\nExecStart=$SCRIPT_PATH\nUser=root\n\n[Install]\nWantedBy=multi-user.target\n" > /etc/systemd/system/zt-firewall-update.service

# zt-firewall-update.timer (Every minute)
printf "[Unit]\nDescription=Run ZeroTier Firewall Update every minute\n\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=1min\nUnit=zt-firewall-update.service\n\n[Install]\nWantedBy=timers.target\n" > /etc/systemd/system/zt-firewall-update.timer

systemctl daemon-reload

# 4. Setup UFW initialization script (/etc/ufw/before.init)
# Use UFW hook because creating ipset via Systemd can cause circular dependencies
echo "🛡️ Setting up UFW initialization script..."

UFW_INIT_SCRIPT="/etc/ufw/before.init"
if [ ! -f "$UFW_INIT_SCRIPT" ]; then
    touch "$UFW_INIT_SCRIPT"
    chmod +x "$UFW_INIT_SCRIPT"
fi

# Append with idempotency in mind
if ! grep -q "zt-peers-v4" "$UFW_INIT_SCRIPT"; then
    echo "  -> Appending ipset creation commands to before.init"
    # Add shebang if missing
    if [ ! -s "$UFW_INIT_SCRIPT" ]; then
        echo "#!/bin/sh" >> "$UFW_INIT_SCRIPT"
    fi
    
    cat <<EOT >> "$UFW_INIT_SCRIPT"

# ZeroTier IPSet Creation (Added by install_zt_puncher.sh)
ipset create zt-peers-v4 hash:ip family inet hashsize 1024 maxelem 65536 -exist
ipset create zt-peers-v6 hash:ip family inet6 hashsize 1024 maxelem 65536 -exist
EOT
    chmod +x "$UFW_INIT_SCRIPT"
else
    echo "  -> Configuration already exists in before.init (Skip)"
fi

# Manually run ipset creation (for first run)
ipset create zt-peers-v4 hash:ip family inet hashsize 1024 maxelem 65536 -exist
ipset create zt-peers-v6 hash:ip family inet6 hashsize 1024 maxelem 65536 -exist


# Enable Update Service itself (not just the timer)
systemctl enable zt-firewall-update.service

# Enable Timer
echo "⏰ Enabling Update Timer..."
systemctl enable --now zt-firewall-update.timer

# 5. Inject UFW rules (ensure idempotency)
echo "🔥 Checking UFW settings..."

# IPv4
if ! grep -q "zt-peers-v4" /etc/ufw/before.rules;
then
    echo "  -> Adding IPv4 rule"
    sed -i '/# End required lines/a -A ufw-before-input -m set --match-set zt-peers-v4 src -p udp -j ACCEPT' /etc/ufw/before.rules
else
    echo "  -> IPv4 rule already exists (Skip)"
fi

# IPv6
if ! grep -q "zt-peers-v6" /etc/ufw/before6.rules;
then
    echo "  -> Adding IPv6 rule"
    sed -i '/# End required lines/a -A ufw6-before-input -m set --match-set zt-peers-v6 src -p udp -j ACCEPT' /etc/ufw/before6.rules
else
    echo "  -> IPv6 rule already exists (Skip)"
fi

# 6. Finishing up
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
echo "Configuration has been improved!"
echo "1. /etc/ufw/before.init: Safely create ipset before UFW loads"
echo "2. zt-firewall-update.timer: Sync latest IPs every minute"
echo "---------------------------------------------------"