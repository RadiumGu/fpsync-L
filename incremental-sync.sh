#!/bin/bash
# incremental-sync.sh — 增量同步(首次全量之后)
#
# 用法与 shard-plan.sh 完全一致,只是默认走【增量模式】:
#   rsync 加 --update --partial,跳过未变文件、只传新增/变化,不清空目的端。
#   复用 fpsync.env 的全部环境参数与主机分片(发送/接收 1:1 配对、组内串行)。
#
# 前提: 已做过一次全量(shard-plan.sh --apply);源端已重新画像(source-profile.sh)。
#
#   ./incremental-sync.sh            # dry-run:配对预览 + 体检 + 预跑(增量)
#   ./incremental-sync.sh --apply    # 真跑增量
#   ./incremental-sync.sh 4 --apply  # 显式指定分组数 K
#
# 说明: 这是"重跑即增量"(fpart 重爬源 + rsync 跳过未变)。海量文件若嫌重爬慢,
#       后续可接入快照差异/变更日志驱动(另见 TODO)。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/shard-plan.sh" --incremental "$@"
