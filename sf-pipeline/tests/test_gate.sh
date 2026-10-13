#!/usr/bin/env bash
# Tests for gate.sh — the run-time permission checks behind the entry-stage approval gate and the
# bypass label — with a stub `gh`. They prove, without a second GitHub account:
#   - only admin and maintain count as admin; write, triage, read and unknown users do not
#   - the role is asked of the GitHub API at run time (collaborators/<login>/permission)
#   - the labeler is the LAST person who added the label
#   - drop-label removes the label and comments why
set -uo pipefail
# shellcheck source=helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

T="$(new_tmp)"
BIN="$T/bin"
LOG="$T/gh.log"
write_stub "$BIN" gh <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
case "$*" in
  *collaborators/alice-admin/permission*) echo "admin" ;;
  *collaborators/mo-maintain/permission*) echo "maintain" ;;
  *collaborators/dev-writer/permission*) echo "write" ;;
  *collaborators/tri-triage/permission*) echo "triage" ;;
  *collaborators/*/permission*) exit 1 ;;
  *issues/7/events*) printf 'dev-writer\nalice-admin\ndev-writer\n' ;;
  "api -X DELETE"*) exit 0 ;;
  "pr comment"*) exit 0 ;;
esac
exit 0
EOF

gate() { RC=0; OUT="$(PATH="$BIN:$PATH" GH_LOG="$LOG" GITHUB_REPOSITORY=acme/sf GH_TOKEN=x bash "$SCRIPTS_DIR/gate.sh" "$@" 2>&1)" || RC=$?; }

section "is-admin: only admin and maintain pass"
: >"$LOG"
gate is-admin alice-admin; assert_eq 0 "$RC" "admin passes"
gate is-admin mo-maintain; assert_eq 0 "$RC" "maintain passes"
gate is-admin dev-writer; assert_eq 1 "$RC" "write does not pass"
gate is-admin tri-triage; assert_eq 1 "$RC" "triage does not pass"
gate is-admin stranger; assert_eq 1 "$RC" "an unknown user does not pass"
gate is-admin ""; assert_eq 1 "$RC" "an empty login does not pass"
assert_contains "$(cat "$LOG")" "repos/acme/sf/collaborators/dev-writer/permission" "the role is asked of the API at run time"

section "role"
gate role dev-writer; assert_eq "write" "$OUT" "role prints the role name"
gate role stranger; assert_eq "none" "$OUT" "an unknown user is none"

section "labeler: the last person who added the label"
gate labeler 7 approved; assert_eq "dev-writer" "$OUT" "the most recent labeler wins (not an earlier admin)"

section "drop-label: removes the label and explains"
: >"$LOG"
gate drop-label 7 approved "only admins may approve the entry stage"
assert_eq 0 "$RC" "drop-label exits 0"
assert_contains "$(cat "$LOG")" "api -X DELETE repos/acme/sf/issues/7/labels/approved" "removes the label"
assert_contains "$(cat "$LOG")" "pr comment 7 --repo acme/sf --body only admins may approve the entry stage" "comments why"

section "usage"
gate bogus; assert_eq 2 "$RC" "an unknown command is a usage error"

finish
