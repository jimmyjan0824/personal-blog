# Jimmy 的資料庫筆記

使用 [Jekyll](https://jekyllrb.com/) 與 [Chirpy](https://github.com/cotes2020/jekyll-theme-chirpy) 主題建立的個人部落格，分享 MySQL、PostgreSQL 等資料庫知識。

網站：<https://jimmyjan0824.github.io/personal-blog/>

## 撰寫新文章

在 `_posts/` 新增檔案，檔名格式為 `YYYY-MM-DD-標題.md`，例如 `2026-11-01-mysql-index-basics.md`：

```markdown
---
title: MySQL 索引入門
date: 2026-11-01 10:00:00 +0800
categories: [MySQL, 索引]        # 第一個是主分類，第二個是子分類
tags: [mysql, index, innodb]     # 標籤建議用小寫
---

內文從這裡開始……
```

建議的主分類：`MySQL`、`PostgreSQL`、`資料庫比較`、`SQL`、`維運`。

推送到 `main` 分支後，GitHub Actions 會自動建置並部署。

## 本機預覽

```bash
bundle install
bundle exec jekyll serve
```

接著開啟 <http://127.0.0.1:4000/personal-blog/>。

## 設定

網站標題、作者、社群連結等設定都在 `_config.yml`，聯絡方式圖示在 `_data/contact.yml`，關於頁面在 `_tabs/about.md`。

## 授權

主題 starter 依 [MIT License](LICENSE) 授權。
