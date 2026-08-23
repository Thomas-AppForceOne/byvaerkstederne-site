# undispatched-remote-vars.awk — the gap check 2 of lint-remote-ssh.sh leaves open.
#
# THE FAILURE THIS PINS
# ---------------------
# bv_remote_run bodies are single-quoted on purpose: that is what stops a
# local value being interpolated into the command line, which was the
# PR-#17 argument-injection finding. Check 2 proves the quoting.
#
# But quoting alone is only half the contract. A single-quoted body reaches
# the remote shell verbatim, so every variable it names must be DISPATCHED
# as a KEY=VALUE argument. Name one that is not, and the remote shell
# expands it to nothing — no error, no warning, just a command missing a
# word.
#
# On 2026-08-23 the deploy's cache-clear step was changed from a literal
# `php` to `$PHP_BIN`, so the tier-specific interpreter would be used. The
# body was correctly single-quoted, so check 2 passed. PHP_BIN was never
# added to the dispatch list, so the remote ran `bin/grav clearcache` with
# no interpreter and the deploy aborted at step 7. It aborted before the
# swap, which is why this cost a diagnosis rather than an outage — but the
# same slip in a body that does not fail loudly would run a command with a
# silently missing argument.
#
# So: a variable in a body must be dispatched on that call, assigned inside
# the body itself, or a shell standard. Anything else is a local variable
# that only LOOKS like it crosses the connection.
#
# Usage: awk -f undispatched-remote-vars.awk deploy/*.sh deploy/lib/*.sh
# Prints one line per undispatched reference; silent when clean.

function emit(body, disp, file, ln,   keys, assigned, s, name, n, c, L) {
    delete keys
    delete assigned

    # Dispatched: the KEY=VALUE arguments after the closing quote.
    s = disp
    while (match(s, /[A-Za-z_][A-Za-z0-9_]*=/)) {
        name = substr(s, RSTART, RLENGTH - 1)
        keys[name] = 1
        s = substr(s, RSTART + RLENGTH)
    }

    # Assigned remote-side: the body may create its own variables, and
    # those need no dispatch — they never existed locally.
    n = split(body, L, "\n")
    for (c = 1; c <= n; c++) {
        if (match(L[c], /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/)) {
            name = L[c]
            sub(/^[ \t]*/, "", name)
            sub(/=.*/, "", name)
            assigned[name] = 1
        }
        s = L[c]
        while (match(s, /(for|read)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
            name = substr(s, RSTART, RLENGTH)
            sub(/^(for|read)[ \t]+/, "", name)
            assigned[name] = 1
            s = substr(s, RSTART + RLENGTH)
        }
    }

    s = body
    while (match(s, /\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) {
        name = substr(s, RSTART, RLENGTH)
        gsub(/[${}]/, "", name)
        s = substr(s, RSTART + RLENGTH)
        if (name in keys || name in assigned) continue
        # Provided by the remote login shell itself.
        if (name ~ /^(HOME|PATH|PWD|OLDPWD|USER|LOGNAME|SHELL|IFS|HOSTNAME|TMPDIR|LANG|LC_ALL|RANDOM|LINENO|PS1|SHLVL|TERM)$/) continue
        printf "      %s:%d  $%s is referenced but never dispatched — expands to empty on the remote\n", \
            file, ln, name
        FOUND = 1
    }
}

function continues(line) { return line ~ /\\[ \t]*$/ }

BEGIN { state = 0; FOUND = 0 }

state == 0 {
    if ($0 ~ /^[ \t]*#/) next
    i = index($0, "bv_remote_run")
    if (i == 0) next
    rest = substr($0, i + 13)
    # The quote must be the first thing after the call, or this is prose
    # about bv_remote_run rather than a call to it — the helper's own
    # error messages name it in a string.
    sub(/^[ \t]+/, "", rest)
    if (substr(rest, 1, 1) != "'") next
    after = substr(rest, 2)
    startline = FNR
    q2 = index(after, "'")
    if (q2 == 0) { body = after "\n"; state = 1; next }
    body = substr(after, 1, q2 - 1)
    disp = substr(after, q2 + 1)
    if (continues(disp)) { state = 2; next }
    emit(body, disp, FILENAME, startline)
    body = ""; disp = ""
    next
}

state == 1 {
    if ($0 ~ /^[ \t]*'/) {
        disp = $0
        sub(/^[ \t]*'/, "", disp)
        if (continues(disp)) { state = 2; next }
        emit(body, disp, FILENAME, startline)
        body = ""; disp = ""; state = 0
        next
    }
    body = body $0 "\n"
    next
}

# The dispatch list ran onto continuation lines.
state == 2 {
    disp = disp " " $0
    if (continues($0)) next
    emit(body, disp, FILENAME, startline)
    body = ""; disp = ""; state = 0
}

END { exit (FOUND ? 1 : 0) }
