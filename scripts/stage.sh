#!/usr/bin/env bash
#
# stage.sh, build the tmux session the talk is delivered from.
#
# The deck takes the top two thirds of the screen and this session takes the
# bottom third. You never switch windows: both panes stay visible for the
# whole talk, which is what lets you say "the same file, the same argument,
# the only difference is which pane I typed it in" and have it be obviously
# true.
#
#   ./scripts/stage.sh            # build the session, detached
#   ./scripts/stage.sh coldopen   # the commands the talk opens with
#
# The left pane is root. Cloud-init grants the demo user NOPASSWD:ALL, so the
# sudo -i below never prompts. Build the session early anyway: a tmux that
# comes up wrong is a problem you want seventy minutes before the talk, not
# ninety seconds before it.
#
# Order on the day:
#
#   1. ./scripts/stage.sh          builds the session detached. Do this before
#                                  you walk on.
#   2. the cold open               in your plain full-width shell, NOT in tmux
#   3. tmux attach -t talk         the split appears for the first time here
#
# Step 2 is deliberately outside tmux. The cold open is a single-pane
# argument, one process seen from inside the container and from the host, so
# it does not need the split and it reads better with the whole screen. Set
# the bare terminal to 20pt too, not just the tmux one.

set -uo pipefail

readonly SESSION="${SESSION:-talk}"
readonly REPO_DIR="${REPO_DIR:-$HOME/crl}"
readonly IMAGE="${IMAGE:-docker.io/library/alpine:3.20}"

# The cold open. Ninety seconds, no slide up, no tmux. One rootless shell at
# full width. The container claims to be root and the host disagrees about
# that very same process, and both of those facts have to land in the same
# pane or the word "same" is doing work it has not earned. Splitting the
# claim across two panes shows two processes and proves nothing.
cold_open() {
  cat <<'CUE'

  COLD OPEN, no slide up, BEFORE you attach to tmux.
  Your own shell, full width, rootless. Run these, then say the line.

    podman run --rm -d --name whoami alpine sleep 300
    podman ps --format '{{.Names}} runs {{.Command}}'
    podman exec whoami id
    pid=$(podman inspect whoami --format '{{.State.Pid}}')
    ps -o user=,pid=,comm= -p $pid
    grep -E '^(Uid|Gid):' /proc/$pid/status

  Say 'the container NAMED whoami' out loud when you create it. Otherwise
  'podman exec whoami id' reads as two commands, and alpine does ship a
  real whoami binary for them to be wrong about.

  The second line exists so the name is visibly a name. The pid line exists
  so the number in the ps output is one they watched you derive.

  The line:
    "Same process. The container says root. The host says ajitem.
     Both of them are telling the truth, and the gap between those
     two answers is the entire subject of this talk."

  Then: tmux attach -t talk, and slide 1.

  The split appears for the first time on that attach, which is the point.
  Up to here you have been arguing about one process. From here you are
  comparing two privilege levels, and the layout should change when the
  argument does.

CUE
}

build() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "session '$SESSION' already exists, attaching"
    tmux attach -t "$SESSION"
    return
  fi

  tmux new-session -d -s "$SESSION" -c "$REPO_DIR"
  tmux split-window -h -t "$SESSION" -c "$REPO_DIR"

  # Left pane, rootful. Becoming root here, once, before anyone is watching.
  tmux select-pane -t "$SESSION".0 -T 'ROOTFUL (uid 0)' -P 'fg=red'
  tmux send-keys -t "$SESSION".0 "sudo -i" C-m
  tmux send-keys -t "$SESSION".0 "cd $REPO_DIR" C-m
  tmux send-keys -t "$SESSION".0 "export PS1='# '" C-m
  tmux send-keys -t "$SESSION".0 "clear" C-m

  # Right pane, rootless. This is you.
  tmux select-pane -t "$SESSION".1 -T "ROOTLESS (uid $(id -u))" -P 'fg=green'
  tmux send-keys -t "$SESSION".1 "cd $REPO_DIR" C-m
  tmux send-keys -t "$SESSION".1 "export PS1='$ '" C-m
  tmux send-keys -t "$SESSION".1 "clear" C-m

  tmux set -t "$SESSION" pane-border-status top
  tmux set -t "$SESSION" pane-border-format ' #{pane_title} '
  tmux set -t "$SESSION" status off

  echo "session '$SESSION' built."
  echo "Set your terminal font to 20pt or larger before attaching."
  echo "Then: tmux attach -t $SESSION"
}

case "${1:-build}" in
  build)    build ;;
  coldopen) cold_open ;;
  kill)     tmux kill-session -t "$SESSION" 2>/dev/null && echo "killed $SESSION" ;;
  *)        echo "usage: stage.sh {build|coldopen|kill}" >&2; exit 2 ;;
esac
