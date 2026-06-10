# fpsync 工具集 — 端到端测试计划

> 测试日期:2026-06-10
> 测试主机:master `ip-10-1-2-140`(AL2023 / t3.large,2 vCPU)
> 工具版本:fpsync/fpart v1.7.1、rsync 3.4.0、GNU awk
> 运行用户:`ec2-user`(非 root)

## 测试对象与环境

本地挂载的两个 EFS:

| 角色 | 挂载点 | 挂载目标 | 说明 |
|---|---|---|---|
| 源 | `/mnt/src`(数据在 `/mnt/src/data/`) | 10.1.2.235,NFS4.1 | 3560 文件 / ~1.1GB(3000×1KB + 500×64KB + 50×5MB + 5×150MB) |
| 目的 | `/mnt/dst/` | 10.1.2.99,NFS4.1 | fpsync 同步落地点(已 chown ec2-user) |

统一配置:`fpsync.env`。**测试前已清空 5 个调优参数**
(`JOBS/FILES_PER_PART/SIZE_PER_PART/RSYNC_OPTS/FPART_OPTS`),
以验证"留空 → 自动推导 → 回写"的完整链路。路径/监控类参数保留:
`SRC_DIR=/mnt/src/data/`、`DST_DIR=/mnt/dst/`、`SRC_MOUNT=/mnt/src`、`DST_HOST=10.1.2.99`、
`RUN_DIR_BASE=/tmp/fpsync_runs`、`LAST_SYNC_MARKER=/home/ec2-user/fpsync_last_sync`
(非 root 可写路径)。

## 测试范围

覆盖复制的各个阶段:配置加载 → 源端画像 → 参数生成/回写 → dry-run → 真实传输 →
完整性校验 → 运行监控 → 同机多实例隔离 → 内容级校验 → 增量同步。

---

## 测试用例

### T1 配置加载与优先级
- **目的**:验证各脚本自动 `source fpsync.env`;配置优先,位置参数仅在留空时回退。
- **步骤**:`source fpsync.env` 后回显变量;不传位置参数运行各脚本。
- **预期**:变量取自配置;调优参数当前为空(待 T3 推导回写)。

### T2 源端画像 `source-profile.sh`
- **目的**:一次 `find` 扫描生成 profile.json(P50/P90/P99 + 分布)。
- **步骤**:`./source-profile.sh`(无参,配置驱动)。
- **预期**:`total_files=3560`、`tiny_ratio≈0.84`、`p50=1024`、`p99=5242880`、分布 3000/500/50/5。

### T3 参数生成 + 自动推导 + 回写 `generate-fpsync-cmd.sh`
- **目的**:留空调优参数 → 按画像自动推导 → 回写 fpsync.env(幂等、备份)。
- **步骤**:`./generate-fpsync-cmd.sh`(无参);检查回写结果;再跑一次验证幂等。
- **预期**:小文件主导场景推导 `-n 4 / -f 1000 / -s 4g / -o ...--whole-file / -O 排除项`;
  5 个字段被写回 fpsync.env(每个恰 1 行);生成 `run.sh`。

### T4 dry-run(`run.sh` 的 `fpsync -p` prepare)
- **目的**:只生成分区、不传输,确认参数可用、分区数合理。
- **步骤**:`bash <WORKDIR>/run.sh`。
- **预期**:输出 `Successfully prepared run`,退出码 0;打印本实例监控命令。

### T5 真实传输 + 完整性校验
- **目的**:执行真实 fpsync 传输,校验目的端与源端一致。
- **步骤**:用配置参数对一个**全新空目录**(`/mnt/dst/` 下的临时子目录,仍在目的 EFS 上)
  执行传输;`rsync -an` 干跑比对。
- **预期**:目的端文件数 = 3560;`rsync` 干跑 diff = 0;fpsync 退出码 0。

### T6 运行监控 `fpsync-monitor`(单实例快照)
- **目的**:验证监控面板读配置、对真实 run 统计正确。
- **步骤**:传输运行时 `FPSYNC_DIR=<run目录> ./fpsync-monitor-20260610.sh 0`。
- **预期**:源/目的取自配置;面板显示该 run 的 queue/work/done、活跃 part≈并发数。

### T7 同机多实例隔离(方案 A)
- **目的**:同机并发多个 fpsync,各实例 `-t/-d` 独立、监控按实例归属。
- **步骤**:并发起 2 个隔离实例(各自 RUN_DIR);分别用 `FPSYNC_DIR` 监控;对比全机 rsync 数。
- **预期**:两实例 runid 不同;各监控只显示本实例(rsync 数=本实例,而非全机汇总);各自传输完整。

### T8 内容级校验 `fpsync-verify.sh`
- **目的**:用 fpsync 并发跑 `rsync --checksum` 干跑做逐文件内容比对。
- **步骤**:`./fpsync-verify.sh`(配置驱动)。
- **预期**:一致 → `✅ 一致 (无差异)`,退出码 0。

### T9 增量同步(`find -newer` + `rsync --files-from`)
- **目的**:基线标记后只同步变更文件。
- **步骤**:`touch $LAST_SYNC_MARKER` → 源新增 5 文件 → `find -newer` 选变更 → `rsync --files-from` 传输。
- **预期**:仅选出/传输这 5 个文件;目的端 +5;完整性一致。

---

## 通过标准
- 各阶段脚本退出码符合预期(0=成功;verify 2=有差异)。
- 画像统计与已知数据集精确吻合。
- 推导参数与场景规则一致并正确回写。
- 真实传输后 `rsync` 干跑 diff = 0。
- 多实例监控按实例正确归属,互不串扰。
- 增量仅传变更文件。

## 清理
测试产生的临时目录(`/mnt/dst/` 下测试子目录、`/tmp/fpsync_runs/*`、增量临时文件)
在测试后清理;测试完成后从备份 `fpsync.env.pretest` 恢复(或保留回写后的配置)。
