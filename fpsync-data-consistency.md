# fpsync 数据一致性说明

> fpsync 的一致性保障分两层：**fpsync 本身**只负责调度并判断"每个 rsync 任务是否成功退出"，
> 真正的数据一致性来自底层 **rsync**。

---

## 一、fpsync 这一层的保障

- fpsync 把每个分区交给一个 rsync 任务，并记录每个任务的退出码（`<logdir>/<part>.ret`）。
- 全部任务退出码为 0 → 日志末尾 `Fpsync completed without error` / `Fpsync stopped (with success)`。
- 任意任务非 0 → 报 `completed with errors`，并列出出错的 `.ret` / `.stderr`，该 run 可 `fpsync -r <runid>` 续跑。
- `fpsync -l` 可查看历史 run 状态。

**结论：fpsync 的保证是"每个 rsync 都成功跑完了"，而不是"逐字节比对过了"。**

---

## 二、rsync 这一层的真正机制（关键）

1. **传输中**：rsync 传完每个文件后，接收端会对重建出的文件算一次整文件校验和并与发送端核对，
   不一致会自动重传。**因此传输过程中的损坏（网络/截断）能被自动发现并纠正**，无需额外参数。

2. **决定"要不要传"时（默认 quick check）**：rsync 默认只比较 **文件大小 + mtime**。
   - 两端 size + mtime 一致 → 直接**跳过**，认为相同。
   - 迁移场景通常足够（源没被改、目的是新写的）。
   - 但它**不会去读已存在且 size+mtime 相同的文件内容**——若目的端被旁路改过且大小/时间未变，默认检测不到。

---

## 三、相关参数

| 参数 | 作用 |
|---|---|
| `-c` / `--checksum` | 改用**逐文件校验和**判断是否需要传（而非 size+mtime），能发现内容差异。代价大（两端都要读全部数据），适合校验/对账，不建议常规传输用 |
| `-t`（fpsync 默认含 `-lptgoD` 即带 `-t`） | 保留 mtime，quick check 才准确 |
| `-i` / `--itemize-changes` | 列出每个文件的差异项，配合 `-n` 干跑做对账 |
| `--delete` | 删除目的端多余文件（fpsync 文件模式默认**不删**） |

---

## 四、需要单独校验吗？——建议做，分两档

fpsync 退出成功 ≠ 帮你逐字节对账过。推荐补一次校验：

### 轻量对账（快，基于 size+mtime）
> 之前的验证就是用这个，输出为空即一致。
```bash
rsync -an --itemize-changes /mnt/src/ /mnt/dst/    # 干跑, 无输出 = 一致
# 再核对文件数与总字节
find /mnt/src -type f | wc -l ;  du -sb /mnt/src
find /mnt/dst -type f | wc -l ;  du -sb /mnt/dst
```

### 强校验（慢，逐文件校验和，权威）
> 割接前 / 抽样建议跑。

**推荐: 用 `fpsync-verify.sh`(并发、可多机、读 `fpsync.env`)**
```bash
# 配置驱动: SRC/DST/JOBS/工作目录均取自 fpsync.env;不传参即校验配置里的源↔目的
./fpsync-verify.sh                       # 退出码 0=一致, 2=有差异(清单见输出)
# 多机并发校验(位置参数全部作为 worker 节点, 工作目录需各节点同路径可写):
./fpsync-verify.sh ec2-user@10.1.2.140 ec2-user@10.1.2.81
```

或手工单条 rsync:
```bash
rsync -anc --itemize-changes /mnt/src/ /mnt/dst/   # -c 读全部数据比对内容
```
或两端各自生成校验和清单再 diff（可并行、可分目录）：
```bash
# 源端
cd /mnt/src && find . -type f -print0 | xargs -0 -P8 sha256sum | sort > /tmp/src.sums
# 目的端
cd /mnt/dst && find . -type f -print0 | xargs -0 -P8 sha256sum | sort > /tmp/dst.sums
diff /tmp/src.sums /tmp/dst.sums
```

---

## 五、割接实务建议

1. **传输**：正常用 fpsync（rsync 传输中已有整文件校验，能纠正传输损坏）。
2. **确认**：fpsync 退出成功 + 检查有无非 0 的 `.ret`。
3. **对账**：先 `rsync -an`（快）确认无遗漏；关键数据再 `rsync -anc` 或 sha256 清单做内容级校验。
4. **镜像一致性**：若要求目的端与源**完全一致（含删除）**，最后用一次带 `--delete` 的全量 rsync 收尾对账（fpsync 默认不删多余文件）。
5. **mtime 精度**：跨文件系统（如 EFS）保留 `-t` 时一般没问题；若担心可直接用 `-c`。

---

## 一句话总结

fpsync/rsync 在传输环节**自带整文件校验和、能纠正传输损坏**；但"跳过未变文件"是按 **size+mtime** 判断的。
要 100% 内容一致的强保证，需用 `--checksum` 或独立的 sha256 清单**单独对账一次**。
