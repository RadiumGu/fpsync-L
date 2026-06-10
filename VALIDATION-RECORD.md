# fpsync 工具集 验证记录

> 记录时间：2026-06-10
> 验证环境：AWS 东京 Region (ap-northeast-1)，真实 EC2 + EFS 实机验证
> 账号：926093770964

---

## 1. 验证概述

对 `fpsync` 自动调参工具集及监控脚本进行了端到端真实验证，覆盖：
1. `source-profile.sh`（源端文件系统画像）
2. `generate-fpsync-cmd.sh`（自动生成 fpsync 参数）
3. `fpsync-monitor-20260610.sh`（fpsync 运行监控）
4. 多 worker 分布式协同（`fpsync -w`）
5. 增量传输与扫描提速

所有结论均基于真实运行结果，并已据此修复脚本缺陷。

---

## 2. 测试环境

| 资源 | ID / 说明 |
|---|---|
| VPC / 子网 | vpc-06731f30388b57818 (openclaw-vpc-v2) / subnet-057b2d3519422d28b (私有1a, NAT出网) |
| master EC2 | i-087839a44a550caf2，t3.large，AL2023，10.1.2.140 |
| worker EC2 | i-0be304b89f081ef1f，t3.large，AL2023，10.1.2.81 |
| EFS 源 | fs-0abcb80fd7a747a30 → MT fsmt-018dcdf7286d82619 (10.1.2.235)，挂 /mnt/src |
| EFS 目的 | fs-093a0dd8193e51c14 → MT fsmt-04365f7c50c728e92 (10.1.2.99)，挂 /mnt/dst |
| 安全组 | EC2 sg-06d3982908235d2ad（含22自引用）/ EFS sg-0437aeecc664dc29b（2049来自EC2 SG）|
| 工具版本 | fpart/fpsync v1.7.1（源码编译）、rsync 3.4.0、GNU Awk 5.1.0、numfmt |
| 测试数据 | 3555 文件 / 1.1GB：3000×1KB + 500×64KB + 50×5MB + 5×150MB |

访问方式：SSM Session Manager（免密钥，私有子网经 NAT 出网）。

---

## 3. 脚本准确性验证

### 3.1 source-profile.sh —— ✅ 完全准确
针对已知分布的数据集，每项统计精确吻合：

| 字段 | 实测值 | 核对 |
|---|---|---|
| total_files | 3555 | ✓ |
| total_size_bytes | 1084416000 | ✓ 精确等于各桶之和 |
| p50 / p90 / p99 | 1024 / 65536 / 5242880 | ✓ 命中 tiny/small/medium |
| max_size_bytes | 157286400 | ✓ |
| distribution | 3000/500/50/5 | ✓ |
| tiny_ratio / large_ratio | 0.8439 / 0.0014 | ✓ |

### 3.2 generate-fpsync-cmd.sh —— ✅ 决策正确，修复 1 个关键 bug
- 决策正确（tiny_ratio 0.8439, cores=2）：`-n 4 / -f 1000 / -s 4g / --whole-file`。
- 三类场景（tiny / large / mixed）决策均与 README 案例一致。
- **🔴 修复关键 bug**：生成的 `run.sh` dry-run 原用 `fpsync -r`，实跑报 `Invalid run ID supplied`（`-r` 是恢复模式、需 runid）。改为 `fpsync -p`（prepare 模式），实测 "Successfully prepared run"、exit=0。
- **修复**：`-O` 不再传 `-L`（fpsync 内部始终自动加 -L，误传会覆盖默认排除项），改为 `-O "-x|.zfs|-x|.snapshot*|-x|.ckpt"`。
- **增强**：JSON 解析对 `{}` 健壮；空/畸形 profile 守卫改为数值安全（实测正确 exit=1）。

### 3.3 fpsync-monitor-20260610.sh —— ✅ 7 面板全部正确（对真实 fpsync 数据）
- 面板 3：part.N 计数不再翻倍（排除 .meta）。
- 面板 4：queue/work/done 三态实时准确（work=并发 -n）。
- 面板 7：基于 done/ 目录的进度，准确。
- 日志路径、QMGR 事件解析正确（实际字符串 `exited (success)` / `[QMGR] Queue processed`）。
- 修复：进程匹配改 ps（兼容 /bin/sh 包装）；rsync 按进程名匹配（实际在 /usr/bin/rsync）；面板 2 区分 rsync 进程数(每任务约3个)与活跃 part(≈并发 job)。

### 3.4 source-profile.sh 边界增强
- 分位数索引加 `[1,n]` 下界保护（极小文件数不再取到空值）。

---

## 4. 多 worker 分布式验证（fpsync -w）

### 结果
| 指标 | 单节点 | 2 节点 |
|---|---|---|
| 耗时 | 52s | 51s |
| dst 文件数 | 3555 | 3555 |
| 完整性 | 一致 | 一致 |
| job 分布 | — | master 12 + worker 12（均分）|

### 结论
- **协同确实生效**（job 均分到两节点），但本测试**没提速**。
- 瓶颈是共享 EFS **Bursting** 吞吐（非客户端），多节点打同一吞吐池故无益。
- **多 worker 提速的前提**：单客户端 CPU/网卡饱和，或源/目的能提供 > 单机的聚合吞吐（EFS Elastic/Provisioned、FSx、S3）。

### 实测踩坑
- `-S`(sudo) 模式下，worker 上 rsync 的 stdout/stderr 重定向以 SSH 登录用户身份执行，写不进 root 拥有的共享 log 目录 → 整批静默失败、dst 0 文件。
- **正解**：以普通用户运行，并让其对 dst 与共享 `-d` 目录可写（本次 `chown ec2-user dst` + ec2-user 密钥，不加 -S）。
- 前置：每节点同路径挂载 src/dst；master→worker 免密 SSH；`-t` 临时目录留 master 本地。

---

## 5. 增量传输 与 扫描优化验证

| 操作 | 耗时 | 说明 |
|---|---|---|
| 单次 find 全量扫描(冷缓存) | 1578 ms / 3555 文件 | 元数据遍历延迟受限 |
| fpsync 全量重跑(无变化) | 4 s | rsync 跳过未变；残留=扫描/stat，非传输 |
| find -newer 选 15 变更 + 定向 rsync | 720 ms | 仅传变更，dst 3555→3560，一致 |

### 结论
- 增量正确性：rsync 默认按 size+mtime 跳过未变；**重跑同一 fpsync 命令即增量**。
- 增量真正成本是**扫描/stat**，不是传输（印证“扫描慢”痛点）。
- 割接增量推荐：`find -newer <marker>` 选变更 → `rsync --files-from` 只传变更（不随总文件数线性增长）；删除同步用窗口末次 `--delete` 全量对账。
- 扫描提速：按顶层子目录并行 find（重叠 NFS 元数据延迟）；超大目录用变更日志(inotify/fanotify)或快照差异取代全量遍历。
- 注意：并行扫描 27ms vs 单次 1578ms 的对比受热缓存影响被高估，需冷缓存分别测才公允。

---

## 6. 交付物清单（S3: fpsync-m/final/ 与 本地 script/）

| 文件 | 说明 |
|---|---|
| source-profile.sh | 源端画像（已增强健壮性） |
| generate-fpsync-cmd.sh | 参数生成（修复 -r→-p、-O、解析健壮性 + 多 worker 建议块） |
| README.md | 工具说明（v3 修改记录） |
| fpsync-advanced-guide.md | 多 worker + 增量/扫描 进阶指南（含实测数据） |
| fpsync-monitor-20260610.sh / .md | fpsync 运行监控（已修复并实测） |
| cleanup-fpsync-test.sh | 资源清理脚本（终止 2 实例 + 删 EFS/挂载目标/SG） |
| VALIDATION-RECORD.md | 本验证记录 |

---

## 7. 环境状态
- 验证环境**保留未清理**（按需求）：master + worker EC2、2 个 EFS、挂载目标、安全组仍在运行（持续计费）。
- 清理：执行 `cleanup-fpsync-test.sh`。
