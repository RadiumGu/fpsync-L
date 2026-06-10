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
# 第 1 步: 一次性扫描,只输出文件大小(原始字节数)
# 这是整个流程中唯一一次完整目录遍历
# ----------------------------------------------------------------------
SCAN_START=$(date +%s)
find "$SRC_DIR" -type f -printf '%s\n' > "$WORKDIR/sizes.txt"
SCAN_END=$(date +%s)
SCAN_SEC=$((SCAN_END - SCAN_START))

# 目录数(可选,单独算一次,代价小)
TOTAL_DIRS=$(find "$SRC_DIR" -type d 2>/dev/null | wc -l)

echo "Scan completed in ${SCAN_SEC}s"

# ----------------------------------------------------------------------
# 第 2 步: 用 awk 一次性计算所有统计量,输出 JSON
# 包含 P50/P90/P99 分位数和大小分桶
# ----------------------------------------------------------------------
awk -v total_dirs="$TOTAL_DIRS" -v src_dir="$SRC_DIR" -v scan_sec="$SCAN_SEC" '
{
    n++
    total += $1
    sizes[n] = $1
    if ($1 < 4096)            tiny++
    else if ($1 < 1048576)    small++
    else if ($1 < 104857600)  medium++
    else                      large++
    if ($1 > max) max = $1
}
END {
    if (n == 0) {
        print "ERROR: no files found in source directory" > "/dev/stderr"
        exit 1
    }
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
' "$WORKDIR/sizes.txt" > "$WORKDIR/profile.json"

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
