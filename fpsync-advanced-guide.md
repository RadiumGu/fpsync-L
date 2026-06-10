# fpsync 进阶指南：多 worker 分布式 与 增量/扫描优化

> 本文所有结论均在东京 region (ap-northeast-1) 真实 EC2 + 2×EFS 环境实测得出。
> 测试数据集：3555 文件 / 1.1 GB（3000×1KB + 500×64KB + 50×5MB + 5×150MB）。

---

## 第一部分：多 worker 分布式 (`fpsync -w`)

### 工作原理
- fpsync 在 **master** 上跑队列管理器(QMGR)与 fpart 爬取；把每个分区(part)作为一个 job。
- 通过 `-w user@host` 列出的 worker，master 用 **SSH** 把 job 派发到各节点执行 rsync。
- master 自己也可以作为一个 worker（`-w user@<master_ip>`）。
- job 在各 worker 间轮转分配，实现负载均衡。

### 实测结果（2 节点）
| 指标 | 单节点 | 2 节点 (master+worker) |
|---|---|---|
| 耗时 | 52s | 51s |
| 目的端文件数 | 3555 | 3555 |
| 完整性(rsync 干跑 diff) | 一致 | 一致 |
| job 分布 | — | master 12 + worker 12（均分）|

**结论：多 worker 协同确实生效（job 均分到两节点），但本测试速度没提升。**

### 关键：什么时候多 worker 才提速？
多 worker 增加的是**客户端侧**的并行能力（CPU、网卡、单机 NFS 客户端的 IOPS）。是否提速取决于瓶颈在哪：

- ✅ **会提速**：
  - 单客户端 CPU / 网卡已打满（海量小文件吃满单机 CPU，或单机网卡带宽封顶）。
  - 源/目的能提供 **超过单客户端** 的聚合吞吐：EFS **Elastic Throughput**、FSx for Lustre、S3、或多个 EFS/卷。
- ❌ **不会提速**（本次情况）：
  - 共享 EFS 处于 **Bursting** 模式、其吞吐本身就是上限时，多节点打的是同一个吞吐池，1 节点 ≈ N 节点。

> **行动建议**：加节点前先定位瓶颈。看单节点跑时的 CPU `%us/%sy`、网卡 `TX/s`、以及 EFS `BurstCreditBalance`/`PermittedThroughput`(CloudWatch)。只有客户端饱和或目的端还能吃更多吞吐时，多 worker 才有意义。

### 实测踩坑与正确做法（务必注意）
1. **每个节点都要在同路径挂载 src 与 dst**（worker 上的 rsync 直接读写本地挂载点）。
2. **master→worker 免密 SSH**：把 master 上运行用户的公钥放进各 worker 该用户的 `authorized_keys`；建议配 `~/.ssh/config` 关掉 `StrictHostKeyChecking` 以免交互卡住。
3. **`-d` 共享目录的写权限坑（最容易翻车）**：
   - `-d` 共享目录存放 parts/log，必须所有节点同路径可见（放在共享存储上）。
   - worker 上 rsync 的 **stdout/stderr 重定向是以 SSH 登录用户身份执行的**（在 sudo 之前），因此该用户必须能写入共享 log 目录。
   - 实测：以 root 在 master 创建共享目录(owner=root) + 用 `-S`(sudo) 跑 → worker 的 ec2-user 写不进 root 的 log 目录，报 `Permission denied`，**整批静默失败、目的端 0 文件**。
   - **正确做法（二选一）**：
     - (a) 以**普通用户**统一运行，并让该用户对 **dst** 和 **共享目录** 可写（本次采用：`chown ec2-user dst挂载点` + 用 ec2-user 的密钥跑，不加 `-S`）。
     - (b) 仍用 `-S`，但要确保共享 log 目录对 SSH 登录用户可写（例如 `chmod 1777` 或 chown 到登录用户）。
4. **`-t` 临时队列目录**（queue/work/done）默认 `/tmp/fpsync`，**留在 master 本地即可**，无需共享。

### 验证过的最小命令（普通用户、非 sudo 模式）
```bash
# 前置: 两节点同路径挂载 /mnt/src /mnt/dst; chown dst 给运行用户; master->各节点免密SSH
fpsync -n 8 -f 200 -s 100m \
    -O "-x|.zfs|-x|.snapshot*|-x|.ckpt" \
    -o "-lptgoD --numeric-ids --inplace" \
    -w ec2-user@<master_ip> -w ec2-user@<worker_ip> \
    -d /mnt/dst/.fpsync_wd \
    /mnt/src/ /mnt/dst/
```

### 与 source-profile / generate-fpsync-cmd 的结合
- 先用 `source-profile.sh` + `generate-fpsync-cmd.sh` 得到单机最优 `-n/-f/-s/-o`。
- 若判断需要分布式（客户端饱和 / 目的端可吃更多吞吐），在生成的命令上追加 `-w ... -w ...` 与共享 `-d`。
- `generate-fpsync-cmd.sh` 的输出末尾已内置“多 worker 建议”块，直接给出可套用的模板与前置条件。
- worker 数估算：先看单节点是否把客户端打满；未打满则加节点无益。打满后，节点数 ≈ ceil(目的端可用聚合吞吐 / 单节点可达吞吐)。

---

## 第二部分：增量传输 与 扫描提速

适用场景：割接前已做过一次/多次全量，割接窗口内只需把**增量变化**同步过去；当前痛点是**扫描慢**。

### 实测数据
| 操作 | 耗时 | 说明 |
|---|---|---|
| 单次 `find` 全量扫描(冷缓存) | **1578 ms** / 3555 文件 (~0.44ms/文件) | NFS 元数据遍历是延迟瓶颈 |
| fpsync 全量重跑(无变化) | **4 s** | rsync 正确跳过所有未变文件；残留开销=扫描+逐文件 stat，**不是**传输 |
| `find -newer` 选出变更(15 个) + 定向 `rsync --files-from` | **720 ms** | 只传 15 个变更文件，dst 3555→3560，完整性一致 |

### 结论与方案
1. **增量正确性**：rsync 默认按 size+mtime 比对、自动跳过未变文件。**重跑同一条 fpsync 命令就是增量同步**（`--inplace` 对断点续传也友好）。无需特殊参数。

2. **增量的真正成本是“扫描 + 逐文件 stat”，不是传输**。全量重跑 4s 几乎全花在遍历/比对上。文件越多，这个固定开销越大——这正是“扫描慢”的根因。

3. **割接窗口的增量优化：用变更清单驱动，绕开全量分区**
   - 维护一个时间戳标记文件（上次同步时间），用 `find <src> -newer <marker>` 选出**仅变更/新增**的文件清单；
   - 直接 `rsync -a --files-from=<清单> <src>/ <dst>/`，跳过 fpart 全量分区、也避免 rsync 在目的端逐个 stat 全部文件。
   - 实测对“少量变更”场景显著更快（720ms vs 4s，且不随总文件数线性增长——只取决于变更数 + 一次 find walk）。
   - 注意：`find -newer` 删除的文件检测不到；若需删除同步，最终窗口用一次带 `--delete` 的全量 rsync 收尾对账。

4. **扫描本身提速**
   - **并行扫描**：按顶层子目录并行跑多个 `find`，重叠 NFS 元数据往返延迟。
     > 实测注意：单次 find 冷缓存 1578ms、并行 27ms 的对比**被缓存预热污染**（第一次 find 已把元数据缓存预热），不能直接作为加速比。但方向成立——元数据遍历是延迟受限、EFS 能并行服务元数据，按子树并行可显著缩短墙钟时间。建议对**冷缓存**分别测量两种方式才公允。
   - 把 `source-profile.sh` 的单进程 `find` 改为按顶层目录并行（见下方片段），对千万级目录收益最大。
   - 极端海量(>千万)且 find 都嫌慢时，用**变更捕获**取代“扫描”：
     - 同步窗口前用 `fanotify`/`inotifywait` 记录变更日志（change journal），割接时只同步日志里的路径；
     - 或利用存储快照差异（EFS/FSx 快照、或源端 LVM/zfs snapshot diff）直接得到变更集。

### 并行扫描片段（可并入 source-profile.sh）
```bash
# 按顶层子目录并行收集文件大小，再合并统计
SRC=/mnt/src; OUT=/tmp/sizes.txt; : > "$OUT"
mapfile -t TOPS < <(find "$SRC" -mindepth 1 -maxdepth 1 -type d)
i=0
for d in "${TOPS[@]}"; do
    find "$d" -type f -printf '%s\n' > "/tmp/.sz.$i" &
    i=$((i+1))
    # 控制并发，避免 fork 过多
    if (( i % 16 == 0 )); then wait; fi
done
# 别忘了顶层散落的文件
find "$SRC" -maxdepth 1 -type f -printf '%s\n' >> "$OUT"
wait
cat /tmp/.sz.* >> "$OUT"; rm -f /tmp/.sz.*
# 之后用同样的 awk 做 P50/P90/P99 统计
```

### 割接增量同步推荐流程
```bash
# 统一从 fpsync.env 取源/目的/增量标记(单一真相源)
cd /path/to/fpsync-latest
. ./fpsync.env          # 提供 SRC_DIR / DST_DIR / LAST_SYNC_MARKER

# T-?: 预热全量(可多次)
bash "${WORKDIR:-/tmp/fpsync_profile}/run.sh"   # 全量(run.sh 同样 source fpsync.env)

# 记录基线时间点
touch "$LAST_SYNC_MARKER"

# ... 业务继续写入 ...

# 割接窗口: 只同步增量
cd "$SRC_DIR"
find . -type f -newer "$LAST_SYNC_MARKER" > /tmp/delta.lst
rsync -a --numeric-ids --inplace --files-from=/tmp/delta.lst "$SRC_DIR" "$DST_DIR"
# 收尾对账(处理删除 + 兜底)
rsync -a --numeric-ids --inplace --delete --dry-run "$SRC_DIR" "$DST_DIR" | tee /tmp/final-diff.txt
touch "$LAST_SYNC_MARKER"   # 更新基线
```

> 实测(东京 EC2 + 双 EFS):`touch "$LAST_SYNC_MARKER"` 后向源新增 5 个文件,
> `find -newer` 精确选出这 5 个,`rsync --files-from` 仅传这 5 个,目的端文件数 +5、完整性一致。
> **非 root 提示**:`LAST_SYNC_MARKER` 默认在 `/var/run`(普通用户不可写),
> 请在 `fpsync.env` 改为用户可写路径(如 `$HOME/fpsync_last_sync`)。

---

## 一句话总结
- **多 worker**：协同已验证(job 均分)，但只在“客户端饱和或目的端能吃更多吞吐”时提速；共享 EFS Bursting 吞吐封顶时加节点无益。注意 `-d` 共享目录对登录用户的写权限坑。
- **增量**：rsync 重跑即增量；瓶颈在扫描/stat 而非传输。用 `find -newer` + `rsync --files-from` 仅传变更；超大目录用并行扫描或变更日志/快照差异取代全量遍历。
