#!/usr/bin/env bash
# git-cleanup scan v1 — read-only facts for branch/worktree cleanup.
# Emits TSV (default) or key=value records. Never writes to the repository.
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0

FORMAT="tsv"
REPO=""
BASE_ARG=""
SCOPE="local"
NO_SIZE=0
TIME_BUDGET=20
PROTECT=()
START=$SECONDS
DEGRADED=""

usage() {
  cat <<'EOF'
git-cleanup scan v1 — read-only facts, no judgments

Usage: bash scripts/scan.sh [options]

  --repo <path>        repository to inspect (default: cwd)
  --base <ref>        base ref (default: origin/HEAD → origin/main → origin/master → @{u})
  --scope local|remote local branches only (default), or also list remote refs
  --protect <glob>    repeatable; echoes a match flag, applies no policy
  --no-size           skip du measurement of ignored artifacts
  --format tsv|kv     output format (default: tsv)
  --time-budget <s>   stop size measurement after this many seconds (default: 20)
  --help

Records (TSV): META, BRANCH, WORKTREE, REMOTE, ERROR.
Field order is fixed; the last field may contain spaces. Parse with a tab
delimiter, never word splitting. Paths may contain spaces: use --format kv
or split only on tabs.

Exit codes: 0 report produced (dirty repo is data, not failure), 10 bad
arguments, 11 not a git worktree, 12 base unresolved, 20 time budget with
no output.

The script never runs fetch/prune/gc/clean and never writes inside the repo.
GIT_OPTIONAL_LOCKS=0 keeps `status` from refreshing the index.
EOF
}

die() { printf 'ERROR\t%s\t%s\t%s\n' "$1" "$2" "$3"; exit "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2-}"; shift 2 ;;
    --base) BASE_ARG="${2-}"; shift 2 ;;
    --scope) SCOPE="${2-local}"; shift 2 ;;
    --protect) PROTECT+=("${2-}"); shift 2 ;;
    --no-size) NO_SIZE=1; shift ;;
    --format) FORMAT="${2-tsv}"; shift 2 ;;
    --time-budget) TIME_BUDGET="${2-20}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die 10 args "unknown option: $1" ;;
  esac
done

case "$FORMAT" in tsv|kv) ;; *) die 10 args "unsupported format: $FORMAT" ;; esac
[ -n "$REPO" ] || REPO="$(pwd)"
cd "$REPO" 2>/dev/null || die 11 repo "cannot cd to $REPO"
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die 11 repo "not a git worktree"
cd "$TOP" || die 11 repo "cannot cd to $TOP"
GD=$(git rev-parse --absolute-git-dir 2>/dev/null) || die 11 repo "cannot resolve git dir"

IS_BARE=$(git rev-parse --is-bare-repository 2>/dev/null)
IS_SHALLOW=$(git rev-parse --is-shallow-repository 2>/dev/null)
GIT_VERSION=$(git --version | awk '{print $3}')

ops=""
for f in rebase-merge:rebase rebase-apply:rebase MERGE_HEAD:merge \
         CHERRY_PICK_HEAD:cherry-pick BISECT_LOG:bisect; do
  [ -e "$GD/${f%%:*}" ] && ops="${ops:+$ops,}${f##*:}"
done
[ -n "$ops" ] || ops="none"

head_ref=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "(detached)")
head_sha=$(git rev-parse --verify HEAD 2>/dev/null || echo "-")
detached=0; [ "$head_ref" = "(detached)" ] && detached=1

fetch_mtime=$(stat -f %m "$GD/FETCH_HEAD" 2>/dev/null || stat -c %Y "$GD/FETCH_HEAD" 2>/dev/null || echo 0)

# --- base resolution -------------------------------------------------------
resolve_base() {
  if [ -n "$BASE_ARG" ]; then echo "$BASE_ARG|arg"; return 0; fi
  local r
  if r=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
    echo "${r#refs/remotes/}|origin/HEAD"; return 0
  fi
  local c
  for c in origin/main origin/master; do
    if git rev-parse --verify --quiet "$c^{commit}" >/dev/null; then
      echo "$c|$c"; return 0
    fi
  done
  if r=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
    echo "$r|upstream"; return 0
  fi
  return 1
}
resolved=$(resolve_base) || die 12 base "cannot resolve base ref (pass --base)"
BASE_REF="${resolved%|*}"
BASE_VIA="${resolved##*|}"
BASE_SHA=$(git rev-parse --verify --quiet "$BASE_REF^{commit}") || die 12 base "base does not resolve to a commit: $BASE_REF"

OUT=$(mktemp "${TMPDIR:-/tmp}/git-cleanup-scan.XXXXXX") || die 20 io "cannot create temp file"
trap 'rm -f "$OUT"' EXIT

# --- worktrees -------------------------------------------------------------
WT_PATHS=(); WT_HEADS=(); WT_BRANCHES=(); WT_LOCKED=(); WT_PRUNABLE=()
cur_path=""; cur_head=""; cur_branch=""; cur_locked=""; cur_prunable=""
flush_wt() {
  [ -n "$cur_path" ] || return 0
  WT_PATHS+=("$cur_path"); WT_HEADS+=("$cur_head"); WT_BRANCHES+=("$cur_branch")
  WT_LOCKED+=("$cur_locked"); WT_PRUNABLE+=("$cur_prunable")
  cur_path=""; cur_head=""; cur_branch=""; cur_locked=""; cur_prunable=""
}
while IFS= read -r -d '' token; do
  case "$token" in
    "") flush_wt ;;
    "worktree "*) cur_path="${token#worktree }" ;;
    "HEAD "*) cur_head="${token#HEAD }" ;;
    "branch "*) cur_branch="${token#branch }" ;;
    "detached") cur_branch="(detached)" ;;
    "locked") cur_locked="locked" ;;
    "locked "*) cur_locked="${token#locked }" ;;
    "prunable") cur_prunable="prunable" ;;
    "prunable "*) cur_prunable="${token#prunable }" ;;
  esac
done < <(git worktree list --porcelain -z 2>/dev/null)
flush_wt

wt_path_for_branch() {
  local want="$1" i
  for i in "${!WT_BRANCHES[@]}"; do
    [ "${WT_BRANCHES[$i]}" = "$want" ] && { printf '%s' "${WT_PATHS[$i]}"; return 0; }
  done
  printf '%s' "-"
}

# --- branches --------------------------------------------------------------
BRANCH_FILE=$(mktemp "${TMPDIR:-/tmp}/git-cleanup-br.XXXXXX") || die 20 io "temp file"
trap 'rm -f "$OUT" "$BRANCH_FILE"' EXIT

git for-each-ref --format='%(refname)%1f%(objectname)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(committerdate:unix)%1f%(subject)' refs/heads/ > "$BRANCH_FILE" 2>/dev/null

branch_count=0
while IFS=$'\x1f' read -r ref sha upstream track epoch subject; do
  [ -n "$ref" ] || continue
  short="${ref#refs/heads/}"
  # shellcheck disable=SC2046  # words are numbers from rev-list
  set -- $(git rev-list --left-right --count "$BASE_SHA...$ref" 2>/dev/null)
  behind="${1:-0}"; ahead="${2:-0}"
  merge_commits=$(git rev-list --count --merges "$BASE_SHA..$ref" 2>/dev/null || echo 0)
  merged=0
  git merge-base --is-ancestor "$ref" "$BASE_SHA" 2>/dev/null && merged=1
  cherry_out=$(git cherry "$BASE_SHA" "$ref" 2>/dev/null)
  cherry_plus=$(printf '%s\n' "$cherry_out" | grep -c '^+ ')
  cherry_minus=$(printf '%s\n' "$cherry_out" | grep -c '^- ')
  content_eq=0
  git diff --quiet "$BASE_SHA" "$ref" 2>/dev/null && content_eq=1
  tree=$(git rev-parse --verify --quiet "$ref^{tree}" 2>/dev/null || echo "-")
  wt_path=$(wt_path_for_branch "$ref")
  protected=0
  if [ ${#PROTECT[@]} -gt 0 ]; then
    for pat in "${PROTECT[@]}"; do
      # shellcheck disable=SC2254  # glob matching is intentional
      case "$short" in $pat) protected=1 ;; esac
    done
  fi
  [ -n "$track" ] || track="-"
  subject=$(printf '%s' "$subject" | tr '\t\n\037' '   ')
  printf 'BRANCH\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ref" "$sha" "${upstream:--}" "$track" "$ahead" "$behind" "$merged" \
    "$merge_commits" "$cherry_plus" "$cherry_minus" "$content_eq" "$tree" \
    "$wt_path" "${epoch:-0}" "$subject" >> "$OUT"
  branch_count=$((branch_count + 1))
done < "$BRANCH_FILE"

# --- worktree records ------------------------------------------------------
ignored_total=0
for i in "${!WT_PATHS[@]}"; do
  p="${WT_PATHS[$i]}"; b="${WT_BRANCHES[$i]}"
  tracked=0; untracked=0; ign_count=0; ign_bytes=0; au=0; sw=0; sm_dirty=0; sm_uninit=0
  exists=1; [ -d "$p" ] || exists=0
  if [ "$exists" = 1 ]; then
    st=$(git -C "$p" status --porcelain -uall 2>/dev/null)
    if [ -n "$st" ]; then
      untracked=$(printf '%s\n' "$st" | grep -c '^?? ')
      tracked=$(( $(printf '%s\n' "$st" | wc -l) - untracked ))
    fi
    ign=$(git -C "$p" status --porcelain --ignored=matching 2>/dev/null | grep -c '^!! ')
    ign_count="${ign:-0}"
    v=$(git -C "$p" ls-files -v 2>/dev/null)
    au=$(printf '%s\n' "$v" | grep -c '^[a-z] ')
    sw=$(printf '%s\n' "$v" | grep -c '^S ')
    sm=$(git -C "$p" submodule status --recursive 2>/dev/null)
    sm_dirty=$(printf '%s\n' "$sm" | grep -c '^[+Uu] ')
    sm_uninit=$(printf '%s\n' "$sm" | grep -c '^-')
    if [ "$NO_SIZE" = 0 ] && [ "$ign_count" -gt 0 ]; then
      if [ $((SECONDS - START)) -lt "$TIME_BUDGET" ]; then
        kb_total=0
        while IFS= read -r igp; do
          [ -n "$igp" ] || continue
          [ -e "$p/$igp" ] || continue
          kb=$(du -sk "$p/$igp" 2>/dev/null | awk '{print $1}')
          kb_total=$((kb_total + ${kb:-0}))
        done < <(git -C "$p" ls-files -o -i --exclude-standard --directory 2>/dev/null)
        ign_bytes=$((kb_total * 1024))
      else
        DEGRADED="${DEGRADED:+$DEGRADED,}no_size"
      fi
    fi
  fi
  ignored_total=$((ignored_total + ign_bytes))
  nested="-"
  for j in "${!WT_PATHS[@]}"; do
    [ "$i" = "$j" ] && continue
    case "${WT_PATHS[$j]}" in "$p"/*) nested="${WT_PATHS[$j]}" ;; esac
  done
  printf 'WORKTREE\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$p" "${WT_HEADS[$i]:--}" "$b" "$([ "$b" = "(detached)" ] && echo 1 || echo 0)" \
    "${WT_LOCKED[$i]:--}" "${WT_PRUNABLE[$i]:--}" "$tracked" "$untracked" \
    "$ign_count" "$ign_bytes" "$au" "$sw" "$sm_dirty" "$sm_uninit" "$nested" "$exists" >> "$OUT"

  # remote scope
done

if [ "$SCOPE" = "remote" ]; then
  git for-each-ref --format='%(refname)%09%(objectname)' refs/remotes/ 2>/dev/null |
  while IFS=$'\t' read -r ref sha; do
    case "$ref" in */HEAD) continue ;; esac
    merged=0
    git merge-base --is-ancestor "$ref" "$BASE_SHA" 2>/dev/null && merged=1
    printf 'REMOTE\t%s\t%s\t%s\t%s\n' "${ref#refs/remotes/}" "$ref" "$sha" "$merged" >> "$OUT"
  done
fi

elapsed_ms=$(( (SECONDS - START) * 1000 ))
worktree_count=${#WT_PATHS[@]}
[ -n "$DEGRADED" ] || DEGRADED="none"

META=$(printf 'META\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  "$TOP" "$GIT_VERSION" "$IS_SHALLOW" "$IS_BARE" "${BASE_ARG:--}" "$BASE_REF" "$BASE_SHA" \
  "$BASE_VIA" "$head_ref" "$head_sha" "$detached" "$ops" "$fetch_mtime" "$branch_count" \
  "$worktree_count" "$ignored_total" "$DEGRADED" "$elapsed_ms")

if [ "$FORMAT" = "tsv" ]; then
  printf '%s\n' "$META"
  cat "$OUT"
  exit 0
fi

# kv: META.field=value, BRANCH.field=value, ...
{ printf '%s\n' "$META"; cat "$OUT"; } | awk -F'\t' '
BEGIN {
  meta="toplevel git_version shallow bare base_arg base_ref base_sha base_resolved_via head_ref head_sha detached op_in_progress fetch_mtime branch_count worktree_count ignored_bytes_total degraded elapsed_ms"
  branch="refname sha upstream upstream_track ahead_commits behind_commits merged merge_commits cherry_plus cherry_minus content_eq tree worktree_path last_commit_epoch subject"
  worktree="path head branch detached locked prunable tracked_dirty untracked_count ignored_count ignored_bytes assume_unchanged skip_worktree submodule_dirty submodule_uninit nested_in exists"
  remote="remote refname sha merged"
}
$1=="META"     { n=split(meta,a," ");     for(i=1;i<=n;i++) print "META."a[i]"="$ (i+1) }
$1=="BRANCH"   { n=split(branch,a," ");   for(i=1;i<=n;i++) print "BRANCH."a[i]"="$ (i+1) }
$1=="WORKTREE" { n=split(worktree,a," "); for(i=1;i<=n;i++) print "WORKTREE."a[i]"="$ (i+1) }
$1=="REMOTE"   { n=split(remote,a," ");   for(i=1;i<=n;i++) print "REMOTE."a[i]"="$ (i+1) }$1=="ERROR"    { print "ERROR.code="$2; print "ERROR.context="$3; print "ERROR.message="$4 }
'
exit 0
