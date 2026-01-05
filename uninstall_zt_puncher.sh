#!/bin/bash
set -e

# ==========================================
# ZeroTier UDP Hole Puncher Uninstaller
# ==========================================

echo "🗑️ アンインストールを開始するばい..."

# 1. Systemd サービスとタイマーの停止・無効化
echo "🛑 Systemdサービスを停止中..."
systemctl stop zt-firewall-update.timer 2>/dev/null || true
systemctl stop zt-firewall-update.service 2>/dev/null || true
systemctl disable zt-firewall-update.timer 2>/dev/null || true
systemctl disable zt-firewall-update.service 2>/dev/null || true

# 旧サービスの停止（念のため）
systemctl stop zt-ipset-prep.service 2>/dev/null || true
systemctl disable zt-ipset-prep.service 2>/dev/null || true

# 2. ファイルの削除
echo "🧹 ファイルを削除中..."
rm -f /etc/systemd/system/zt-firewall-update.service
rm -f /etc/systemd/system/zt-firewall-update.timer
rm -f /etc/systemd/system/zt-ipset-prep.service
rm -f /usr/local/bin/update-zt-firewall.py

systemctl daemon-reload

# 3. UFW初期化スクリプト(/etc/ufw/before.init)の掃除
echo "🧹 /etc/ufw/before.init をクリーンアップ中..."
UFW_INIT_SCRIPT="/etc/ufw/before.init"
if [ -f "$UFW_INIT_SCRIPT" ]; then
    # 追記したブロックを削除（sedで開始〜終了パターンを削除）
    # 開始: # ZeroTier IPSet Creation (Added by install_zt_puncher.sh)
    # 終了: ipset create zt-peers-v6 ... の次の行まで
    # 簡易的に、特定のキーワードを含む行を削除する
    sed -i '/# ZeroTier IPSet Creation/d' "$UFW_INIT_SCRIPT"
    sed -i '/ipset create zt-peers-v4/d' "$UFW_INIT_SCRIPT"
    sed -i '/ipset create zt-peers-v6/d' "$UFW_INIT_SCRIPT"
    
    # ファイルが空、またはシェバンだけなら削除してもいいが、
    # ユーザーが他の用途で使ってるかもしれないので、副作用を避けてファイルは残す
    echo "  -> before.init から設定を削除しました"
else
    echo "  -> before.init は見つかりませんでした (Skip)"
fi

# 4. UFWルールの削除
echo "🔥 UFWルールを削除中..."

# IPv4
if [ -f /etc/ufw/before.rules ]; then
    sed -i '/-m set --match-set zt-peers-v4 src -p udp -j ACCEPT/d' /etc/ufw/before.rules
    echo "  -> IPv4ルールを削除しました"
fi

# IPv6
if [ -f /etc/ufw/before6.rules ]; then
    sed -i '/-m set --match-set zt-peers-v6 src -p udp -j ACCEPT/d' /etc/ufw/before6.rules
    echo "  -> IPv6ルールを削除しました"
fi

# 5. UFWリロードとIPSet破棄
echo "🔄 UFWをリロード中..."
ufw reload

echo "🗑️ IPSetを破棄中..."
ipset destroy zt-peers-v4 2>/dev/null || true
ipset destroy zt-peers-v6 2>/dev/null || true

echo "🎉 アンインストール完了したばい！"
echo "完全に元に戻ったけん、安心してね。"
