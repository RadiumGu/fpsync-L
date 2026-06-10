#!/bin/bash
# shard-plan.sh — 按字节均衡把源端顶层子树分成 K 组,生成/执行跨云分片传输
#
# 依赖: 先跑 source-profile.sh 生成 <WORKDIR>/subtree-sizes.tsv。
# 读取 fpsync.env: SRC_DIR / RUN_DIR_BASE / 调优参数 / RSYNC_SSH / BWLIMIT /
#                  AWS_RECEIVERS(接收端列表) / GCP_SENDERS(发送端列表,空=本机)
#
# 用法:
#   ./shard-plan.sh [K] [--apply]
#     K        分组数(留空则交互提示);例: ./shard-plan.sh 3
#     --apply  真正启动传输(默认只 dry-run: fpsync -p 预跑 + 打印命令)
#
# 设计: 1 分片(顶层子树)= 1 个 fpsync 实例(独立 -t/-d),DST 保持相对路径
#       拼到接收端 EFS 子路径;组 i -> (发送节点 i%N, 接收端 i%M),1:1 最简。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/fpsync.env" ] && . "$SCRIPT_DIR/fpsync.env"

WORKDIR="${WORKDIR:-/tmp/fpsync_profile}"
SUBSZ="$WORKDIR/subtree-sizes.tsv"
SRC_DIR="${SRC_DIR:-}"
RUN_DIR_BASE="${RUN_DIR_BASE:-/var/log/fpsync_runs}"
RSYNC_SSH="${RSYNC_SSH:-}"
BWLIMIT="${BWLIMIT:-}"
JOBS="${JOBS:-8}"
FILES_PER_PART="${FILES_PER_PART:-2000}"
SIZE_PER_PART="${SIZE_PER_PART:-4g}"
RSYNC_OPTS="${RSYNC_OPTS:--lptgoD --numeric-ids --inplace}"
FPART_OPTS="${FPART_OPTS:--x|.zfs|-x|.snapshot*|-x|.ckpt}"
AWS_RECEIVERS="${AWS_RECEIVERS:-}"
GCP_SENDERS="${GCP_SENDERS:-}"

# ---------- 参数解析 ----------
K=""
APPLY=0
for a in "$@"; do
    case "$a" in
        --apply) APPLY=1 ;;
        ''|*[!0-9]*) : ;;   # 非纯数字忽略(如 --apply)
        *) K="$a" ;;
    esac
done

# ---------- 前置检查 ----------
[ -n "$SRC_DIR" ] || { echo "ERROR: SRC_DIR 未设置(fpsync.env)" >&2; exit 1; }
[ -f "$SUBSZ" ]   || { echo "ERROR: 未找到 $SUBSZ,请先运行 ./source-profile.sh" >&2; exit 1; }
[ -n "$AWS_RECEIVERS" ] || { echo "ERROR: AWS_RECEIVERS 未设置(fpsync.env),需至少一个接收端" >&2; exit 1; }

# 接收端 / 发送端数组
read -ra RCV <<< "$AWS_RECEIVERS"
read -ra SND <<< "$GCP_SENDERS"
M=${#RCV[@]}
N=${#SND[@]}

TOTAL_BYTES=$(awk -F'\t' '{b+=$1} END{print b+0}' "$SUBSZ")
TOTAL_FILES=$(awk -F'\t' '{f+=$2} END{print f+0}' "$SUBSZ")
NSUB=$(wc -l < "$SUBSZ")

human() { awk -v b="$1" 'BEGIN{split("B K M G T P",u);for(i=1;b>=1024&&i<6;i++)b/=1024;printf "%.1f%s",b,u[i]}'; }

echo "================================================================"
echo "  分片计划 (shard-plan)"
echo "================================================================"
echo "源:        $SRC_DIR"
echo "顶层子树:  $NSUB 个,总量 $(human "$TOTAL_BYTES") / $TOTAL_FILES 文件"
echo "接收端(M): $M  -> ${RCV[*]:-(无)}"
echo "发送端(N): $([ "$N" -gt 0 ] && echo "$N -> ${SND[*]}" || echo "本机(local)")"
echo ""

# ---------- 取 K ----------
if [ -z "$K" ]; then
    if [ -t 0 ]; then
        printf "请输入分组数 K (建议 = 节点对数): "
        read -r K
    fi
fi
case "${K:-}" in ''|*[!0-9]*) echo "ERROR: 需要一个正整数 K(例: ./shard-plan.sh 3)" >&2; exit 1 ;; esac
[ "$K" -ge 1 ] || { echo "ERROR: K 必须 >= 1" >&2; exit 1; }
[ "$K" -le "$NSUB" ] || { echo "ERROR: K($K) 不能大于顶层子树数($NSUB);请减小 K 或先把大子树降层" >&2; exit 1; }

# ---------- LPT 贪心装箱(按字节;输入已按字节降序) ----------
ASSIGN="$WORKDIR/shard-assign.tsv"   # bucket \t bytes \t files \t rel
awk -F'\t' -v K="$K" '
{ b[NR]=$1; f[NR]=$2; r[NR]=$3; n=NR }
END{
    for(i=1;i<=K;i++) load[i]=0
    for(i=1;i<=n;i++){
        m=1; for(j=2;j<=K;j++) if(load[j]<load[m]) m=j
        printf "%d\t%d\t%d\t%s\n", m, b[i], f[i], r[i]
        load[m]+=b[i]
    }
}' "$SUBSZ" | sort -t"$(printf '\t')" -k1,1n > "$ASSIGN"

# ---------- 输出 manifest ----------
echo "─────────────── 分配建议 (K=$K, 按字节均衡 LPT) ───────────────"
printf "%-4s %-12s %-10s %-6s %s\n" "组" "字节" "可读" "占比%" "子树"
# 用 bash 聚合每组(便于人读)
maxb=0; minb=-1
for g in $(cut -f1 "$ASSIGN" | sort -un); do
    gb=$(awk -F'\t' -v g="$g" '$1==g{b+=$2}END{print b+0}' "$ASSIGN")
    gf=$(awk -F'\t' -v g="$g" '$1==g{f+=$3}END{print f+0}' "$ASSIGN")
    gs=$(awk -F'\t' -v g="$g" '$1==g{printf "%s%s",sep,$4; sep=","}END{print ""}' "$ASSIGN")
    pct=$(awk -v a="$gb" -v t="$TOTAL_BYTES" 'BEGIN{printf "%.0f", (t>0)?a*100/t:0}')
    printf "%-4s %-12s %-10s %-6s %s\n" "$g" "$gb" "$(human "$gb")" "$pct" "$gs"
    [ "$gb" -gt "$maxb" ] && maxb=$gb
    { [ "$minb" -lt 0 ] || [ "$gb" -lt "$minb" ]; } && minb=$gb
done

# 均衡度
if [ "${minb:-0}" -gt 0 ]; then
    ratio=$(awk -v a="$maxb" -v b="$minb" 'BEGIN{printf "%.2f", a/b}')
else
    ratio="inf"
fi
echo ""
echo "均衡度 max/min = $ratio  (越接近 1 越均衡)"

# 超大子树告警: 最大单子树 > 总量/K 则无论如何分不均
BIGB=$(head -1 "$SUBSZ" | cut -f1)
BIGR=$(head -1 "$SUBSZ" | cut -f3-)
THRESH=$(awk -v t="$TOTAL_BYTES" -v k="$K" 'BEGIN{printf "%d", t/k}')
if [ "${BIGB:-0}" -gt "$THRESH" ]; then
    echo "⚠️  超大子树: '$BIGR' = $(human "$BIGB") > 均分阈值 $(human "$THRESH")"
    echo "    单子树超过 总量/K,无法靠顶层均衡。建议: 增大 K,或对该子树降一层再分片。"
fi

# 组数与节点对数关系
PAIRS=$M; [ "$N" -gt 0 ] && [ "$N" -lt "$PAIRS" ] && PAIRS=$N
if [ "$K" -gt "$PAIRS" ]; then
    echo "ℹ️  组数 K=$K > 可用节点对数=$PAIRS: 多出的组会在同一对节点上【排队串行】(非并行)。"
fi
echo ""

# ---------- 生成每组/每子树的隔离实例命令 ----------
STAMP=$(date +%Y%m%d_%H%M%S)
RSYNC_OPTS_EFF="$RSYNC_OPTS"
[ -n "$BWLIMIT" ] && RSYNC_OPTS_EFF="$RSYNC_OPTS_EFF --bwlimit=$BWLIMIT"

[ "$APPLY" -eq 1 ] && echo "=== 模式: APPLY(真实传输)===" || echo "=== 模式: DRY-RUN(仅 fpsync -p 预跑 + 打印命令;加 --apply 真跑)==="

i=0
while IFS=$'\t' read -r bucket bytes files rel; do
    # 组 i -> 接收端/发送端 (按组号,1:1)
    ridx=$(( (bucket - 1) % M ))
    rcv="${RCV[$ridx]}"
    if [ "$N" -gt 0 ]; then sidx=$(( (bucket - 1) % N )); sender="${SND[$sidx]}"; else sender=""; fi

    safe=$(printf '%s' "$rel" | tr -c 'A-Za-z0-9_.-' '_')
    RUN_DIR="${RUN_DIR_BASE}/shard_${STAMP}_b${bucket}_${safe}"

    if [ "$rel" = "<root-files>" ]; then
        # 顶层散落文件: 用 rsync --files-from(fpart 不便处理散文件)
        SRC="$SRC_DIR"
        DST="${rcv%/}/"
        echo "--- [组$bucket] <root-files> -> $DST  (发送: ${sender:-local})  顶层散文件用 rsync --files-from ---"
        echo "    (本批先列出; 散文件清单建议: cd \"$SRC_DIR\" && find . -maxdepth 1 -type f > files.lst; rsync -a --files-from=files.lst ...)"
        continue
    fi

    SRC="${SRC_DIR%/}/$rel/"
    DST="${rcv%/}/$rel/"

    echo "--- [组$bucket] $rel  ($(human "$bytes")/$files 文件)  发送:${sender:-local} -> $DST ---"

    # dry-run: prepare(只爬源)
    DRY="fpsync -p -n $JOBS -f $FILES_PER_PART -s $SIZE_PER_PART -O \"$FPART_OPTS\" -t \"${RUN_DIR}_dry\" -d \"${RUN_DIR}_dry\" \"$SRC\" \"$DST\""
    # real: 带 RSYNC_RSH(若有)+ nohup
    PFX=""; [ -n "$RSYNC_SSH" ] && PFX="RSYNC_RSH=\"$RSYNC_SSH\" "
    REAL="${PFX}nohup fpsync -n $JOBS -f $FILES_PER_PART -s $SIZE_PER_PART -O \"$FPART_OPTS\" -o \"$RSYNC_OPTS_EFF\" -t \"$RUN_DIR\" -d \"$RUN_DIR\" \"$SRC\" \"$DST\" > \"$RUN_DIR.log\" 2>&1 &"

    run_here() {  # 在发送端(本机或 ssh)执行一条命令
        local c="$1"
        if [ -z "$sender" ] || [ "$sender" = "localhost" ]; then
            [ -n "$RSYNC_SSH" ] && export RSYNC_RSH="$RSYNC_SSH"
            mkdir -p "$RUN_DIR" "${RUN_DIR}_dry" 2>/dev/null || true
            bash -c "$c"
        else
            ssh -o StrictHostKeyChecking=no "$sender" "mkdir -p '$RUN_DIR' '${RUN_DIR}_dry'; $c"
        fi
    }

    if [ "$APPLY" -eq 1 ]; then
        echo "    启动: $REAL"
        run_here "$REAL"
    else
        echo "    预跑: $DRY"
        run_here "$DRY" 2>&1 | grep -E 'Successfully prepared|ERROR|error' | sed 's/^/      /' || true
        echo "    真跑命令(--apply 时执行 / 也可手动复制到发送端):"
        echo "      $REAL"
    fi
    echo "    监控: FPSYNC_DIR=$RUN_DIR $SCRIPT_DIR/fpsync-monitor-20260610.sh 5  $([ -n "$sender" ] && echo "(在 $sender 上)")"
    i=$((i+1))
done < "$ASSIGN"

echo ""
echo "分配明细: $ASSIGN"
[ "$APPLY" -eq 0 ] && echo "确认无误后加 --apply 真跑:  $0 $K --apply"
