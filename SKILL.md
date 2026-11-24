---
name: git-cleanup
description: "Use when 本地分支或工作树堆积需要清理——几十个分支只剩几个还在用、`git worktree list` 一屏放不下、目录已删但仍报 prunable、分支显示 `:gone`、磁盘被 ignored 产物吃满而 `git status` 却是 clean、prune 之后留下一片空目录——或准备交接仓库、做例行仓库卫生、想删分支但怕误删未合入提交时。Keywords: git branch cleanup, git worktree remove, prune, stale branch, merged branch, gone upstream, squash-merged, patch-id, cherry-pick equivalence, orphaned worktree, dangling worktree, ignored build artifacts, reclaim disk space, repo hygiene."
---

# Git Cleanup

安全清理本地分支与工作树：**先证明删除不会丢内容，再动手**。

三条不可妥协的原则：

1. **证明先于销毁。** 每个 `-D` 之前必须有内容级证明，并已建好 rescue ref。
2. **报告与执行分离。** 没拿到对应范围的授权，一步不动。
3. **工作树逐个点名。** ignored 产物不计入 `git status`，必须单独量化、单独确认。

一次真实清理的规模：39 个本地分支 → 1，10 个工作树 → 1，释放 9.3 GB。其中 7 个 `git status` 显示 clean 的工作树藏着 719 MB 未入库的已签名 `.app`/`.dmg`；`git worktree remove` 删除它们时不提示、也不需要 `--force`。

## When to Use

- 分支堆积：几十个分支，只有几个还在用。
- 工作树堆积：`git worktree list` 一屏放不下，或出现 `prunable`。
- 分支显示 `:gone`，但不确定能不能删。
- 仓库很大而 `git status` 却是 clean。
- prune 之后留下空目录或 "not a git repository" 的残留目录。
- 交接仓库、例行卫生、想删分支但怕误删未合入提交。

## When NOT

- 目录不是 git 仓库，或目标是 bare 仓库（本 skill 不处理 bare）。
- 用户只想看提交历史、diff、blame。
- 用户已明确指定要删的分支名和删除方式——照做即可，不需要本流程。
- 仓库处于 shallow clone（历史不完整，所有合并判定都会给假阴性）。

## 输入与默认

| 参数 | 默认 | 说明 |
|---|---|---|
| `repo` | 当前目录 | 由 `git rev-parse --show-toplevel` 归一 |
| `base` | `origin/HEAD` → `origin/main` → `origin/master` → `@{u}` | 解析后**冻结为 SHA**，全程只引用该 SHA |
| `scope` | `local` | 远端分支只报告，不删除 |
| `keep` | 空 | 额外保护名单，按 `casefold + Unicode NFC` 归一后比较 |
| `dry-run` | 恒为真 | 本流程没有"自动执行"模式 |

## Phase 0 冻结与快照

按顺序执行，任一条不满足就停止：

```bash
git rev-parse --show-toplevel
git rev-parse --is-bare-repository      # true → 停止
git rev-parse --is-shallow-repository   # true → 停止，先 fetch --unshallow（需单独授权）
GD=$(git rev-parse --absolute-git-dir)
test -e "$GD/rebase-merge" -o -e "$GD/rebase-apply" -o -e "$GD/MERGE_HEAD" \
  -o -e "$GD/CHERRY_PICK_HEAD" -o -e "$GD/BISECT_LOG"   # 存在 → 停止
```

**快照先于一切变更**（包括 fetch）：

```bash
SNAP_DIR=$(mktemp -d)
git for-each-ref --format='update %(refname) %(objectname)' \
  refs/heads refs/remotes refs/tags > "$SNAP_DIR/refs-before.txt"
# 仓库小于 1GB 时追加完整备份
git bundle create "$SNAP_DIR/repo.bundle" --all
```

恢复方式：`git update-ref --stdin < "$SNAP_DIR/refs-before.txt"`。

**`git fetch --prune` 是写操作，必须单独授权。** 推荐只用 `--no-prune`：

```bash
git fetch --no-prune --all          # 需授权
git remote prune origin --dry-run   # 只报告将被删除的远端跟踪 ref
```

解析并冻结 base：

```bash
BASE=$(git symbolic-ref --quiet refs/remotes/origin/HEAD | sed 's#^refs/remotes/##') \
  || BASE=origin/main
BASE_SHA=$(git rev-parse --verify "$BASE^{commit}")
```

解析失败立即中止；**禁止空参数或 HEAD 兜底**（`git branch --merged` 无参数等于 merged into HEAD）。

名字歧义检查：短名可能被同名 tag 遮蔽，而 git 只在 stderr 给一行 warning。

```bash
git rev-parse --symbolic-full-name "$NAME"   # 必须等于 refs/heads/$NAME
```

不相等、或输出含 `is ambiguous`，整批中止。之后所有命令**只使用全限定 ref**：`refs/heads/x`、`refs/remotes/origin/x`。

## Phase 1 采集

```bash
bash scripts/scan.sh --repo . --base "$BASE_SHA"
```

脚本只输出**事实**（TSV），不做判定：`merged`、`ahead_commits`、`merge_commits`、`cherry_plus`、`cherry_minus`、`content_eq`、`ignored_bytes`、`locked_reason`、`prunable`、`hidden_flags`、`submodule_state` 等。判定全部在 Phase 2 与 Phase 4。

## Phase 2 分支判定

| 判定 | 条件 | 动作 | 授权 |
|---|---|---|---|
| 保护 | `BASE_SHA` / 当前 HEAD / `keep` 名单 | 永不删 | — |
| 已合入 | `git merge-base --is-ancestor refs/heads/x "$BASE_SHA"` | 建 rescue ref，再在 base 工作树 `branch -d` | 批量 |
| 内容等价 | `git diff --quiet "$BASE_SHA" refs/heads/x` 为 0，且 `ahead_commits > 0` | 建 rescue ref 后 `-D` | 逐项 |
| 补丁等价 | 见 Phase 4 的四个条件全部成立 | 建 rescue ref 后 `-D` | 逐项 |
| 重复祖先 | 另一个保留分支 `--contains` 命中 | 只删重复名 | 逐项 |
| 独有提交 | 以上都不成立 | 保留，列出差异文件 | 用户决策 |
| 上游 `:gone` | **属性，不是判定** | 不构成删除理由 | — |

判定顺序即优先级。`merged` 为假不代表没合入——squash merge 的分支不在 `--merged` 里。

## Phase 3 工作树判定

| 判定 | 条件 | 动作 | 授权 |
|---|---|---|---|
| 锁定 | `locked` 非空 | 跳过；需用户先 `git worktree unlock` | — |
| 嵌套 | 路径前缀包含另一个已注册工作树 | 跳过 | — |
| 被占用 | `lsof +D <path>` / `pgrep -fl <basename>` / `index.lock` 命中 | 跳过 | — |
| 隐藏修改 | `git ls-files -v` 有 `^[a-z]`（assume-unchanged）或 `^S `（skip-worktree）；或子模块脏（覆盖 `ignoreSubmodules`） | 按"有跟踪修改"处理 | — |
| 有跟踪修改 | `status --porcelain -uall` 有非 `??` 行 | 禁止删除 | 用户处理 |
| 有产物 | 未跟踪文件，或 `ignored_bytes > 0` | 清单 → 归档 → 逐路径确认 | 逐路径 |
| 干净 | 以上均无 | `git worktree remove -- <path>` | 逐路径 |
| prunable | gitdir 指向不存在 | 先备份其 HEAD ref，再 `remove` | 逐路径 |
| 子模块已初始化 | 存在 `.gitmodules` 且 `submodule status` 有输出 | 先 `submodule deinit`，或逐路径确认后才 `-f` | 逐路径 |

**clean 的真实定义**：`status --porcelain -uall` 为空 **且** `ls-files -v` 无小写标记 **且** 子模块全净。只看 status 会把 ignored 与隐藏修改当成干净。

## Phase 4 无损证明

四种证明，任一成立即可进入对应动作；**都不成立就是"无法证明"，保留**。

```bash
# A. 已合入（祖先关系）
git merge-base --is-ancestor refs/heads/x "$BASE_SHA"

# B. 内容等价（tree 完全相同）
git diff --quiet "$BASE_SHA" refs/heads/x

# C. squash 吸收（合并结果相对 base 无新增）
TMPOBJ=$(mktemp -d)
M=$(GIT_OBJECT_DIRECTORY="$TMPOBJ" \
    GIT_ALTERNATE_OBJECT_DIRECTORIES="$(git rev-parse --absolute-git-dir)/objects" \
    git merge-tree --write-tree "$BASE_SHA" refs/heads/x) || echo "无法判定"
[ "$M" = "$(git rev-parse "$BASE_SHA^{tree}")" ] && echo absorbed
```

`merge-tree` 会写对象，所以必须重定向 `GIT_OBJECT_DIRECTORY`，保证仓库本身零改动。git < 2.38 不支持该用法，视为无法证明。

```bash
# D. 补丁等价：四个条件全部成立
git rev-list --count "$BASE_SHA..refs/heads/x"            # > 0
git rev-list --count --no-merges "$BASE_SHA..refs/heads/x" # 与上一行相等
git cherry "$BASE_SHA" refs/heads/x                        # 非空，且每行都以 "-" 开头
git diff --name-only "$BASE_SHA" refs/heads/x | while IFS= read -r p; do
  [ "$(git rev-parse "$BASE_SHA:$p" 2>/dev/null)" = "$(git rev-parse "refs/heads/x:$p" 2>/dev/null)" ] \
    || echo "DIFF $p"
done
```

**`git cherry` 永远不能单独作为证明**：已合并分支输出为空（vacuous），revert 后仍显示 `-`，单提交 squash 也显示 `-`，只含 merge 提交的分支输出为空。

## Phase 5 报告契约

按宿主能力取第一档可用，并在报告首行注明用了哪档：

1. 有 `openchamber_render` → `render.page`，一页，`title: "Git Cleanup — {repo}"`。
2. 有 openui-lang（`Table` / `Details`）→ 用块，不写 HTML。
3. 其他 CLI/TUI → markdown 表，首行写 `渲染降级：<宿主> 无 render.page`。

四块顺序不可调换：

1. **HEAD 概要**：分支、base、ahead/behind、工作区状态。
2. **可清理清单**：分支｜判定｜本地｜远端｜占用工作树。
3. **保留与需决策**：独有提交、未合入、需要归档的产物。
4. **执行结果**：Phase 8 回填，未执行时写"未执行"。

空块写 `（无）`。**不得出现采集结果里没有的分支名。**

## 回滚前提（必须在授权前说明）

- 每个待删分支先建 rescue ref，报告里列出：

  ```bash
  git update-ref "refs/backup/cleanup/$(date +%Y%m%d)/$NAME" "$(git rev-parse "refs/heads/$NAME")"
  ```

- **reflog 不是备份**：`branch -D` 会同时删除该分支自己的 reflog；从未 checkout 过的分支只剩 `git fsck --lost-found`（默认 2 周，受 `gc.pruneExpire` 控制）。
- 工作树目录**不要 `rm -rf`**：先 `tar` 到仓库外并 `shasum -a 256` 校验，再交给 `git worktree remove`。
- 远端分支删除**不可回滚**（只能重建再 push），默认不做。
- rescue ref 至少保留 7 天；清理它需要用户单独确认。

## Phase 6 授权

三档，互不替代：

| 档位 | 覆盖范围 | 明确不覆盖 |
|---|---|---|
| 批量 | 已合入分支的 `-d` | `-D`、工作树、远端 |
| 逐项 | 单个 `-D` 分支 | 其他分支、工作树 |
| 逐路径 | 单个工作树及其产物 | 其他工作树、分支、远端 |

授权工作树时必须同时给出：路径、体积、未入库文件数、会被删除的 ignored 产物清单。产物只有两种合法处置：

1. **归档**：`tar -czf <仓库外>/wt-<name>.tgz …` + `shasum -a 256`，再删。
2. **明确丢弃**：用户逐路径选择"不留档"，报告记录被丢弃的清单与体积。

## Phase 7 执行顺序（不可交换）

```bash
# 1. 救援 ref：所有待删分支（含 -d 的）
git update-ref refs/backup/cleanup/<date>/<name> <sha>

# 2. 逐个移除工作树（先于分支删除）
git worktree remove -- <path>
# 失败即停；不重试加力

# 3. 只读检查 prune 目标，再 prune
git worktree prune -n
git worktree prune

# 4. 已合入分支：在 base 所在工作树执行，禁止让 upstream 参与证明
git -C <base-worktree> branch -d -- <short>

# 5. 已证明的 -D
git branch -D -- <short>

# 6. 孤儿目录单独一步：断言非软链、realpath 在允许根内，才处理
```

为什么是这个顺序：

- `prune` 先跑会让元数据消失，之后 `remove` 报 `not a working tree`。
- 分支被工作树检出时 `-d` 必然失败，先 remove 才顺。
- `worktree remove` 会连带删掉该工作树的 `logs/HEAD`，所以合入证明与 rescue ref 必须**先于** remove。
- `-d` 的判定是 HEAD 或 upstream，任一命中就放行（只打 warning）；因此它不能当作"base 已含"的证据。

## Phase 8 验证与残留

| 检查 | 期望 |
|---|---|
| `git for-each-ref refs/heads \| wc -l` | 等于报告中的剩余数 |
| `git worktree list --porcelain` | 只含预期保留项 |
| `git rev-list --left-right --count "$BASE_SHA...HEAD"` | 与执行前的差异可解释 |
| `git status --porcelain -uall` | clean |
| `git for-each-ref refs/backup/cleanup` | 每个被删分支都有 rescue ref |
| `find <worktree-parent> -maxdepth 2 -name .git -type f` | 无指向已删 gitdir 的残留 |

结果块追加到同一份报告，写清：删了多少分支、移除多少工作树、释放多少空间、保留了哪些、残留了哪些。

prune 之后目录可能仍在（空目录或指向已删 gitdir 的 `.git` 文件）。目录处置是独立一步，逐路径确认；`git worktree prune` 只删元数据。

## 失败处理

| 现象 | 原因 | 处理 |
|---|---|---|
| `branch -d` 报 not fully merged | HEAD 不是 base，或确未合入 | 回到 Phase 4 证明；不要直接升级 `-D` |
| `-d` 成功但 warning merged to upstream | 证明来自 upstream，不是 base | 视为未证明，改用逐项 `-D` |
| `remove` 报 contains modified or untracked files | 有未跟踪文件或已跟踪修改 | 停止，走产物清单流程；不要自动 `--force` |
| `remove` 报 locked | 工作树被 lock | 跳过，交用户 `unlock` |
| `remove` 报 submodules cannot be removed | 子模块已初始化 | `submodule deinit` 后再试，或逐路径确认 `-f` |
| `remove` 报 not a working tree | 已 prune 或路径错误 | 用 `worktree prune` 清元数据，不要 `rm -rf` |
| `merge-tree` 报 unknown option | git 太旧 | 视为无法证明，保留分支 |
| `fetch` 403 / 网络失败 | 无凭据或离线 | 跳过远端同步，按本地已知状态报告（`fetch_state=stale`） |

## 反合理化

| 借口 | 现实 |
|---|---|
| "status 是干净的，可以删" | ignored 产物不出现在 status；先跑 `--ignored=matching` |
| ":gone 说明远端都不要了" | 远端删了提交仍在本地；看 `ahead_commits` |
| "`-d` 失败了，加 `-D` 就行" | 失败可能只是 HEAD 不对；先证明，再逐项授权 |
| "cherry 全是 `-`，肯定合过了" | 空输出、merge 提交、revert 都会骗过它 |
| "prune 只删元数据，无害" | detached 工作树的 HEAD 与 reflog 一起消失 |
| "工作树干净，直接 `rm -rf` 更快" | 那是数据销毁；先归档，再走 `worktree remove` |
| "reflog 能找回" | `-D` 会删分支自己的 reflog；未 checkout 的只剩约 2 周 |
| "一次确认就够了" | 删分支 ≠ 删工作树 ≠ 删远端 ≠ 删 ignored 产物 |

## Red Flags

出现任一条，立即停止并回到报告阶段：

- 命令里出现 `--force`、`-f -f`、`rm -rf`。
- 用 `git update-ref -d refs/heads/*` 代替 `git branch -d/-D`。
- 先 `prune` 再 `remove`。
- 没有 rescue ref 就 `-D`。
- 对 locked、嵌套、被进程占用的工作树继续执行。
- 报告里出现采集结果之外的分支名，或把体积写成估计值。

## 快速参考

只读：

```bash
git rev-parse --is-bare-repository --is-shallow-repository
git for-each-ref --format='%(refname:short) %(objectname:short) %(upstream:track)' refs/heads
git branch --merged "$BASE_SHA"
git worktree list --porcelain
git -C <wt> status --porcelain -uall
git -C <wt> status --porcelain --ignored=matching
git -C <wt> ls-files -v
git -C <wt> submodule status --recursive
```

写操作（全部需要 Phase 6 授权）：

```bash
git update-ref refs/backup/cleanup/<date>/<name> <sha>
git worktree remove -- <path>
git worktree prune
git branch -d -- <short>
git branch -D -- <short>
git push origin --delete <branch>   # 默认不做，需单独授权
```

## 相关技能

**REQUIRED:** 执行任何删除前，先读 `~/.config/opencode/memory/SAFETY_RULES.md`。
工作树的创建与迁移用 `using-git-worktrees`；提交历史操作不在本技能范围。
