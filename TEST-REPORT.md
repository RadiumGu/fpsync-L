# fpsync 工具集 — 端到端测试报告

> 执行日期:2026-06-10
> 执行主机:master `ip-10-1-2-140`(AL2023 / t3.large,2 vCPU),用户 `ec2-user`(非 root)
> 工具:fpsync/fpart v1.7.1、rsync 3.4.0、GNU awk
> 配置:`fpsync.env`(测试前已清空 5 个调优参数以验证自动推导+回写)
> 对照:`TEST-PLAN.md`

## 1. 测试环境

| 角色 | 挂载点 | 挂载目标 | 数据 |
|---|---|---|---|
| 源 EFS | `/mnt/src`(`/mnt/src/data/`) | 10.1.2.235,NFS4.1 | 3560 文件 / ~1.03 GiB |
| 目的 EFS | `/mnt/dst/` | 10.1.2.99,NFS4.1 | 同步落地点(含历史测试残留文件) |

> 说明:`/mnt/dst/` 顶层留有历次测试的残留文件,为得到干净的计数,真实传输(T5)与
> 多实例(T7)使用目的 EFS 上的全新子目录;完整性以 `rsync` 干跑 diff 衡量,不受残留影响。

## 2. 结果总览

| 用例 | 内容 | 结果 |
|---|---|---|
| T1 | 配置加载与优先级 | ✅ 通过 |
| T2 | 源端画像 | ✅ 通过 |
| T3 | 参数生成 + 自动推导 + 回写 | ✅ 通过 |
| T4 | dry-run(`fpsync -p`) | ✅ 通过 |
| T5 | 真实传输 + 完整性 | ✅ 通过 |
| T6 | 运行监控(单实例快照) | ✅ 通过 |
| T7 | 同机多实例隔离(方案 A) | ✅ 通过 |
| T8 | 内容级校验 `fpsync-verify.sh` | ✅ 通过(见 4.8 说明)|
| T9 | 增量同步 | ✅ 通过 |

**结论:9/9 通过。** 统一配置、自动推导回写、传输完整性、多实例隔离、增量与内容级校验
均按预期工作。

## 3. 关键指标

| 指标 | 实测值 |
|---|---|
| 源端扫描耗时(3560 文件) | 2 s |
| 推导参数 | `-n 4 / -f 1000 / -s 4g / -o "-lptgoD --numeric-ids --inplace --whole-file" / -O "-x|.zfs|-x|.snapshot*|-x|.ckpt"` |
| 全量传输(3560 文件 / 1.03 GiB,单实例 -n4) | 35.05 s,退出码 0 |
| 全量传输完整性(`rsync -an` diff) | 0 |
| 多实例并发(2×) | 各 3560 文件、diff 0;runid 互异 |
| 增量(变更 5 文件) | `find -newer` 精确选 5,目的端 +5 |

## 4. 各用例详情

### 4.1 T1 配置加载与优先级 — ✅
`source fpsync.env` 后:`SRC_DIR=/mnt/src/data/`、`DST_DIR=/mnt/dst/`、
`WORKDIR=/home/ec2-user/fpsync_profile`;5 个调优参数均为空(待 T3 推导)。
不传位置参数即可驱动各脚本,确认"配置优先、参数留空回退"。

### 4.2 T2 源端画像 — ✅
`./source-profile.sh`(无参)输出 profile.json:
```
total_files=3560  total_dirs=5  total_size_bytes=1084426480
p50=1024  p90=65536  p99=5242880  max=157286400
distribution: tiny<4KB=3005, 4KB–1MB=500, 1MB–100MB=50, >100MB=5
tiny_ratio=0.8441  large_ratio=0.0014  scan_seconds=2
```
与已知数据集吻合(小文件主导)。

### 4.3 T3 参数生成 + 自动推导 + 回写 — ✅
留空 → 按画像推导(tiny_ratio>0.7 走小文件分支):
```
[-n] 4     tiny files dominate; metadata IOPS 瓶颈,提高并发(EFS nconnect 上限 16)
[-f] 1000  small partitions => 更高并行度
[-s] 4g    default
[-o] -lptgoD --numeric-ids --inplace --whole-file   (小文件加 --whole-file)
[-O] -x|.zfs|-x|.snapshot*|-x|.ckpt                  (保留默认排除项)
```
5 个字段已回写 `fpsync.env`(回写前备份 `.bak`);再次运行确认**幂等**(每键恰 1 行)。
生成 `run.sh`。

### 4.4 T4 dry-run(`fpsync -p`)— ✅
`bash <WORKDIR>/run.sh` 输出 `Successfully prepared run: 1781089789-71409`,退出码 0;
并打印本实例监控命令 `FPSYNC_DIR=/tmp/fpsync_runs/run_..._71405 ./fpsync-monitor-20260610.sh 5`。
仅生成分区、不传输。

### 4.5 T5 真实传输 + 完整性 — ✅
对目的 EFS 全新子目录 `/mnt/dst/testT5_*` 执行真实 fpsync:
- 目的端文件数 0 → **3560**;耗时 **35.05 s**;退出码 **0**。
- `rsync -an --numeric-ids` 干跑比对差异 = **0**(源全部正确落地)。

### 4.6 T6 运行监控(单实例快照)— ✅
运行中 `FPSYNC_DIR=<run目录> ./fpsync-monitor-20260610.sh 0`:
源/目的取自配置;面板显示该 run 的 `queue/work/done`、`work=4`(=并发 `-n`)、
活跃 part 4(期望 ≈4),进度与 run.meta 一致。

### 4.7 T7 同机多实例隔离(方案 A)— ✅
并发起两个隔离实例(各自 `-t/-d`):
| | 实例 A | 实例 B |
|---|---|---|
| runid | `1781089840-72762` | `1781089840-72763`(互异)|
| 监控 rsync 进程数 | **12(本 run)** | **12(本 run)** |
| work(并发) | 4 | 4 |
| 完成后目的端 | 3560,diff 0 | 3560,diff 0 |

对照:全机 `pgrep -x rsync` = **24**。每个实例的监控仅统计本实例的 12 个 rsync
(而非全机 24),证明 `FPSYNC_DIR` 定向 + 按 runid 过滤的隔离生效;两实例互不串扰。

### 4.8 T8 内容级校验 `fpsync-verify.sh` — ✅(附说明)
`./fpsync-verify.sh`(配置驱动,并发 `rsync --checksum` 干跑)对 `/mnt/src/data/` ↔ `/mnt/dst/`:
- 退出码 2,报"发现 4 处差异"。
- 经核查,这 **4 处全部是目录 mtime 差异**(itemize `.d..t......`),由 `/mnt/dst/` 顶层
  历史残留文件改动了目录修改时间所致;**文件级 `--checksum` 内容差异 = 0**。
- 对**干净的 T5 副本**重新做内容校验:**0 差异**。

**判定**:工具行为正确(能并发跑校验、聚合各分区差异、退出码区分一致/差异)。
源↔目的在**文件内容层面一致**。
**观察项(非阻塞)**:`fpsync-verify.sh` 的差异过滤 `^(\*deleting|[<>ch.][fdL])` 会把
目录 mtime 行(`.d`)也计入"差异"。若只关心文件内容,可将过滤收紧为仅文件
(如排除以 `.d` 开头且仅 mtime 变化的行),避免在目的端有额外文件时产生此类噪声。

### 4.9 T9 增量同步 — ✅
`touch $LAST_SYNC_MARKER` → 源新增 5 个文件 → `find . -newer $LAST_SYNC_MARKER`
**精确选出这 5 个**(`_t9_1..5.txt`)→ `rsync --files-from` 传输:
目的端 3560 → **3565**,5 个文件全部到位。增量成本只取决于变更数 + 一次 find walk。

## 5. 发现与建议

1. **`fpsync-verify.sh` 目录 mtime 噪声**(见 4.8):内容一致时,若目的端有额外文件,
   会因目录 mtime 变化报出 `.d..t` 差异。建议把差异过滤限定到文件级。
2. **非 root 路径**:`/var/log`、`/var/run` 对 `ec2-user` 不可写;本测试已将
   `RUN_DIR_BASE=/tmp/fpsync_runs`、`LAST_SYNC_MARKER=/home/ec2-user/fpsync_last_sync`、
   `WORKDIR=/home/ec2-user/fpsync_profile` 设为用户可写路径。生产以普通用户运行时同此处理。
3. **海量文件增量**:`find -newer` 成本随**总文件数**线性增长(本测试 3560 文件扫描 2 s)。
   千万级目录建议改用变更日志(inotify/fanotify)或存储快照差异驱动增量(见进阶指南)。
4. **EFS 吞吐**:本环境多实例未提速(共享 Bursting 吞吐为瓶颈),与历史结论一致;
   隔离能力本身已验证。需要提速时应确认瓶颈再决定多 worker/多实例。

## 6. 测试后状态
- 所有测试临时目录(`/mnt/dst/testT5_*`、`/mnt/dst/T7a_*`、`/mnt/dst/T7b_*`、
  `/tmp/fpsync_runs/*`、增量临时文件)已清理;源端新增的 5 个增量文件已删除。
- `fpsync.env` 的 5 个调优参数经自动推导**已回写**(与测试前一致);
  测试前备份保留在 `fpsync.env.pretest`。
- 产出文档:`TEST-PLAN.md`、`TEST-REPORT.md`(本文件)。
