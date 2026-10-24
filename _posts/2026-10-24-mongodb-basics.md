---
title: MongoDB 入門：文件模型與基本操作
date: 2026-10-24 09:10:00 +0800
categories: [MongoDB, 入門]
tags: [mongodb, nosql, document]
description: 認識 MongoDB 的文件模型、CRUD 操作、索引與資料建模的基本觀念。
---

MongoDB 是最具代表性的文件型（Document）NoSQL 資料庫。它以類 JSON 的 BSON 格式儲存資料，結構彈性高，很適合需求快速變動的應用。

## 核心概念對照

| 關聯式資料庫 | MongoDB |
| :--- | :--- |
| Database | Database |
| Table | Collection |
| Row | Document |
| Column | Field |
| JOIN | 內嵌文件（Embedding）或 `$lookup` |
| Primary Key | `_id`（預設為 ObjectId） |

## 一份文件長什麼樣子

```json
{
  "_id": ObjectId("6717a1f2c3b4a5d6e7f80912"),
  "name": "Jimmy",
  "email": "jimmy@example.com",
  "skills": ["MySQL", "PostgreSQL", "MongoDB"],
  "address": {
    "city": "台北市",
    "zip": "100"
  }
}
```

同一個 collection 中的文件不需要有完全相同的欄位，陣列與巢狀物件也可以直接存放。

## 基本 CRUD

以下指令可在 `mongosh` 中執行：

```javascript
// 新增
db.users.insertOne({ name: "Jimmy", age: 30, skills: ["MySQL"] });

// 查詢：年齡大於 25，只回傳 name 欄位
db.users.find({ age: { $gt: 25 } }, { name: 1, _id: 0 });

// 更新：在陣列中加入一個技能
db.users.updateOne(
  { name: "Jimmy" },
  { $push: { skills: "MongoDB" } }
);

// 刪除
db.users.deleteOne({ name: "Jimmy" });
```

## 索引

沒有索引時，MongoDB 會做 collection scan。常用索引類型：

```javascript
// 單欄位索引
db.users.createIndex({ email: 1 }, { unique: true });

// 複合索引：注意欄位順序（ESR 原則：Equality → Sort → Range）
db.orders.createIndex({ userId: 1, createdAt: -1 });

// 查看執行計畫
db.orders.find({ userId: 42 }).sort({ createdAt: -1 }).explain("executionStats");
```

> 從 `explain()` 中看到 `COLLSCAN` 通常代表缺少合適的索引；`IXSCAN` 則表示有用到索引。
{: .prompt-tip }

## 資料建模：內嵌還是參照？

- **內嵌（Embedding）**：一起讀取、一對少、資料不會無限成長時使用，例如使用者的地址。
- **參照（Referencing）**：一對多且數量龐大、資料會被多處共用時使用，例如使用者與訂單。

MongoDB 的建模原則是「**依照查詢方式設計結構**」，而不是像關聯式資料庫那樣先做正規化。

## 什麼時候適合用 MongoDB？

- 資料結構多變，或欄位因資料而異（例如商品屬性、事件紀錄）
- 需要水平擴展（Sharding）處理大量寫入
- 應用以單一文件為主要存取單位

如果業務需要大量跨資料表的 JOIN 與嚴謹的關聯約束，關聯式資料庫通常仍是比較好的選擇。
