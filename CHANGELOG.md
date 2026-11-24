# Changelog

## v1.0.0 — 2026-11-24

首个公开版本。

### 新增

- `SKILL.md`：完整清理流程——冻结与快照、事实采集、分支判定、工作树判定、无损证明、报告、授权、执行、验证；附反合理化表与 Red Flags。
- `scripts/scan.sh`：只读扫描，输出 TSV / kv。覆盖合并状态、ahead/behind、merge 提交数、cherry 计数、内容等价、ignored 体积、assume-unchanged / skip-worktree、子模块、锁、嵌套、prunable。
- 安全模型：删除前建 `refs/backup/cleanup/*`、报告与执行分离、工作树逐路径确认、默认不动远端与 stash。
- `references/rationale.md`：squash / cherry / merge-tree / reflog / prune / 名字歧义的实测依据。
- `tests/run.sh`：29 条 fixture 断言，覆盖 squash merge、部分 cherry-pick、`:gone`、ignored 产物、锁定 / 嵌套 / 失效工作树、assume-unchanged。
- CI：ShellCheck + fixture 测试。

### 已知限制

- squash 吸收证明需要 git 2.38+；更旧版本降级为“无法证明”，分支保留。
- 不处理 bare 仓库与 shallow clone。
- 远端分支只报告，不删除。
