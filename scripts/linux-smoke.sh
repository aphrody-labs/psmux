#!/bin/sh
# Linux smoke test: new-session, send-keys, capture-pane, list-panes,
# split-window, kill-session, kill-server and control mode, run against a
# private namespace (-L) and a private data dir, so nothing in the default
# namespace is touched. The same script runs against a real tmux for a
# side by side comparison.
#
#   scripts/linux-smoke.sh [path-to-psmux-or-tmux]
#
# Exit status is 0 when every check passed.
set -u

BIN=${1:-${PSMUX_BIN:-psmux}}
NS="smoke$$"
SHELL=/bin/sh
export SHELL
TMP=$(mktemp -d)
FAIL=0
# SMOKE_REAL_TMUX=1 runs the same checks against a real tmux, which has no
# PSMUX_DATA_DIR and wants an empty config.
IS_TMUX=0
if [ -n "${SMOKE_REAL_TMUX:-}" ]; then IS_TMUX=1; fi
if [ "$IS_TMUX" = 0 ]; then
    PSMUX_DATA_DIR="$TMP/data"
    export PSMUX_DATA_DIR
    t() { "$BIN" -L "$NS" "$@"; }
else
    TMUX_TMPDIR="$TMP"
    export TMUX_TMPDIR
    t() { "$BIN" -L "$NS" -f /dev/null "$@"; }
fi

cleanup() {
    t kill-server >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

check() { # check <name> <condition exit status>
    if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi
}

echo "== new-session"
t new-session -d -s t -x 80 -y 24
check "new-session -d exits 0" $?

echo "== list-sessions"
out=$(t list-sessions 2>&1); echo "$out"
case $out in t:*) check "list-sessions shows t" 0 ;; *) check "list-sessions shows t" 1 ;; esac

echo "== send-keys / capture-pane"
t send-keys -t t 'echo hi-$((40+2))' Enter
i=0; cap=""
while [ $i -lt 50 ]; do
    cap=$(t capture-pane -p -t t 2>&1)
    case $cap in *"hi-42"*) break ;; esac
    i=$((i + 1)); sleep 0.1
done
echo "$cap" | grep -v '^$'
case $cap in
    *hi-42*) check "capture-pane shows the command output hi-42" 0 ;;
    *) check "capture-pane shows the command output hi-42" 1 ;;
esac

echo "== list-panes"
out=$(t list-panes -t t -F '#{pane_id} #{pane_width}x#{pane_height}' 2>&1); echo "$out"
case $out in %[0-9]*" 80x24") check "list-panes prints %<n> 80x24" 0 ;; *) check "list-panes prints %<n> 80x24" 1 ;; esac

echo "== split-window"
t split-window -t t
n=$(t list-panes -t t 2>&1 | wc -l)
t list-panes -t t -F '#{pane_id} #{pane_width}x#{pane_height}'
[ "$n" -eq 2 ]; check "two panes after split-window" $?

echo "== control mode"
cm=$(printf 'list-sessions\n' | t -C attach -t t 2>&1)
echo "$cm"
case $cm in *%begin*%end*) check "control mode emits %begin ... %end" 0 ;; *) check "control mode emits %begin ... %end" 1 ;; esac

if [ "$IS_TMUX" = 0 ]; then
    echo "== unix hygiene"
    mode() { stat -c %a "$1"; }
    [ "$(mode "$PSMUX_DATA_DIR")" = 700 ]; check "data dir is 0700" $?
    modes=$(for f in "$PSMUX_DATA_DIR"/"${NS}"__t.key "$PSMUX_DATA_DIR"/"${NS}"__t.port; do mode "$f"; done | tr '\n' ' ')
    [ "$modes" = "600 600 " ]; check "key and port files are 0600 (got: $modes)" $?
    srv=$(t display-message -p -t t '#{pid}')
    [ "$(ps -o sid= -p "$srv" | tr -d ' ')" != "$(ps -o sid= -p $$ | tr -d ' ')" ]
    check "server $srv runs in its own session" $?
fi

echo "== kill-session / kill-server"
panes=$(t list-panes -a -F '#{pane_pid}' 2>/dev/null)
t kill-session -t t
check "kill-session exits 0" $?
t new-session -d -s u -x 80 -y 24
panes="$panes $(t list-panes -a -F '#{pane_pid}' 2>/dev/null)"
t kill-server
check "kill-server exits 0" $?
i=0; left=""
while [ $i -lt 30 ]; do
    left=$(pgrep -af -- "-L $NS" | grep -v pgrep)
    for p in $panes; do
        # A zombie is already dead; only a live pane child counts.
        case $(ps -o stat= -p "$p" 2>/dev/null) in ""|Z*) ;; *) left="$left pane child $p" ;; esac
    done
    [ -z "$left" ] && break
    i=$((i + 1)); sleep 0.1
done
[ -z "$left" ]; check "no server or pane child left for namespace $NS" $?
[ -z "$left" ] || echo "$left"

exit $FAIL
