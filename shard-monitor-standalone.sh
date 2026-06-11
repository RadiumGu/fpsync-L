#!/bin/bash
# shard-monitor-standalone.sh — 分片传输【汇总进度 + 各发送端网卡吞吐】监控(独立版)
#
# 与 shard-monitor.sh 功能一致,但【不依赖 fpsync.env】,完全自包含:
# 所需配置全部通过【命令行参数】或【独立环境变量 MON_*】提供(命令行优先)。
# 纯读 fpsync 的 done/parts/run.meta,零写入、零额外依赖(只用 ssh/awk/find)。
#
# ─────────────────────────── 配置项 ───────────────────────────
# 命令行参数(优先) / 对应环境变量 / 默认值:
#   --senders "<list>"     | MON_SENDERS        | "local"
#       发送机清单(空格分隔)。每项为 ssh 目标:local/localhost=本机;
#       其余直接作 ssh 目标,如 "ec2-user@10.0.1.22" 或 "10.0.1.22"。
#   --run-dir-base <path>  | MON_RUN_DIR_BASE   | "/var/log/fpsync_runs"
#       各发送机上 fpsync 的运行目录基准(shard-plan 的 RUN_DIR_BASE)。
#   --stamp <STAMP>        | MON_STAMP          | (自动取最近一批)
#       批次时间戳,对应目录名 shard_<STAMP>_*;留空=自动挑最近一批。
#   --refresh <秒>         | MON_REFRESH        | 5
#       刷新间隔;0=只出一次快照。也可作第 1 个位置参数:`... 5`。
#   --no-net               | MON_NO_NET=1       | (默认采网卡吞吐)
#       关闭"各发送端网卡吞吐"采样(省去每发送端 1s 采样)。
#   -h | --help            打印本说明
#
# 示例:
#   ./shard-monitor-standalone.sh 5
#   ./shard-monitor-standalone.sh --senders "localhost ec2-user@10.0.1.22" \
#       --run-dir-base /tmp/fpsync_runs --refresh 5
#   MON_SENDERS="localhost ec2-user@10.0.1.22" MON_RUN_DIR_BASE=/tmp/fpsync_runs \
#       ./shard-monitor-standalone.sh 0
# ----------------------------------------------------------------------

set -u

# ---------- 默认值 / 环境变量 ----------
SENDERS_STR="${MON_SENDERS:-local}"
RUN_DIR_BASE="${MON_RUN_DIR_BASE:-/var/log/fpsync_runs}"
STAMP_ARG="${MON_STAMP:-}"
REFRESH="${MON_REFRESH:-5}"
NO_NET="${MON_NO_NET:-0}"

# ---------- 命令行解析(优先于环境变量)----------
print_help() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --senders)      SENDERS_STR="$2"; shift 2 ;;
        --run-dir-base) RUN_DIR_BASE="$2"; shift 2 ;;
        --stamp)        STAMP_ARG="$2"; shift 2 ;;
        --refresh)      REFRESH="$2"; shift 2 ;;
        --no-net)       NO_NET=1; shift ;;
        -h|--help)      print_help; exit 0 ;;
        ''|*[!0-9]*)    echo "未知参数: $1" >&2; exit 1 ;;
        *)              REFRESH="$1"; shift ;;   # 裸数字 = 刷新间隔
    esac
done

read -ra SND <<< "$SENDERS_STR"
[ "${#SND[@]}" -eq 0 ] && SND=(local)

human() { awk -v b="$1" 'BEGIN{split("B K M G T P",u);for(i=1;b>=1024&&i<6;i++)b/=1024;printf "%.1f%s",b,u[i]}'; }

# 采样某发送端主网卡 1s 吞吐: "iface tx_bytes_per_s rx_bytes_per_s"
net_rate() {
    local sender="$1"
    if [ "$sender" = "local" ] || [ "$sender" = "localhost" ]; then
        bash -s <<'NETEOF'
ifc=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
[ -z "$ifc" ] && ifc=$(ls /sys/class/net 2>/dev/null | grep -vx lo | head -1)
[ -z "$ifc" ] && { echo "- 0 0"; exit 0; }
t1=$(cat /sys/class/net/$ifc/statistics/tx_bytes 2>/dev/null); r1=$(cat /sys/class/net/$ifc/statistics/rx_bytes 2>/dev/null)
sleep 1
t2=$(cat /sys/class/net/$ifc/statistics/tx_bytes 2>/dev/null); r2=$(cat /sys/class/net/$ifc/statistics/rx_bytes 2>/dev/null)
echo "$ifc $((t2-t1)) $((r2-r1))"
NETEOF
    else
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=6 "$sender" bash -s <<'NETEOF' 2>/dev/null
ifc=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
[ -z "$ifc" ] && ifc=$(ls /sys/class/net 2>/dev/null | grep -vx lo | head -1)
[ -z "$ifc" ] && { echo "- 0 0"; exit 0; }
t1=$(cat /sys/class/net/$ifc/statistics/tx_bytes 2>/dev/null); r1=$(cat /sys/class/net/$ifc/statistics/rx_bytes 2>/dev/null)
sleep 1
t2=$(cat /sys/class/net/$ifc/statistics/tx_bytes 2>/dev/null); r2=$(cat /sys/class/net/$ifc/statistics/rx_bytes 2>/dev/null)
echo "$ifc $((t2-t1)) $((r2-r1))"
NETEOF
    fi
}

# 在某发送端收集分片进度: 每行 "label<TAB>total<TAB>done<TAB>work"
collect() {
    local sender="$1" stamp="$2"
    local script='RDB="'"$RUN_DIR_BASE"'"; STAMP="'"$stamp"'"
        for rd in "$RDB"/shard_${STAMP}_*; do
            case "$rd" in *_dry) continue ;; esac
            [ -d "$rd" ] || continue
            pd=$(ls -1dt "$rd"/parts/*/ 2>/dev/null | head -1); [ -n "$pd" ] || continue
            runid=$(basename "$pd")
            total=$( ( total_num_parts=0; . "$rd/parts/$runid/run.meta" 2>/dev/null; echo "${total_num_parts:-0}" ) )
            done=$(find "$rd/done/$runid" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l)
            work=$(find "$rd/work/$runid" -mindepth 1 -maxdepth 1 -type f ! -name fp_done 2>/dev/null | wc -l)
            printf "%s\t%s\t%s\t%s\n" "$(basename "$rd")" "${total:-0}" "${done:-0}" "${work:-0}"
        done'
    if [ "$sender" = "local" ] || [ "$sender" = "localhost" ]; then
        bash -c "$script"
    else
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=6 "$sender" "bash -c '$script'" 2>/dev/null
    fi
}

# 自动取最近批次 STAMP(从第一个发送端探测)
detect_stamp() {
    local s="$1"
    local sc='RDB="'"$RUN_DIR_BASE"'"; ls -1d "$RDB"/shard_*/ 2>/dev/null | sed -nE "s#.*/shard_([0-9]{8}_[0-9]{6})_.*#\1#p" | sort -u | tail -1'
    if [ "$s" = "local" ] || [ "$s" = "localhost" ]; then bash -c "$sc"; else
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=6 "$s" "bash -c '$sc'" 2>/dev/null; fi
}

snapshot() {
    clear 2>/dev/null || true
    local stamp="$STAMP_ARG"
    [ -z "$stamp" ] && stamp="$(detect_stamp "${SND[0]}")"
    echo "fpsync 分片汇总监控(独立版)  $(date '+%F %T')"
    if [ -z "$stamp" ]; then
        echo "⚠️  未发现分片批次(${RUN_DIR_BASE}/shard_* 为空,或发送端不可达)"
        return
    fi
    echo "批次: $stamp   发送端: ${SND[*]}   运行目录基准: $RUN_DIR_BASE"
    echo "------------------------------------------------------------------"
    printf "%-26s %-20s %-12s %-6s %s\n" "分片" "发送端" "done/total" "%" "work"
    local tot_done=0 tot_total=0 tot_work=0 anyrow=0
    local sender label total done work pct
    for sender in "${SND[@]}"; do
        while IFS=$'\t' read -r label total done work; do
            [ -n "${label:-}" ] || continue
            anyrow=1
            label="${label#shard_${stamp}_}"
            pct=$(awk -v d="${done:-0}" -v t="${total:-0}" 'BEGIN{printf "%s", (t>0)?sprintf("%.0f",d*100/t):"-"}')
            printf "%-26s %-20s %-12s %-6s %s\n" "$label" "$sender" "${done:-0}/${total:-0}" "$pct" "${work:-0}"
            tot_done=$((tot_done + ${done:-0})); tot_total=$((tot_total + ${total:-0})); tot_work=$((tot_work + ${work:-0}))
        done < <(collect "$sender" "$stamp")
    done
    echo "------------------------------------------------------------------"
    if [ "$anyrow" -eq 0 ]; then
        echo "(本批次暂无可读分区数据;FPART 仍在爬取或任务未启动)"; return
    fi
    local apct; apct=$(awk -v d="$tot_done" -v t="$tot_total" 'BEGIN{printf "%s",(t>0)?sprintf("%.1f",d*100/t):"-"}')
    echo "合计: ${tot_done}/${tot_total} 分区  ≈ ${apct}%   活跃 work 合计: ${tot_work}"
    if [ "$NO_NET" != "1" ]; then
        echo "------------------------------------------------------------------"
        echo "网络吞吐(各发送端, 1s 采样):"
        printf "%-20s %-8s %-12s %s\n" "发送端" "网卡" "TX/s↑" "RX/s"
        local s ifc tx rx
        for s in "${SND[@]}"; do
            read -r ifc tx rx < <(net_rate "$s")
            printf "%-20s %-8s %-12s %s\n" "$s" "${ifc:--}" "$(human "${tx:-0}")/s" "$(human "${rx:-0}")/s"
        done
    fi
    echo "(完成以各分片 fpsync 主进程退出 + 日志 'Fpsync stopped (with success)' 为准)"
}

# ---------- 主循环 ----------
if ! [ "$REFRESH" -ge 0 ] 2>/dev/null; then
    echo "refresh 必须是 >=0 的整数,收到: $REFRESH" >&2; exit 1
fi
if [ "$REFRESH" -eq 0 ]; then snapshot; exit 0; fi
trap 'echo; echo "退出汇总监控"; exit 0' INT TERM
while true; do
    snapshot
    echo; echo "刷新间隔: ${REFRESH}s   Ctrl+C 退出"
    sleep "$REFRESH"
done
