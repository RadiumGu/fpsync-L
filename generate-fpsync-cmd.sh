#!/bin/bash
# generate-fpsync-cmd.sh
# 根据 source-profile.sh 生成的画像,推导出最优的 fpsync 命令
#
# 用法:
#   ./generate-fpsync-cmd.sh <PROFILE_JSON> <SRC_DIR> <DST_DIR>
# 示例:
#   ./generate-fpsync-cmd.sh /tmp/fpsync_profile/profile.json /mnt/source/ /mnt/efs-target/
#
# 输出:
#   - 详细分析与决策依据
#   - 可直接执行的 fpsync 命令(stdout)
#   - <WORKDIR>/run.sh 可执行脚本

set -euo pipefail

# ----------------------------------------------------------------------
# 加载统一配置 fpsync.env (同目录)。配置优先,位置参数仅在配置留空时回退。
# ----------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FPSYNC_ENV="$SCRIPT_DIR/fpsync.env"
[ -f "$FPSYNC_ENV" ] && . "$FPSYNC_ENV"

# 路径类: 配置优先,位置参数回退
WORKDIR="${WORKDIR:-/tmp/fpsync_profile}"
PROFILE="${PROFILE_JSON:-${1:-$WORKDIR/profile.json}}"
SRC="${SRC_DIR:-${2:-/mnt/source/}}"
DST="${DST_DIR:-${3:-/mnt/efs-target/}}"

# 调优参数: 先把配置里的"覆盖值"存下来(可能为空)。
# 非空 => 用作覆盖,跳过对应自动推导;空 => 走自动推导,稍后回写。
JOBS_OVERRIDE="${JOBS:-}"
FILES_PER_PART_OVERRIDE="${FILES_PER_PART:-}"
SIZE_PER_PART_OVERRIDE="${SIZE_PER_PART:-}"
RSYNC_OPTS_OVERRIDE="${RSYNC_OPTS:-}"
FPART_OPTS_OVERRIDE="${FPART_OPTS:-}"

if [ -z "$PROFILE" ] || [ ! -f "$PROFILE" ]; then
    echo "Usage: $0 <PROFILE_JSON> <SRC_DIR> <DST_DIR>" >&2
    echo "  (或在 $FPSYNC_ENV 中设置 PROFILE_JSON / SRC_DIR / DST_DIR)" >&2
    echo "Run source-profile.sh first to generate the profile." >&2
    exit 1
fi

# run.sh 与回写都基于 profile 所在目录
WORKDIR=$(dirname "$PROFILE")

# ----------------------------------------------------------------------
# 第 1 步: 解析 profile.json (用 awk,无需 jq)
# ----------------------------------------------------------------------
parse_field() {
    local field=$1
    awk -F'[:,]' -v f="$field" '
        $0 ~ "\""f"\"" {
            gsub(/[ ",{}]/,"",$2)
            print $2
            exit
        }
    ' "$PROFILE"
}

TOTAL_FILES=$(parse_field "total_files")
TOTAL_SIZE=$(parse_field "total_size_bytes")
AVG_SIZE=$(parse_field "avg_size_bytes")
P50=$(parse_field "p50_bytes")
P90=$(parse_field "p90_bytes")
P99=$(parse_field "p99_bytes")
MAX_SIZE=$(parse_field "max_size_bytes")
TINY_COUNT=$(awk -F'[:,]' '/tiny_lt_4KB/{gsub(/[ ",{}]/,"",$2);print $2; exit}' "$PROFILE")
LARGE_COUNT=$(awk -F'[:,]' '/large_gt_100MB/{gsub(/[ ",{}]/,"",$2);print $2; exit}' "$PROFILE")
TINY_RATIO=$(parse_field "tiny_ratio")

# 健壮性检查 (数值安全: 空值/非数字/0 都判为无效)
if ! [ "${TOTAL_FILES:-0}" -gt 0 ] 2>/dev/null; then
    echo "ERROR: invalid or empty profile (total_files=${TOTAL_FILES:-unset})" >&2
    echo "Hint: profile.json 应由 source-profile.sh 生成,请勿手工编辑破坏格式" >&2
    exit 1
fi

CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# 用 awk 做浮点比较(避免 bc 依赖)
fcmp_gt() { awk "BEGIN{exit !($1 > $2)}"; }

# ----------------------------------------------------------------------
# 第 2 步: 决策逻辑
# ----------------------------------------------------------------------
echo "================================================================"
echo "  FPSYNC PARAMETER GENERATOR"
echo "================================================================"
echo ""
echo "=== Source Profile ==="
printf "  Total files:    %s\n" "$TOTAL_FILES"
if command -v numfmt >/dev/null 2>&1; then
    printf "  Total size:     %s\n" "$(numfmt --to=iec "$TOTAL_SIZE")"
    printf "  Avg file size:  %s\n" "$(numfmt --to=iec "$AVG_SIZE")"
    printf "  P50 size:       %s\n" "$(numfmt --to=iec "$P50")"
    printf "  P99 size:       %s\n" "$(numfmt --to=iec "$P99")"
    printf "  Max size:       %s\n" "$(numfmt --to=iec "$MAX_SIZE")"
else
    printf "  Total size:     %s bytes\n" "$TOTAL_SIZE"
    printf "  Avg file size:  %s bytes\n" "$AVG_SIZE"
    printf "  P99 size:       %s bytes\n" "$P99"
fi
printf "  Tiny ratio:     %s\n" "$TINY_RATIO"
printf "  Large count:    %s\n" "$LARGE_COUNT"
printf "  CPU cores:      %s\n" "$CORES"
echo ""

# === 决策 1: 并发数 -n ===
# EFS NFS nconnect 上限 16,fpsync 并发超过此值收益递减
echo "=== Decision Process ==="

if fcmp_gt "$TINY_RATIO" "0.7"; then
    SCENARIO="tiny-files-dominant"
    JOBS=$((CORES * 2))
    [ $JOBS -gt 16 ] && JOBS=16
    REASONING="tiny files dominate; metadata IOPS is bottleneck, raise concurrency (cap 16 for EFS nconnect)"
elif [ "$LARGE_COUNT" -gt 100 ]; then
    SCENARIO="large-files-dominant"
    JOBS=$CORES
    [ $JOBS -gt 8 ] && JOBS=8
    REASONING="many large files; bandwidth-bound, moderate concurrency to avoid contention"
else
    SCENARIO="mixed"
    JOBS=$((CORES + CORES / 2))
    [ $JOBS -gt 16 ] && JOBS=16
    REASONING="mixed workload; balanced concurrency"
fi
if [ -n "$JOBS_OVERRIDE" ]; then
    JOBS="$JOBS_OVERRIDE"
    REASONING="overridden by fpsync.env (JOBS)"
fi
echo "  [-n] $JOBS  ($REASONING)"

# === 决策 2: 每分区文件数 -f ===
# 关键修正: 小文件场景应该【减小】-f,让多个 rsync 并行分担 IOPS
# 而不是塞一大堆给单个 rsync 串行处理
if fcmp_gt "$TINY_RATIO" "0.7"; then
    FILES_PER_PART=1000
    F_REASONING="small partitions => more parallelism for IOPS-bound workload"
elif [ "$P99" -gt 1073741824 ]; then
    # P99 > 1GB
    FILES_PER_PART=200
    F_REASONING="large files => few files per partition, balance load"
else
    FILES_PER_PART=2000
    F_REASONING="default for mixed workload"
fi
if [ -n "$FILES_PER_PART_OVERRIDE" ]; then
    FILES_PER_PART="$FILES_PER_PART_OVERRIDE"
    F_REASONING="overridden by fpsync.env (FILES_PER_PART)"
fi
echo "  [-f] $FILES_PER_PART  ($F_REASONING)"

# === 决策 3: 每分区字节数 -s ===
# 用 P99 而非 AVG 判断,避免长尾大文件影响
if [ "$P99" -gt 5368709120 ]; then
    # P99 > 5GB
    SIZE_PER_PART="20g"
    S_REASONING="P99>5GB, enlarge partition to keep big files together"
elif [ "$AVG_SIZE" -lt 65536 ]; then
    # AVG < 64KB
    SIZE_PER_PART="512m"
    S_REASONING="tiny files, small partition by size"
else
    SIZE_PER_PART="4g"
    S_REASONING="default 4GB"
fi
if [ -n "$SIZE_PER_PART_OVERRIDE" ]; then
    SIZE_PER_PART="$SIZE_PER_PART_OVERRIDE"
    S_REASONING="overridden by fpsync.env (SIZE_PER_PART)"
fi
echo "  [-s] $SIZE_PER_PART  ($S_REASONING)"

# === 决策 4: rsync 选项 ===
RSYNC_OPTS="-lptgoD --numeric-ids --inplace"
if fcmp_gt "$TINY_RATIO" "0.7"; then
    RSYNC_OPTS="$RSYNC_OPTS --whole-file"
fi
if [ "$P99" -gt 1073741824 ]; then
    RSYNC_OPTS="$RSYNC_OPTS --sparse"
fi
# 跨云/远程检测: DST 为 user@host:/path 或配置了 RSYNC_SSH 时,加入续传/超时保护
REMOTE_PUSH=0
case "$DST" in *:*) REMOTE_PUSH=1 ;; esac
[ -n "${RSYNC_SSH:-}" ] && REMOTE_PUSH=1
if [ "$REMOTE_PUSH" -eq 1 ]; then
    RSYNC_OPTS="$RSYNC_OPTS --partial --timeout=600"
fi
if [ -n "$RSYNC_OPTS_OVERRIDE" ]; then
    RSYNC_OPTS="$RSYNC_OPTS_OVERRIDE"
    echo "  [-o rsync_opts] $RSYNC_OPTS  (overridden by fpsync.env)"
else
    echo "  [-o rsync_opts] $RSYNC_OPTS"
fi
if [ "$REMOTE_PUSH" -eq 1 ]; then
    echo "  [远程模式] DST 为远程或已设 RSYNC_SSH: rsync 经 SSH 推送(RSYNC_RSH),已加 --partial --timeout"
    [ -n "${BWLIMIT:-}" ] && echo "             限速: --bwlimit=$BWLIMIT (运行时追加)"
fi

# === 决策 5: fpart 选项 (-O) ===
# 重要: fpsync 内部调用 fpart 时【始终】自动加 -L (live mode)，无需也不应通过 -O 再传 -L。
# 而 -O 会【覆盖】fpsync 默认的 fpart 排除项，因此这里显式传回默认排除项以免丢失，
# 同时保留 live mode(由 fpsync 自动启用)。
FPART_OPTS="-x|.zfs|-x|.snapshot*|-x|.ckpt"
if [ -n "$FPART_OPTS_OVERRIDE" ]; then
    FPART_OPTS="$FPART_OPTS_OVERRIDE"
    echo "  [-O fpart_opts] $FPART_OPTS  (overridden by fpsync.env)"
else
    echo "  [-O fpart_opts] $FPART_OPTS  (保留默认排除项; live mode 由 fpsync 自动启用 -L)"
fi

# === 决策 6: 工作目录 ===
# RUN_DIR_BASE 来自 fpsync.env(稳定基准);run.sh 运行时拼 时间戳+PID,
# 既便于反复增量审计,又能让同机多实例互不撞名(方案A 实例隔离)。
RUN_DIR_BASE="${RUN_DIR_BASE:-/var/log/fpsync_runs}"
echo "  [-d/-t workdir] ${RUN_DIR_BASE}/run_<时间戳>_<PID>  (每实例独立 -t/-d)"
echo ""

# 仅用于下方 stdout 的示例展示;真实 RUN_DIR 由 run.sh 运行时拼接(含 PID)
RUN_DIR="${RUN_DIR_BASE}/run_$(date +%Y%m%d_%H%M%S)_$$"

# ----------------------------------------------------------------------
# 第 2.5 步: 把最终调优值回写到 fpsync.env (唯一真相源)
# 仅更新这 5 个 KEY,保留其余内容与行内注释;幂等;先备份 .bak。
# ----------------------------------------------------------------------
writeback_env() {
    local envfile="$1"
    [ -f "$envfile" ] || { echo "  [writeback] 跳过(未找到 $envfile)"; return 0; }
    cp -f "$envfile" "${envfile}.bak"
    local tmp; tmp="$(mktemp)"
    WB_JOBS="$JOBS" \
    WB_FILES_PER_PART="$FILES_PER_PART" \
    WB_SIZE_PER_PART="$SIZE_PER_PART" \
    WB_RSYNC_OPTS="$RSYNC_OPTS" \
    WB_FPART_OPTS="$FPART_OPTS" \
    awk '
    BEGIN {
        n = split("JOBS FILES_PER_PART SIZE_PER_PART RSYNC_OPTS FPART_OPTS", ks, " ")
        for (i=1;i<=n;i++) want[ks[i]] = 1
    }
    {
        line = $0; matched = 0
        for (k in want) {
            if (line ~ ("^[ \t]*" k "=")) {
                cmt = ""
                if (match(line, /#.*$/)) cmt = substr(line, RSTART)
                nl = k "=\"" ENVIRON["WB_" k] "\""
                if (cmt != "") nl = nl "   " cmt
                print nl
                seen[k] = 1; matched = 1
                break
            }
        }
        if (!matched) print line
    }
    END {
        for (i=1;i<=n;i++) if (!(ks[i] in seen)) print ks[i] "=\"" ENVIRON["WB_" ks[i]] "\""
    }
    ' "$envfile" > "$tmp" && mv -f "$tmp" "$envfile"
    echo "  [writeback] 已回写调优值到 $envfile (备份: ${envfile}.bak)"
}
writeback_env "$FPSYNC_ENV"
echo ""

# ----------------------------------------------------------------------
# 第 3 步: 生成可执行脚本 (run.sh 从 fpsync.env 取值; 每实例独立 -t/-d)
# ----------------------------------------------------------------------
RUN_SCRIPT="$WORKDIR/run.sh"
{
# --- 动态头部(生成时注入: 时间戳/画像/场景/配置文件绝对路径) ---
cat <<EOF
#!/bin/bash
# Auto-generated fpsync command
# Generated at: $(date)
# Profile: $PROFILE
# Scenario: $SCENARIO
# 说明: 本脚本从统一配置 fpsync.env 读取全部参数(单一真相源)。
#       改 fpsync.env 后重跑本脚本即可生效,无需重新 generate。
#       每次运行用 时间戳+PID 的独立 -t/-d 目录: 同机多实例并发互不撞名。

set -euo pipefail

FPSYNC_ENV="$FPSYNC_ENV"
EOF
# --- 静态主体(运行时才求值: 这里的 \$ 引用在 run.sh 执行时解析) ---
cat <<'EOF'
if [ ! -f "$FPSYNC_ENV" ]; then
    echo "ERROR: 配置文件不存在: $FPSYNC_ENV" >&2
    exit 1
fi
. "$FPSYNC_ENV"

# 必需参数(缺失即报错,提示先跑 generate 回写)
SRC="${SRC_DIR:?SRC_DIR 未在 fpsync.env 设置}"
DST="${DST_DIR:?DST_DIR 未在 fpsync.env 设置}"
JOBS="${JOBS:?JOBS 未设置(先跑 generate-fpsync-cmd.sh 回写调优值)}"
FILES_PER_PART="${FILES_PER_PART:?FILES_PER_PART 未设置}"
SIZE_PER_PART="${SIZE_PER_PART:?SIZE_PER_PART 未设置}"
RSYNC_OPTS="${RSYNC_OPTS:?RSYNC_OPTS 未设置}"
FPART_OPTS="${FPART_OPTS:?FPART_OPTS 未设置}"
RUN_DIR_BASE="${RUN_DIR_BASE:-/var/log/fpsync_runs}"

# 跨云/远程: 配置了 RSYNC_SSH 则 rsync 经该 SSH 命令传输(RSYNC_RSH);
# 配置了 BWLIMIT 则限速。两者留空 = 本地模式,行为不变。
RSYNC_SSH="${RSYNC_SSH:-}"
BWLIMIT="${BWLIMIT:-}"
RSYNC_OPTS_EFF="$RSYNC_OPTS"
[ -n "$BWLIMIT" ] && RSYNC_OPTS_EFF="$RSYNC_OPTS_EFF --bwlimit=$BWLIMIT"
[ -n "$RSYNC_SSH" ] && export RSYNC_RSH="$RSYNC_SSH"
SSH_PREFIX=""
[ -n "$RSYNC_SSH" ] && SSH_PREFIX="RSYNC_RSH=\"$RSYNC_SSH\" "

# 时间戳+PID 子目录: 同机多实例/同秒启动也不撞名;-t 与 -d 同指本目录,
# queue/work/done/parts/log 全部隔离在本实例下,监控可按目录定向(方案A)。
RUN_DIR="${RUN_DIR_BASE}/run_$(date +%Y%m%d_%H%M%S)_$$"

mkdir -p "$RUN_DIR"

echo "=== Dry-run first: just generate partitions (prepare mode -p) ==="
fpsync -p \
    -n "$JOBS" \
    -f "$FILES_PER_PART" \
    -s "$SIZE_PER_PART" \
    -O "$FPART_OPTS" \
    -t "${RUN_DIR}_dryrun" \
    -d "${RUN_DIR}_dryrun" \
    "$SRC" "$DST"

echo ""
echo "=== Partition count generated above. Review then run actual transfer. ==="
echo "To execute the real transfer, run the command below (writes to DST):"
[ -n "$RSYNC_SSH" ] && echo "(远程模式: 经 SSH 推送; 命令已自带 RSYNC_RSH)"
echo ""
cat <<CMD
${SSH_PREFIX}nohup fpsync \\
    -n $JOBS \\
    -f $FILES_PER_PART \\
    -s $SIZE_PER_PART \\
    -O "$FPART_OPTS" \\
    -o "$RSYNC_OPTS_EFF" \\
    -t "$RUN_DIR" \\
    -d "$RUN_DIR" \\
    "$SRC" "$DST" \\
    > "$RUN_DIR.log" 2>&1 &
CMD

echo ""
echo "Monitor (本实例; 同机多开时各监控各的, 用 FPSYNC_DIR 指向本实例目录):"
echo "  FPSYNC_DIR=$RUN_DIR $(dirname "$FPSYNC_ENV")/fpsync-monitor-20260610.sh 5"
echo "  tail -f $RUN_DIR.log"
echo "  ls $RUN_DIR/log/    # per-worker rsync logs"
EOF
} > "$RUN_SCRIPT"
chmod +x "$RUN_SCRIPT"

# ----------------------------------------------------------------------
# 第 4 步: 输出最终命令到 stdout
# ----------------------------------------------------------------------
echo "================================================================"
echo "  GENERATED FPSYNC COMMAND"
echo "================================================================"
cat <<EOF

# === Recommended command ===
fpsync \\
    -n ${JOBS} \\
    -f ${FILES_PER_PART} \\
    -s ${SIZE_PER_PART} \\
    -O "${FPART_OPTS}" \\
    -o "${RSYNC_OPTS}" \\
    -t "${RUN_DIR}" \\
    -d "${RUN_DIR}" \\
    "${SRC}" "${DST}"

# === Suggested execution (with logging) ===
mkdir -p "${RUN_DIR}"
nohup fpsync \\
    -n ${JOBS} \\
    -f ${FILES_PER_PART} \\
    -s ${SIZE_PER_PART} \\
    -O "${FPART_OPTS}" \\
    -o "${RSYNC_OPTS}" \\
    -t "${RUN_DIR}" \\
    -d "${RUN_DIR}" \\
    "${SRC}" "${DST}" \\
    > "${RUN_DIR}.log" 2>&1 &

# === Monitoring (本实例; 同机多开各监控各的) ===
# FPSYNC_DIR=${RUN_DIR} ./fpsync-monitor-20260610.sh 5
# tail -f ${RUN_DIR}.log
# ls ${RUN_DIR}/log/                    # per-worker logs

EOF

# ----------------------------------------------------------------------
# 第 5 步: 场景特定建议
# ----------------------------------------------------------------------
echo "================================================================"
echo "  SCENARIO-SPECIFIC RECOMMENDATIONS"
echo "================================================================"

if fcmp_gt "$TINY_RATIO" "0.7"; then
    cat <<'ADV'

[!] Tiny files dominate (>70%). Metadata IOPS is the primary bottleneck.

EFS recommendations:
  - Switch to Elastic Throughput mode (or General Purpose with Provisioned IOPS)
  - Mount with: nfsvers=4.1,rsize=1048576,wsize=1048576,hard,noresvport,nconnect=16
  - Consider tar-piping for extreme small-file scenarios:
      tar -cf - -C /mnt/source . | pv | tar -xf - -C /mnt/dest

System tuning:
  ulimit -n 1048576
  sysctl -w fs.file-max=2097152
ADV
fi

if [ "$LARGE_COUNT" -gt 100 ]; then
    cat <<'ADV'

[*] Many large files detected. Bandwidth is likely the bottleneck.

Network recommendations:
  - Use ENA-enabled instance types: c5n / m5n / r5n (25-100 Gbps)
  - For multi-host parallelism: fpsync -w worker1,worker2,worker3
  - TCP tuning:
      sysctl -w net.core.rmem_max=134217728
      sysctl -w net.core.wmem_max=134217728
ADV
fi

if [ "$TOTAL_FILES" -gt 10000000 ]; then
    cat <<'ADV'

[!] Very large file count (>10M). Pay attention to:
  - Workdir disk space: /var/log needs >2GB free for partition lists
  - Memory: each rsync process consumes 100-300MB
  - Consider sharding by top-level directory and running multiple fpsync instances
ADV
fi

# === 多 worker (分布式) 建议 ===
cat <<MWADV

[+] 多 worker 分布式 (fpsync -w) —— 何时用 / 怎么用
    经 2 节点实测验证: 任务会在各 worker 间均分(本测试 12/12)。
    但【是否提速取决于瓶颈】:
      - 提速场景: 单客户端 CPU/网卡已饱和, 或 源/目的能提供 > 单机的聚合带宽
        (EFS Elastic/Provisioned、FSx for Lustre、S3 等)。
      - 不提速场景: 共享 EFS Bursting 吞吐本身是上限时, 多加节点也打同一个吞吐池
        (本次 EFS 测试 1 节点≈2 节点)。先确认瓶颈再加节点。

    分布式命令模板 (在本机生成的基础上加 -w 与共享 -d):
      fpsync -n ${JOBS} -f ${FILES_PER_PART} -s ${SIZE_PER_PART} \\
          -O "${FPART_OPTS}" -o "${RSYNC_OPTS}" \\
          -w user@node1 -w user@node2 [-w user@node3 ...] \\
          -d <共享目录: 所有节点同路径可读写, 如挂在 NFS/EFS 上> \\
          "${SRC}" "${DST}"

    关键前置 (实测踩坑):
      1) master 到每个 worker 免密 SSH; src 与 dst 在【每个】节点同路径挂载。
      2) -d 共享目录必须对【运行 rsync 的登录用户】可写: worker 上 rsync 的
         stdout/stderr 重定向以登录用户身份执行, 写不进 root 拥有的共享 log 目录。
         做法二选一: (a) 以普通用户跑、并让该用户对 dst 及共享目录可写;
                     (b) 用 -S(sudo) 跑 rsync, 但需保证共享 log 目录登录用户可写。
      3) -t 临时队列目录默认 /tmp/fpsync 留在 master 本地即可(无需共享)。
    详见 fpsync-advanced-guide.md。
MWADV

echo ""
echo "Run script saved to: $RUN_SCRIPT"
echo "Review and execute:  bash $RUN_SCRIPT"
