#!/usr/bin/env bash
# =============================================================================
# 订阅聚合构建脚本 / Subscription aggregator build script
# -----------------------------------------------------------------------------
# 作用 / What it does
#   1. 按 sources.tsv 抓取各上游订阅 / fetch every upstream list in sources.tsv
#   2. 只保留 vless / trojan / vmess / ss / hy2 / hysteria2 / tuic 协议行
#      keep only known proxy protocol lines
#   3. 同源内按“节点指纹”去重（去掉 ?query 与 #fragment 后相同即视为同一节点）
#      de-duplicate inside a source by node fingerprint (query+fragment stripped)
#   4. 生成短名单（<= MAX_SHORT，超出则均匀抽样）与可选完整名单
#      emit the short list (<= MAX_SHORT, evenly sampled) and optional full list
#   5. 生成合并名单 all.short.txt / all.full.txt 与 counts.json / stats.md
#
# 设计取舍 / Design notes
#   - 不使用 set -e：单个上游挂掉不应该让整次构建失败；
#     single-source failure must not abort the whole run.
#   - 抓取失败时保留上一次的产物并标记 status=stale_kept，绝不写入空文件；
#     on fetch failure the previous output is kept and flagged, never emptied.
#   - 产物里不写时间戳：数据没变 => 文件逐字节不变 => workflow 不会产生空提交；
#     no timestamps inside artifacts, so an unchanged upstream means zero diff.
#
# 环境变量 / Environment
#   SOURCES   源清单路径 / source list path      (default: sources.tsv)
#   OUT       输出目录 / output dir              (default: configs)
#   MAX_SHORT 短名单上限 / short list cap        (default: 300)
#   SAMPLE_DIV 抽样基准（说明用，逐源均匀抽样）/ sampling hint (default: 4)
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SOURCES="${SOURCES:-sources.tsv}"
OUT="${OUT:-configs}"
MAX_SHORT="${MAX_SHORT:-300}"
SAMPLE_DIV="${SAMPLE_DIV:-4}"
PROTO_RE='^(vless|trojan|vmess|ss|hy2|hysteria2|tuic)://'
UA='vpn-sub-aggregator/1.0'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT" "$OUT/full"

# --- 工具函数 / helpers ------------------------------------------------------

# raw.githubusercontent.com -> cdn.jsdelivr.net 备用镜像 / fallback mirror
mirror_url() {
  printf '%s\n' "$1" | sed -E \
    's#^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/(refs/heads/)?([^/]+)/(.+)$#https://cdn.jsdelivr.net/gh/\1/\2@\4/\5#'
}

# 带重试与镜像回退的下载 / download with retries and mirror fallback
fetch() {
  local url="$1" dest="$2" code alt
  code="$(curl -sSL -A "$UA" --connect-timeout 15 --max-time 180 \
            --retry 2 --retry-delay 3 -o "$dest" -w '%{http_code}' "$url" 2>/dev/null)" || code=000
  if [ "$code" = "200" ] && [ -s "$dest" ]; then return 0; fi
  alt="$(mirror_url "$url")"
  if [ -n "$alt" ] && [ "$alt" != "$url" ]; then
    code="$(curl -sSL -A "$UA" --connect-timeout 15 --max-time 180 \
              -o "$dest" -w '%{http_code}' "$alt" 2>/dev/null)" || code=000
    if [ "$code" = "200" ] && [ -s "$dest" ]; then
      echo "    ↳ 使用镜像 / via mirror: $alt" >&2
      return 0
    fi
  fi
  return 1
}

# 过滤 + 去掉重复整行，保持原始顺序 / filter protocols, drop exact duplicates, keep order
normalize() {
  tr -d '\r' \
    | grep -aE "$PROTO_RE" \
    | sed -E 's/[[:space:]]+$//' \
    | awk '!seen[$0]++'
}

# 节点指纹去重：vless://uuid@host:port?a=b#name -> vless://uuid@host:port
dedupe_nodes() {
  awk '{ k=$0; sub(/[?#].*$/, "", k); if (k in seen) next; seen[k]=1; print }'
}

# 均匀抽样到 $1 条 / evenly sample down to $1 lines
sample() {
  awk -v max="$1" '
    { a[NR]=$0 }
    END {
      n=NR
      if (n <= max) { for (i=1; i<=n; i++) print a[i]; exit }
      for (i=0; i<max; i++) { idx = int(i*n/max) + 1; print a[idx] }
    }'
}

# 统计配置文件里的节点数（跳过 # 注释行）/ count nodes in a generated file
count_cfg() {
  [ -f "$1" ] || { echo 0; return; }
  local c
  c="$(grep -acE "$PROTO_RE" "$1" 2>/dev/null)"
  echo "${c:-0}"
}

is_big() { [ "$(wc -c < "$1")" -gt 1000000 ]; }

echo "==========================================================="
echo " 构建开始 / build start   MAX_SHORT=$MAX_SHORT  OUT=$OUT"
echo "==========================================================="

# --- 主循环 / main loop ------------------------------------------------------
: > "$TMP/all.short.raw"
: > "$TMP/all.full.raw"
: > "$TMP/per_source.tsv"   # id \t zh \t en \t short \t full \t status \t group

while IFS=$'\t' read -r id zh en url variants || [ -n "${id:-}" ]; do
  case "${id:-}" in ''|\#*) continue ;; esac
  variants="${variants:-short}"
  group="goida"; case "$url" in *igareck*) group="igareck" ;; esac

  raw="$TMP/raw.txt"; : > "$raw"
  if ! fetch "$url" "$raw"; then
    if [ -f "$OUT/$id.txt" ]; then
      echo "  ✗ $id 抓取失败，保留旧文件 / fetch failed, keeping previous output"
      printf '%s\t%s\t%s\t%s\t%s\tstale_kept\t%s\n' \
        "$id" "$zh" "$en" "$(count_cfg "$OUT/$id.txt")" \
        "$(count_cfg "$OUT/full/$id.txt")" "$group" >> "$TMP/per_source.tsv"
    else
      echo "  ✗ $id 抓取失败且无旧文件，跳过 / fetch failed, skipped"
      printf '%s\t%s\t%s\t0\t0\tfetch_failed\t%s\n' "$id" "$zh" "$en" "$group" >> "$TMP/per_source.tsv"
    fi
    continue
  fi

  if is_big "$raw"; then
    echo "  · $id 源体积 $(wc -c < "$raw") 字节 / source size in bytes"
  fi

  full="$TMP/full.$id.txt"
  normalize < "$raw" | dedupe_nodes > "$full"
  n="$(wc -l < "$full" | tr -d ' ')"

  if [ "$n" -eq 0 ]; then
    if [ -f "$OUT/$id.txt" ]; then
      echo "  ! $id 过滤后为空，保留旧文件 / empty after filter, keeping previous output"
      printf '%s\t%s\t%s\t%s\t%s\tempty_kept\t%s\n' \
        "$id" "$zh" "$en" "$(count_cfg "$OUT/$id.txt")" \
        "$(count_cfg "$OUT/full/$id.txt")" "$group" >> "$TMP/per_source.tsv"
    else
      echo "  ! $id 过滤后为空，跳过 / empty after filter, skipped"
      printf '%s\t%s\t%s\t0\t0\tempty\t%s\n' "$id" "$zh" "$en" "$group" >> "$TMP/per_source.tsv"
    fi
    continue
  fi

  # 短名单 / short list
  short="$TMP/short.$id.txt"
  if [ "$n" -le "$MAX_SHORT" ]; then
    cp "$full" "$short"
    kind_zh="全量"; kind_en="all ($n nodes)"
  else
    sample "$MAX_SHORT" < "$full" > "$short"
    kind_zh="抽样"; kind_en="sampled ($n → $(( $(wc -l < "$short") )))"
  fi
  short_n="$(wc -l < "$short" | tr -d ' ')"

  {
    echo "# 源 / Source: $id · $zh / $en"
    echo "# 类型 / Kind: 短名单 / short — $kind_zh / $kind_en, 上限 / cap $MAX_SHORT"
    echo "# 上游 / Upstream: $url"
    echo "# 说明 / Note: 自动聚合的公开订阅，非本项目提供的服务器 / auto-aggregated public list; servers are not ours"
  } > "$OUT/$id.txt"
  cat "$short" >> "$OUT/$id.txt"

  full_n=0
  case "$variants" in
    *full*)
      {
        echo "# 源 / Source: $id · $zh / $en"
        echo "# 类型 / Kind: 完整名单 / full — 全部 $n 条 / all $n nodes（客户端可能卡顿 / may lag the client）"
        echo "# 上游 / Upstream: $url"
        echo "# 说明 / Note: 自动聚合的公开订阅，非本项目提供的服务器 / auto-aggregated public list; servers are not ours"
      } > "$OUT/full/$id.txt"
      cat "$full" >> "$OUT/full/$id.txt"
      full_n="$n"
      ;;
  esac

  cat "$short" >> "$TMP/all.short.raw"
  cat "$full"  >> "$TMP/all.full.raw"
  printf '%s\t%s\t%s\t%s\t%s\tok\t%s\n' "$id" "$zh" "$en" "$short_n" "$full_n" "$group" >> "$TMP/per_source.tsv"
  echo "  ✓ $id  $zh / $en : 上游 / upstream $n → 短名单 / short $short_n${full_n:+, 完整 / full $full_n}"
done < "$SOURCES"

# --- 合并名单 / merged lists -------------------------------------------------
{
  echo "# 合并短名单 / merged short list — 所有已启用源，按节点指纹全局去重"
  echo "# merged from every enabled source, de-duplicated by node fingerprint"
  echo "# 说明 / Note: 自动聚合的公开订阅，非本项目提供的服务器 / auto-aggregated public list; servers are not ours"
  dedupe_nodes < "$TMP/all.short.raw"
} > "$OUT/all.short.txt"

{
  echo "# 合并完整名单 / merged full list — 所有已启用源的全部节点，全局去重"
  echo "# every node from every enabled source, globally de-duplicated"
  echo "# 说明 / Note: 自动聚合的公开订阅，非本项目提供的服务器 / auto-aggregated public list; servers are not ours"
  dedupe_nodes < "$TMP/all.full.raw"
} > "$OUT/all.full.txt"

total_short="$(count_cfg "$OUT/all.short.txt")"
total_full="$(count_cfg "$OUT/all.full.txt")"

# --- counts.json -------------------------------------------------------------
{
  echo '{'
  echo '  "schema": 1,'
  echo "  \"max_short\": $MAX_SHORT,"
  echo "  \"sample_div\": $SAMPLE_DIV,"
  echo '  "totals": {'
  echo "    \"short\": $total_short,"
  echo "    \"full\": $total_full"
  echo '  },'
  echo '  "sources": ['
  first=1
  while IFS=$'\t' read -r id zh en s f st grp; do
    [ $first -eq 1 ] || echo ','
    first=0
    printf '    { "id": "%s", "name_zh": "%s", "name_en": "%s", "group": "%s", "short": %s, "full": %s, "status": "%s" }' \
      "$id" "$zh" "$en" "$grp" "${s:-0}" "${f:-0}" "$st"
  done < "$TMP/per_source.tsv"
  echo
  echo '  ]'
  echo '}'
} > "$OUT/counts.json"

# --- stats.md（写入 Actions 摘要 / goes to the step summary）------------------
{
  echo "## 订阅构建结果 / Subscription build result"
  echo
  echo "短名单合计 **$total_short** 个节点（全局去重）· 完整名单合计 **$total_full** 个节点 · 上限 / cap: $MAX_SHORT"
  echo
  echo "| # | 源 / Source | 组 / Group | 短名单 short | 完整 full | 状态 status |"
  echo "|---|---|---|---|---|---|"
  while IFS=$'\t' read -r id zh en s f st grp; do
    echo "| $id | $zh / $en | $grp | ${s:-0} | ${f:-0} | $st |"
  done < "$TMP/per_source.tsv"
} > "$OUT/stats.md"

echo "==========================================================="
echo " 短名单 / short total : $total_short"
echo " 完整 / full total    : $total_full"
echo " 产物 / artifacts     : $OUT/{<id>.txt, full/<id>.txt, all.short.txt, all.full.txt, counts.json, stats.md}"
echo " 完成 / done"
echo "==========================================================="
