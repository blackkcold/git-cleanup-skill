# 判定原理

SKILL.md 里的每条规则都有实测依据。这份文件只在用户质疑判定时加载。

## 为什么 `git branch --merged` 不够

它只回答"分支 tip 是否是 base 的祖先"。squash merge 与 rebase merge 都会重写提交，tip 不再是祖先，因此这类分支不会出现。更危险的是，它只认 `refs/heads`，且 base 若是本地同名分支会漏报——clone 后本地 `main` 可能落后于 `origin/main`。

## 为什么 `git cherry` 不能作证明

`git cherry` 逐提交比较 patch-id，输出 `+`（未等价）或 `-`（已存在等价补丁）。四种失效方式：

1. 已正常合并的分支输出为**空**，"全为 `-`" 被空集合真空满足。
2. 分支只含 merge commit 时输出为空，而冲突解决方案只存在于 merge 提交里。
3. cherry-pick 后又被 revert 的提交仍显示 `-`，内容其实已不在 base。
4. 单提交分支被 squash 后 patch-id 恰好相同，显示 `-`；多提交 squash 则全部 `+`。

所以它只能当辅助证据，且必须叠加"非空、无 merge 提交、逐文件 blob 一致"。

## 精确的三种证明

- **祖先**：`git merge-base --is-ancestor A B` 为真。
- **内容等价**：`git diff --quiet B A` 为 0，两棵树完全相同。
- **squash 吸收**：`git merge-tree --write-tree B A` 的结果树等于 `B^{tree}`，说明把 A 合进 B 不会产生任何新内容。它计算的是三方合并结果，不受提交历史形状影响，因此比"在 base 历史里找相同 tree"可靠——后者在多分支 squash 时必然找不到，且会被 revert 分支的旧 tree 骗过。

`merge-tree --write-tree` 会写对象，所以扫描时必须把 `GIT_OBJECT_DIRECTORY` 指向临时目录，仓库本身保持零改动。git < 2.38 没有这个用法，按"无法证明"处理。

## ignored 产物

`git status` 默认不列 ignored 文件。`git worktree remove` 对只有 ignored 产物的目录**不加 `--force` 也能成功**，且没有提示。构建目录、签名后的 `.app`、`.dmg`、本地 `.env` 都在这一类。所以 clean 的定义必须是 `status --ignored=matching` 为空，而不是 `status` 为空。

## reflog 不是备份

`git branch -D` 会同时删除 `.git/logs/refs/heads/<branch>`。只有曾经 checkout 过的分支能靠 HEAD reflog 找回；从未 checkout 的分支只剩 `git fsck --lost-found`，受 `gc.pruneExpire`（默认 2 周）约束。默认 `gc.reflogExpire` 是 90 天，但一旦执行 `gc --prune=now` 就归零。

结论：删除前必须建 `refs/backup/cleanup/<date>/<name>`，这是唯一便宜的确定性保险。

## prune 的边界

`git worktree prune` 只删 `.git/worktrees/<id>` 元数据，不删磁盘目录；目录会留下一个指向已删 gitdir 的 `.git` 文件。反过来，先 prune 再 `remove` 会报 `not a working tree`。所以顺序是 remove 在前、prune 在后，且目录处置是独立的一步。

detached 工作树的 `HEAD` 与 `logs/HEAD` 会随 prune 一起消失。prune 前对每个 prunable 条目检查其 HEAD 是否可达，不可达就先建备份 ref。

## 隐藏修改

`assume-unchanged` 与 `skip-worktree` 会让 `git status` 与 `git diff` 都不显示修改。`git ls-files -v` 用小写标记与 `S` 暴露它们。子模块的改动还会被 `diff.ignoreSubmodules=all` 隐藏，必须显式覆盖后重新判脏。

## 名字歧义

短名解析顺序是 `refs/<name>` → `refs/tags/<name>` → `refs/heads/<name>`。当 tag 与分支同名时，`git cherry` 与 `merge-base` 会作用在 tag 上，产出"已合入"的假证明，而 git 只在 stderr 打一行 warning。所有判定命令必须用全限定 ref。
