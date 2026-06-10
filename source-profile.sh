#!/bin/bash
# source-profile.sh
# 扫描源端目录,生成文件系统画像 (含 P50/P90/P99 分位数)
# 一次扫描,后续全部基于内存数据分析,适合 EFS / 大目录场景
#
# 用法:
#   ./source-profile.sh <SRC_DIR> [WORKDIR]
# 示例:
#   ./source-profile.sh /mnt/source /tmp/fpsync_profile
#
# 输出:
#   <WORKDIR>/sizes.txt     原始文件大小列表
#   <WORKDIR>/profile.json  统计画像(供 generate-fpsync-cmd.sh 使用)

set -euo pipefail

# ----------------------------------------------------------------------
# 加载统一配置 fpsync.env (同目录)。配置优先,位置参数仅在配置留空时回退。
# ----------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/fpsync.env" ] && . "$SCRIPT_DIR/fpsync.env"

SRC_DIR="${SRC_DIR:-${1:-}}"
WORKDIR="${WORKDIR:-${2:-/tmp/fpsync_profile}}"

if [ -z "$SRC_DIR" ]; then
    echo "Usage: $0 <SRC_DIR> [WORKDIR]" >&2
    echo "  (或在 $SCRIPT_DIR/fpsync.env 中设置 SRC_DIR / WORKDIR)" >&2
    exit 1
fi

if [ ! -d "$SRC_DIR" ]; then
    echo "ERROR: $SRC_DIR is not a directory" >&2
    exit 1
fi

mkdir -p "$WORKDIR"

echo "=== Scanning $SRC_DIR ==="
echo "Workdir: $WORKDIR"

# ----------------------------------------------------------------------
# 第 1 步: 扫描源端。按【顶层子目录并行】遍历,重叠 NFS 元数据延迟,
#          千万级目录显著缩短墙钟时间。一次遍历同时拿到文件大小与目录数。
#   中间文件 entries.txt: 每行 "<type> <size>" (type: f=文件 d=目录 ...)
#   兼容产出 sizes.txt: 仅文件大小,一行一个(供参考/排错)
# ----------------------------------------------------------------------
# 并行度: 配置 SCAN_PARALLEL 优先;留空则按 CPU 估(核数×4,下限 4)
SCAN_PARALLEL="${SCAN_PARALLEL:-}"
if ! [ "${SCAN_PARALLEL:-0}" -ge 1 ] 2>/dev/null; then
    SCAN_PARALLEL=$(( $(nproc 2>/dev/null || echo 4) * 4 ))
    [ "$SCAN_PARALLEL" -lt 4 ] && SCAN_PARALLEL=4
fi
echo "Scan parallelism: $SCAN_PARALLEL (按顶层子目录并行 find)"

SCAN_START=$(date +%s)
ENTRIES="$WORKDIR/entries.txt"
SUBSZ="$WORKDIR/subtree-sizes.tsv"   # 每行: bytes <TAB> files <TAB> 顶层子树相对路径(供 shard-plan.sh)
PARTD="$WORKDIR/.scan_parts"
: > "$ENTRIES"; : > "$SUBSZ"
rm -rf "$PARTD"; mkdir -p "$PARTD"

# 顶层散落文件单列为伪子树 "<root-files>"(子目录交给并行 worker,避免重复计数)
find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type f -printf 'f %s\n' > "$PARTD/root.entries" 2>/dev/null || true

# 顶层子目录 -> 各自递归扫描(含子树内文件+目录),并行执行;-print0 兼容特殊文件名
# 每个 worker 产出 entries(p.XXXX)与子树标签(p.XXXX.subtree)
find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null \
  | xargs -0 -P "$SCAN_PARALLEL" -I{} sh -c '
        pf="$(mktemp "$2/p.XXXXXX")"
        find "$1" -printf "%y %s\n" > "$pf" 2>/dev/null
        printf "%s" "$1" > "$pf.subtree"
    ' _ {} "$PARTD" || true

# 合并全局 entries + 生成每子树汇总
cat "$PARTD/root.entries" >> "$ENTRIES" 2>/dev/null || true
[ -s "$PARTD/root.entries" ] && \
    awk '$1=="f"{b+=$2;f++} END{printf "%d\t%d\t%s\n", b+0, f+0, "<root-files>"}' "$PARTD/root.entries" >> "$SUBSZ"
for pf in "$PARTD"/p.*; do
    case "$pf" in *.subtree) continue ;; esac
    [ -f "$pf" ] || continue
    cat "$pf" >> "$ENTRIES"
    lbl=$(cat "$pf.subtree" 2>/dev/null)
    rel=${lbl#"$SRC_DIR"}; rel=${rel#/}        # 相对 SRC_DIR 的顶层名
    awk -v r="$rel" '$1=="f"{b+=$2;f++} END{printf "%d\t%d\t%s\n", b+0, f+0, r}' "$pf" >> "$SUBSZ"
done
# subtree-sizes.tsv 按字节降序(便于装箱与查看)
if [ -s "$SUBSZ" ]; then
    sort -t"$(printf '\t')" -k1,1nr -o "$SUBSZ" "$SUBSZ" 2>/dev/null || true
fi

rm -rf "$PARTD"

SCAN_END=$(date +%s)
SCAN_SEC=$((SCAN_END - SCAN_START))

# 兼容产出: sizes.txt(仅文件大小)
awk '$1=="f"{print $2}' "$ENTRIES" > "$WORKDIR/sizes.txt"

echo "Scan completed in ${SCAN_SEC}s"
echo "Per-subtree sizes -> $SUBSZ ($(wc -l < "$SUBSZ") 个顶层子树, 供 shard-plan.sh 分片)"

# ----------------------------------------------------------------------
# 第 2 步: 用 awk 一次性计算所有统计量,输出 JSON
# 包含 P50/P90/P99 分位数和大小分桶;total_dirs 由 'd' 行计数 + SRC_DIR 根目录
# ----------------------------------------------------------------------
awk -v src_dir="$SRC_DIR" -v scan_sec="$SCAN_SEC" '
$1=="f" {
    n++
    sz = $2
    total += sz
    sizes[n] = sz
    if (sz < 4096)            tiny++
    else if (sz < 1048576)    small++
    else if (sz < 104857600)  medium++
    else                      large++
    if (sz > max) max = sz
}
$1=="d" { ddirs++ }
END {
    if (n == 0) {
        print "ERROR: no files found in source directory" > "/dev/stderr"
        exit 1
    }
    total_dirs = ddirs + 1   # 各子树目录数 + SRC_DIR 根目录本身
    asort(sizes)
    # 分位数索引下界保护: 极小 n 时 int(n*q) 可能为 0,导致取到空值
    i50 = int(n*0.50); if (i50 < 1) i50 = 1; if (i50 > n) i50 = n
    i90 = int(n*0.90); if (i90 < 1) i90 = 1; if (i90 > n) i90 = n
    i99 = int(n*0.99); if (i99 < 1) i99 = 1; if (i99 > n) i99 = n
    p50 = sizes[i50]
    p90 = sizes[i90]
    p99 = sizes[i99]

    printf "{\n"
    printf "  \"source_dir\": \"%s\",\n", src_dir
    printf "  \"scan_seconds\": %d,\n", scan_sec
    printf "  \"total_files\": %d,\n", n
    printf "  \"total_dirs\": %d,\n", total_dirs
    printf "  \"total_size_bytes\": %d,\n", total
    printf "  \"avg_size_bytes\": %d,\n", total/n
    printf "  \"max_size_bytes\": %d,\n", max
    printf "  \"p50_bytes\": %d,\n", p50
    printf "  \"p90_bytes\": %d,\n", p90
    printf "  \"p99_bytes\": %d,\n", p99
    printf "  \"distribution\": {\n"
    printf "    \"tiny_lt_4KB\": %d,\n", tiny+0
    printf "    \"small_4KB_1MB\": %d,\n", small+0
    printf "    \"medium_1MB_100MB\": %d,\n", medium+0
    printf "    \"large_gt_100MB\": %d\n", large+0
    printf "  },\n"
    printf "  \"tiny_ratio\": %.4f,\n", (tiny+0)/n
    printf "  \"large_ratio\": %.4f\n", (large+0)/n
    printf "}\n"
}
' "$ENTRIES" > "$WORKDIR/profile.json"

# ----------------------------------------------------------------------
# 第 3 步: 友好输出
# ----------------------------------------------------------------------
echo ""
echo "=== Profile (saved to $WORKDIR/profile.json) ==="
cat "$WORKDIR/profile.json"
echo ""

# 人类可读摘要(用 numfmt 格式化)
if command -v numfmt >/dev/null 2>&1; then
    TOTAL=$(awk -F'[:,]' '/total_size_bytes/{gsub(/ /,"",$2);print $2}' "$WORKDIR/profile.json")
    AVG=$(awk -F'[:,]' '/avg_size_bytes/{gsub(/ /,"",$2);print $2}' "$WORKDIR/profile.json")
    MAX=$(awk -F'[:,]' '/max_size_bytes/{gsub(/ /,"",$2);print $2}' "$WORKDIR/profile.json")
    P50=$(awk -F'[:,]' '/p50_bytes/{gsub(/ /,"",$2);print $2}' "$WORKDIR/profile.json")
    P99=$(awk -F'[:,]' '/p99_bytes/{gsub(/ /,"",$2);print $2}' "$WORKDIR/profile.json")
    echo "=== Human-readable summary ==="
    printf "  Total size: %s\n" "$(numfmt --to=iec "$TOTAL")"
    printf "  Avg size:   %s\n" "$(numfmt --to=iec "$AVG")"
    printf "  P50 size:   %s\n" "$(numfmt --to=iec "$P50")"
    printf "  P99 size:   %s\n" "$(numfmt --to=iec "$P99")"
    printf "  Max size:   %s\n" "$(numfmt --to=iec "$MAX")"
fi

echo ""
echo "Next step:"
echo "  ./generate-fpsync-cmd.sh $WORKDIR/profile.json <SRC> <DST>"
