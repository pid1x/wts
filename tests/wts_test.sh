#!/usr/bin/env bash
# Portable integration tests for wts.
# Works on bash 3.2+.
# Usage: bash tests/wts_test.sh

set -euo pipefail

WTS="./wts"

if [[ ! -x "$WTS" ]]; then
  echo "wts script not found or not executable"
  exit 1
fi

MOCK_BIN=""
TEST_ROOT=""
FAILURES=0
TESTS_RUN=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf 'ok %s\n' "$1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); FAILURES=$((FAILURES + 1)); printf 'not ok %s\n  %s\n' "$1" "$2"; }

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -Fq -- "$needle"; then
    pass "$name"
  else
    fail "$name" "expected to contain: $needle"
  fi
}

assert_not_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -Fq -- "$needle"; then
    fail "$name" "expected NOT to contain: $needle"
  else
    pass "$name"
  fi
}

setup() {
  TEST_ROOT="$(mktemp -d -t wts-test.XXXXXX)"
  MOCK_BIN="$(mktemp -d -t wts-mock.XXXXXX)"

  # Simple, very portable gh mock.
  cat > "$MOCK_BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  # wts queries one branch at a time (--head). Emit the matching PR as
  #   "<number>\t<pr_state>\t<review_status>"
  head=""
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in --head) head="$2"; shift 2 ;; *) shift ;; esac
  done
  case "$head" in
    feat-open-pr)   printf '%d\t%s\t%s\n' 42 OPEN   review_required ;;
    feat-ready-pr)  printf '%d\t%s\t%s\n' 43 OPEN   ready ;;
    feat-merged-pr) printf '%d\t%s\t%s\n' 44 MERGED merged ;;
    main)           printf '%d\t%s\t%s\n' 99 MERGED merged ;;  # stray PR on default branch
  esac
  exit 0
fi

echo "mock gh: unsupported $*" >&2
exit 1
MOCKGH
  chmod +x "$MOCK_BIN/gh"
  export PATH="$MOCK_BIN:$PATH"

  # Create real git repo + worktrees
  mkdir -p "$TEST_ROOT/repo"
  (
    cd "$TEST_ROOT/repo"
    git init -q -b main
    git config user.email t@t
    git config user.name t
    echo hello > README.md
    git add README.md
    git commit -q -m init
  )

  # open pr scenario
  (cd "$TEST_ROOT/repo" && git checkout -q -b feat-open-pr && git commit -q --allow-empty -m wip)
  (cd "$TEST_ROOT/repo" && git checkout -q main && git worktree add -q "$TEST_ROOT/wt-open" feat-open-pr)

  # dirty
  (cd "$TEST_ROOT/repo" && git checkout -q main && git checkout -q -b feat-dirty)
  (cd "$TEST_ROOT/repo" && git checkout -q main && git worktree add -q "$TEST_ROOT/wt-dirty" feat-dirty)
  echo dirty >> "$TEST_ROOT/wt-dirty/README.md"

  # ahead
  (cd "$TEST_ROOT/repo" && git checkout -q main && git checkout -q -b feat-ahead && echo x > x.txt && git add x.txt && git commit -q -m ahead)
  (cd "$TEST_ROOT/repo" && git checkout -q main && git worktree add -q "$TEST_ROOT/wt-ahead" feat-ahead)

  # ready to merge -> should be GREEN
  (cd "$TEST_ROOT/repo" && git checkout -q main && git commit -q --allow-empty -m "ready wip" && git checkout -q -b feat-ready-pr)
  (cd "$TEST_ROOT/repo" && git checkout -q main && git worktree add -q "$TEST_ROOT/wt-ready" feat-ready-pr)

  # merged PR -> should be GREEN (free to reuse)
  (cd "$TEST_ROOT/repo" && git checkout -q main && git checkout -q -b feat-merged-pr && git commit -q --allow-empty -m "merged wip")
  (cd "$TEST_ROOT/repo" && git checkout -q main && git worktree add -q "$TEST_ROOT/wt-merged" feat-merged-pr)

  # path containing a space (regression: porcelain parsing must not split on it)
  (cd "$TEST_ROOT/repo" && git checkout -q main && git worktree add -q "$TEST_ROOT/wt space" -b feat-space)

  # back to main
  (cd "$TEST_ROOT/repo" && git checkout -q main)
}

teardown() {
  [[ -n "${TEST_ROOT:-}" ]] && rm -rf "$TEST_ROOT"
  [[ -n "${MOCK_BIN:-}" ]] && rm -rf "$MOCK_BIN"
}
trap teardown EXIT

setup

echo "=== syntax check ==="
bash -n "$WTS" && pass "syntax ok"

# === classify tests via the binary ===
main_out=$("$WTS" --repo "$TEST_ROOT/repo" --no-color 2>/dev/null || true)
assert_contains "main repo reports GREEN" "$main_out" "GREEN"
assert_contains "main worktree labelled base" "$main_out" "base"

# dirty
dirty_out=$("$WTS" --repo "$TEST_ROOT/wt-dirty" --no-color 2>/dev/null || true)
assert_contains "dirty -> RED" "$dirty_out" "RED"
assert_contains "dirty state label" "$dirty_out" "uncommitted"

# ahead
ahead_out=$("$WTS" --repo "$TEST_ROOT/wt-ahead" --no-color 2>/dev/null || true)
assert_contains "ahead -> RED" "$ahead_out" "RED"
assert_contains "ahead state label" "$ahead_out" "ahead"

# open PR
(cd "$TEST_ROOT/wt-open" && git checkout -q feat-open-pr 2>/dev/null || true)
pr_out=$("$WTS" --repo "$TEST_ROOT/wt-open" --no-color 2>/dev/null || true)
assert_contains "open pr -> YELLOW" "$pr_out" "YELLOW"
assert_contains "open pr state label" "$pr_out" "PR open"
pr_json=$("$WTS" --repo "$TEST_ROOT/wt-open" --json 2>/dev/null || true)
assert_contains "json mentions PR 42" "$pr_json" "42"
assert_contains "json shows review status" "$pr_json" "review needed"

# ready to merge -> GREEN (not YELLOW)
ready_out=$("$WTS" --repo "$TEST_ROOT/wt-ready" --no-color 2>/dev/null || true)
assert_contains "ready to merge -> GREEN" "$ready_out" "GREEN"
assert_contains "ready state label" "$ready_out" "PR ready"

# merged PR -> GREEN, free to reuse
merged_out=$("$WTS" --repo "$TEST_ROOT/wt-merged" --no-color 2>/dev/null || true)
assert_contains "merged pr -> GREEN" "$merged_out" "GREEN"
assert_contains "merged state label" "$merged_out" "PR merged"

# full table + summary
full=$("$WTS" --repo "$TEST_ROOT/repo" --no-color 2>/dev/null || true)
assert_contains "has header" "$full" "Worktree"
assert_contains "has summary line" "$full" "Summary:"

# space path (porcelain parsing must keep it intact, not truncate at the space)
assert_contains "space path shown intact" "$full" "wt space"

# free-only
free=$("$WTS" --repo "$TEST_ROOT/repo" --free-only --no-color 2>/dev/null || true)
assert_not_contains "free-only should not show dirty" "$free" "wt-dirty"

# JSON output is well-formed (regression: paths/branches must be escaped)
json_out=$("$WTS" --repo "$TEST_ROOT/repo" --json 2>/dev/null || true)
assert_contains "json has status field" "$json_out" '"status"'
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$json_out" | python3 -c 'import sys, json; json.load(sys.stdin)' 2>/dev/null; then
    pass "json parses as valid JSON"
  else
    fail "json parses as valid JSON" "python3 json.load rejected the output"
  fi
fi

# short flags behave like their long forms
short_free=$("$WTS" -r "$TEST_ROOT/repo" -f -n 2>/dev/null || true)
assert_not_contains "short -f hides dirty like --free-only" "$short_free" "wt-dirty"
short_json=$("$WTS" -r "$TEST_ROOT/repo" -j 2>/dev/null || true)
assert_contains "short -j emits JSON like --json" "$short_json" '"status"'

# === edge cases in an isolated repo (behind-only, detached HEAD) ===
EDGE="$TEST_ROOT/edge"
mkdir -p "$EDGE"
(
  cd "$EDGE"
  git init -q -b main
  git config user.email t@t
  git config user.name t
  echo a > f.txt && git add f.txt && git commit -q -m c1
  git checkout -q -b feat-behind          # branch sits at c1
  git checkout -q main
  echo b >> f.txt && git add f.txt && git commit -q -m c2   # main moves ahead
)

# behind-only worktree: clean, just behind default -> GREEN (free to reuse)
(cd "$EDGE" && git worktree add -q "$EDGE-wt-behind" feat-behind)
behind_out=$("$WTS" --repo "$EDGE-wt-behind" --no-color 2>/dev/null || true)
assert_contains "behind-only -> GREEN" "$behind_out" "GREEN"
assert_contains "behind-only reports behind count" "$behind_out" "behind"

# detached HEAD must not crash classification
(cd "$EDGE" && git worktree add -q --detach "$EDGE-wt-detached" main)
det_out=$("$WTS" --repo "$EDGE-wt-detached" --no-color 2>/dev/null || true)
assert_contains "detached HEAD still produces a summary" "$det_out" "Summary:"

# regression: the default branch must stay "base" even if a PR has head=main
# (the gh mock returns a merged PR for head=main; classify must not query it).
BASEPR="$TEST_ROOT/basepr"
mkdir -p "$BASEPR"
(
  cd "$BASEPR"
  git init -q -b main
  git config user.email t@t
  git config user.name t
  echo a > f.txt && git add f.txt && git commit -q -m init
)
basepr_out=$("$WTS" --repo "$BASEPR" --no-color 2>/dev/null || true)
assert_contains "default branch stays base with a stray PR" "$basepr_out" "base"
assert_not_contains "default branch not mislabelled as PR merged" "$basepr_out" "PR merged"

# no gh graceful
OLD_PATH=$PATH
PATH=/usr/bin:/bin
no_gh=$("$WTS" --repo "$TEST_ROOT/repo" --no-color 2>/dev/null || true)
assert_not_contains "no-gh does not explode on login message" "$no_gh" "gh auth login"
PATH=$OLD_PATH

echo
printf 'Ran %d tests, %d failures\n' "$TESTS_RUN" "$FAILURES"

[[ $FAILURES -eq 0 ]] && exit 0 || exit 1
