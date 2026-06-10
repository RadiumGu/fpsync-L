# fpsync 工具集 — 待办 / 后续增强 (Backlog)

> 记录时间:2026-06-10
> 当前已完成:统一配置 fpsync.env、同机多实例隔离(方案A)、跨云远程 push(RSYNC_RSH)、
> 并行画像 + per-subtree 大小、分片器 shard-plan.sh(单对/本机已实测)、监控自动发现。
> 以下为三项后续增强,尚未实现。

---

## TODO-1: `<root-files>` 的 `--files-from` 真实现
**背景**:源端顶层散落文件(不在任何子目录下)被画像标为伪子树 `<root-files>`。
fpart 不便处理散文件,所以 `shard-plan.sh` 目前对它**只打印提示、未真正传输**。

**待做**:
- 在 `shard-plan.sh` 里为 `<root-files>` 分片生成真实命令:
  `cd "$SRC_DIR" && find . -maxdepth 1 -type f > files.lst`,再
  `rsync -a --files-from=files.lst <RSYNC_OPTS> "$SRC_DIR" "<receiver>/"`(带 `RSYNC_RSH`)。
- 纳入 dry-run / `--apply` 两种模式,RUN_DIR 隔离 + 日志。
- 注意:`--files-from` 清单是相对 `$SRC_DIR` 的路径。

**验证**:在源顶层放几个散文件,跑 shard-plan,确认它们落到接收端根路径、计数/完整性正确。

---

## TODO-2: 远程发送节点 (GCP_SENDERS) 多对并行端到端编排 — ✅ 已完成并实测
**实现**(`shard-plan.sh`):
1. **SSH 扇出启动**:控制机经 `ssh <sender> bash -s <<EOF` heredoc 在各发送机起 fpsync,
   `RSYNC_RSH` 用 `printf %q` 安全注入,规避引号问题;本机发送直接本地跑。
2. **前置体检** `preflight()`:逐发送机校验 SSH 可达 + fpsync 存在 + 源已挂载 + 运行目录可写;
   `--apply` 前不通即中止。
3. **1:1 映射**:组 i → 发送 i / 接收 i;组数 > 节点对数时排队提示(已有)。
4. **汇总进度**:配合 `shard-monitor.sh`(SSH 收集各发送机各 run 的 done/total)。

**已实测**(东京 EC2,2 对并行):
- 临时起 2 台接收节点(new1=10.1.2.94 / new2=10.1.2.103,仅挂 EFS+rsync,用后已终止);
- 发送端 = master(本机) + worker(10.1.2.81),接收端 = new1 / new2,`RSYNC_SSH` 走 SSH;
- `shard-plan 2`:pair1 large 经 master→new1,pair2 medium/small/tiny 经 **81→new2**(远程 SSH 扇出);
- 预跑(prepare)在各自发送机成功;`--apply` 并行传输;汇总监控跨两发送机 2/7→7/7=100%;
- EFS 落地 large5/medium50/small500/tiny3005=3560,各子树完整性 diff=0。

**仍待打磨(可选)**:失败分片自动 `fpsync -r` 续传/重试、`--wait` 阻塞到全部完成。

---

## TODO-3: 汇总监控(一屏看所有分片进度) — ✅ 已完成 (shard-monitor.sh)
**实现**:`shard-monitor.sh`(GCP 发送侧,纯读、零依赖/零凭证)。
汇总 `shard-plan.sh` 启动的一批分片(按最近 STAMP 或指定 STAMP),显示每分片
done/total、%、活跃 work,以及合计总进度;多发送机时经 SSH 收集(`GCP_SENDERS`)。
用法:`./shard-monitor.sh [刷新秒数] [STAMP]`(0=单次快照)。
**已实测**:本机发送 → 10.1.2.81 接收,K=2 分片,运行中 14.3% → 完成 7/7=100%,
落地 large5/medium50/small500/tiny3005 正确。
**目的端健康(EFS)**:不自己推,直接看 CloudWatch 现成 EFS 指标
(`PercentIOLimit`、`BurstCreditBalance`、metered throughput)+ 告警即可。

> 多发送机(GCP_SENDERS 非空)经 SSH 收集的路径已实现,待真实多节点环境验证(同 TODO-2)。

---

## 备注
- 真实场景为多对并行(N=M 对 GCP 发送 / AWS 接收),TODO-2 是生产必需项。
- 增量扫描(快照差异 / 变更日志驱动)是另一条独立线,按之前约定单独成脚本,不在此三项内。
