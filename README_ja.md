# ZeroTier UDP Puncher

[English](README.md) | **日本語**

**信頼性を重視した設計: ZeroTier のための動的かつ高性能なファイアウォールホールパンチングツール**

このツールは、IPSet を介して UFW ファイアウォールルールを動的に管理することで、ZeroTier P2P (Direct) 通信の成功率を劇的に向上させます。厳格な Linux ファイアウォール環境において、セキュリティを犠牲にして広範囲のポートを開放することなく、UDP パケットがブロックされるという重大な問題を解決します。

## 🏗️ アーキテクチャとデータフロー

システムコンポーネント（ZeroTier、Python 更新ロジック、Systemd タイマー、カーネルの Netfilter サブシステム）間の詳細な相互作用は以下の通りです。

```mermaid
graph TD
    subgraph "ZeroTier Layer"
        ZT[ZeroTier One Daemon]
        API[Local API :9993]
        Peer[Remote Peer]
        ZT <-->|UDP P2P| Peer
        ZT -->|Expose Status| API
    end

    subgraph "Control Plane (User Space)"
        Timer[Systemd Timer] -->|Trigger (1min)| Scriptor[update-zt-firewall.py]
        Scriptor -->|GET /peer| API
        Scriptor -->|Parse IPs| Logic{Extract External IPs}
        Logic -->|Update| IPSetUtils[ipset Command]
    end

    subgraph "Data Plane (Kernel Space)"
        IPSetUtils -->|Swap Atomic| KernelSet[Kernel IPSet (Hash:IP)]
        Netfilter[Netfilter / UFW Chain]
        Netfilter -->|Match src| KernelSet
        KernelSet -->|Allow/Drop| Netfilter
    end

    Peer -.->|UDP Packet| Netfilter
```

## 🚀 技術的観点からの主な特徴

### 1. O(1) パケットフィルタリング性能
`iptables` ルールを線形に追加していく従来のスクリプト（計算量 O(n)）とは異なり、本ツールは **IPSet** (`hash:ip` タイプ) を利用しています。
*   **線形ルール (非効率)**: 100 ピア = パケットを受信するたびに 100 回のルールチェックが発生。
*   **IPSet (効率的)**: 100 ピア = **1 回のハッシュルックアップ** (O(1))。
これにより、ZeroTier ネットワークが数千ピアにスケールしても、CPU 負荷は無視できるレベルに保たれます。

### 2. 解決済み: Systemd の「ブートループ」競合状態 (Race Condition)
UFW で ipset を永続化しようとする際によくある落とし穴として、ブート時の循環依存や競合状態があります：
1.  `ufw.service` がルールをロードする。
2.  ルールは `ipset` セット（例: `zt-peers-v4`）を参照している。
3.  セットがまだ存在しない場合、**UFW の起動は失敗する**。
4.  標準的な永続化サービスは、ネットワークの後や UFW と並行して開始されることが多く、予測不能なブート失敗を引き起こす。

**我々の解決策**:
**UFW `before.init` フック** (`/etc/ufw/before.init`) を活用しています。
このシェルスクリプトは、UFW コマンドが実行される **直前に** 同期的に実行されます。ここに `ipset create` コマンドを注入することで、以下を保証します：
*   ルールが参照するよりも *前に* セットが存在すること。
*   Systemd のサービス起動順序に全く依存しないこと。
*   **100% の再起動安全性 (Reboot Safety)**。

### 3. アトミックな更新
Python スクリプトは、**Swap-Describe** パターンを使用して IPSet を更新します：
1.  一時的なセット (`zt-peers-v4-tmp`) を作成。
2.  最新の IP を入力。
3.  一時セットと本番セットを **アトミックにスワップ** (`ipset swap`)。
4.  一時セットを破棄。
これにより、更新中にパケットがドロップされる「空白期間」やダウンタイムが **ゼロ** になります。

## ⚙️ コンポーネントと設定

### 前提条件
*   Linux (Debian/Ubuntu ベース) で、`systemd`, `ufw`, `ipset`, `python3` が利用可能であること。
*   ZeroTier One がインストールされ、動作していること。

### インストール方法

```bash
git clone https://github.com/photoguild/zt-udp-puncher.git
cd zt-udp-puncher
chmod +x install_zt_puncher.sh
sudo ./install_zt_puncher.sh
```

### 環境変数 (高度な設定)
コアロジックは `/usr/local/bin/update-zt-firewall.py` にあります。必要に応じて、生成された systemd サービスファイルを修正し、これらの変数を上書きすることができます。

| 変数名 | デフォルト値 | 説明 |
| :--- | :--- | :--- |
| `ZT_API_URL` | `http://localhost:9993/peer` | ローカル ZeroTier API エンドポイント |
| `ZT_TOKEN_PATH` | `/var/lib/zerotier-one/authtoken.secret` | API 認証トークンのパス |
| `ZT_TIMEOUT` | `10` | API 呼び出しやサブプロセスのタイムアウト時間（秒） |
| `ZT_IPSET_V4` | `zt-peers-v4` | IPv4 ipset の名前 |
| `ZT_IPSET_V6` | `zt-peers-v6` | IPv6 ipset の名前 |

## 🛠️ 運用状況とトラブルシューティング

### サービスステータスの確認
```bash
systemctl status zt-firewall-update.timer
systemctl status zt-firewall-update.service
```

### ファイアウォール状態の検査
`before.rules` の注入が機能し、パケットがマッチしているか確認します：
```bash
# UFW の状態を確認 ("zt-peers-v4" を探す)
sudo ufw status verbose

# 現在ホワイトリストに登録されている実際の IP を表示
sudo ipset list zt-peers-v4
```

### ログ
構造化されたログは stdout/stderr を経由して journald に送信されます。
```bash
journalctl -u zt-firewall-update.service -f
```

## 🔐 セキュリティモデル / なぜ `hash:ip` なのか？
私たちは、`hash:net` (サブネット) ではなく、意図的に `hash:ip` (単一 IP アドレス) を選択しました。
ZeroTier ピアは、動的な家庭用 IP 上にあることがよくあります。サブネット全体（例: /24）をホワイトリストに登録すると、同じ ISP ノード上の近隣住民や他のユーザーに対して UDP ポートを開放してしまうリスクがあります。
認証されたピアの **検出された正確なグローバル IP** のみにホワイトリストを厳格に制限することで、「最小権限」の原則を維持しています。

## 🗑️ アンインストール

すべてのサービス、タイマー、スクリプトを完全に削除し、UFW/IPSet 設定を元に戻します：

```bash
sudo ./uninstall_zt_puncher.sh
```
