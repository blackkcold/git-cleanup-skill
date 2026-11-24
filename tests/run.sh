#!/usr/bin/env bash
# Fixture-based tests for scripts/scan.sh. No network, no user repo access.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ROOT/scripts/scan.sh"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/git-cleanup-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }
check_eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2] got [$3]"; fi; }
check_gt() { if [ "$2" -gt "$3" ] 2>/dev/null; then ok; else bad "$1: expected > $3 got [$2]"; fi; }

export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.com
export GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.com
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

git init -q --bare "$T/origin.git"
git init -q -b main "$T/repo"
cd "$T/repo"
git remote add origin "$T/origin.git"

printf 'build/\n*.log\n' > .gitignore
echo base > f.txt
git add . && git commit -qm "base"
git push -q -u origin main

# merged: fast-forward into main
git checkout -qb merged
echo m >> f.txt && git commit -qam "m1"
git checkout -q main && git merge -q --ff-only merged && git push -q origin main

# squash2: two commits squashed into one
git checkout -qb squash2
echo s1 > s1.txt && git add s1.txt && git commit -qm "s1"
echo s2 > s2.txt && git add s2.txt && git commit -qm "s2"
git checkout -q main && git merge -q --squash squash2 && git commit -qm "squash 2" && git push -q origin main

# cherry3: three commits, one cherry-picked
git checkout -qb cherry3
echo c1 > c1.txt && git add c1.txt && git commit -qm "c1"
PICK=$(git rev-parse HEAD)
echo c2 > c2.txt && git add c2.txt && git commit -qm "c2"
echo c3 > c3.txt && git add c3.txt && git commit -qm "c3"
git checkout -q main
echo drift >> f.txt && git commit -qam "main drift"
git cherry-pick "$PICK" && git push -q origin main

# unique: never merged
git checkout -qb unique
echo u > u.txt && git add u.txt && git commit -qm "u1"
git checkout -q main

# duplicates
git branch dup-a main
git branch dup-b main

# gone: upstream deleted after fetch --prune
git checkout -qb gone
echo g > g.txt && git add g.txt && git commit -qm "g1"
git push -q -u origin gone
git checkout -q main
git push -q origin --delete gone
git fetch -q --prune

# tag shadows a branch name
git branch v1.0 main
git tag v1.0 main

# worktrees
git worktree add -q "$T/wt-ignored" -b wt-ignored main
mkdir -p "$T/wt-ignored/build" && echo artifact > "$T/wt-ignored/build/out.o"
git worktree add -q "$T/wt-untracked" -b wt-untracked main
echo scratch > "$T/wt-untracked/scratch.txt"
git worktree add -q "$T/wt-dirty" -b wt-dirty main
echo change >> "$T/wt-dirty/f.txt"
git worktree add -q "$T/wt-locked" -b wt-locked main
git worktree lock --reason "keep for review" "$T/wt-locked"
git worktree add -q "$T/wt-prunable" -b wt-prunable main
mv "$T/wt-prunable" "$T/wt-prunable-moved"
git worktree add -q "$T/wt-assume" -b wt-assume main
git -C "$T/wt-assume" update-index --assume-unchanged f.txt
echo hidden >> "$T/wt-assume/f.txt"
git worktree add -q --detach "$T/wt-detached" main
git worktree add -q "$T/wt-outer" -b wt-outer main
git worktree add -q "$T/wt-outer/inner" -b wt-inner main
git worktree add -q "$T/wt space" -b spaced main

# --- scan ----------------------------------------------------------------
INDEX_BEFORE=$(cksum .git/index | awk '{print $1":"$2}')
bash "$SCAN" --repo . --base main > "$T/out.tsv"
INDEX_AFTER=$(cksum .git/index | awk '{print $1":"$2}')
check_eq "scan keeps index untouched" "$INDEX_BEFORE" "$INDEX_AFTER"

b() { awk -F'\t' -v r="refs/heads/$1" -v f="$2" '$1=="BRANCH" && $2==r {print $(f)}' "$T/out.tsv"; }
w() { awk -F'\t' -v p="$1" -v f="$2" '$1=="WORKTREE" && $2==p {print $(f)}' "$T/out.tsv"; }

check_eq "META field count" "19" "$(awk -F'\t' '$1=="META"{print NF}' "$T/out.tsv")"
check_eq "merged is ancestor" "1" "$(b merged 8)"
check_eq "squash2 not ancestor" "0" "$(b squash2 8)"
check_eq "squash2 two plus patches" "2" "$(b squash2 10)"
check_eq "cherry3 two plus patches" "2" "$(b cherry3 10)"
check_eq "cherry3 one equivalent patch" "1" "$(b cherry3 11)"
check_eq "gone upstream track" "gone" "$(b gone 5)"
check_eq "gone still has ahead commits" "1" "$(b gone 6)"
check_eq "unique has one ahead commit" "1" "$(b unique 6)"
check_eq "duplicates share sha" "$(b dup-a 3)" "$(b dup-b 3)"
check_eq "tag shadow branch is listed" "refs/heads/v1.0" "$(awk -F'\t' '$1=="BRANCH" && $2=="refs/heads/v1.0"{print $2}' "$T/out.tsv")"

check_eq "ignored-only worktree untracked count" "0" "$(w "$T/wt-ignored" 9)"
check_gt "ignored-only worktree ignored count" "$(w "$T/wt-ignored" 10)" "0"
check_gt "ignored-only worktree ignored bytes" "$(w "$T/wt-ignored" 11)" "0"
check_gt "untracked worktree count" "$(w "$T/wt-untracked" 9)" "0"
check_gt "dirty worktree tracked count" "$(w "$T/wt-dirty" 8)" "0"
check_eq "locked worktree reported" "keep for review" "$(w "$T/wt-locked" 6)"
check_eq "prunable worktree reported" "1" "$(awk -F'\t' -v p="$T/wt-prunable" '$1=="WORKTREE" && $2==p && $7!="-"{print 1}' "$T/out.tsv")"
check_gt "assume-unchanged detected" "$(w "$T/wt-assume" 12)" "0"
check_eq "detached worktree flagged" "1" "$(w "$T/wt-detached" 5)"
check_eq "nested worktree detected" "1" "$(awk -F'\t' -v p="$T/wt-outer" '$1=="WORKTREE" && $2==p && $16!="-"{print 1}' "$T/out.tsv")"
check_eq "worktree path with space parsed" "1" "$(awk -F'\t' -v p="$T/wt space" '$1=="WORKTREE" && $2==p{print 1}' "$T/out.tsv")"
check_eq "worktree record field count" "17" "$(awk -F'\t' '$1=="WORKTREE" && $2=="'"$T"'/wt space"{print NF}' "$T/out.tsv")"

bash "$SCAN" --repo . --base main --format kv > "$T/out.kv"
check_eq "kv format meta" "1" "$(grep -c '^META.toplevel=' "$T/out.kv")"
check_eq "kv format branch" "1" "$(grep -c '^BRANCH.refname=refs/heads/merged$' "$T/out.kv")"

set +e
bash "$SCAN" --repo "$T" --base main >/dev/null 2>&1; code_repo=$?
bash "$SCAN" --repo . --base nope >/dev/null 2>&1; code_base=$?
bash "$SCAN" --repo . --bogus >/dev/null 2>&1; code_arg=$?
set -e
check_eq "non-repo exit" "11" "$code_repo"
check_eq "bad base exit" "12" "$code_base"
check_eq "bad arg exit" "10" "$code_arg"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
