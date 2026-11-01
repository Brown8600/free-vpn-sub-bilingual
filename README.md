# 免费订阅聚合 · Free VPN Subscription Aggregator

> 借鉴 [Hidashimora/free-vpn-anti-rkn](https://github.com/Hidashimora/free-vpn-anti-rkn) 的思路重写：
> 用 GitHub Actions 定时抓取公开订阅、裁剪到可用规模、生成统计与页面。
> Rewritten from the same idea: GitHub Actions periodically fetches public subscriptions,
> trims them to a client-friendly size, and publishes counts plus a page.

[中文](#中文) · [English](#english)

---

## 中文

### 一句话

上游订阅动辄上千个节点，客户端会卡。本项目只做三件事：**抓取 → 过滤去重 → 均匀裁剪到 ≤300 条**，然后把结果提交回仓库，直接用 raw 链接订阅。

### 与原仓库的差异（重要）

抄之前先知道这几件事，都是实测出来的：

| 项 | 原仓库 | 本项目 |
|---|---|---|
| 更新频率 | workflow 写 `* * * * *`，宣称每分钟 | `*/5 * * * *`。**GitHub cron 最短就是 5 分钟**，写 1 分钟也不会更快，只会在高峰期被丢弃 |
| 上游可用性 | 26 个源指向 `AvenCores/goida-vpn-configs` | 该仓库**已 404 消失**，本项目改指活跃镜像 `aneek0/goida-vpn-configs`，并默认只开小体积源 |
| 失效信号 | 抓不到就静默保留旧文件，看不出来 | `counts.json` 里有 `status`（`ok` / `stale_kept` / `fetch_failed`），页面直接标黄标红 |
| 去重 | 无 | 同源按节点指纹（去掉 `?query`、`#fragment`）去重；合并名单全局去重 |
| 抽样 | 每 4 行取 1 行 | 超过上限时按 `int(i*n/max)` **均匀**抽取，覆盖整个列表而不是扎堆前段 |
| 提交噪音 | 每次跑都可能 commit（已 4500+ 次提交） | 产物内**不写时间戳**，上游没变 → 逐字节相同 → 零 diff → 不提交 |
| 并发 | 无保护 | `concurrency` 串行，后到的排队，不会互相覆盖 |
| 文档 | 俄文 | 中英双语（本文件、产物头部注释、Actions 摘要都是） |

### 目录结构

```
.github/workflows/update-vpn-config.yml   定时构建 / scheduled build
scripts/build.sh                          抓取·过滤·去重·抽样·统计
sources.tsv                               源清单（改这里就能加源）
configs/<id>.txt                          短名单（≤300）
configs/full/<id>.txt                     完整名单（仅 variants 含 full 的源）
configs/all.short.txt                     合并短名单（全局去重）
configs/all.full.txt                      合并完整名单（全局去重）
configs/counts.json                       节点数与每个源的状态
configs/stats.md                          本次运行摘要（写入 Actions Summary）
configs/last-update.txt                   最近一次「数据真正变化」的时间
index.html                                双语订阅页
```

### 部署（3 步）

1. **Fork / 新建仓库**，把本目录内容推上去，默认分支 `main`。
2. **Settings → Actions → General** 确认 *Workflow permissions* 选 **Read and write permissions**（否则 bot 推不上去）。
3. **Settings → Pages** 选 `Deploy from a branch` → `main` / `/ (root)`。
   页面：`https://<用户名>.github.io/<仓库名>/`
   订阅：`https://raw.githubusercontent.com/<用户名>/<仓库名>/main/configs/all.short.txt`

第一次手动跑一次：**Actions → 更新订阅 / Update subscriptions → Run workflow**。

### 订阅链接

| 用途 | 文件 |
|---|---|
| 只想能用、不折腾 | `configs/all.short.txt`（全局去重后的短名单） |
| 要某个来源 | `configs/<id>.txt`，id 见下表 |
| 要全量（可能卡） | `configs/all.full.txt`、`configs/full/<id>.txt` |

默认启用的源（改 `sources.tsv` 增删）：

| id | 源 | 组 |
|---|---|---|
| 27–34 | igareck/vpn-configs-for-russia（SS+All、VLESS 黑名单、白名单 Reality/CIDR/SNI） | igareck |
| 6, 8, 9, 11, 16, 18, 22, 23, 24, 25 | goida 聚合镜像中的小体积文件 | goida |

`goida` 段的大文件（`2.txt` 单文件 100 MB）默认注释掉了，按需开。

### 想比 5 分钟更快？

GitHub 自己做不到，但可以让**外部定时器**通过 API 触发 `workflow_dispatch`：

```bash
# 生成一个 fine-grained PAT，权限只给 Actions: write
curl -X POST \
  -H "Authorization: Bearer $GH_PAT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/<owner>/<repo>/actions/workflows/update-vpn-config.yml/dispatches \
  -d '{"ref":"main"}'
```

放在 cron-job.org / Cloudflare Worker Cron / 你自己服务器的 crontab 里即可。**别真的每分钟跑**：GitHub 免费额度 2000 分钟/月，一次构建约 1 分钟，每分钟跑必超额；5–15 分钟是合理区间。

### 本地跑

```bash
bash scripts/build.sh                 # 默认 MAX_SHORT=300
MAX_SHORT=100 bash scripts/build.sh   # 改上限
bash scripts/build.sh 2>&1 | tail -5  # 看结果
```

依赖：`bash` + `curl` + `grep/sed/awk`（GitHub runner 全都有，无 Python/Node 依赖）。

### 坑 / 已知限制

- **计划任务会被停**：公开仓库 60 天无活动，GitHub 会自动暂停 scheduled workflow。手动跑一次或用外部触发器可恢复。
- **高峰延迟**：`*/5` 只是「最快」，实际常在 5–20 分钟之间抖动。
- **免费节点是消耗品**：失效是常态。本项目不检测存活、不测延迟——那种能力需要跑 xray 探活，会显著拉长构建时间，属于可选的下一步。
- **`raw.githubusercontent.com` 在部分网络下不可达**：脚本抓取时已内置 jsdelivr 镜像回退；但**你订阅时**如果 raw 打不开，把链接换成
  `https://cdn.jsdelivr.net/gh/<owner>/<repo>@main/configs/all.short.txt` 即可。
- 产物文件头部有 `#` 注释行，主流客户端（v2rayN / v2rayNG / Hiddify / NekoRay / V2Box）会忽略它们。

### 免责声明

本项目只是对**公开数据**做机械聚合与裁剪，不运营任何服务器，不审查节点内容，不对其可用性、安全性、合法性作任何担保。请自行判断并遵守所在地法律。你如何使用这些配置与本项目无关。

---

## English

### What it is

Public subscription lists ship thousands of nodes, which makes clients lag or crash. This repo does exactly three
things: **fetch → filter & de-duplicate → evenly trim to ≤300**, then commits the result so you can subscribe by raw URL.

### Differences from the original repo (verified, not guessed)

| | Original | This repo |
|---|---|---|
| Frequency | `* * * * *`, claims "every minute" | `*/5 * * * *`. **GitHub cron's floor is 5 minutes**; asking for 1 minute buys nothing and just gets dropped at peak |
| Upstream | 26 sources on `AvenCores/goida-vpn-configs` | That repo is **gone (HTTP 404)**. This repo uses the live mirror `aneek0/goida-vpn-configs` and only enables the small files by default |
| Failure signal | Silent: keeps stale files, nobody notices | `counts.json` carries `status` (`ok` / `stale_kept` / `fetch_failed`); the page flags it |
| Dedupe | none | per-source node fingerprint (`?query` and `#fragment` stripped); merged lists de-duplicated globally |
| Sampling | every 4th line | evenly spaced `int(i*n/max)`, so the whole list is covered, not just the head |
| Commit noise | commits on most runs (4500+ commits) | artifacts contain **no timestamps** → unchanged upstream means zero diff → no commit |
| Concurrency | none | `concurrency` makes runs queue instead of clobbering |
| Docs | Russian | bilingual (this file, artifact headers, Actions summary) |

### Deploy

1. Fork or create a repo, push these files, default branch `main`.
2. **Settings → Actions → General → Workflow permissions** → **Read and write** (otherwise the bot cannot push).
3. **Settings → Pages** → `Deploy from a branch` → `main` / `/ (root)`.

Then run it once: **Actions → Update subscriptions → Run workflow**.

- Page: `https://<user>.github.io/<repo>/`
- Feed: `https://raw.githubusercontent.com/<user>/<repo>/main/configs/all.short.txt`

### Feeds

| Need | File |
|---|---|
| Just works | `configs/all.short.txt` |
| One specific source | `configs/<id>.txt` |
| Everything (may lag) | `configs/all.full.txt`, `configs/full/<id>.txt` |

Enabled by default: ids 27–34 (`igareck/vpn-configs-for-russia`) and 6, 8, 9, 11, 16, 18, 22, 23, 24, 25 (small goida files).
Edit `sources.tsv` to add or remove sources — one TAB-separated line each, `#` comments allowed.

### Faster than 5 minutes

GitHub alone cannot. Trigger the workflow from an external scheduler instead:

```bash
curl -X POST -H "Authorization: Bearer $GH_PAT" -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/<owner>/<repo>/actions/workflows/update-vpn-config.yml/dispatches \
  -d '{"ref":"main"}'
```

Use a fine-grained PAT with `Actions: write`. Do **not** actually run this every minute: the free plan gives
2000 minutes/month and one build is ~1 minute. 5–15 minutes is the sane range.

### Local run

```bash
bash scripts/build.sh
MAX_SHORT=100 bash scripts/build.sh
```

Requires only `bash`, `curl`, `grep/sed/awk`. No Python, no Node.

### Known limits

- Scheduled workflows are disabled after 60 days of repository inactivity on public repos.
- `*/5` is a floor, not a promise — real runs drift 5–20 minutes at peak.
- Free nodes die constantly. This project deliberately does **not** probe liveness or measure latency; that needs
  an xray-based health check and is a separate, optional step.
- `raw.githubusercontent.com` is unreachable on some networks. Fetching already falls back to jsDelivr; for
  subscribing, swap the URL for `https://cdn.jsdelivr.net/gh/<owner>/<repo>@main/configs/all.short.txt`.
- Generated files start with `#` comment lines; mainstream clients (v2rayN, v2rayNG, Hiddify, NekoRay, V2Box) ignore them.

### Disclaimer

This project only mechanically aggregates and trims **public data**. It runs no server, does not audit node content,
and makes no warranty about availability, safety or legality. Judge for yourself and follow local law.

---

MIT License · 见 [`LICENSE`](LICENSE)
