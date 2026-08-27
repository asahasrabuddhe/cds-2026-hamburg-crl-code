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
#   ./scripts/stage.sh            # build the session and attach
#   ./scripts/stage.sh coldopen   # the two commands the talk opens with
#
# The left pane is root. It asks for a password once, when you run this, and
# not again in front of an audience.

set -uo pipefail

readonly SESSION="${SESSION:-talk}"
readonly REPO_DIR="${REPO_DIR:-$HOME/crl}"
readonly IMAGE="${IMAGE:-docker.io/library/alpine:3.20}"

# The cold open. Two commands, ninety seconds, no slide up. The left pane
# shows a container claiming to be root; the right pane shows the host
# disagreeing about the very same process.
cold_open() {
  cat <<'CUE'

  COLD OPEN, no slide up. Run these, then say the line.

  RIGHT pane:
    podman run --rm -d --name whoami alpine sleep 300
    podman exec whoami id
    ps -eo user,pid,comm | grep -w sleep
    cat /proc/<pid>/status | grep -E '^(Uid|Gid):'

  The line:
    "Same process. The container says root. The host says ajitem.
     Both of them are telling the truth, and the gap between those
     two answers is the entire subject of this talk."

  Then slide 1.

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
