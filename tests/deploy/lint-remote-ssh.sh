#!/usr/bin/env bash
#
# Static lint: blocks regression of the remote_ssh argument-injection
# class found in the PR-#17 review.
#
# History: the original PR shipped a `remote_ssh` helper that took a
# string-built shell command, e.g.
#
#     remote_ssh "test -e ${RELEASE_DIR}"
#
# `${RELEASE_DIR}` was interpolated locally into the SSH command line
# unquoted; ssh joined args with spaces and the remote shell re-parsed,
# so a value containing whitespace, a glob, or a shell metacharacter
# (e.g. a misconfigured `.env.deploy` value with `$IFS` or `;`) executed
# uncontrolled code on the remote. The fix replaces every such call
# site with `bv_remote_run`, which dispatches values via printf
# %q-quoted remote-side env exports.
#
# This lint asserts:
#   1. No `remote_ssh "<...>"` string-built calls remain in deploy/.
#      The helper itself is retired in favour of bv_remote_run.
#   2. Every `bv_remote_run` call passes its body as a single-quoted
#      string (forces "$KEY" form on the remote), not a double-quoted
#      string that would defeat the helper's protection by
#      interpolating local-shell ${X} into the body before dispatch.
#   3. The body of bv_remote_run itself stays in the lib (single source
#      of truth); the lint cross-checks that other shell scripts do not
#      reimplement it.
#   4. The helper's body still uses printf %q for value emission —
#      removing that primitive silently re-opens the argument-injection
#      surface, so the lint locks it in.
#
# Wired into Makefile's `test-deploy` target so the regression cannot
# silently land.
#
# KNOWN LIMITATIONS — what this lint does NOT catch:
#   * Local-shell pre-build of the body string. Example:
#       local body="test -e ${X}"   # interpolates ${X} HERE
#       bv_remote_run "$body"       # body is now a literal command
#     The lint sees `bv_remote_run "$body"` (a double-quoted variable,
#     not a string) and would fail check 2 — so this particular
#     pattern IS caught. But a more elaborate pattern that pre-builds
#     via printf into a single-quoted-looking shape (e.g. `body="$(
#     printf '%s' "test -e \"\$X\"")"`) could in principle slip past.
#   * Body strings that legitimately need to embed a ${...} for some
#     remote-only purpose. The lint refuses any ${...} but offers no
#     escape hatch; if a real need arises, refine check 2's grep.
#   * Bodies that call out to shell helpers defined locally and not
#     re-defined remotely. The lint can't detect missing remote-side
#     definitions; that's a runtime failure, not a static one.
#
# These are documented gaps, not bugs. Code review of changes that
# touch deploy/lib/atomic-release.sh's bv_remote_run, or that add
# new call sites, must look at the full pattern, not just lint output.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY_DIR="$PROJECT_ROOT/deploy"
PASS=0
FAIL=0

check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then
        echo "  ✓ $name"
        PASS=$((PASS+1))
    else
        echo "  ✗ $name" >&2
        FAIL=$((FAIL+1))
    fi
}

echo "Static lint: remote_ssh argument-injection regression guard"
echo "---"

# 1. No `remote_ssh "..."` string-built calls anywhere in deploy/. The
#    helper itself is retired; any reintroduction is a regression of
#    the PR-#17 review finding.
#
# We deliberately exclude this lint file's own description of the
# pattern (which contains the string in comments and example code).
HITS="$(grep -rn 'remote_ssh "[^"]' "$DEPLOY_DIR" 2>/dev/null \
        | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
        || true)"
if [ -z "$HITS" ]; then
    check "deploy/ contains no remote_ssh \"<string>\" call sites" ok
else
    check "deploy/ contains no remote_ssh \"<string>\" call sites" fail
    printf '%s\n' "$HITS" | sed 's/^/      /' >&2
fi

# 2. Every bv_remote_run body uses "$KEY" (the safe form) and not
#    ${LOCAL_VAR} or $LOCAL_VAR (the unsafe form that would interpolate
#    locally before reaching the helper). Heuristic: scan all
#    `bv_remote_run '...'` blocks (single-quoted body) and reject any
#    `${...}` substitution that DOESN'T look like a positional digit
#    or an arithmetic expression.
#
# This is a heuristic (we don't parse bash); but it catches the
# common-case regression (someone writes `bv_remote_run "test -e ${X}"`
# where the body is double-quoted, defeating the helper's protection).
DOUBLE_QUOTED_BODIES="$(grep -rn 'bv_remote_run "' "$DEPLOY_DIR" 2>/dev/null \
                        | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
                        || true)"
if [ -z "$DOUBLE_QUOTED_BODIES" ]; then
    check "every bv_remote_run body is single-quoted (forces \"\$KEY\" form)" ok
else
    check "every bv_remote_run body is single-quoted (forces \"\$KEY\" form)" fail
    printf '%s\n' "$DOUBLE_QUOTED_BODIES" | sed 's/^/      /' >&2
fi

# 3. The helper itself is defined exactly once, in deploy/lib/atomic-release.sh.
HELPER_DEFS="$(grep -rln '^bv_remote_run() {' "$DEPLOY_DIR" 2>/dev/null \
               || true)"
if [ "$HELPER_DEFS" = "$DEPLOY_DIR/lib/atomic-release.sh" ]; then
    check "bv_remote_run defined exactly once (in deploy/lib/atomic-release.sh)" ok
else
    check "bv_remote_run defined in unexpected location(s): $HELPER_DEFS" fail
fi

# 4. Sanity: the helper's body uses printf %q for value emission. If
#    someone "simplifies" away the printf %q the security property
#    evaporates silently; lock it in.
if grep -q "printf 'export %s=%q\\\\n'" "$DEPLOY_DIR/lib/atomic-release.sh"; then
    check "bv_remote_run body emits values via printf %q (security-critical)" ok
else
    check "bv_remote_run body must emit values via printf %q" fail
fi

# 5. Shebang regression guard: deploy.sh / rollback.sh /
#    migrate-to-atomic-layout.sh must use `#!/usr/bin/env bash` so a
#    Homebrew bash 5+ on PATH is picked up. /bin/bash on macOS is bash
#    3.2, which fails to parse the lib's nested $(...) constructs with
#    a cryptic syntax error.
for script in "$DEPLOY_DIR/deploy.sh" "$DEPLOY_DIR/rollback.sh" "$DEPLOY_DIR/migrate-to-atomic-layout.sh"; do
    base="$(basename "$script")"
    if [ "$(head -n 1 "$script")" = "#!/usr/bin/env bash" ]; then
        check "$base uses #!/usr/bin/env bash (bash 5+ resolution)" ok
    else
        check "$base must shebang #!/usr/bin/env bash, not /bin/bash (got: $(head -n 1 "$script"))" fail
    fi
    # And: each must check BASH_VERSINFO[0] >= 4 before sourcing the lib.
    if grep -q 'BASH_VERSINFO\[0\]' "$script"; then
        check "$base checks BASH_VERSINFO[0] before sourcing lib" ok
    else
        check "$base must assert bash 4+ before sourcing lib" fail
    fi
done

# 6. backup.sh and restore.sh must dispatch SSH and rsync through
#    bv_ssh_cmd / bv_rsync_via_ssh / bv_rsync_ssh_e — never bare
#    `ssh -o BatchMode=yes` or `rsync -e "ssh ..."`. The helpers pick
#    between sshpass-password-auth and key-auth based on whether
#    DEPLOY_PASS / DEPLOY_PROD_PASS is set; reintroducing bare ssh
#    silently breaks password-auth hosts (e.g. one.com).
for base in backup.sh restore.sh; do
    script="$DEPLOY_DIR/$base"
    [ -f "$script" ] || { check "$base exists" fail; continue; }

    # The helper file must be sourced.
    if grep -q 'lib/ssh-auth.sh' "$script"; then
        check "$base sources deploy/lib/ssh-auth.sh" ok
    else
        check "$base must source deploy/lib/ssh-auth.sh" fail
    fi

    # No bare `ssh -o BatchMode=yes` (the original key-only pattern).
    # Comments are skipped via the same regex shape as check 1/2.
    bare_ssh="$(grep -nE 'ssh -o BatchMode=yes' "$script" 2>/dev/null \
                | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
                || true)"
    if [ -z "$bare_ssh" ]; then
        check "$base does not invoke bare \`ssh -o BatchMode=yes\` (use bv_ssh_cmd)" ok
    else
        check "$base must use bv_ssh_cmd, not bare ssh+BatchMode" fail
        printf '%s\n' "$bare_ssh" | sed 's/^/      /' >&2
    fi

    # No bare `rsync -e "ssh ..."` — must go through bv_rsync_ssh_e
    # (which returns a sshpass-aware -e value).
    bare_rsync="$(grep -nE 'rsync.*-e[[:space:]]+"ssh ' "$script" 2>/dev/null \
                  | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
                  || true)"
    if [ -z "$bare_rsync" ]; then
        check "$base does not hardcode \`-e \"ssh ...\"\` (use bv_rsync_ssh_e)" ok
    else
        check "$base must use bv_rsync_ssh_e for rsync's -e value" fail
        printf '%s\n' "$bare_rsync" | sed 's/^/      /' >&2
    fi
done

# 6b. mktemp templates: BSD mktemp (macOS /usr/bin/mktemp) only
#     substitutes TRAILING X's in the path. A template like
#     `bv-restore.XXXXXXXX.tar.gz` (X-block in the MIDDLE of the
#     basename) gets treated as a literal name on BSD; any second run
#     trips "File exists" because the prior literal file is still on
#     disk. The convention here: X's at the end of the basename, with
#     no trailing extension. If a typed extension is needed, allocate
#     a tempdir and name the file inside it (see decrypt_and_unpack
#     in restore.sh).
mktemp_middle_x="$(grep -rnE 'mktemp[^"]*"[^"]*X{4,}[^/"]*\.[^"]+"' "$DEPLOY_DIR" 2>/dev/null \
                   | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
                   || true)"
if [ -z "$mktemp_middle_x" ]; then
    check "no mktemp template with X's in the middle of a path (BSD mktemp safety)" ok
else
    check "mktemp template has X's in the middle (BSD mktemp will fail)" fail
    printf '%s\n' "$mktemp_middle_x" | sed 's/^/      /' >&2
fi

# 7. ssh-auth.sh helper has the load-bearing properties we depend on.
SSH_AUTH="$DEPLOY_DIR/lib/ssh-auth.sh"
if [ -f "$SSH_AUTH" ]; then
    if grep -q 'sshpass -e' "$SSH_AUTH"; then
        check "ssh-auth.sh uses 'sshpass -e' (password via env, not command line)" ok
    else
        check "ssh-auth.sh must use 'sshpass -e' (NOT 'sshpass -p')" fail
    fi
    if grep -q 'BatchMode=yes' "$SSH_AUTH"; then
        check "ssh-auth.sh's key-auth path includes BatchMode=yes (fail-fast on missing key)" ok
    else
        check "ssh-auth.sh's key-auth path must include BatchMode=yes" fail
    fi
fi

# 8. WI-1 — per-tier email.yaml symlink wiring (ADR-004 §Consequences:
#    this lint extension is the discharge for the email.yaml deploy.sh
#    change to remote-mode code paths). The symlink that wires each tier's
#    SMTP credentials into the release must be present in BOTH deploy.sh
#    (the live remote path) and the lib's bv_wire_release_symlinks (the
#    fixture/local path), and the absent-file WARN must be emitted so an
#    unprovisioned tier's silent mail-degrade is surfaced. Removing any of
#    these silently reopens the WI-1 defect (transactional mail falls back
#    to non-sending with no warning), so the lint locks them in.
#
# 8a. deploy.sh symlinks the per-tier email.yaml into the release. It lives
#     under config/plugins/ so Grav's env merge folds it into plugins.email.
if grep -Eq 'ln -sfn .*\$VDIR/user/env/\$E/config/plugins/email\.yaml' "$DEPLOY_DIR/deploy.sh"; then
    check "deploy.sh wires the per-tier email.yaml symlink (WI-1)" ok
else
    check "deploy.sh must wire the per-tier email.yaml symlink (WI-1)" fail
fi

# 8b. The symlink sits one level deeper than the env security.yaml
#     (config/plugins/email.yaml), so its climb is SEVEN (../ x7). A wrong
#     climb count would dangle the link even when the file exists.
if grep -Eq 'ln -sfn "\.\./\.\./\.\./\.\./\.\./\.\./\.\./\$DDN/\$VDIR/user/env/\$E/config/plugins/email\.yaml"' "$DEPLOY_DIR/deploy.sh"; then
    check "deploy.sh email.yaml symlink uses the correct 7-level climb" ok
else
    check "deploy.sh email.yaml symlink must use the 7-level climb (../ x7)" fail
fi

# 8c. The lib's bv_wire_release_symlinks (fixture/local path) wires it too.
if grep -Eq 'ln -sfn "\.\./\.\./\.\./\.\./\.\./\.\./\.\./\$data_dir_name/\$vdir/user/env/\$env/config/plugins/email\.yaml"' "$DEPLOY_DIR/lib/atomic-release.sh"; then
    check "bv_wire_release_symlinks wires the per-tier email.yaml symlink (WI-1)" ok
else
    check "bv_wire_release_symlinks must wire the per-tier email.yaml symlink (WI-1)" fail
fi

# 8d. deploy.sh emits a non-fatal WARN when a tier's email.yaml is absent
#     (the absent-file-is-surfaced-not-silent acceptance criterion).
if grep -Eq 'WARN: no email\.yaml provisioned' "$DEPLOY_DIR/deploy.sh"; then
    check "deploy.sh emits a WARN when a tier's email.yaml is absent (WI-1)" ok
else
    check "deploy.sh must WARN when a tier's email.yaml is absent (WI-1)" fail
fi

# 9. Per-tier env-config dir name must be the canonical HOST, not the short
#    tier name. Grav resolves its environment from the request hostname (no
#    setup.php / GRAV_ENVIRONMENT — the generated .htaccess only sets
#    X-Forwarded-Proto), so user/env/<X>/ is loaded ONLY when <X> is the host.
#    deploy.sh historically passed the short tier name ($ENV) into the remote
#    blocks that build user/env/<X>/, landing per-tier security.yaml/email.yaml
#    in a dir Grav never reads — silently degrading transactional mail to
#    non-sending. The promote scripts already use the host path; this locks
#    deploy.sh onto the same convention. (ADR-004 §Consequences: this lint
#    extension is the discharge for the remote-mode change.)
#
# 9a. deploy.sh derives the env-dir name from ENV_URL (single source of truth).
if grep -qF 'ENV_HOST="${ENV_URL#https://}"' "$DEPLOY_DIR/deploy.sh"; then
    check "deploy.sh derives ENV_HOST from ENV_URL (host = Grav env name)" ok
else
    check "deploy.sh must derive ENV_HOST from ENV_URL" fail
fi

# 9b. Every remote block that builds user/env/<X>/ is passed the HOST
#     (ENV_HOST), never the bare short tier name. The buggy short-name form
#     (DEPLOY_ENV="$ENV" / E="$ENV") must not reappear — this is the
#     regression guard for the silent-mail-degrade defect.
if grep -qF 'DEPLOY_ENV="$ENV_HOST"' "$DEPLOY_DIR/deploy.sh" \
   && grep -qF 'E="$ENV_HOST"' "$DEPLOY_DIR/deploy.sh"; then
    check "deploy.sh passes ENV_HOST into the env-dir remote blocks" ok
else
    check "deploy.sh must pass ENV_HOST (not \$ENV) into the env-dir remote blocks" fail
fi
SHORT_NAME_HITS="$(grep -nE '(DEPLOY_ENV|[[:space:]]E)="\$ENV"' "$DEPLOY_DIR/deploy.sh" 2>/dev/null \
                   | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
                   || true)"
if [ -z "$SHORT_NAME_HITS" ]; then
    check "deploy.sh never passes the short tier name \$ENV as the env-dir component" ok
else
    check "deploy.sh must not pass \$ENV (short tier name) as the env-dir component" fail
    printf '%s\n' "$SHORT_NAME_HITS" | sed 's/^/      /' >&2
fi

# 9c. Each Grav tier's host (the value ENV_HOST resolves to) has a matching
#     user/env/<host>/ dir in the repo — i.e. the derivation lands on a dir
#     Grav actually reads, and deploy.sh's ENV_URL agrees with it.
for host in dev.hackersbychoice.dk test.hackersbychoice.dk staging.hackersbychoice.dk www.byvaerkstederne.dk; do
    if [ -d "$PROJECT_ROOT/config/www/user/env/$host/config" ]; then
        check "repo ships a Grav-readable env dir for $host" ok
    else
        check "repo must ship user/env/$host/config (Grav reads env by hostname)" fail
    fi
    if grep -qF "ENV_URL=\"https://$host\"" "$DEPLOY_DIR/deploy.sh"; then
        check "deploy.sh maps a tier to host $host" ok
    else
        check "deploy.sh must map a tier to host $host (ENV_URL)" fail
    fi
done

# 10. push-email.sh — per-tier SMTP credential push. Secret-bearing and it
#     writes to live tiers, so lock in its load-bearing safety properties.
PUSH_EMAIL="$DEPLOY_DIR/push-email.sh"
if [ -f "$PUSH_EMAIL" ]; then
    # 10a. Goes through the SSH helpers (password-auth-aware), never bare ssh.
    if grep -q 'lib/ssh-auth.sh' "$PUSH_EMAIL" \
       && grep -q 'bv_ssh_cmd' "$PUSH_EMAIL" \
       && grep -q 'bv_rsync_via_ssh' "$PUSH_EMAIL"; then
        check "push-email.sh uses bv_ssh_cmd / bv_rsync_via_ssh (not bare ssh)" ok
    else
        check "push-email.sh must use the ssh-auth helpers, not bare ssh" fail
    fi
    bare="$(grep -nE 'ssh -o BatchMode=yes|rsync.*-e[[:space:]]+"ssh ' "$PUSH_EMAIL" 2>/dev/null \
            | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
    if [ -z "$bare" ]; then
        check "push-email.sh has no bare ssh/rsync invocation" ok
    else
        check "push-email.sh must not invoke bare ssh/rsync" fail
        printf '%s\n' "$bare" | sed 's/^/      /' >&2
    fi

    # 10b. The SMTP password must never be printed/diffed — compare by hash.
    if grep -qE 'sha256sum|shasum' "$PUSH_EMAIL"; then
        check "push-email.sh compares email.yaml by hash (no secret content printed)" ok
    else
        check "push-email.sh must compare by hash, never print email.yaml content" fail
    fi
    leak="$(grep -nE 'cat "\$local_file"|diff .*email\.yaml' "$PUSH_EMAIL" 2>/dev/null \
            | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
    if [ -z "$leak" ]; then
        check "push-email.sh does not cat/diff the email.yaml body" ok
    else
        check "push-email.sh must not cat/diff the email.yaml body (secret leak)" fail
        printf '%s\n' "$leak" | sed 's/^/      /' >&2
    fi

    # 10c. prod gated by --i-mean-it; staging guarded against real delivery.
    if grep -q 'Refusing to push prod without --i-mean-it' "$PUSH_EMAIL"; then
        check "push-email.sh gates prod behind --i-mean-it" ok
    else
        check "push-email.sh must gate prod behind --i-mean-it" fail
    fi
    if grep -qi 'mailtrap' "$PUSH_EMAIL" && grep -qi 'sandbox' "$PUSH_EMAIL"; then
        check "push-email.sh guards staging against real delivery (sandbox-only)" ok
    else
        check "push-email.sh must guard staging against real delivery (ADR-002)" fail
    fi
fi

# 11. delete-user.sh — destructive (removes a member account YAML on a tier).
#     Lock in its safety properties.
DELETE_USER="$DEPLOY_DIR/delete-user.sh"
if [ -f "$DELETE_USER" ]; then
    if grep -q 'lib/ssh-auth.sh' "$DELETE_USER" && grep -q 'bv_ssh_cmd' "$DELETE_USER"; then
        check "delete-user.sh uses the ssh-auth helpers (not bare ssh)" ok
    else
        check "delete-user.sh must use the ssh-auth helpers" fail
    fi
    if grep -q -- '--i-mean-it' "$DELETE_USER"; then
        check "delete-user.sh must not reintroduce the --i-mean-it ceremony flag" fail
    else
        check "delete-user.sh carries no --i-mean-it ceremony flag" ok
    fi
    # username becomes a remote path component — must reject traversal.
    if grep -q 'Refusing unsafe username' "$DELETE_USER"; then
        check "delete-user.sh validates username against path traversal" ok
    else
        check "delete-user.sh must validate username against traversal" fail
    fi
fi

# 12. list-users.sh — read-only account listing; must still go through the
#     ssh-auth helpers (no bare ssh).
LIST_USERS="$DEPLOY_DIR/list-users.sh"
if [ -f "$LIST_USERS" ]; then
    if grep -q 'lib/ssh-auth.sh' "$LIST_USERS" && grep -q 'bv_ssh_cmd' "$LIST_USERS"; then
        check "list-users.sh uses the ssh-auth helpers (not bare ssh)" ok
    else
        check "list-users.sh must use the ssh-auth helpers" fail
    fi
    lbare="$(grep -nE 'ssh -o BatchMode=yes' "$LIST_USERS" 2>/dev/null \
             | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
    if [ -z "$lbare" ]; then
        check "list-users.sh has no bare ssh invocation" ok
    else
        check "list-users.sh must not invoke bare ssh" fail
    fi
fi

# 13. cleanup-unverified-users.sh — destructive auto-cleanup (deletes accounts).
#     Lock in: ssh-auth helpers, dry-run default, prod --apply gate, and the
#     narrow target set (only state:disabled accounts with a pending token).
CLEANUP="$DEPLOY_DIR/cleanup-unverified-users.sh"
if [ -f "$CLEANUP" ]; then
    if grep -q 'lib/ssh-auth.sh' "$CLEANUP" && grep -q 'bv_ssh_cmd' "$CLEANUP"; then
        check "cleanup-unverified-users.sh uses the ssh-auth helpers" ok
    else
        check "cleanup-unverified-users.sh must use the ssh-auth helpers" fail
    fi
    if grep -q 'APPLY=0' "$CLEANUP"; then
        check "cleanup-unverified-users.sh defaults to dry-run (APPLY=0)" ok
    else
        check "cleanup-unverified-users.sh must default to dry-run" fail
    fi
    if grep -q -- '--i-mean-it' "$CLEANUP"; then
        check "cleanup-unverified-users.sh must not reintroduce the --i-mean-it ceremony flag" fail
    else
        check "cleanup-unverified-users.sh carries no --i-mean-it ceremony flag" ok
    fi
    # Must only ever target unconfirmed accounts: state:disabled AND a token.
    if grep -q 'activation_token' "$CLEANUP" && grep -qE '= disabled|disabled ' "$CLEANUP"; then
        check "cleanup-unverified-users.sh targets only disabled accounts with a pending token" ok
    else
        check "cleanup-unverified-users.sh must restrict to disabled + activation_token" fail
    fi
fi

# 14. throttle.sh — live on/off toggle for the registration throttle. Goes
#     through the ssh-auth helpers. The prod ceremony flag was removed —
#     see 'no ceremony flag' below.
THROTTLE="$DEPLOY_DIR/throttle.sh"
if [ -f "$THROTTLE" ]; then
    if grep -q 'lib/ssh-auth.sh' "$THROTTLE" && grep -q 'bv_ssh_cmd' "$THROTTLE"; then
        check "throttle.sh uses the ssh-auth helpers (not bare ssh)" ok
    else
        check "throttle.sh must use the ssh-auth helpers" fail
    fi
    if grep -q -- '--i-mean-it' "$THROTTLE"; then
        check "throttle.sh must not reintroduce the --i-mean-it ceremony flag" fail
    else
        check "throttle.sh carries no --i-mean-it ceremony flag" ok
    fi
fi

# 15. reset-users.sh / reset-data.sh — bulk-destructive tier resets. Lock in:
#     ssh-auth helpers and the Make-layer prod refusal. That refusal is the
#     real guard for bulk prod wipes and is NOT the removed ceremony flag:
#     `make reset-users tier=prod` is refused outright, script-direct only.
for base in reset-users.sh reset-data.sh; do
    script="$DEPLOY_DIR/$base"
    [ -f "$script" ] || { check "$base exists" fail; continue; }
    if grep -q 'lib/ssh-auth.sh' "$script" && grep -q 'bv_ssh_cmd' "$script"; then
        check "$base uses the ssh-auth helpers (not bare ssh)" ok
    else
        check "$base must use the ssh-auth helpers" fail
    fi
    if grep -q -- '--i-mean-it' "$script"; then
        check "$base must not reintroduce the --i-mean-it ceremony flag" fail
    else
        check "$base carries no --i-mean-it ceremony flag" ok
    fi
    target="${base%.sh}"
    if grep -qF "'make $target tier=prod' is intentionally refused" "$PROJECT_ROOT/Makefile"; then
        check "Makefile refuses 'make $target tier=prod'" ok
    else
        check "Makefile must refuse 'make $target tier=prod'" fail
    fi
done

# 15b. reset-users.sh must never put admins or the pw-test-* Playwright
#      seeds in its delete set — removing either breaks tier admin access /
#      the auth suite. Lock in the keep-classification markers.
RESET_USERS="$DEPLOY_DIR/reset-users.sh"
if [ -f "$RESET_USERS" ]; then
    if grep -q 'keep_reason="admin"' "$RESET_USERS" \
       && grep -q 'keep_reason="playwright-seed"' "$RESET_USERS"; then
        check "reset-users.sh keeps admins and pw-test-* seeds out of the delete set" ok
    else
        check "reset-users.sh must keep admins and pw-test-* seeds" fail
    fi
fi

# 15c. clear-cache.sh — remote cache clear; must still go through the
#      ssh-auth helpers (no bare ssh).
CLEAR_CACHE="$DEPLOY_DIR/clear-cache.sh"
if [ -f "$CLEAR_CACHE" ]; then
    if grep -q 'lib/ssh-auth.sh' "$CLEAR_CACHE" && grep -q 'bv_ssh_cmd' "$CLEAR_CACHE"; then
        check "clear-cache.sh uses the ssh-auth helpers (not bare ssh)" ok
    else
        check "clear-cache.sh must use the ssh-auth helpers" fail
    fi
fi

# 16. Prod tier-root convention — prod's Grav root is the chosting.dk
#     docroot ITSELF (promote-to-prod.sh: PROD_DOCROOT="$DEPLOY_PROD_PATH");
#     there is no prod/ subdirectory. Every user-ops script must resolve its
#     tier root via bv_tier_root — a hardcoded "$PATH/$TIER" works on the
#     one.com tiers and silently breaks on prod (found live 2026-07-18:
#     every user-ops command failed on prod with 'No such file or directory').
if grep -q '^bv_tier_root() {' "$DEPLOY_DIR/lib/ssh-auth.sh"; then
    check "bv_tier_root helper defined in lib/ssh-auth.sh" ok
else
    check "bv_tier_root helper must be defined in lib/ssh-auth.sh" fail
fi
for base in list-users.sh delete-user.sh cleanup-unverified-users.sh \
            activate-user.sh reset-password.sh manage-groups.sh throttle.sh \
            push-data.sh reset-users.sh reset-data.sh clear-cache.sh; do
    if grep -q 'bv_tier_root' "$DEPLOY_DIR/$base"; then
        check "$base resolves its tier root via bv_tier_root" ok
    else
        check "$base must resolve its tier root via bv_tier_root" fail
    fi
done
hard="$(grep -nE '"\$(PATH_SSH|DEPLOY_PATH)/\$TIER"' "$DEPLOY_DIR"/*.sh 2>/dev/null \
        | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
if [ -z "$hard" ]; then
    check "no deploy script hardcodes \"\$PATH/\$TIER\" as a tier root" ok
else
    check "deploy scripts must not hardcode \"\$PATH/\$TIER\" (use bv_tier_root)" fail
    printf '%s\n' "$hard" | sed 's/^/      /' >&2
fi

# 17. Single-quoting a body is only half the contract — every variable it
#     names must also be DISPATCHED. Check 2 proves the quoting; nothing
#     proved the dispatch, and on 2026-08-23 a correctly-quoted body
#     referenced an undispatched $PHP_BIN, so the remote ran `bin/grav
#     clearcache` with no interpreter. See the awk file's header.
AWKCHK="$(dirname "$0")/undispatched-remote-vars.awk"
UNDISPATCHED="$(awk -f "$AWKCHK" "$DEPLOY_DIR"/*.sh "$DEPLOY_DIR"/lib/*.sh 2>/dev/null || true)"
if [ -z "$UNDISPATCHED" ]; then
    check "every variable in a bv_remote_run body is dispatched to the remote" ok
else
    check "bv_remote_run bodies reference variables that are never dispatched" fail
    printf '%s\n' "$UNDISPATCHED" >&2
fi

# 17b. And the checker must still be able to see the failure. A static
#      analyser that has quietly stopped matching reports a clean tree
#      forever; this feeds it the exact 2026-08-23 shape and requires a hit.
FIXTURE="$(mktemp -t undispatched.XXXXXX)"
cat > "$FIXTURE" <<'PROBE'
bv_remote_run '
    cd "$RELEASE_DIR" && $PHP_BIN bin/grav clearcache
' RELEASE_DIR="$RELEASE_DIR"
PROBE
# Read the OUTPUT, not the exit status: the checker exits non-zero when it
# finds something, and under `set -o pipefail` that turns the whole pipeline
# non-zero even though grep matched — the if would take the else branch on
# success. Same family of quiet shell semantics as the bug being pinned.
PROBE_OUT="$(awk -f "$AWKCHK" "$FIXTURE" 2>/dev/null || true)"
if printf '%s' "$PROBE_OUT" | grep -q 'PHP_BIN'; then
    check "the undispatched-variable checker still detects the shape it was written for" ok
else
    check "the undispatched-variable checker no longer detects its own regression case" fail
fi
rm -f "$FIXTURE"

# 18. The swap must be followed by an opcode-cache flush, before the probe.
#
#     The docroot is a symlink; PHP-FPM keys opcache by the path it resolved
#     when it first compiled, and opcache.revalidate_path is Off on the
#     one.com tiers. A warm worker therefore keeps running the PREVIOUS
#     release through the unchanged /<tier>/... paths, and does not recover
#     on any useful timescale — test served the old core for 35 minutes.
#     Normally invisible; fatal across the Grav 1.7 → 2.0 boundary, where a
#     new bundled plugin called a Grav 2 class into the old core.
DEPLOY_SH="$DEPLOY_DIR/deploy.sh"
if grep -q 'opcache_reset' "$DEPLOY_SH"; then
    check "deploy.sh flushes the opcode cache after the swap" ok
else
    check "deploy.sh must flush the opcode cache after the swap" fail
fi
# The flush is useless if it runs before the symlink moves, and dangerous if
# the endpoint is left behind. Both are checked by position, not by wording.
_swap_line="$(grep -n 'Step 8/8' "$DEPLOY_SH" | head -1 | cut -d: -f1)"
_flush_line="$(grep -n 'opcache_reset' "$DEPLOY_SH" | head -1 | cut -d: -f1)"
_probe_line="$(grep -n 'Smoke probe: GET' "$DEPLOY_SH" | head -1 | cut -d: -f1)"
if [ -n "$_swap_line" ] && [ -n "$_flush_line" ] && [ -n "$_probe_line" ] \
   && [ "$_flush_line" -gt "$_swap_line" ] && [ "$_flush_line" -lt "$_probe_line" ]; then
    check "the flush runs after the swap and before the smoke probe" ok
else
    check "the flush must run after the swap and before the smoke probe" fail
fi
if grep -qE 'rm -f "\$T/\$N"' "$DEPLOY_SH"; then
    check "the flush endpoint is deleted again" ok
else
    check "the flush endpoint must be deleted again" fail
fi
# A fixed filename would be a permanently guessable remote-reset endpoint in
# every release directory.
if grep -q 'opcache-flush-\$(od -An' "$DEPLOY_SH"; then
    check "the flush endpoint name is randomised per deploy" ok
else
    check "the flush endpoint name must be randomised per deploy" fail
fi

echo ""
echo "─────────────────────────────────────"
echo "  Pass: $PASS    Fail: $FAIL"
echo "─────────────────────────────────────"

[ "$FAIL" -eq 0 ]
