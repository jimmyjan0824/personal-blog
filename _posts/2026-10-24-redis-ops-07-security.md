---
title: Redis 運維 07：安全與權限管理
date: 2026-10-24 12:00:00 +0800
categories: [Redis, 安全權限]
tags: [redis, redis7, redis8, dba, security, acl, tls, cve]
description: 以 Redis 7.4 為主，整理網路隔離、protected-mode、從 requirepass 到 ACL 的帳號設計、危險指令控管、TLS 加密、安全修補與稽核，並比較 8.x 的安全強化。
---

Redis 最早的設計假設是「跑在受信任的內網」，所以預設幾乎沒有安全防護。網路上長期有大量沒設密碼、直接暴露在公網的 Redis 被入侵（寫入 SSH 金鑰、挖礦程式）。本篇以 Redis 7.4 為主，整理該做的防護，最後比較 8.x。

{% include redis-ops-series.md %}

## 第一層：網路

```ini
bind 192.168.58.11 127.0.0.1 -::1   # 只聽內網 IP，絕對不要 0.0.0.0 對外
protected-mode yes                   # 預設。沒設密碼時拒絕非本機連線
port 6379
```

- Redis **不應該直接暴露在公網**。用防火牆或安全群組限制只有應用伺服器的網段能連 6379（Sentinel 26379、Cluster Bus 16379 也一樣）。
- Rocky Linux：`firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.0.1.0/24 port port=6379 protocol=tcp accept'`。
- 改預設 port 不是安全措施，只能擋掉最粗糙的掃描。

## 第二層：帳號與 ACL

### requirepass 只是 default 使用者的密碼

```ini
requirepass "ChangeMe_Redis_2026"
```

6.0 之後 `requirepass` 實際上是設定 ACL 裡 `default` 使用者的密碼。所有人共用一組密碼、擁有全部權限，無法區分是哪個應用做了什麼。

### 用 ACL 建立個別帳號

正式環境建議改用 ACL 檔案集中管理：

```ini
# redis.conf
aclfile /etc/redis/users.acl
```

```text
# /etc/redis/users.acl（權限 640，owner redis）
# 關閉 default 使用者，強迫所有連線都要用具名帳號
user default off
# 管理員
user admin on #<sha256 雜湊> ~* &* +@all
# 應用程式：只能存取自己前綴的 key，禁止危險與管理指令
user app_order on #<sha256 雜湊> ~order:* ~cart:* &order:* +@all -@dangerous -@admin
# 唯讀報表
user report on #<sha256 雜湊> ~* +@read -@dangerous
# 監控（redis_exporter）
user monitor on #<sha256 雜湊> ~* +@connection +info +ping +config|get +client|list +slowlog +latency +memory|stats +cluster|info
# 從庫連主庫用
user replica on #<sha256 雜湊> +psync +replconf +ping
```

- 密碼用 `#<sha256>` 形式存放雜湊值，產生方式：`echo -n '密碼' | sha256sum`。
- `~pattern` 限制可存取的 key，`&pattern` 限制 Pub/Sub 頻道，`+@category` / `-@category` 以類別授權。
- 7.0 起可以分開設定讀寫權限（`%R~report:*`、`%W~tmp:*`），也支援 selector（`(...)` 括號內一組獨立的規則）。
- 修改後用 `ACL LOAD` 重新載入；用 `ACL SAVE` 把線上的變更寫回檔案。**`aclfile` 和 redis.conf 裡的 `user` 指令不能同時使用**。
- 從庫要設 `masteruser replica` 與 `masterauth`；Sentinel 要設 `sentinel auth-user` 與 `sentinel auth-pass`。

查看與稽核：

```bash
redis-cli ACL LIST
redis-cli ACL WHOAMI
redis-cli ACL DRYRUN app_order FLUSHALL     # 7.0+：測試某帳號能不能執行某指令
redis-cli ACL LOG 10                         # 被拒絕的指令與登入失敗紀錄
```

## 第三層：危險指令

| 指令 | 風險 |
| :--- | :--- |
| `FLUSHALL` / `FLUSHDB` | 清空資料 |
| `KEYS` | 大量 key 時阻塞 |
| `CONFIG SET` | 可修改 `dir` + `dbfilename` 把檔案寫到任意位置（經典入侵手法） |
| `DEBUG` | 可讓伺服器當機、睡眠 |
| `MODULE LOAD` | 載入任意 .so 執行程式碼 |
| `EVAL` / `FUNCTION` | 執行 Lua，曾有多個沙箱逃脫漏洞 |

處理方式：

- 用 ACL 的 `-@dangerous` 拿掉應用帳號的危險指令，這是**首選做法**。
- `rename-command` 是舊做法，會讓 AOF 與從庫上的指令名稱不一致，且已被官方建議改用 ACL。
- 7.0 起預設 `enable-debug-command no`、`enable-module-command no`、`enable-protected-configs no`：`DEBUG`、`MODULE` 與修改 `dir` 等敏感設定預設只允許本機連線執行，**不要改成 `yes`**。

## 第四層：TLS 加密

TLS 要在編譯時開啟：

```bash
sudo dnf install -y openssl-devel
make -j"$(nproc)" USE_SYSTEMD=yes BUILD_TLS=yes
```

```ini
port 0                                   # 關閉明文 port
tls-port 6379
tls-cert-file /etc/redis/tls/redis.crt
tls-key-file /etc/redis/tls/redis.key
tls-ca-cert-file /etc/redis/tls/ca.crt
tls-auth-clients optional                # 預設 yes：要求用戶端憑證；只要加密不要雙向驗證時設 optional
tls-replication yes                      # 主從複製也走 TLS
tls-cluster yes                          # Cluster Bus 也走 TLS
tls-protocols "TLSv1.2 TLSv1.3"
```

TLS 會增加 CPU 負擔，7.x 的 I/O 多執行緒也不支援 TLS。延遲敏感的內網環境，通常用網路隔離取代 TLS；跨機房、跨雲則一定要開。

## 第五層：修補與稽核

- **追最新 patch**：7.4.9～7.4.11 連續三版都是 `SECURITY` 等級，修正了 Lua Use-After-Free、`RESTORE` 惡意資料、RDB `SLOT_INFO` 越界等可能導致遠端執行程式碼的漏洞，還有 `SORT` / `GEORADIUS` / `XREAD` 的 ACL key 權限繞過。
- **不要用 root 執行 Redis**，以專用的 `redis` 使用者執行，資料目錄權限 750。
- **`sanitize-dump-payload`**：預設 `no`，對外開放 `RESTORE` 的環境（例如資料搬遷工具）可設為 `yes`，載入時完整檢查 payload。
- **稽核**：Redis 本身沒有完整的稽核日誌，可用 `ACL LOG` 看拒絕紀錄、`MONITOR`（只在排查時短暫使用，非常耗效能）看即時指令，或在 Proxy 層記錄。

## 版本差異比較：7.4 vs 8.x

| 項目 | 7.4.11 | 8.x（8.10.2） |
| :--- | :--- | :--- |
| ACL 類別 | 傳統類別 | 8.0 新增 `@search`、`@json`、`@timeseries`、`@bloom`、`@cuckoo`、`@cms`、`@topk`、`@tdigest` |
| 用戶端憑證登入 | TLS 憑證只用來驗證身分，仍要 `AUTH` | 8.6 新增 `tls-auth-clients-user`，可依憑證的 CN 自動對應 ACL 使用者 |
| 節點間驗證 | 無 | 8.10 新增 TLS 憑證的 server-to-server 驗證與 `tls-expected-peer-name` |
| Cluster Bus | 無驗證，任何能連到 16379 的主機都能加入 | 8.10.2 起未開 `tls-cluster` 會在啟動時警告；`cluster-bus-port-protected-mode yes` 可拒絕在未驗證狀態下啟動 |
| 安全修補 | 7.4 仍有修補，但只修安全與嚴重錯誤 | 新功能與修補都在 8.x |
| 授權 | RSALv2 / SSPLv1 | 多了 AGPLv3 |

### 給安全管理的升級建議

- 升到 8.x 後，原本用 `+@all -@dangerous` 授權的帳號會自動包含新的模組指令（例如 `FT.*`、`JSON.*`）。應用帳號若不需要，記得用 `-@search -@json` 等拿掉。
- Cluster 跨網段部署的環境，升到 8.10.2 之後評估開啟 `tls-cluster` 與 `cluster-bus-port-protected-mode yes`。
- 不管 7.x 或 8.x，**最重要的是追最新的 patch**。

## 小結

- 網路隔離是第一道防線，Redis 絕不對外。
- 用 ACL 為每個應用建立帳號，關閉 `default`，用 `-@dangerous` 拿掉危險指令。
- `enable-debug-command`、`enable-module-command`、`enable-protected-configs` 維持預設 `no`。
- 跨機房開 TLS；不論版本，都要追最新的安全修補。

下一篇：[變更管理與發布]({% post_url 2026-10-24-redis-ops-08-change-management %})。

### 參考資料

- [Redis security](https://redis.io/docs/latest/operate/oss_and_stack/management/security/)
- [Redis ACL](https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/)
- [TLS](https://redis.io/docs/latest/operate/oss_and_stack/management/security/encryption/)
- [Redis 7.4 release notes](https://github.com/redis/redis/blob/7.4/00-RELEASENOTES)
