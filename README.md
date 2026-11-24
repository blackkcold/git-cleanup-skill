# git-cleanup

[![CI](https://github.com/blackkcold/git-cleanup-skill/actions/workflows/ci.yml/badge.svg)](https://github.com/blackkcold/git-cleanup-skill/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/blackkcold/git-cleanup-skill?display_name=tag&sort=semver)](https://github.com/blackkcold/git-cleanup-skill/releases)
[![License: MIT](https://img.shields.io/github/license/blackkcold/git-cleanup-skill)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)](#requirements)
[![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](#requirements)
[![OpenCode skill](https://img.shields.io/badge/OpenCode-skill-6E56CF)](https://opencode.ai)

**先证明不会丢内容，再删除。** 一个用于安全清理 Git 分支与工作树的 OpenCode skill。

> Safely clean stale Git branches and worktrees. Every deletion is backed by a
> content-level proof and a rescue ref; worktrees are confirmed one path at a time.

## 为什么

`git status` 干净不等于工作树里没有东西。`.build/`、`release/*.app`、`*.dmg`、本地 `.env` 都被 `.gitignore` 覆盖，`git worktree remove` 删除它们时不提示、也不需要 `--force`。`git branch --merged` 看不见 squash merge；`git cherry` 在空输出、merge 提交、revert 和单提交 squash 四种情况下都会给出错误结论。

这个 skill 把这些坑写成固定流程：先采集事实，再按矩阵判定，逐条证明，最后才执行；每个待删分支先建 rescue ref，每个工作树单独点名确认。

一次真实清理：**39 个本地分支 → 1，10 个工作树 → 1，释放 9.3 GB**。其中 7 个 `git status` 显示 clean 的工作树里藏着 719 MB 未入库的已签名构建产物。

## 安全模型

1. **证明先于销毁**：`-D` 之前必须有内容级证明，并已建 `refs/backup/cleanup/<date>/<name>`。
2. **报告与执行分离**：批量、逐项、逐路径三档授权互不替代。
3. **工作树逐个点名**：路径、体积、未入库文件数、ignored 产物清单，全部先报后删。
4. **默认不碰远端**：远端分支只报告；`git fetch --prune` 也需要单独授权。
5. **不动 stash、不跑 gc**：reflog 只当线索，不当备份。

## 安装

```bash
git clone https://github.com/blackkcold/git-cleanup-skill.git
cd git-cleanup-skill
./install.sh
```

默认安装到 `${OPENCODE_SKILLS_DIR:-$HOME/.config/opencode/skills}/git-cleanup`，可用 `--dest` 指定。安装后重启宿主，让它重新读取 skills 目录。

手动安装只需要三个文件：

```text
~/.config/opencode/skills/git-cleanup/
├── SKILL.md
├── scripts/scan.sh
└── references/rationale.md
```

## 使用

在 OpenCode 里直接说：

> 看看这个仓库有哪些分支和工作树可以清理

或手动运行只读扫描：

```bash
bash ~/.config/opencode/skills/git-cleanup/scripts/scan.sh --repo . --base origin/main
bash ~/.config/opencode/skills/git-cleanup/scripts/scan.sh --repo . --format kv
bash ~/.config/opencode/skills/git-cleanup/scripts/scan.sh --repo . --scope remote
```

`scan.sh` 只输出事实，不做判定，也从不写仓库：`GIT_OPTIONAL_LOCKS=0`，不 fetch、不 prune、不 gc、不 clean。

## 判定一览

**分支**

| 判定 | 依据 | 动作 |
|---|---|---|
| 保护 | base / 当前 HEAD / keep 名单 | 永不删 |
| 已合入 | `merge-base --is-ancestor` | 建 rescue ref 后 `-d` |
| 内容等价 | `git diff --quiet` 为 0 | 建 rescue ref 后 `-D` |
| 补丁等价 | 非空、无 merge、`cherry` 全 `-`、逐文件 blob 一致 | 建 rescue ref 后 `-D` |
| 重复祖先 | 另一保留分支已包含 | 只删重复名 |
| 独有提交 | 以上都不成立 | 保留并列出差异 |

**工作树**

| 判定 | 依据 | 动作 |
|---|---|---|
| 锁定 / 嵌套 / 被占用 | `locked`、路径包含、`lsof` | 跳过 |
| 隐藏修改 | `ls-files -v` 的 `h`/`S`、子模块脏 | 按有修改处理 |
| 有跟踪修改 | `status` 非 `??` 行 | 禁止删除 |
| 有产物 | 未跟踪文件或 ignored 字节 | 清单 → 归档 → 逐路径确认 |
| 干净 | 以上均无 | `worktree remove` |

## 它不会做什么

- 不执行 `git push --delete`（除非单独授权）。
- 不使用 `git update-ref -d refs/heads/*` 绕过 git 的保护。
- 不对 `worktree remove` 自动加 `--force`。
- 不删除 stash，不运行 `git gc --prune=now`。
- 不在 shallow clone 或 bare 仓库上做合并判定。
- 不编造采集结果里没有的分支名。

## 要求

- git **2.38+**（`merge-tree --write-tree`；更旧的版本会把 squash 判定降级为"无法证明"）
- bash 3.2+（macOS 自带版本即可）
- macOS 或 Linux

## 开发

```bash
bash tests/run.sh
```

测试在临时目录里生成 16 类 fixture（含 squash merge、部分 cherry-pick、`:gone`、忽略产物、锁定/嵌套/失效工作树、assume-unchanged 等），不联网、不访问用户仓库。CI 会额外跑 ShellCheck。

目录结构：

```text
.
├── SKILL.md                 # 技能主体：流程、判定矩阵、命令、红线
├── scripts/scan.sh          # 只读扫描，输出 TSV / kv
├── references/rationale.md  # 判定原理与实测依据
├── tests/run.sh             # fixture 测试
├── install.sh               # 安装到 OpenCode skills 目录
└── .github/workflows/ci.yml
```

## 许可

[MIT](LICENSE)

## 安全

发现会导致内容丢失的判定漏洞，请开 issue 并附最小复现仓库，不要附真实仓库数据。
