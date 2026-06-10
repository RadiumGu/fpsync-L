#!/bin/bash
# fpsync-monitor.sh - 监控 fpsync 同步进度
# 适用场景: NFS 3.0 -> NFS 4.1 大规模数据迁移 (fpsync + rsync)
# Usage: ./fpsync-monitor.sh [refresh_seconds]
#   refresh_seconds: 刷新间隔，默认 10 秒；传 0 则只输出一次快照
#
# 说明: 本脚本只读不写，不会干扰 fpsync 本身。
# 目录/日志结构依据 fpsync 官方源码 (martymac/fpart, v1.7.1):
#   queue: <tmp>/queue/<runid>/        队列里待调度的 job
#   work : <tmp>/work/<runid>/         正在运行的 job (按 part 号命名)
#   done : <tmp>/done/<runid>/         已完成的 job  <- 进度的权威来源
#   parts: <shared>/parts/<runid>/     part.N 文件列表 + part.N.meta + run.meta
#   log  : <shared>/log/<runid>/fpsync.log  主日志 (+ N.stdout/N.stderr/N.ret)
# 本地模式下 <shared> 等于 <tmp> (默认 /tmp/fpsync)。
# runid 形如 <epoch>-<pid>。

set -u

REFRESH="${1:-10}"

# ---------- 加载统一配置 fpsync.env (同目录) ----------
# 配置优先;留空项回退到默认。refresh_seconds 仍由位置参数控制(非复制配置)。
#
# 同机多实例(方案A): 每个 fpsync 实例用独立的 -t/-d 目录(由 run.sh 的
#   RUN_DIR=${RUN_DIR_BASE}/run_<ts>_<pid> 提供)。
#   - 默认(不传任何东西): 自动从 fpsync.env 的 RUN_DIR_BASE 下挑【最近一个真实 run 目录】,
#     所以单实例场景直接 `./fpsync-monitor-20260610.sh 5` 即可,无需手动指定目录。
#   - 多实例并发要盯某一个时,用 FPSYNC_DIR 指向该实例目录:
#     FPSYNC_DIR=/tmp/fpsync_runs/run_20260610_120000_12345 ./fpsync-monitor-20260610.sh 5
#   - 也可用 FPSYNC_RUNID(或第 2 个位置参数)锁定具体 run。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/fpsync.env" ] && . "$SCRIPT_DIR/fpsync.env"

# 实例定向: FPSYNC_DIR / FPSYNC_RUNID 不在 fpsync.env 中,故调用前 export 不会被覆盖
FPSYNC_DIR="${FPSYNC_DIR:-}"
TARGET_RUNID="${2:-${FPSYNC_RUNID:-}}"

# 自动发现: 未显式指定 FPSYNC_DIR 时,若 fpsync.env 配了 RUN_DIR_BASE,
# 取其下【最近一个含 parts/ 的真实 run 目录】(排除 *_dryrun),实现"读配置即可监控"。
if [ -z "$FPSYNC_DIR" ] && [ -n "${RUN_DIR_BASE:-}" ] && [ -d "${RUN_DIR_BASE:-}" ]; then
    FPSYNC_DIR=$(ls -1dt "$RUN_DIR_BASE"/*/ 2>/dev/null | while read -r d; do
        case "$d" in *_dryrun/) continue ;; esac
        [ -d "${d}parts" ] && { printf '%s\n' "${d%/}"; break; }
    done)
    FPSYNC_DIR="${FPSYNC_DIR:-}"
fi

# ---------- 配置位 (优先取 fpsync.env,留空则用默认) ----------
if [ -n "$FPSYNC_DIR" ]; then
    # 实例目录: queue/work/done/parts/log 全部在该目录下(run.sh 的 -t=-d)
    FPSYNC_TMPDIR="$FPSYNC_DIR"
    FPSYNC_SHARED_DIR="$FPSYNC_DIR"
else
    FPSYNC_TMPDIR="${FPSYNC_TMPDIR:-/tmp/fpsync}"        # fpsync -t 临时目录 (默认 /tmp/fpsync)
    FPSYNC_SHARED_DIR="${FPSYNC_SHARED_DIR:-$FPSYNC_TMPDIR}"  # fpsync -d 共享目录; 本地模式=临时目录
fi
SRC_MOUNT="${SRC_MOUNT:-${SRC_DIR:-/mnt/src}}"      # 源端挂载点; 留空回退 SRC_DIR
DST_HOST="${DST_HOST:-}"                            # 目的端 NFS/rsyncd 主机
EXPECTED_JOBS="${EXPECTED_JOBS:-${JOBS:-12}}"       # fpsync -n; 留空回退 JOBS,再退 12

# ---------- 派生路径 ----------
QUEUE_BASE="${FPSYNC_TMPDIR}/queue"
WORK_BASE="${FPSYNC_TMPDIR}/work"
DONE_BASE="${FPSYNC_TMPDIR}/done"
PARTS_BASE="${FPSYNC_SHARED_DIR}/parts"
LOG_BASE="${FPSYNC_SHARED_DIR}/log"

SELF_NAME="$(basename "$0")"

# ---------- 辅助函数 ----------
human_size() {
    # 输入字节，输出 B/K/M/G/T
    awk -v b="$1" 'BEGIN{
        split("B K M G T P", u);
        for(i=1; b>=1024 && i<6; i++) b/=1024;
        printf "%.2f%s", b, u[i]
    }'
}

print_section() {
    echo
    echo "========== $1 =========="
}

# 安全地数“某目录下符合条件的文件数”，输出永远是干净的整数
# $1 = 目录   $2.. = 额外要排除的文件名(basename)
count_files_excluding() {
    local dir="$1"; shift
    [ -d "$dir" ] || { echo 0; return; }
    local n
    n=$(find "$dir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | while read -r f; do
            local base; base="$(basename "$f")"
            local skip=0
            for ex in "$@"; do [ "$base" = "$ex" ] && skip=1 && break; done
            [ "$skip" -eq 0 ] && echo "$f"
        done | wc -l)
    echo "${n:-0}" | tr -d '[:space:]'
}

# 找出最新的 run id (按 parts 目录的 mtime)
latest_runid() {
    [ -d "$PARTS_BASE" ] || return 1
    local d
    d=$(ls -1dt "${PARTS_BASE}"/*/ 2>/dev/null | head -1) || return 1
    [ -n "$d" ] || return 1
    basename "$d"
}

# 从 run.meta 读取一个键 (total_num_parts / total_num_files / total_size)
read_run_meta() {
    local runid="$1" key="$2"
    local f="${PARTS_BASE}/${runid}/run.meta"
    [ -f "$f" ] || { echo 0; return; }
    ( eval "${key}=0"; . "$f" 2>/dev/null; eval "echo \"\${${key}}\"" ) 2>/dev/null || echo 0
}

# ---------- 主监控函数 ----------
monitor_once() {
    clear
    echo "fpsync 监控面板  $(date '+%F %T')"
    echo "源: $SRC_MOUNT  ->  目的: $DST_HOST"

    RUNID="$(latest_runid || true)"
    if [ -n "${TARGET_RUNID:-}" ]; then
        RUNID="$TARGET_RUNID"   # 锁定到指定实例的 run,避免 latest 取到别的实例
    fi
    if [ -n "${RUNID:-}" ]; then
        echo "当前 run: $RUNID"
    else
        echo "⚠️  未在 ${PARTS_BASE}/ 下找到任何 run（fpsync 可能尚未启动）"
    fi

    # ---- 1. fpsync 主进程 ----
    print_section "1. fpsync 主进程"
    # fpsync 是 /bin/sh 脚本，命令行形如 "/bin/sh /usr/bin/fpsync -n 12 ..."。
    # 用 ps + 全命令行匹配（Linux/macOS 通用），[f]psync 规避匹配到 grep 自身，
    # 再排除监控脚本本身。
    echo "PID     ELAPSED    CMD"
    FPSYNC_PROC=$(ps -eo pid=,etime=,args= 2>/dev/null \
        | grep -E '[f]psync' | grep -v "$SELF_NAME" \
        | grep -vE 'fpart |[t]ee |rsync ' || true)
    if [ -n "$FPSYNC_DIR" ]; then
        # 方案A: 只显示属于本实例目录的 fpsync 主进程(其 -t/-d 指向该目录)
        FPSYNC_PROC=$(printf '%s\n' "$FPSYNC_PROC" | grep -F -- "$FPSYNC_SHARED_DIR" || true)
    else
        # 非定向: 沿用原逻辑,排除引用 tmp 路径的子进程行
        FPSYNC_PROC=$(printf '%s\n' "$FPSYNC_PROC" | grep -v "${FPSYNC_TMPDIR}/" || true)
    fi
    if [ -n "$FPSYNC_PROC" ]; then
        echo "$FPSYNC_PROC"
    else
        echo "⚠️  未发现 fpsync 主进程（可能已结束，需查日志确认成功/失败）"
    fi

    # ---- 2. rsync 子进程并发数 ----
    print_section "2. rsync 子进程"
    # 用 -x 精确匹配进程名 rsync，路径无关，且不会数到 /bin/sh 包装进程。
    # 注意: rsync 每个传输任务通常 fork 3 个进程(generator/sender/receiver)，
    # 因此"rsync 进程数"≈ 3×并发 job 数。真正的并发度看"活跃 part 数"。
    RSYNC_PIDS=$(pgrep -x rsync 2>/dev/null || true)
    if [ -n "$RSYNC_PIDS" ]; then
        PS_RSYNC_ALL=$(ps -o pid=,etime=,args= -p "$(printf '%s' "$RSYNC_PIDS" | tr '\n' ',' | sed 's/,$//')" 2>/dev/null)
    else
        PS_RSYNC_ALL=""
    fi
    # 方案A: 锁定了 run 时,只数属于该 run 的 rsync(按 --files-from 里的 /<runid>/ 过滤),
    # 避免把同机其它 fpsync 实例的 rsync 一并算进来导致并发度失真。
    if [ -n "${RUNID:-}" ]; then
        PS_RSYNC=$(printf '%s\n' "$PS_RSYNC_ALL" | grep -F "/${RUNID}/" || true)
        SCOPE_NOTE="(本 run)"
    else
        PS_RSYNC="$PS_RSYNC_ALL"
        SCOPE_NOTE="(全机)"
    fi
    RSYNC_COUNT=$(printf '%s\n' "$PS_RSYNC" | grep -c . || true)
    [ -z "$PS_RSYNC" ] && RSYNC_COUNT=0
    if [ "$RSYNC_COUNT" -gt 0 ]; then
        ACTIVE_PARTS=$(printf '%s\n' "$PS_RSYNC" | grep -oE 'part\.[0-9]+' | sort -u | grep -c . || true)
        echo "rsync 进程数: ${RSYNC_COUNT} ${SCOPE_NOTE}   活跃 part(≈并发 job 数): ${ACTIVE_PARTS} (期望 ≈ ${EXPECTED_JOBS})"
        echo
        printf "%-7s %-10s %s\n" "PID" "ELAPSED" "PART"
        printf '%s\n' "$PS_RSYNC" | \
            awk '{
                pid=$1; etime=$2;
                part="-";
                for(i=3;i<=NF;i++){
                    if($i ~ /^--files-from=/){ p=$i; sub(/^--files-from=/,"",p); sub(/.*\//,"",p); if(p ~ /part\.[0-9]+/) part=p }
                }
                printf "%-7s %-10s %s\n", pid, etime, part
            }' | sort -k3 | head -30
    else
        echo "rsync 进程数: 0   活跃 part: 0 (期望 ≈ ${EXPECTED_JOBS})"
    fi

    # ---- 3. FPART 分区进度 ----
    print_section "3. FPART 分区写入进度"
    if [ -n "${RUNID:-}" ]; then
        # 只数 part.N，排除 part.N.meta 和 run.meta
        PART_FILES=$(ls -1 "${PARTS_BASE}/${RUNID}" 2>/dev/null | grep -cE '^part\.[0-9]+$' || true)
        META_TOTAL=$(read_run_meta "$RUNID" total_num_parts)
        # 判断 fpart 是否已爬完 (fp_done 标志出现在 queue 或 work 目录)
        if [ -f "${QUEUE_BASE}/${RUNID}/fp_done" ] || [ -f "${WORK_BASE}/${RUNID}/fp_done" ]; then
            CRAWL_STATE="已完成 (fp_done)"
        else
            CRAWL_STATE="进行中 (分区数还会增长)"
        fi
        echo "已落盘 part.N 文件: ${PART_FILES}"
        echo "run.meta 记录总分区数: ${META_TOTAL}"
        echo "FPART 爬取状态: ${CRAWL_STATE}"
    else
        echo "无 run，跳过"
    fi

    # ---- 4. QMGR 队列状态 ----
    print_section "4. QMGR 队列状态"
    if [ -n "${RUNID:-}" ]; then
        # 基于目录的权威计数（不依赖日志/verbosity）
        QUEUED=$(count_files_excluding "${QUEUE_BASE}/${RUNID}" info sl_stop fp_done)
        RUNNING=$(count_files_excluding "${WORK_BASE}/${RUNID}" fp_done)
        DONE=$(count_files_excluding "${DONE_BASE}/${RUNID}")
        echo "排队中(queue): ${QUEUED}   运行中(work): ${RUNNING}   已完成(done): ${DONE}"

        LOG_FILE="${LOG_BASE}/${RUNID}/fpsync.log"
        if [ -f "$LOG_FILE" ]; then
            echo "log: $LOG_FILE"
            echo "--- 最近 8 条 QMGR/FPART 事件 ---"
            grep -E '\[QMGR\]|\[FPART\]' "$LOG_FILE" 2>/dev/null | tail -8 || true
        else
            echo "(未找到日志文件 $LOG_FILE)"
        fi
    else
        echo "无 run，跳过"
    fi

    # ---- 5. 网络吞吐 (1s 采样) ----
    print_section "5. 网络吞吐 (1s 采样)"
    IFACE=$(ip -o -4 route get "$DST_HOST" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1); exit}}')
    if [ -n "$IFACE" ] && [ -d "/sys/class/net/$IFACE" ]; then
        RX1=$(cat "/sys/class/net/$IFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
        TX1=$(cat "/sys/class/net/$IFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
        sleep 1
        RX2=$(cat "/sys/class/net/$IFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
        TX2=$(cat "/sys/class/net/$IFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
        echo "网卡: $IFACE  ->  $DST_HOST"
        echo "  RX: $(human_size $((RX2-RX1)))/s    TX: $(human_size $((TX2-TX1)))/s"
        echo "  (注: 是该网卡全部流量，混部场景需自行扣减)"
    else
        echo "无法解析到 $DST_HOST 的出网网卡（或非 Linux 环境）"
    fi

    # ---- 6. 挂载点容量 ----
    print_section "6. 挂载点容量"
    if mountpoint -q "$SRC_MOUNT" 2>/dev/null; then
        df -h "$SRC_MOUNT" | tail -1 | awk '{printf "源 %s  used=%s/%s (%s)\n", $6, $3, $2, $5}'
    else
        echo "源挂载点 $SRC_MOUNT 未挂载或不可用"
    fi
    DST_MOUNT=$(mount 2>/dev/null | awk -v h="$DST_HOST" '$1 ~ h {print $3; exit}')
    if [ -n "$DST_MOUNT" ]; then
        df -h "$DST_MOUNT" | tail -1 | awk '{printf "目 %s  used=%s/%s (%s)\n", $6, $3, $2, $5}'
    else
        echo "目的端未以本地挂载形式存在（rsync:// 模式下属正常）"
    fi

    # ---- 7. 完成率估算 ----
    print_section "7. 进度估算"
    if [ -n "${RUNID:-}" ]; then
        # 权威进度: done 文件数 / run.meta 总分区数
        TOTAL="${META_TOTAL:-0}"
        DONE_N="${DONE:-0}"
        if [ "$TOTAL" -gt 0 ] 2>/dev/null; then
            PCT=$(awk -v f="$DONE_N" -v t="$TOTAL" 'BEGIN{printf "%.1f", f*100/t}')
            echo "已完成 ${DONE_N} / 总分区 ${TOTAL}  ≈ ${PCT}%"
            DONE_FILES=$(read_run_meta "$RUNID" total_num_files)
            DONE_SIZE=$(read_run_meta "$RUNID" total_size)
            echo "本次 run 总量: ${DONE_FILES} 文件 / $(human_size "${DONE_SIZE:-0}")"
        else
            echo "run.meta 尚未写入总量（FPART 仍在爬取），暂以已落盘分区数 ${PART_FILES:-0} 参考"
        fi
        echo "(完成以 fpsync 主进程退出 + 日志末尾 '[QMGR] Queue processed' / 'Fpsync stopped (with success)' 为准)"
    else
        echo "无 run，跳过"
    fi

    echo
    [ "$REFRESH" -gt 0 ] 2>/dev/null && echo "刷新间隔: ${REFRESH}s   按 Ctrl+C 退出"
}

# ---------- 主循环 ----------
if ! [ "$REFRESH" -ge 0 ] 2>/dev/null; then
    echo "refresh_seconds 必须是 >=0 的整数，收到: $REFRESH" >&2
    exit 1
fi

if [ "$REFRESH" -eq 0 ]; then
    monitor_once
    exit 0
fi

trap 'echo; echo "退出监控"; exit 0' INT TERM
while true; do
    monitor_once
    sleep "$REFRESH"
done
