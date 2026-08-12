#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

write_stub() {
  local name="$1"
  local body="$2"

  cat >"$stub_bin/$name" <<SH
#!/bin/bash
$body
SH
  chmod +x "$stub_bin/$name"
}

run_pkg_cache() {
  PATH="$stub_bin:$PATH" "$ROOT/bin/omarchy-update-pkg-cache"
}

# Record the paccache invocation so the keep count stays pinned above one.
write_stub sudo 'printf "%s\n" "$*" >"$PACCACHE_LOG"; exit 0'

PACCACHE_LOG="$test_tmp/args" run_pkg_cache >"$test_tmp/trim.out" 2>&1
grep -q 'paccache' "$test_tmp/args" || fail "cache trim runs paccache"
grep -qE 'paccache .*-rk2' "$test_tmp/args" ||
  fail "cache trim keeps more than one version" "$(cat "$test_tmp/args")"
pass "cache trim prunes with a rollback version to spare"

# A failed trim is housekeeping, not a reason to abort the whole update.
write_stub sudo 'exit 1'
run_pkg_cache >"$test_tmp/fail.out" 2>&1 ||
  fail "cache trim survives paccache failure"
grep -q 'Could not trim the package cache' "$test_tmp/fail.out" ||
  fail "cache trim warns when pruning fails" "$(cat "$test_tmp/fail.out")"
pass "cache trim warns but does not abort the update"

# The trim only protects rollback if it runs before packages are updated, and it
# only frees space if it runs before the snapshot pins the extents it prunes.
line_of() {
  grep -n "^[[:space:]]*$1\b" "$ROOT/bin/omarchy-update" | head -1 | cut -d: -f1
}

cache_line=$(line_of omarchy-update-pkg-cache)
snapshot_line=$(line_of omarchy-snapshot)
pkgs_line=$(line_of omarchy-update-system-pkgs)
[[ -n $cache_line && -n $snapshot_line && -n $pkgs_line ]] ||
  fail "omarchy-update runs the cache trim, the snapshot, and the packages update"

(( cache_line < pkgs_line )) ||
  fail "cache trim runs before the packages update" "trim: $cache_line, packages: $pkgs_line"
pass "cache trim runs before the packages update"

(( cache_line < snapshot_line )) ||
  fail "cache trim runs before the snapshot" "trim: $cache_line, snapshot: $snapshot_line"
pass "cache trim runs before the snapshot pins what it prunes"
