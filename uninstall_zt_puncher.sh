#!/bin/bash
set -e

# ==========================================
# ZeroTier UDP Hole Puncher Uninstaller
# Copyright (c) 2026 PhotoGuild Inc.
# Released under the MIT license
# https://opensource.org/licenses/MIT
# ==========================================

echo "🗑️ Starting uninstallation..."

# 1. Stop and disable Systemd service and timer
echo "🛑 Stopping Systemd service..."
systemctl stop zt-firewall-update.timer 2>/dev/null || true
systemctl stop zt-firewall-update.service 2>/dev/null || true
systemctl disable zt-firewall-update.timer 2>/dev/null || true
systemctl disable zt-firewall-update.service 2>/dev/null || true

# Stop old service (just in case)
systemctl stop zt-ipset-prep.service 2>/dev/null || true
systemctl disable zt-ipset-prep.service 2>/dev/null || true

# 2. Delete files
echo "🧹 Deleting files..."
rm -f /etc/systemd/system/zt-firewall-update.service
rm -f /etc/systemd/system/zt-firewall-update.timer
rm -f /etc/systemd/system/zt-ipset-prep.service
rm -f /usr/local/bin/update-zt-firewall.py

systemctl daemon-reload

# 3. Clean up UFW initialization script (/etc/ufw/before.init)
echo "🧹 Cleaning up /etc/ufw/before.init..."
UFW_INIT_SCRIPT="/etc/ufw/before.init"
if [ -f "$UFW_INIT_SCRIPT" ]; then
    # Delete the appended block (using sed to remove start~end pattern)
    # Start: # ZeroTier IPSet Creation (Added by install_zt_puncher.sh)
    # End: until the line after ipset create zt-peers-v6 ...
    # Simply delete lines containing specific keywords
    sed -i '/# ZeroTier IPSet Creation/d' "$UFW_INIT_SCRIPT"
    sed -i '/ipset create zt-peers-v4/d' "$UFW_INIT_SCRIPT"
    sed -i '/ipset create zt-peers-v6/d' "$UFW_INIT_SCRIPT"
    
    # If the file is empty or only contains shebang, we could delete it,
    # but since the user might use it for other purposes, we keep the file to avoid side effects
    echo "  -> Removed settings from before.init"
else
    echo "  -> before.init not found (Skip)"
fi

# 4. Delete UFW rules
echo "🔥 Deleting UFW rules..."

# IPv4
if [ -f /etc/ufw/before.rules ]; then
    sed -i '/-m set --match-set zt-peers-v4 src -p udp -j ACCEPT/d' /etc/ufw/before.rules
    echo "  -> IPv4 rule deleted"
fi

# IPv6
if [ -f /etc/ufw/before6.rules ]; then
    sed -i '/-m set --match-set zt-peers-v6 src -p udp -j ACCEPT/d' /etc/ufw/before6.rules
    echo "  -> IPv6 rule deleted"
fi

# 5. Reload UFW and destroy IPSet
echo "🔄 Reloading UFW..."
ufw reload

echo "🗑️ Destroying IPSet..."
ipset destroy zt-peers-v4 2>/dev/null || true
ipset destroy zt-peers-v6 2>/dev/null || true

echo "🎉 Uninstallation complete!"
echo "Everything is back to normal."
