# fpsync 监控脚本说明 (20260610)

## 场景

源端: NFSv3 挂载点 `/mnt/eu-gke-center-filestore-en/`（GCP Filestore，rsize/wsize 1MB 设不上）
目的端: NFSv4.1 + rsyncd `rsync://syncuser@10.190.7.162/aws-efs/...`
工具: `fpsync -n 12 -f 3000 -s 1g`（12 路并发，每分区最多 3000 文件 / 1GB）

单文件 20G 时能跑到 200MB/s，但多 worker + 海量小文件场景下，需要持续观察整体进度、并发度、网络吞吐、是否卡住。

## 脚本

`fpsync-monitor-20260610.sh`

```bash
chmod +x fpsync-monitor-20260610.sh
./fpsync-monitor-20260610.sh        # 默认每 10s 刷新
./fpsync-monitor-20260610.sh 5      # 每 5s 刷新
./fpsync-monitor-20260610.sh 0      # 单次快照（写日志、邮件告警时用）
```

## fpsync 实际目录结构（依据官方源码 martymac/fpart v1.7.1）

⚠️ 这里和早期版本说明不同，**已按源码核对修正**。fpsync 把“队列管理”相关目录放在临时目录 `-t`（默认 `/tmp/fpsync`）下，把“分区列表 + 日志”放在共享目录 `-d` 下（本地模式 `-d` 默认等于 `-t`）：

```
<tmp>/queue/<runid>/        # 待调度 job（含 info / fp_done / sl_stop 标志文件）
<tmp>/work/<runid>/         # 正在运行的 job（按 part 号命名，如 0,1,2...）
<tmp>/done/<runid>/         # 已完成 job   <- 进度的权威来源
<shared>/parts/<runid>/     # part.N（rsync 的 --files-from 列表）
                            #   + part.N.meta（单分区文件数/大小）
                            #   + run.meta（整个 run 的 total_num_parts/files/size）
<shared>/log/<runid>/fpsync.log   # 主日志（另有 N.stdout / N.stderr / N.ret）
```

- `runid` 格式为 `<epoch>-<pid>`（源码 `FPSYNC_RUNID="$(date '+%s')-$$"`）。
- 本地模式（无 `-w` workers）下 `<shared>` = `<tmp>` = `/tmp/fpsync`。
- 如果你用了 `-t` / `-d` 自定义目录，请改脚本顶部的 `FPSYNC_TMPDIR` / `FPSYNC_SHARED_DIR`。

## 输出 7 个面板

| 面板 | 看什么 | 异常信号 |
|---|---|---|
| 1. fpsync 主进程 | 主进程是否还活着、运行多久 | 主进程消失 = 整个任务结束（成功/失败需查 log） |
| 2. rsync 子进程 | 当前并发度（应 ≈ `-n 12`）、各自跑的 part | 长期 < 12 → FPART 来不及切分或 worker 闲置；某 PID elapsed 远超平均 → 大文件或卡住 |
| 3. FPART 分区进度 | 已落盘 part.N 数、run.meta 总数、爬取是否完成 | 爬取状态长期“进行中” → 源端目录 walk 慢 |
| 4. QMGR 队列状态 | queue / work / done 三个目录的 job 数 | work 应 ≈ `-n`；done 持续增长说明在推进；都不动 = 卡住 |
| 5. 网络吞吐 | 出网网卡 TX/s | 海量小文件几 MB/s 正常（IOPS bound）；大文件应接近带宽上限 |
| 6. 容量 | 源/目的挂载点 used | 目的端 used 应持续接近源端（仅本地挂载可见，rsync:// 模式目的端不显示） |
| 7. 进度估算 | done 分区数 / run.meta 总分区数 | FPART 没爬完时 run.meta 总量还会变，仅参考 |

## 进度是怎么算的（关键修正）

进度**不再依赖 grep 日志**（日志输出受 fpsync verbosity 影响，且早期脚本里 grep 的字符串与实际不符），改用 fpsync 自己维护的目录状态，这也是 fpsync 内部 `run_complete_jobs_count` 的做法：

- 分母：`<shared>/parts/<runid>/run.meta` 里的 `total_num_parts`（FPART 爬完后即为最终值）。
- 分子：`<tmp>/done/<runid>/` 目录下的 job 文件数（每完成一个分区，fpsync 把该 job 文件 mv 到 done/）。
- `完成率 = done 文件数 / total_num_parts`。

日志里的 `[QMGR]` / `[FPART]` 事件仅作为“最近发生了什么”的上下文展示，不参与计数。

## 配置位

脚本顶部按实际改：

```bash
FPSYNC_TMPDIR="/tmp/fpsync"                  # 对应 fpsync -t
FPSYNC_SHARED_DIR="$FPSYNC_TMPDIR"           # 对应 fpsync -d（本地模式=临时目录）
SRC_MOUNT="/mnt/eu-gke-center-filestore-en"
DST_HOST="10.190.7.162"
EXPECTED_JOBS=12                             # 对应 fpsync -n，用于并发度对比
```

## 与 fpsync 调参的配合

观察脚本几小时后，做这三类调整判断：

1. *并发数 `-n`* — 面板 2 长期满载 12 + 面板 5 网络远未饱和 → 加到 `-n 16/24`；
   若 CPU `%sy` 高、NFS server 端 op/s 接近上限，反而要往下调。
2. *分区粒度 `-s/-f`* — FPART 写得太慢（面板 3 增长缓慢）说明源端目录 walk 慢，
   `-s 1g -f 3000` 已经很大；如果是海量小文件可减到 `-s 256m -f 1000` 让 worker 更早开工。
3. *卡住排查* — 某个 rsync PID elapsed 极长且无 IO，
   去看对应 `parts/<runid>/part.NN` 里是不是单个超大文件 / 含特殊字符路径，
   `--inplace --partial` 对断点续传友好；也可以 `fpsync -r <runid>` 直接续跑。

## fpsync 自带的进度手段（推荐配合使用）

- `kill -INFO <fpsync_pid>`（或在 fpsync 的终端按 `^T`）：fpsync 会立即打印
  parts/files/bytes 的完成数、百分比和 ETA（源码 `siginfo_handler`）。
- `fpsync -l`：列出所有 run 及其状态（resumable / replayable / completed）。
- 这两个是官方实现，比任何外部脚本都准；本监控脚本是为了**持续刷新的总览面板**。

## 多 run 处理

脚本通过 `latest_runid()` 按 `<shared>/parts/<runid>/` 目录的 mtime 自动挑选**最新的一个 run** 进行监控:

```bash
ls -1dt "${PARTS_BASE}"/*/ | head -1
```

行为含义:

- 同一台机器先后跑过多次 fpsync,只监控最新一次,旧 run 的 `parts/` / `done/` 不会被统计。
- 如果你想监控某个**历史 run**,需要手动改脚本里 `RUNID="$(latest_runid || true)"` 这一行,或者把 `latest_runid()` 改成接受参数。
- 同时并发跑多个 fpsync 任务时(罕见),脚本只会显示其中一个,这种场景应该跑多个监控实例,各自指向不同的 `FPSYNC_TMPDIR`。

## 平台依赖说明

脚本以 Linux 为主目标,以下面板依赖 Linux 特有工具,在 macOS/BSD 上会优雅降级或失效:

| 面板 | 依赖工具 | 非 Linux 行为 |
|---|---|---|
| 5. 网络吞吐 | `ip -o -4 route get`, `/sys/class/net/<iface>/statistics/` | 输出"无法解析到 ... 的出网网卡(或非 Linux 环境)" |
| 6. 挂载点容量 | `mountpoint -q` | 走 fallback,可能误判源端"未挂载" |
| 1/2. 进程 | `ps -eo pid=,etime=,args=`, `pgrep -x` | 一般可用(macOS 也支持),但 etime 格式略有差异 |

- `human_size` / `awk` / `df` / `ls` / `find` 全部 POSIX,无平台问题。
- 如需 macOS 完整体验,把面板 5 换成 `nettop -n -P -l 1` 解析,面板 6 用 `df` 直接判断。

## 容器 / K8s 部署注意

把监控脚本和 fpsync 跑在不同 pod / container 时,需保证三件事同时满足:

1. **共享 PID namespace** (`hostPID: true` 或在同一 pod 内用 `shareProcessNamespace: true`)
   - 否则 `pgrep -x rsync` / `ps -eo` 看不到 fpsync 派生的 rsync 进程。
2. **共享 fpsync 工作目录** (`/tmp/fpsync` 或自定义的 `-t` 路径)
   - 否则读不到 `queue/work/done/` 三个目录,面板 3/4/7 全部失效。
3. **共享 `parts/` 和 `log/` 所在目录** (`-d` 指向的路径,本地模式 = 工作目录)
   - 否则读不到 `run.meta` 和 `fpsync.log`,进度估算变成"分母为 0"。

最简单的做法是让监控容器和 fpsync 容器共用同一个 emptyDir/hostPath 卷,挂在同一路径。

## ⚠️ 一般注意

- 脚本只读不写,不会干扰 fpsync 本身。
- `pgrep` / `ps` 在容器/PID namespace 受限场景可能看不全(见上节)。
- fpsync 是 `/bin/sh` 脚本,进程命令行形如 `/bin/sh /usr/bin/fpsync ...`,
  所以面板 1 用 `ps` 匹配 cmdline 中的 `fpsync` 关键字(Linux/macOS 通用,已排除监控脚本自身)。
- 面板 2 用 `pgrep -x rsync` 精确按进程名匹配,路径无关,也不会把 `/bin/sh -c '...rsync...'` 包装进程算进并发数。
- 完成判断:最终以 fpsync 主进程退出 + 日志末尾的 `[QMGR] Queue processed`
  / `Info: Fpsync stopped (with success)` 为准(源码确认无 "All jobs done" 字样)。
- **验证目的端完整性** 不能只看 fpsync 退出,建议事后再跑一次
  `rsync -avAXn --numeric-ids --inplace --info=stats2 …`(干跑)看 transferred=0 才算齐。

## 路径

`/psync-monitor-20260610.sh`
