#!/bin/bash
# shard-plan.sh — 主机驱动的跨云分片传输
#   按字节把源端顶层子树均衡分成 K 组(默认 K = 节点对数),1:1 配对到
#   (发送机, 接收机);每发送机一次只跑一个 fpsync(组内子树串行),发送机之间并行。
#
# 依赖: 先跑 source-profile.sh 生成 <WORKDIR>/subtree-sizes.tsv。
# 读 fpsync.env:
#   SRC_DIR / RUN_DIR_BASE / 调优参数(JOBS/.../FPART_OPTS) / RSYNC_SSH / BWLIMIT
#   SSH_USER     两端统一登录用户
#   DST_BASE     接收端 EFS 本地挂载路径(各接收端一致)
#   GCP_SENDERS  发送机清单(只填 IP/主机名;localhost=控制机本身;或完整 user@host)
#   AWS_RECEIVERS 接收机清单(只填 IP;或完整 user@host:/path);与发送机【等长 1:1】
#
# 用法:
#   ./shard-plan.sh [K] [--apply]
#     K        分组数;留空 = 自动 = 节点对数
#     --apply  真正启动传输(默认 dry-run: 预跑 fpsync -p + 打印配对/命令)

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
SSH_USER="${SSH_USER:-ec2-user}"
DST_BASE="${DST_BASE:-/mnt/dst}"
AWS_RECEIVERS="${AWS_RECEIVERS:-}"
GCP_SENDERS="${GCP_SENDERS:-}"

# ---------- 参数 ----------
K=""; APPLY=0; INCR=0
for a in "$@"; do
    case "$a" in
        --apply) APPLY=1 ;;
        --incremental|--incr) INCR=1 ;;
        ''|*[!0-9]*) : ;;
        *) K="$a" ;;
    esac
done

# ---------- 前置检查 ----------
[ -n "$SRC_DIR" ] || { echo "ERROR: SRC_DIR 未设置(fpsync.env)" >&2; exit 1; }
[ -f "$SUBSZ" ]   || { echo "ERROR: 未找到 $SUBSZ,请先运行 ./source-profile.sh" >&2; exit 1; }
[ -n "$AWS_RECEIVERS" ] || { echo "ERROR: AWS_RECEIVERS 未设置(多对模式需至少一个接收机)" >&2; exit 1; }

human() { awk -v b="$1" 'BEGIN{split("B K M G T P",u);for(i=1;b>=1024&&i<6;i++)b/=1024;printf "%.1f%s",b,u[i]}'; }

# ---------- 展开 主机清单(只填 IP -> 拼 SSH_USER / DST_BASE;兼容完整写法)----------
read -ra RCV_RAW <<< "$AWS_RECEIVERS"
read -ra SND_RAW <<< "$GCP_SENDERS"
RCV=(); for e in "${RCV_RAW[@]}"; do
    case "$e" in
        *:*) RCV+=("$e") ;;                       # 已含 host:/path
        *@*) RCV+=("$e:$DST_BASE") ;;             # 含 user@host,补 base
        *)   RCV+=("$SSH_USER@$e:$DST_BASE") ;;   # 纯 IP
    esac
done
M=${#RCV[@]}
# 发送机:留空 -> 全部 local(单控制机);否则展开
SND=()
if [ "${#SND_RAW[@]}" -eq 0 ]; then
    for ((i=0;i<M;i++)); do SND+=("local"); done
else
    for e in "${SND_RAW[@]}"; do
        case "$e" in
            localhost|local) SND+=("local") ;;
            *@*)             SND+=("$e") ;;
            *)               SND+=("$SSH_USER@$e") ;;
        esac
    done
fi
N=${#SND[@]}

# ---------- 等长校验(1:1)----------
if [ "$N" -ne "$M" ]; then
    echo "ERROR: 发送机数($N)与接收机数($M)不一致;需 1:1 等长配对。" >&2
    echo "  GCP_SENDERS=($N): ${SND[*]}" >&2
    echo "  AWS_RECEIVERS=($M): ${RCV[*]}" >&2
    exit 1
fi
P=$M   # 节点对数

TOTAL_BYTES=$(awk -F'\t' '{b+=$1} END{print b+0}' "$SUBSZ")
TOTAL_FILES=$(awk -F'\t' '{f+=$2} END{print f+0}' "$SUBSZ")
NSUB=$(wc -l < "$SUBSZ")

# ---------- K: 默认 = 对数 ----------
if [ -z "$K" ]; then K=$P; AUTOK=1; else AUTOK=0; fi
case "$K" in ''|*[!0-9]*) echo "ERROR: K 需为正整数" >&2; exit 1 ;; esac
[ "$K" -ge 1 ] || { echo "ERROR: K 必须 >= 1" >&2; exit 1; }
[ "$K" -le "$NSUB" ] || { echo "ERROR: K($K) 大于顶层子树数($NSUB);减小 K 或对大子树降层" >&2; exit 1; }

echo "================================================================"
echo "  分片计划 (shard-plan) — 主机驱动 / 1:1 配对"
echo "================================================================"
echo "源:        $SRC_DIR"
echo "顶层子树:  $NSUB 个,总量 $(human "$TOTAL_BYTES") / $TOTAL_FILES 文件"
echo "节点对数:  $P    分组 K: $K $([ "$AUTOK" = 1 ] && echo '(自动=对数)')"
echo ""

# ---------- 配对预览 ----------
echo "─────────────── 配对预览 (1:1) ───────────────"
for ((p=0;p<P;p++)); do
    printf "  对%d: 发送 %-22s ->  接收 %s\n" "$((p+1))" "${SND[$p]}" "${RCV[$p]}"
done
echo ""

# ---------- LPT 贪心装箱(按字节;输入已降序)----------
ASSIGN="$WORKDIR/shard-assign.tsv"
awk -F'\t' -v K="$K" '
{ b[NR]=$1; f[NR]=$2; r[NR]=$3; n=NR }
END{ for(i=1;i<=K;i++) load[i]=0
     for(i=1;i<=n;i++){ m=1; for(j=2;j<=K;j++) if(load[j]<load[m]) m=j
        printf "%d\t%d\t%d\t%s\n", m, b[i], f[i], r[i]; load[m]+=b[i] } }
' "$SUBSZ" | sort -t"$(printf '\t')" -k1,1n > "$ASSIGN"

# ---------- 分组 manifest + 均衡度 ----------
echo "─────────────── 分配建议 (K=$K, 按字节均衡 LPT) ───────────────"
printf "%-4s %-10s %-6s %s\n" "组" "可读" "占比%" "子树"
maxb=0; minb=-1
for g in $(cut -f1 "$ASSIGN" | sort -un); do
    gb=$(awk -F'\t' -v g="$g" '$1==g{b+=$2}END{print b+0}' "$ASSIGN")
    gs=$(awk -F'\t' -v g="$g" '$1==g{printf "%s%s",sep,$4; sep=","}END{print ""}' "$ASSIGN")
    pct=$(awk -v a="$gb" -v t="$TOTAL_BYTES" 'BEGIN{printf "%.0f",(t>0)?a*100/t:0}')
    printf "%-4s %-10s %-6s %s\n" "$g" "$(human "$gb")" "$pct" "$gs"
    [ "$gb" -gt "$maxb" ] && maxb=$gb
    { [ "$minb" -lt 0 ] || [ "$gb" -lt "$minb" ]; } && minb=$gb
done
if [ "${minb:-0}" -gt 0 ]; then ratio=$(awk -v a="$maxb" -v b="$minb" 'BEGIN{printf "%.2f",a/b}'); else ratio="inf"; fi
echo ""
echo "均衡度 max/min = $ratio  (越接近 1 越均衡)"
BIGB=$(head -1 "$SUBSZ" | cut -f1); BIGR=$(head -1 "$SUBSZ" | cut -f3-)
THRESH=$(awk -v t="$TOTAL_BYTES" -v k="$K" 'BEGIN{printf "%d",t/k}')
[ "${BIGB:-0}" -gt "$THRESH" ] && {
    echo "⚠️  超大子树: '$BIGR' = $(human "$BIGB") > 均分阈值 $(human "$THRESH");建议增大 K 或对其降层。"; }
[ "$K" -gt "$P" ] && echo "ℹ️  K=$K > 对数 $P: 多出的组排队到同一对(同发送机上串行)。"
[ "$K" -lt "$P" ] && echo "ℹ️  K=$K < 对数 $P: 有 $((P-K)) 对节点本次空闲。"
echo ""

# ---------- 前置体检 ----------
STAMP=$(date +%Y%m%d_%H%M%S)
RSYNC_OPTS_EFF="$RSYNC_OPTS"; [ -n "$BWLIMIT" ] && RSYNC_OPTS_EFF="$RSYNC_OPTS_EFF --bwlimit=$BWLIMIT"
if [ "$INCR" -eq 1 ]; then
    case " $RSYNC_OPTS_EFF " in *" --update "*) : ;; *) RSYNC_OPTS_EFF="$RSYNC_OPTS_EFF --update" ;; esac
    case " $RSYNC_OPTS_EFF " in *" --partial "*) : ;; *) RSYNC_OPTS_EFF="$RSYNC_OPTS_EFF --partial" ;; esac
    echo "★ 增量模式: rsync --update --partial(跳过未变文件,只传新增/变化;不清目的端)"
    echo "  rsync 选项: $RSYNC_OPTS_EFF"
    echo ""
fi

ssh_run() {  # 在发送机执行一段(本机直接 / 远程 ssh);stdin 透传命令
    local sender="$1"; shift
    if [ "$sender" = "local" ]; then bash -c "$*"; else ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$sender" "$*"; fi
}

preflight() {
    local ok=1 p sender rcv rhost rbase out
    echo "=== 前置体检 ==="
    # 去重发送机做基础检查
    local seen=" "
    for ((p=0;p<P;p++)); do
        sender="${SND[$p]}"
        case "$seen" in *" $sender "*) : ;; *)
            seen="$seen$sender "
            out=$(ssh_run "$sender" 'command -v fpsync >/dev/null 2>&1 && echo FP_OK; [ -d "'"$SRC_DIR"'" ] && echo SRC_OK; mkdir -p "'"$RUN_DIR_BASE"'" 2>/dev/null && [ -w "'"$RUN_DIR_BASE"'" ] && echo RD_OK' 2>/dev/null) || { echo "  ✗ 发送 $sender: 不可达"; ok=0; continue; }
            local miss=""
            echo "$out" | grep -q FP_OK  || miss="$miss fpsync"
            echo "$out" | grep -q SRC_OK || miss="$miss 源未挂载"
            echo "$out" | grep -q RD_OK  || miss="$miss 运行目录"
            [ -z "$miss" ] && echo "  ✓ 发送 $sender: fpsync/源/运行目录 OK" || { echo "  ✗ 发送 $sender:$miss"; ok=0; }
            ;;
        esac
    done
    # 每对: 发送机 -> 接收机 的 SSH 与 DST_BASE 可写
    for ((p=0;p<P;p++)); do
        sender="${SND[$p]}"; rcv="${RCV[$p]}"
        rhost="${rcv%%:*}"; rbase="${rcv#*:}"
        out=$(ssh_run "$sender" "${RSYNC_SSH:+RSYNC_RSH='$RSYNC_SSH' }ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 $rhost 'mkdir -p \"$rbase\" 2>/dev/null && [ -w \"$rbase\" ] && echo RCV_OK'" 2>/dev/null) || { echo "  ✗ 对$((p+1)) $sender→$rhost: 推送 SSH 不通"; ok=0; continue; }
        echo "$out" | grep -q RCV_OK && echo "  ✓ 对$((p+1)) $sender→$rhost: SSH + $rbase 可写" || { echo "  ✗ 对$((p+1)) $sender→$rhost: $rbase 不可写/无法建"; ok=0; }
    done
    return $((1-ok))
}

if ! preflight; then
    echo "‼ 前置体检未通过。"
    [ "$APPLY" -eq 1 ] && { echo "  已中止 --apply,请修复后重试。" >&2; exit 1; }
    echo "  (dry-run 继续)"
fi
echo ""

# ---------- 远程执行封装(ssh bash -s heredoc,注入 RSYNC_RSH)----------
exec_bg() {  # $1=sender $2=mkdirs $3=要后台运行的命令链
    local sender="$1" mkdirs="$2" cmd="$3"
    if [ "$sender" = "local" ]; then
        [ -n "$RSYNC_SSH" ] && export RSYNC_RSH="$RSYNC_SSH"
        mkdir -p $mkdirs 2>/dev/null || true
        bash -c "nohup bash -c '$cmd' >/dev/null 2>&1 &"
    else
        ssh -o StrictHostKeyChecking=no "$sender" bash -s <<EOF
$( [ -n "$RSYNC_SSH" ] && printf 'export RSYNC_RSH=%q\n' "$RSYNC_SSH" )
mkdir -p $mkdirs 2>/dev/null || true
nohup bash -c '$cmd' >/dev/null 2>&1 &
EOF
    fi
}
exec_fg() {  # 前台执行(dry-run prepare)
    local sender="$1" mkdirs="$2" cmd="$3"
    if [ "$sender" = "local" ]; then
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

# ---------- 按发送机聚合(组内/同发送机串行)----------
declare -A SEQ MKD DRY
ORDER=()
while IFS=$'\t' read -r bucket bytes files rel; do
    [ "$rel" = "<root-files>" ] && { echo "[跳过] <root-files>(顶层散文件,见 TODO-1)"; continue; }
    pair=$(( (bucket - 1) % P ))
    sender="${SND[$pair]}"; rcvbase="${RCV[$pair]}"
    safe=$(printf '%s' "$rel" | tr -c 'A-Za-z0-9_.-' '_')
    RUN_DIR="${RUN_DIR_BASE}/shard_${STAMP}_b${bucket}_${safe}"
    SRC="${SRC_DIR%/}/$rel/"; DST="${rcvbase%/}/$rel/"
    # 先用单进程 rsync 建好目的【目录骨架】(只建目录、不传文件),消除并行 rsync
    # 同时 mkdir 同一目录的竞争(rsync 报 "File exists"/code 11 导致该分区整批失败)。
    skel="rsync -a -f\"+ */\" -f\"- *\" \"$SRC\" \"$DST\" > \"$RUN_DIR.log\" 2>&1"
    one="$skel; fpsync -n $JOBS -f $FILES_PER_PART -s $SIZE_PER_PART -O \"$FPART_OPTS\" -o \"$RSYNC_OPTS_EFF\" -t \"$RUN_DIR\" -d \"$RUN_DIR\" \"$SRC\" \"$DST\" >> \"$RUN_DIR.log\" 2>&1"
    dry="fpsync -p -n $JOBS -f $FILES_PER_PART -s $SIZE_PER_PART -O \"$FPART_OPTS\" -t \"${RUN_DIR}_dry\" -d \"${RUN_DIR}_dry\" \"$SRC\" \"$DST\""
    if [ -z "${SEQ[$sender]:-}" ]; then SEQ[$sender]="$one"; DRY[$sender]="$dry"; else SEQ[$sender]="${SEQ[$sender]}; $one"; DRY[$sender]="${DRY[$sender]}; $dry"; fi
    MKD[$sender]="${MKD[$sender]:-} $RUN_DIR ${RUN_DIR}_dry"
    case " ${ORDER[*]:-} " in *" $sender "*) : ;; *) ORDER+=("$sender") ;; esac
    echo "  [组$bucket] $rel ($(human "$bytes")/$files)  发送:$sender -> $DST"
done < "$ASSIGN"
echo ""

[ "$APPLY" -eq 1 ] && echo "=== 模式: APPLY(各发送机并行;组内串行)===" || echo "=== 模式: DRY-RUN(预跑 fpsync -p;--apply 真跑)==="
for sender in "${ORDER[@]}"; do
    if [ "$APPLY" -eq 1 ]; then
        echo "  >> 发送机 $sender 启动(其子树串行)"
        exec_bg "$sender" "${MKD[$sender]}" "${SEQ[$sender]}"
    else
        echo "  >> 发送机 $sender 预跑:"
        exec_fg "$sender" "${MKD[$sender]}" "${DRY[$sender]}" 2>&1 | grep -E 'Successfully prepared|ERROR|error|denied|No such' | sed 's/^/       /' || true
    fi
done

echo ""
echo "分配明细: $ASSIGN"
echo "汇总进度(一屏看所有分片+各发送端吞吐): $SCRIPT_DIR/shard-monitor.sh 5"
[ "$APPLY" -eq 0 ] && echo "确认无误后真跑:  $0 ${K} --apply"
