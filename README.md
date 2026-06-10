# fpsync 自动调参工具集

根据源端文件系统画像,自动生成最优的 `fpsync` 命令参数。适用于 AWS EFS、FSx、EBS、本地存储之间的批量同步场景。

---

## 工具组成

| 文件 | 作用 |
|---|---|
| `fpsync.env` | **统一配置文件**(复制相关环境变量的唯一真相源,各脚本与 run.sh 共同加载) |
| `source-profile.sh` | 扫描源端,生成 JSON 格式的文件系统画像(含 P50/P90/P99 分位数) |
| `generate-fpsync-cmd.sh` | 读取画像,推导出最优 fpsync 参数,生成可执行命令 |
| `shard-plan.sh` | 按字节均衡把源端顶层子树分成 K 组,生成/执行跨云分片传输(多组 = 多对 发送/接收节点) |
| `fpsync-verify.sh` | 用 fpsync 并发做内容级一致性校验(rsync `--checksum` 干跑),读 `fpsync.env` |
| `fpsync-data-consistency.md` | fpsync/rsync 一致性机制说明与校验/对账建议 |
| `README.md` | 本说明文档 |

设计原则:
- **一次扫描**: 整个流程只对源目录做一次完整 `find` 遍历
- **无外部依赖**: 不需要 `jq` / `bc`,只用 `awk` 完成全部计算
- **决策可解释**: 每个参数的推导依据都明确输出
- **生产安全**: 默认先 dry-run 看分区情况,确认无误再正式执行

---

## 前置条件

```bash
# 必须已安装 fpsync (来自 fpart 包)
# Amazon Linux / RHEL:
sudo yum install -y fpart

# Ubuntu / Debian:
sudo apt-get install -y fpart

# macOS (用于本机测试):
brew install fpart
```

可选依赖:
- `numfmt` (coreutils): 用于人类可读的大小输出。缺失时降级为字节数显示。

---

## 统一配置 `fpsync.env`

所有"复制相关"的环境变量集中在脚本同目录的 `fpsync.env`,作为**唯一真相源**。
`source-profile.sh`、`generate-fpsync-cmd.sh`、`fpsync-verify.sh`、`fpsync-monitor-*.sh`
以及 `generate` 生成的 `run.sh` 都会自动 `source` 它。

### 配置项

| 变量 | 含义 | 留空行为 |
|---|---|---|
| `SRC_DIR` | 源目录(扫描 + 同步源) | 回退到位置参数 |
| `DST_DIR` | 目的目录 | 回退到位置参数 |
| `WORKDIR` | 画像工作目录 | 默认 `/tmp/fpsync_profile` |
| `PROFILE_JSON` | profile.json 路径 | 默认 `${WORKDIR}/profile.json` |
| `SRC_MOUNT` | 源端挂载点(监控用) | 回退到 `SRC_DIR` |
| `DST_HOST` | 目的端 NFS/rsyncd 主机(监控网卡吞吐) | 空 |
| `FPSYNC_TMPDIR` | fpsync `-t` 临时目录 | 默认 `/tmp/fpsync` |
| `FPSYNC_SHARED_DIR` | fpsync `-d` 共享目录 | 默认 = `FPSYNC_TMPDIR` |
| `JOBS` | fpsync `-n` 并发数 | **自动推导**(generate 回写) |
| `FILES_PER_PART` | fpsync `-f` 每分区文件数 | **自动推导**(generate 回写) |
| `SIZE_PER_PART` | fpsync `-s` 每分区字节数 | **自动推导**(generate 回写) |
| `RSYNC_OPTS` | fpsync `-o` rsync 透传选项 | **自动推导**(generate 回写) |
| `FPART_OPTS` | fpsync `-O` fpart 选项/排除项 | **自动推导**(generate 回写) |
| `RUN_DIR_BASE` | 运行目录基准(见下) | 默认 `/var/log/fpsync_runs` |
| `LAST_SYNC_MARKER` | 增量基线时间戳标记 | 默认 `/var/run/fpsync_last_sync` |

### 优先级

**配置文件优先**。脚本里对每个变量套 `${VAR:-默认}` 兜底,位置参数仅在对应配置项
**留空**时作为回退。配置就绪后,各步骤无需再传位置参数。

### 调优参数:自动推导 + 回写

`JOBS/FILES_PER_PART/SIZE_PER_PART/RSYNC_OPTS/FPART_OPTS` 留空时由
`generate-fpsync-cmd.sh` 按源端画像自动推导;**推导出的最终值会回写进 `fpsync.env`**
(回写前备份 `fpsync.env.bak`,幂等)。回写后这些字段非空即变成"手动覆盖值",下次直接采用;
想恢复自动推导,把对应字段清空即可。

### 运行目录、时间戳与同机多实例隔离(方案 A)

`fpsync.env` 只存稳定的 `RUN_DIR_BASE`,**不存时间戳**。`run.sh` 每次运行动态拼接:

```bash
RUN_DIR="${RUN_DIR_BASE}/run_$(date +%Y%m%d_%H%M%S)_$$"   # 时间戳 + PID
```

并把 fpsync 的 **`-t` 与 `-d` 同时指向这个 `RUN_DIR`**,使
queue/work/done/parts/log 全部落在该实例独立目录下。带来两个好处:

1. **反复增量**:各次运行的分区清单与日志互不覆盖,便于审计。
2. **同机多实例并发**:时间戳+PID 保证不撞名,各实例的临时/共享目录完全隔离
   (例如按顶层目录分片,同机起多个 `run.sh`)。

> **监控(默认即可)**:`fpsync-monitor` 会 `source fpsync.env`,**未指定时自动挑
> `RUN_DIR_BASE` 下最近一个真实 run 目录**,所以单实例直接运行即可,无需手动指定目录:
> ```bash
> ./fpsync-monitor-20260610.sh 5        # 5 秒刷新; 自动定位最近的 run
> ```
>
> **盯某个具体实例(同机多开时)**:用 `FPSYNC_DIR` 指向该实例的 `RUN_DIR`,面板只统计该实例
> (面板 3/4/7 按该目录,面板 1 按 `-d` 路径过滤主进程,面板 2 的 rsync 按 `--files-from`
> 里的 `/<runid>/` 过滤,不会把别的实例的 rsync 混进来):
> ```bash
> FPSYNC_DIR=/tmp/fpsync_runs/run_20260610_120000_12345 ./fpsync-monitor-20260610.sh 5
> # 也可用 FPSYNC_RUNID 或第 2 个位置参数锁定具体 run
> ```
> `run.sh` 运行后会直接打印本实例对应的监控命令。

> **非 root 运行注意**:默认 `RUN_DIR_BASE=/var/log/fpsync_runs`、
> `LAST_SYNC_MARKER=/var/run/fpsync_last_sync` 需要写权限。以普通用户(如 `ec2-user`)运行时
> `/var/log`、`/var/run` 通常不可写,请改为用户可写路径,例如
> `RUN_DIR_BASE="$HOME/fpsync_runs"`、`LAST_SYNC_MARKER="$HOME/fpsync_last_sync"`。

### 配置驱动的完整流程

```bash
cd /path/to/fpsync-latest
vi fpsync.env             # 1. 至少填 SRC_DIR / DST_DIR
./source-profile.sh       # 2. 扫描(无需传参)
./generate-fpsync-cmd.sh  # 3. 生成命令 + 回写调优值
bash "$(. ./fpsync.env; echo "${WORKDIR:-/tmp/fpsync_profile}")/run.sh"   # 4. dry-run
# 5. 改并发? 直接改 fpsync.env 的 JOBS,重跑同一 run.sh 即可,无需重新 generate
```

---

## 快速使用

### 一行命令完整流程

```bash
cd /Users/glei/genai/fpsync-m

# 1. 扫描源端
./source-profile.sh /mnt/source /tmp/fpsync_profile

# 2. 生成 fpsync 命令
./generate-fpsync-cmd.sh /tmp/fpsync_profile/profile.json /mnt/source/ /mnt/efs-target/

# 3. 查看自动生成的执行脚本
cat /tmp/fpsync_profile/run.sh

# 4. (可选) 直接执行
bash /tmp/fpsync_profile/run.sh
```

### 完整工作流示例

```bash
SRC=/mnt/source
DST=/mnt/efs-target
WORKDIR=/tmp/fpsync_profile

# Step 1: 扫描(对大目录可能耗时几分钟到数十分钟)
./source-profile.sh "$SRC" "$WORKDIR"

# Step 2: 生成命令(秒级)
./generate-fpsync-cmd.sh "$WORKDIR/profile.json" "$SRC/" "$DST/"

# Step 3: 先 dry-run 看分区数
bash "$WORKDIR/run.sh"

# Step 4: 满意后正式执行(脚本中已带 nohup 模板)
# 把 run.sh 中的 nohup 块取消注释执行,或手动复制命令
```

---

## 脚本详解

### 1. `source-profile.sh`

```bash
./source-profile.sh <SRC_DIR> [WORKDIR]
```

**参数**:
- `SRC_DIR`: 源目录(必填)
- `WORKDIR`: 工作目录,默认 `/tmp/fpsync_profile`

**输出**:
- `<WORKDIR>/sizes.txt`: 每行一个文件大小(原始字节)
- `<WORKDIR>/profile.json`: 统计画像

**画像 JSON 字段**:

| 字段 | 含义 |
|---|---|
| `total_files` | 文件总数 |
| `total_dirs` | 目录总数 |
| `total_size_bytes` | 总字节数 |
| `avg_size_bytes` | 平均文件大小 |
| `p50_bytes` | 中位数文件大小 |
| `p90_bytes` | P90 文件大小 |
| `p99_bytes` | P99 文件大小(决策大文件场景的关键指标) |
| `max_size_bytes` | 最大文件大小 |
| `distribution.tiny_lt_4KB` | <4KB 的文件数 |
| `distribution.small_4KB_1MB` | 4KB-1MB |
| `distribution.medium_1MB_100MB` | 1MB-100MB |
| `distribution.large_gt_100MB` | >100MB |
| `tiny_ratio` | 小文件比例(0.0-1.0) |
| `large_ratio` | 大文件比例 |
| `scan_seconds` | 扫描耗时(秒) |

**性能特征**:
- 1000 万文件、EFS 源、c5.4xlarge: 约 5-15 分钟
- 100 万文件、EBS gp3 源、t3.large: 约 30-90 秒

### 2. `generate-fpsync-cmd.sh`

```bash
./generate-fpsync-cmd.sh <PROFILE_JSON> <SRC_DIR> <DST_DIR>
```

**参数**:
- `PROFILE_JSON`: 由 `source-profile.sh` 生成的 profile.json
- `SRC_DIR`: 源目录(会写入生成的命令中)
- `DST_DIR`: 目的目录

**输出**:
- 标准输出: 详细决策过程 + 推荐命令
- `<WORKDIR>/run.sh`: 可执行脚本

---

## 决策逻辑详解

### 参数 `-n` (并发 worker 数)

| 场景 | 取值 | 上限 | 理由 |
|---|---|---|---|
| 小文件占比 >70% | 2 × CPU 核 | 16 | metadata IOPS 瓶颈,提高并发 |
| 大文件 >100 个 | 1 × CPU 核 | 8 | 带宽瓶颈,避免争用 |
| 混合场景 | 1.5 × CPU 核 | 16 | 平衡 |

> **EFS 注意**: nconnect 上限 16,fpsync `-n` 超过此值收益递减,且可能触发 metadata 限流。

### 参数 `-f` (每分区文件数)

| 场景 | 取值 | 理由 |
|---|---|---|
| 小文件占比 >70% | 1000 | **小分区 = 高并行度**(修正了"小文件用大分区"的常见误区) |
| P99 > 1GB | 200 | 大文件分区文件少,均衡负载 |
| 混合 | 2000 | 默认 |

> **关键**: 不是文件越小分区越大。小文件场景如果 `-f` 设成 5000,单个 rsync 要串行处理 5000 个小文件,其他 worker 闲着,负载严重不均。

### 参数 `-s` (每分区字节数)

| 条件 | 取值 | 理由 |
|---|---|---|
| P99 > 5GB | 20g | 避免大文件被频繁切区 |
| AVG < 64KB | 512m | 极小文件,按 size 限制意义不大 |
| 其他 | 4g | 默认 |

> 用 P99 而非 AVG 判断,长尾大文件不会被均值掩盖。

### 参数 `-O` (fpart 选项 / 排除项)

> **重要更正**: fpsync 内部调用 fpart 时**始终自动加 `-L` (live mode)**——边扫描边派发分区、拿到一个分区就立刻派发 rsync，实现"半流式"传输。**live mode 不需要、也不应该通过 `-O "-L"` 去开启。**
>
> 而 `-O` 会**整体覆盖** fpsync 的默认 fpart 选项（默认是排除 `.zfs` / `.snapshot*` / `.ckpt`）。所以本工具用 `-O` 显式传回这些默认排除项，避免误传 `-O "-L"` 把排除项弄丢：
>
> ```
> -O "-x|.zfs|-x|.snapshot*|-x|.ckpt"
> ```
> （`-O` 的值用 `|` 分隔 token，fpsync 内部按 `|` 拆分后传给 fpart；live mode 仍由 fpsync 自动启用。）
> 如需额外排除目录，往这个管道串里加 `-x|<pattern>` 即可。

### 参数 `-o` (rsync 透传选项)

基础: `-lptgoD --numeric-ids --inplace`
- `-lptgoD`: 等价于 `-a` 减去 `-r`(fpsync 用 `--files-from` 喂清单,不需要 rsync 递归)
- `--numeric-ids`: 跨主机迁移保留 UID/GID
- `--inplace`: 原地写入,避免临时文件占空间

条件追加:
- `--whole-file`: 小文件场景,跳过 delta 算法节省 CPU
- `--sparse`: P99 > 1GB 时,处理稀疏文件

---

## 场景案例

### 案例 1: 海量小文件(EFS → EFS,代码仓库迁移)

```
画像: 200万文件, P50=8KB, P99=2MB, tiny_ratio=0.85
```

生成命令:
```bash
fpsync -n 16 -f 1000 -s 512m \
    -O "-x|.zfs|-x|.snapshot*|-x|.ckpt" \
    -o "-lptgoD --numeric-ids --inplace --whole-file" \
    -d /var/log/fpsync_run_xxx \
    /mnt/source/ /mnt/efs-target/
```

额外建议输出:
- 切换 EFS 到 Elastic Throughput
- nconnect=16 挂载
- 考虑 tar 管道方案

### 案例 2: 视频文件(EBS → S3 间通过 EC2 中转)

```
画像: 5000个文件, P50=500MB, P99=8GB, large_count=4500
```

生成命令:
```bash
fpsync -n 8 -f 200 -s 20g \
    -O "-x|.zfs|-x|.snapshot*|-x|.ckpt" \
    -o "-lptgoD --numeric-ids --inplace --sparse" \
    -d /var/log/fpsync_run_xxx \
    /mnt/source/ /mnt/dest/
```

额外建议:
- 使用 c5n / m5n 实例
- 调大 TCP 缓冲

### 案例 3: 混合场景

```
画像: 50万文件, P50=200KB, P99=300MB, tiny_ratio=0.3
```

生成命令:
```bash
fpsync -n 12 -f 2000 -s 4g \
    -O "-x|.zfs|-x|.snapshot*|-x|.ckpt" \
    -o "-lptgoD --numeric-ids --inplace" \
    -d /var/log/fpsync_run_xxx \
    /mnt/source/ /mnt/dest/
```

---

## 实战建议

### 生产环境推荐流程

```bash
# 1. 扫描 + 生成画像
./source-profile.sh /mnt/source /var/log/fpsync_profile

# 2. 检查画像合理性(查看 P50/P99 是否符合预期)
cat /var/log/fpsync_profile/profile.json

# 3. 生成命令并 dry-run
./generate-fpsync-cmd.sh /var/log/fpsync_profile/profile.json /mnt/source/ /mnt/dest/
bash /var/log/fpsync_profile/run.sh

# 4. 检查 dry-run 输出的分区数,经验值:
#    - 分区数应 >= worker 数 × 4 (保证负载均衡)
#    - 分区数 < 5000 (避免调度开销过大)
#    如果不满足,调整 -f 或 -s 重新生成

# 5. 满意后取消 run.sh 中的 nohup 块注释,或直接执行命令
nohup fpsync ... > run.log 2>&1 &

# 6. 监控
tail -f run.log
ls /var/log/fpsync_run_xxx/log/   # 每个 worker 的独立日志
ps -ef | grep -c rsync             # 活跃 worker 数
```

### 验证 `-O "-L"` (live mode) 生效

```bash
# 任务运行中,另开 terminal:
ps -ef | grep -E "fpart|rsync" | head

# 应看到 fpart 进程在持续运行,同时已有 rsync 进程在跑
# 这说明扫描和传输并行(live mode 生效)
# 如果 fpart 已退出但 rsync 才开始,说明非 live 模式
```

---

## 常见问题

### Q: 扫描阶段太慢怎么办?

A: 几个选项:
1. 顶层目录并行扫描(脚本目前是单进程 find,可改为按子目录并行)
2. 用 `fd` 替代 `find`(更快但需额外安装)
3. 利用 fpart 自身的 `-z` 选项做"零拷贝模式"扫描
4. 如果是 EFS,先临时切换到 Elastic Throughput 模式做扫描

### Q: 生成的并发数太低/太高怎么调整?

A: 直接编辑 `generate-fpsync-cmd.sh` 中"决策 1"部分的常量,或者扫描后手动改 profile.json 的关键字段(比如把 tiny_ratio 调高强制走小文件分支)。

### Q: 中途想暂停/恢复怎么办?

A: fpsync 本身支持断点续传(rsync 默认行为):
```bash
# 暂停: kill 主进程,worker 会自然结束
pkill -TERM fpsync

# 恢复: 重新跑同样命令,rsync 会跳过已完成的文件
bash /var/log/fpsync_profile/run.sh
```

### Q: 跨账号 / 跨 region 同步怎么改?

A: 在 `generate-fpsync-cmd.sh` 中给 RSYNC_OPTS 加 SSH 选项:
```bash
RSYNC_OPTS="$RSYNC_OPTS -e 'ssh -T -c aes128-gcm@openssh.com -o Compression=no'"
```
或者用 `fpsync -w worker1,worker2` 多 worker 节点分布式跑。

---

## 已知限制

1. **macOS 上扫描脚本不能直接用**: `find -printf` 是 GNU 扩展,BSD find 不支持。需要在 Linux/EC2 上跑。
2. **awk 解析 JSON 比较脆弱**: 如果手工编辑 profile.json 格式不严格会解析失败。建议不要手改。
3. **决策逻辑是经验值**: 针对常见场景调优过,极端工况(如全是 100GB 单文件、或纯硬链接目录)可能需要手动调整。
4. **未考虑目的端反压**: 当前不监测目的端 IOPS/带宽饱和度。生产环境建议配合 CloudWatch 监控。

---

## 文件清单

```
/Users/glei/genai/fpsync-m/
├── README.md                    # 本文件
├── source-profile.sh            # 扫描脚本(可执行)
├── generate-fpsync-cmd.sh       # 参数生成脚本(可执行)
├── source-profile.md            # 历史版本(初版,有性能问题,保留参考)
└── fpsync-c.md                  # 历史版本(初版,有方向性错误,保留参考)
```

历史版本与新版差异请参见提交记录或对比 README 中的"决策逻辑详解"章节。

---

## 修改记录

- **v3 (当前版, 经东京 EC2+EFS 实机验证)**:
  - 修复(关键): 生成的 `run.sh` dry-run 由 `fpsync -r` 改为 `fpsync -p`。
    `-r` 是 fpsync 的"恢复(resume)"选项且需要 runid，原写法实跑必报
    `Invalid run ID supplied` 而失败；`-p` 才是 prepare(只爬取生成分区、不传输)模式。
  - 修复: `-O` 不再传 `-L`。fpsync 内部始终自动启用 `-L` live mode，
    误用 `-O "-L"` 反而会覆盖并丢失默认排除项(`.zfs`/`.snapshot*`/`.ckpt`)；
    现改为 `-O "-x|.zfs|-x|.snapshot*|-x|.ckpt"` 显式保留默认排除项。
  - 增强: profile 解析对 `{`/`}` 等字符更健壮，空/畸形 profile 的校验改为数值安全判断。
  - 增强: `source-profile.sh` 分位数索引加 `[1,n]` 下界保护(极小文件数不再取到空值)。
  - 验证: `source-profile.sh` 在已知分布(3000×1KB+500×64KB+50×5MB+5×150MB)下，
    total/分布/P50/P90/P99/ratio 全部精确吻合。

- **v2**:
  - 修复:扫描脚本从 9 次 find 优化为 1 次,性能提升 ~10x
  - 修复:加入 P50/P90/P99 分位数,决策更精准
  - 修复:小文件场景 `-f` 方向反转(从 5000 改为 1000)
  - 新增:fpart live mode(注: v3 已澄清 live mode 为 fpsync 内置,无需手动开启)
  - 新增:rsync 加 `--inplace`、按 P99 加 `--sparse`
  - 新增:dry-run 工作流,生成 `run.sh` 可执行脚本
  - 移除:`jq` / `bc` 依赖,统一用 awk
  - 增强:健壮性检查(空目录、除零、参数校验)
