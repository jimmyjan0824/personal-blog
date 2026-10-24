---
title: Redis 入門：資料結構與快取應用
date: 2026-10-24 09:20:00 +0800
categories: [Redis, 入門]
tags: [redis, nosql, cache, key-value]
description: 認識 Redis 的常用資料結構、過期機制，以及常見的快取模式。
---

Redis 是一個以記憶體為主的 Key-Value 資料庫，讀寫延遲通常在毫秒以下。它最常被用在快取、Session 儲存、排行榜、計數器與訊息佇列等場景。

## 常用資料結構

| 型別 | 用途範例 | 常用指令 |
| :--- | :--- | :--- |
| String | 快取、計數器 | `SET` `GET` `INCR` |
| Hash | 物件欄位 | `HSET` `HGET` `HGETALL` |
| List | 佇列、最新清單 | `LPUSH` `RPOP` `LRANGE` |
| Set | 不重複集合、標籤 | `SADD` `SISMEMBER` `SINTER` |
| Sorted Set | 排行榜 | `ZADD` `ZRANGE` `ZREVRANK` |
| Stream | 事件串流、訊息佇列 | `XADD` `XREADGROUP` |

## 基本操作

以下指令可在 `redis-cli` 中執行：

```shell
# String 與過期時間（60 秒）
SET user:1001:name "Jimmy" EX 60
GET user:1001:name
TTL user:1001:name

# 計數器
INCR page:home:views

# Hash
HSET user:1001 name "Jimmy" city "台北"
HGETALL user:1001

# Sorted Set 排行榜
ZADD leaderboard 980 "alice" 1200 "bob" 1050 "jimmy"
ZREVRANGE leaderboard 0 2 WITHSCORES
```

> Key 的命名建議使用冒號分層，例如 `物件:ID:欄位`，方便管理與觀察。
{: .prompt-tip }

## 快取模式：Cache-Aside

最常見的做法是 Cache-Aside（旁路快取）：

1. 應用程式先查 Redis
2. 命中就直接回傳
3. 沒命中就查資料庫（如 MySQL），寫回 Redis 並設定 TTL

```python
import json
import redis

r = redis.Redis()

def get_user(user_id, db):
    key = f"user:{user_id}"
    cached = r.get(key)
    if cached:
        return json.loads(cached)

    user = db.query_user(user_id)        # 從 MySQL / PostgreSQL 讀取
    r.set(key, json.dumps(user), ex=300)  # 快取 5 分鐘
    return user
```

資料更新時，常見做法是**先更新資料庫，再刪除快取**，讓下一次讀取重新載入最新資料。

## 持久化

Redis 雖然把資料放在記憶體，但仍提供兩種持久化方式：

- **RDB**：定期產生快照，檔案小、重啟快，但可能遺失最後一段時間的資料。
- **AOF**：記錄每個寫入指令，資料較完整，檔案較大。

正式環境常會兩者一起開啟。

## 使用時要注意

- 避免在正式環境使用 `KEYS *`，改用 `SCAN`
- 注意大 Key（Big Key）造成的阻塞與記憶體壓力
- 設定 `maxmemory` 與淘汰策略（例如 `allkeys-lru`）
- 快取要考慮穿透、擊穿與雪崩的防護
