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

# ---------- 前置体检(发送端)----------
preflight() {
    local ok=1 s out miss
    local list=()
    if [ "$N" -gt 0 ]; then list=("${SND[@]}"); else list=("local"); fi
    echo "=== 前置体检(发送端)==="
    for s in "${list[@]}"; do
        if [ "$s" = "local" ] || [ "$s" = "localhost" ]; then
            local lok=1
            command -v fpsync >/dev/null 2>&1 || { echo "  ✗ local: fpsync 缺失"; lok=0; }
            [ -d "$SRC_DIR" ] || { echo "  ✗ local: 源 $SRC_DIR 不存在/未挂载"; lok=0; }
            mkdir -p "$RUN_DIR_BASE" 2>/dev/null; [ -w "$RUN_DIR_BASE" ] || { echo "  ✗ local: 运行目录 $RUN_DIR_BASE 不可写"; lok=0; }
            [ "$lok" = 1 ] && echo "  ✓ local: fpsync/源/运行目录 OK" || ok=0
        else
            out=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$s" '
                command -v fpsync >/dev/null 2>&1 && echo FP_OK
                [ -d "'"$SRC_DIR"'" ] && echo SRC_OK
                mkdir -p "'"$RUN_DIR_BASE"'" 2>/dev/null && [ -w "'"$RUN_DIR_BASE"'" ] && echo RD_OK
            ' 2>/dev/null) || { echo "  ✗ $s: SSH 不可达"; ok=0; continue; }
            miss=""
            echo "$out" | grep -q FP_OK  || miss="$miss fpsync"
            echo "$out" | grep -q SRC_OK || miss="$miss 源未挂载($SRC_DIR)"
            echo "$out" | grep -q RD_OK  || miss="$miss 运行目录不可写"
            [ -z "$miss" ] && echo "  ✓ $s: fpsync/源/运行目录 OK" || { echo "  ✗ $s:$miss"; ok=0; }
        fi
    done
    return $((1 - ok))
}

if ! preflight; then
    echo "‼ 前置体检未通过。"
    if [ "$APPLY" -eq 1 ]; then echo "  已中止 --apply,请修复后重试。" >&2; exit 1; fi
    echo "  (dry-run 继续,仅供查看)"
fi
echo ""

# ---------- 在发送端执行: 本机直接跑;远程经 ssh bash -s + heredoc(规避引号噩梦)----------
exec_on() {
    # $1=sender  $2=待建目录(空格分隔)  $3=命令(不含 RSYNC_RSH 前缀,由本函数注入)
    local sender="$1" mkdirs="$2" cmd="$3"
    if [ "$sender" = "local" ] || [ "$sender" = "localhost" ] || [ -z "$sender" ]; then
        [ -n "$RSYNC_SSH" ] && export RSYNC_RSH="$RSYNC_SSH"
        mkdir -p $mkdirs 2>/dev/null || true
        bash -c "$cmd"
    else
        ssh -o StrictHostKeyChecking=no "$sender" bash -s <<EOF
$( [ -n "$RSYNC_SSH" ] && printf 'export RSYNC_RSH=%q\n' "$RSYNC_SSH" )
mkdir -p $mkdirs 2>/dev/null || true
$cmd
EOF
    fi
}

[ "$APPLY" -eq 1 ] && echo "=== 模式: APPLY(真实传输)===" || echo "=== 模式: DRY-RUN(fpsync -p 预跑 + 打印命令;--apply 真跑)==="

while IFS=$'\t' read -r bucket bytes files rel; do
    ridx=$(( (bucket - 1) % M )); rcv="${RCV[$ridx]}"
    if [ "$N" -gt 0 ]; then sidx=$(( (bucket - 1) % N )); sender="${SND[$sidx]}"; else sender="local"; fi
    safe=$(printf '%s' "$rel" | tr -c 'A-Za-z0-9_.-' '_')
    RUN_DIR="${RUN_DIR_BASE}/shard_${STAMP}_b${bucket}_${safe}"

    if [ "$rel" = "<root-files>" ]; then
        echo "--- [组$bucket] <root-files> (顶层散文件)  发送:${sender} -> ${rcv%/}/ ---"
        echo "    (TODO-1: 顶层散文件用 rsync --files-from 传输;本批跳过)"
        continue
    fi

    SRC="${SRC_DIR%/}/$rel/"; DST="${rcv%/}/$rel/"
    echo "--- [组$bucket] $rel ($(human "$bytes")/$files 文件)  发送:${sender} -> $DST ---"

    DRY="fpsync -p -n $JOBS -f $FILES_PER_PART -s $SIZE_PER_PART -O \"$FPART_OPTS\" -t \"${RUN_DIR}_dry\" -d \"${RUN_DIR}_dry\" \"$SRC\" \"$DST\""
    REAL="nohup fpsync -n $JOBS -f $FILES_PER_PART -s $SIZE_PER_PART -O \"$FPART_OPTS\" -o \"$RSYNC_OPTS_EFF\" -t \"$RUN_DIR\" -d \"$RUN_DIR\" \"$SRC\" \"$DST\" > \"$RUN_DIR.log\" 2>&1 </dev/null &"
    PFX=""; [ -n "$RSYNC_SSH" ] && PFX="RSYNC_RSH=\"$RSYNC_SSH\" "

    if [ "$APPLY" -eq 1 ]; then
        echo "    启动(发送端 ${sender})"
        exec_on "$sender" "$RUN_DIR ${RUN_DIR}_dry" "$REAL"
    else
        echo "    预跑:"
        exec_on "$sender" "${RUN_DIR}_dry" "$DRY" 2>&1 | grep -E 'Successfully prepared|ERROR|error|denied|No such' | sed 's/^/      /' || true
        echo "    真跑命令(也可手动复制到发送端 ${sender} 执行):"
        echo "      ${PFX}$REAL"
    fi
    if [ "$sender" = "local" ] || [ "$sender" = "localhost" ]; then
        echo "    监控: FPSYNC_DIR=$RUN_DIR $SCRIPT_DIR/fpsync-monitor-20260610.sh 5"
    else
        echo "    监控: ssh $sender 'FPSYNC_DIR=$RUN_DIR <脚本目录>/fpsync-monitor-20260610.sh 5'"
    fi
done < "$ASSIGN"

echo ""
echo "分配明细: $ASSIGN"
echo "汇总进度(一屏看所有分片): $SCRIPT_DIR/shard-monitor.sh 5"
[ "$APPLY" -eq 0 ] && echo "确认无误后真跑:  $0 $K --apply"
