#!/usr/bin/env bash
#
# PreToolUse hook: confines tool calls to $GAN_WORKTREE when a GAN run
# is active. Triggered by the presence of .gan/confinement-active, which
# the orchestrator writes when it spawns sub-agents and removes when
# the run ends.
#
# The file holds one line: the absolute path of the worktree the agents
# are allowed to write to. Every Edit/Write/NotebookEdit target path and
# every Bash command is checked against that root.
#
# This is a seatbelt, not a sandbox. It catches the "oops" patterns that
# have burned us before (rsync --delete onto the main repo, rm -rf on
# live state dirs, accidental writes to the project root). A sufficiently
# creative agent could still escape via shell tricks. Pair this with
# explicit rules in agent prompts and CLAUDE.md.
#
# Input: JSON on stdin from Claude Code with shape:
#   {"tool_name": "...", "tool_input": {...}, "cwd": "..."}
# Output: exit 0 to allow, non-zero to deny. Stderr is shown to the model.

set -euo pipefail

MARKER_FILE=".gan/confinement-active"

# No active GAN confinement → pass everything through.
if [[ ! -f "$MARKER_FILE" ]]; then
  exit 0
fi

WORKTREE="$(head -n1 "$MARKER_FILE" | tr -d '[:space:]')"
if [[ -z "$WORKTREE" || ! -d "$WORKTREE" ]]; then
  echo "gan-confine: marker file present but worktree '$WORKTREE' invalid; refusing to gate (fix marker or remove file)" >&2
  exit 0
fi

# Normalize to absolute + trailing slash for prefix matching.
WORKTREE_ABS="$(cd "$WORKTREE" && pwd)"
WORKTREE_PREFIX="$WORKTREE_ABS/"

# Main repo root = parent of .gan/ (the directory containing the marker).
REPO_ROOT="$(cd "$(dirname "$MARKER_FILE")/.." && pwd)"
REPO_PREFIX="$REPO_ROOT/"

payload="$(cat)"

tool="$(printf '%s' "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_name",""))' 2>/dev/null || true)"

deny() {
  echo "GAN CONFINEMENT: $1" >&2
  echo "Active worktree: $WORKTREE_ABS" >&2
  echo "To override, the user must remove $MARKER_FILE. Agents must not do this themselves." >&2
  exit 2
}

# Extract a JSON field safely via python.
field() {
  printf '%s' "$payload" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    cur = d
    for k in sys.argv[1:]:
        if isinstance(cur, dict): cur = cur.get(k, '')
        else: cur = ''
    print(cur if isinstance(cur, str) else '')
except Exception:
    print('')
" "$@"
}

path_under_worktree() {
  # $1 is an absolute path; returns 0 if under WORKTREE_ABS, 1 otherwise.
  local p="$1"
  [[ "$p" == "$WORKTREE_ABS" || "$p" == "$WORKTREE_PREFIX"* ]]
}

path_is_harness_metadata() {
  # Agents legitimately write to $REPO_ROOT/.gan/ — contracts, reviews,
  # feedback, objections, spec.md. This is the orchestrator's coordination
  # surface and must remain writable. We permit $REPO_ROOT/.gan/* but
  # exclude $REPO_ROOT/.gan/worktree/** (which is the worktree root
  # itself — it has its own allow rule).
  local p="$1"
  local gan_dir="$REPO_ROOT/.gan"
  [[ "$p" == "$gan_dir"/* && "$p" != "$gan_dir/worktree"* ]]
}

absolutize() {
  # Resolve $1 to an absolute path. If relative, treat as cwd-relative.
  # Does NOT resolve symlinks; we want to catch the literal path the
  # agent asked for, not where it chases to.
  local p="$1" base="${2:-$PWD}"
  if [[ "$p" = /* ]]; then
    printf '%s' "$p"
  else
    printf '%s/%s' "$base" "$p"
  fi
}

case "$tool" in
  Edit|Write|NotebookEdit)
    target="$(field tool_input file_path)"
    [[ -z "$target" ]] && target="$(field tool_input notebook_path)"
    if [[ -z "$target" ]]; then
      deny "write-class tool invoked with no file_path — refusing under confinement"
    fi
    abs="$(absolutize "$target")"
    if ! path_under_worktree "$abs" && ! path_is_harness_metadata "$abs"; then
      deny "$tool refused — target '$abs' is outside $WORKTREE_ABS (and not a harness metadata file under $REPO_ROOT/.gan/)"
    fi
    ;;

  Bash)
    cmd="$(field tool_input command)"
    if [[ -z "$cmd" ]]; then exit 0; fi

    # Hard-block the patterns that have burned us.
    if [[ "$cmd" =~ rsync.*--delete ]]; then
      deny "Bash refused — 'rsync --delete' is forbidden under confinement"
    fi

    # Block any absolute path that points into the main repo but NOT under the worktree.
    # This catches both writes (rm -rf /…/config/www/user/accounts) and reads-with-intent.
    # We match against the repo prefix specifically; other system paths (/usr, /etc, $HOME)
    # are left alone — the agent needs to read them sometimes.
    while IFS= read -r token; do
      [[ -z "$token" ]] && continue
      if [[ "$token" == "$REPO_PREFIX"* && "$token" != "$WORKTREE_PREFIX"* && "$token" != "$WORKTREE_ABS" ]]; then
        # Carve-outs for paths the agents legitimately reference:
        #  - the marker file itself (for display/logging)
        #  - $REPO_ROOT/.gan/* harness metadata (contracts, feedback, spec, etc.)
        if [[ "$token" == "$REPO_ROOT/$MARKER_FILE" ]]; then continue; fi
        if path_is_harness_metadata "$token"; then continue; fi
        deny "Bash refused — command references '$token' which is inside the main repo but outside the worktree"
      fi
    done < <(printf '%s\n' "$cmd" | grep -oE "$REPO_PREFIX[A-Za-z0-9_./+-]*" || true)

    # Block rm -rf / rm -r with relative targets that escape the worktree via ../
    # (naive but effective — any '..' in an rm path under confinement is sus).
    if [[ "$cmd" =~ rm[[:space:]]+-[rRf]+.*\.\. ]]; then
      deny "Bash refused — 'rm -r' with '..' traversal is forbidden under confinement"
    fi

    # Block writes to known live-state dirs via any mechanism, even relative.
    for sentinel in "config/www/user/accounts" "config/www/user/data" "config/www/logs"; do
      if [[ "$cmd" =~ (^|[^A-Za-z0-9_/])${sentinel}($|[^A-Za-z0-9_]) ]]; then
        # If the whole command is cd'd into the worktree (common pattern: cd WORKTREE && ...),
        # assume the relative path is worktree-relative and let it through.
        if [[ "$cmd" =~ cd[[:space:]]+\"?${WORKTREE_ABS}\"? ]] || [[ "$cmd" =~ cd[[:space:]]+\"?${WORKTREE_PREFIX}[^\"[:space:]]*\"? ]]; then
          continue
        fi
        deny "Bash refused — command touches live-state path '$sentinel' without first cd-ing into the worktree"
      fi
    done
    ;;

  *)
    # Read, Glob, Grep, WebFetch, task spawning etc. — allow.
    exit 0
    ;;
esac

exit 0
