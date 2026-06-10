#!/bin/bash
# fpsync-verify.sh — 用 fpsync 并发做"内容级"一致性校验 (rsync --checksum 干跑)
#
# 原理: 校验=对每个文件跑一次 rsync 比对; fpsync 把文件分区并发跑 rsync(还能多机 -w),
#       因此可用 fpsync 实现并发校验。通过 -o 把 rsync 切到 "校验模式": -c(校验和) -n(干跑) -i(列差异)。
#
# 用法:
#   ./fpsync-verify.sh <SRC/> <DST/> [JOBS] [WORKDIR] [user@host ...]
# 示例(单机):
#   ./fpsync-verify.sh /mnt/src/ /mnt/dst/ 8
# 示例(多机, WORKDIR 必须是所有节点同路径可写的共享目录):
#   ./fpsync-verify.sh /mnt/src/ /mnt/dst/ 8 /mnt/dst/.fpsync_verify ec2-user@10.1.2.140 ec2-user@10.1.2.81
#
# 退出码: 0=完全一致; 2=发现差异; 1=参数/运行错误
#
# ⚠️ 关键: 干跑模式下即使有差异 rsync 也退出 0, 所以【不能只看 fpsync 退出码】,
#         必须聚合每个分区的 stdout 日志(本脚本已自动做)。

set -u

# ----------------------------------------------------------------------
# 加载统一配置 fpsync.env (同目录)。
# 配置驱动: 若 fpsync.env 提供了 SRC_DIR + DST_DIR,则 SRC/DST/JOBS/工作目录
#           全部取自配置,【所有位置参数都视为 worker 节点】(user@host)。
# 回退兼容: 否则沿用原位置参数接口 <SRC/> <DST/> [JOBS] [WORKDIR] [user@host ...]。
# ----------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/fpsync.env" ] && . "$SCRIPT_DIR/fpsync.env"

WORKERS=()
if [ -n "${SRC_DIR:-}" ] && [ -n "${DST_DIR:-}" ]; then
    # --- 配置驱动 ---
    SRC="$SRC_DIR"
    DST="$DST_DIR"
    JOBS="${JOBS:-8}"
    WD="${RUN_DIR_BASE:-/tmp/fpsync_runs}/verify_$(date +%s)_$$"
    for w in "$@"; do WORKERS+=( -w "$w" ); done   # 位置参数 = worker 节点
else
    # --- 回退: 原位置参数接口 ---
    SRC="${1:-}"
    DST="${2:-}"
    JOBS="${3:-8}"
    WD="${4:-/tmp/fpsync_verify_$(date +%s)_$$}"
    if [ "$#" -gt 4 ]; then
        shift 4
        for w in "$@"; do WORKERS+=( -w "$w" ); done
    fi
fi

# 分区/排除项也复用配置(留空给默认),与传输阶段保持一致
FILES_PER_PART="${FILES_PER_PART:-2000}"
SIZE_PER_PART="${SIZE_PER_PART:-4g}"
FPART_OPTS="${FPART_OPTS:--x|.zfs|-x|.snapshot*|-x|.ckpt}"

if [ -z "$SRC" ] || [ -z "$DST" ]; then
    echo "Usage: $0 <SRC/> <DST/> [JOBS] [WORKDIR] [user@host ...]" >&2
    echo "  (或在 $SCRIPT_DIR/fpsync.env 中设置 SRC_DIR / DST_DIR,位置参数则全部作为 worker 节点)" >&2
    exit 1
fi

command -v fpsync >/dev/null 2>&1 || { echo "ERROR: fpsync 不在 PATH" >&2; exit 1; }

echo "================ fpsync 并发校验 ================"
echo "SRC      = $SRC"
echo "DST      = $DST"
echo "JOBS(-n) = $JOBS"
echo "WORKDIR  = $WD"
echo "WORKERS  = ${WORKERS[*]:-(本机)}"
echo "================================================="

rm -rf "$WD" 2>/dev/null
mkdir -p "$WD" || { echo "ERROR: 无法创建 WORKDIR=$WD (多机时需所有节点同路径可写)" >&2; exit 1; }

# -c 校验和比对 / -n 干跑 / -i itemize 列出差异 ; -O 保留 fpart 默认排除项
# -t 与 -d 同指 WD: 同机并发多个校验/同步时互不干扰(方案A 实例隔离)
set -x
fpsync -n "$JOBS" -f "$FILES_PER_PART" -s "$SIZE_PER_PART" \
    -o "-lptgoD --numeric-ids -c -n -i" \
    -O "$FPART_OPTS" \
    "${WORKERS[@]}" \
    -t "$WD" \
    -d "$WD" \
    "$SRC" "$DST"
FPRC=$?
set +x
echo "fpsync 退出码 = $FPRC (干跑模式下 0 仅表示任务跑完, 不代表一致)"

# ---- 聚合每个分区 stdout 的 itemize 差异行 ----
LOGDIR=$(ls -1dt "$WD"/log/*/ 2>/dev/null | head -1)
if [ -z "$LOGDIR" ]; then
    echo "ERROR: 未找到日志目录 $WD/log/*/ (校验可能未真正运行)" >&2
    exit 1
fi
echo "日志目录: $LOGDIR"

# rsync -i 只会为"有差异/需传输"的文件输出行; 完全相同的文件不输出。
# itemize 行形如:  >f..c...... path   /  cd+++++++++ dir/  /  *deleting path
DIFF_FILE="$WD/diffs.txt"
cat "$LOGDIR"/*.stdout 2>/dev/null \
    | grep -E '^(\*deleting|[<>ch.][fdLDS])' > "$DIFF_FILE" 2>/dev/null || true
N=$(wc -l < "$DIFF_FILE" 2>/dev/null | tr -d '[:space:]')
N="${N:-0}"

echo "================================================="
if [ "${N:-0}" -eq 0 ]; then
    echo "结果: ✅ 一致 (无差异)"
    echo "(差异清单为空: $DIFF_FILE)"
    exit 0
else
    echo "结果: ⚠️  发现 $N 处差异 (完整清单: $DIFF_FILE, 前 50 条如下)"
    echo "  itemize 含义: 第3位 'c'=内容/校验和不同, '>f...'=需从源拷贝, 'cd...'=目的端缺目录, '*deleting'=目的端多余"
    head -50 "$DIFF_FILE"
    exit 2
fi
