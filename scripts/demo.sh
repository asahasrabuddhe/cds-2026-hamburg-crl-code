#!/usr/bin/env bash
#
# rootless-demos.sh, demo driver for "The Reality of Rootless Containers"
#
# ONE script, TWO panes. The script detects which side it is running on and
# runs the identical commands either way. That is the staging trick: the
# audience sees the same input in both panes and different output, and you
# never have to claim "trust me, the other side does X".
#
#   LEFT pane  (rootful):   sudo -i ; cd <here> ; ./rootless-demos.sh 3
#   RIGHT pane (rootless):            cd <here> ; ./rootless-demos.sh 3
#
# Every demo is independent and idempotent: run them in any order, repeat any
# of them, skip any of them.
#
#   ./rootless-demos.sh check    # pre-flight, run this the morning of the talk
#   ./rootless-demos.sh a        # Demo A, the Go program (rootless pane only)
#   ./rootless-demos.sh 1..5     # a single demo
#   ./rootless-demos.sh all      # rehearsal, with pauses

set -uo pipefail

readonly RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' DIM=$'\e[2m' RESET=$'\e[0m'
readonly IMAGE="${IMAGE:-docker.io/library/alpine:3.20}"

# ------------------------------------------------------------- which side ---

if [[ $(id -u) -eq 0 ]]; then
  readonly SIDE="ROOTFUL"
  readonly SIDE_COLOUR="$RED"
  readonly ENGINE="${ENGINE:-$(command -v docker >/dev/null && echo docker || echo podman)}"
else
  readonly SIDE="ROOTLESS"
  readonly SIDE_COLOUR="$GREEN"
  readonly ENGINE="${ENGINE:-podman}"
fi

# ------------------------------------------------------- demo 3 safety net ---
#
# Demo 3 deliberately appends an unauthenticated root account to this
# machine's /etc/passwd, so that the rootful pane shows what a careless bind
# mount really costs. Everything in this block exists to guarantee that the
# line comes back out again.
#
# The cleanup keys off whether the line is actually present, never off which
# pane we are in. Side is the wrong predicate: the write is performed by the
# container engine, not by this shell, so a rootless-looking pane driving a
# rootful Docker daemon (ENGINE=docker, user in the docker group) writes the
# backdoor for real. Gating on $SIDE would skip the cleanup in exactly that
# case and leave the account behind permanently.

readonly PASSWD_FILE="${PASSWD_FILE:-/etc/passwd}"

backdoor_present() {
  [[ -r "$PASSWD_FILE" ]] && grep -q '^backdoor:' "$PASSWD_FILE" 2>/dev/null
}

# remove_backdoor is idempotent: it is safe to call when nothing was written,
# safe to call twice, and safe to call from a trap. It returns 0 when the file
# is clean, whether or not it had to do anything.
remove_backdoor() {
  backdoor_present || return 0

  if [[ $(id -u) -ne 0 ]]; then
    # This is the dangerous case the side gate used to miss. Do not fail
    # quietly: an unauthenticated root account is on this box right now.
    printf '\n%s!! %s contains an unauthenticated root account and this\n' "$RED" "$PASSWD_FILE" >&2
    printf '!! shell cannot remove it. Run this as root, now:\n' >&2
    printf '!!   sudo sed -i "/^backdoor:/d" %s%s\n\n' "$PASSWD_FILE" "$RESET" >&2
    return 1
  fi

  local tmp
  tmp="$(mktemp)" || return 1

  # Filter into a temp file, then copy the contents back over the original.
  # Writing through the existing inode rather than renaming over it keeps the
  # file's mode, owner, hard links and SELinux label intact, which `sed -i`
  # would not. A rename here can also leave the box unloginable if it fails
  # halfway.
  if grep -v '^backdoor:' "$PASSWD_FILE" > "$tmp" && [[ -s "$tmp" ]]; then
    cat "$tmp" > "$PASSWD_FILE"
  fi
  rm -f "$tmp"

  if backdoor_present; then
    printf '\n%s!! CLEANUP FAILED, %s still contains a root account%s\n\n' \
      "$RED" "$PASSWD_FILE" "$RESET" >&2
    return 1
  fi
  return 0
}

# Armed for the whole run, not just for demo 3, so an interrupt anywhere
# cleans up. Ctrl-C during a hung `podman run` is the realistic case.
trap remove_backdoor EXIT INT TERM

# ---------------------------------------------------------------- helpers ---

say()   { printf '\n%s▶ %s%s\n' "$YELLOW" "$1" "$RESET"; }
note()  { printf '%s  %s%s\n' "$DIM" "$1" "$RESET"; }
pause() { printf '%s  [enter]%s' "$DIM" "$RESET"; read -r _; }

banner() {
  printf '\n%s┌─ %s ── %s ─┐%s\n' \
    "$SIDE_COLOUR" "$SIDE" "$1" "$RESET"
}

# Echo a command, then run it. This is what the audience reads, so keep every
# command short enough to fit on one line at 20pt.
run() {
  printf '\n%s$ %s%s\n' "$SIDE_COLOUR" "$*" "$RESET"
  "$@" 2>&1 | sed 's/^/  /'
}

ctr() { run "$ENGINE" "$@"; }

# The scratch directory is per-uid. Sharing one path between the panes meant
# the rootful pane created it owned by root, and the rootless pane could then
# neither remove it nor write into it, so demo 3(c) collapsed on the right
# whenever the left had run first.
SCRATCH="/tmp/rootless-demo-$(id -u)"
readonly SCRATCH

reset_env() {
  # `rm -af` is podman-only; docker has no -a on rm, so the rootful pane was
  # silently not cleaning up and the second run hit a name conflict.
  case "$ENGINE" in
    *podman*) "$ENGINE" rm -af >/dev/null 2>&1 ;;
    *) "$ENGINE" rm -f "$("$ENGINE" ps -aq 2>/dev/null)" >/dev/null 2>&1 ;;
  esac
  rm -rf "$SCRATCH" && mkdir -p "$SCRATCH"
}

# ------------------------------------------------------------------ check ---

demo_check() {
  banner "pre-flight"

  run id
  note "engine: $ENGINE"

  if [[ "$SIDE" == "ROOTLESS" ]]; then
    run cat /etc/subuid
    run cat /etc/subgid
    command -v newuidmap >/dev/null || \
      printf '%s  MISSING: newuidmap (install uidmap / shadow-utils)%s\n' "$RED" "$RESET"
    [[ -x ./nsdemo ]] || \
      printf '%s  MISSING: run make build to produce ./nsdemo%s\n' "$RED" "$RESET"

    # Assert this directly. Beat 3 of the Go demo prints the same "operation
    # not permitted" whether it is working correctly or the sysctl is
    # blocking it outright, so it is the one beat that cannot be trusted as
    # an indicator. Beats 1, 2 and 4 fail loudly; beat 3 lies.
    say "Unprivileged user namespaces must be permitted"
    if [[ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]]; then
      local restrict
      restrict="$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns)"
      if [[ "$restrict" != "0" ]]; then
        printf '%s  BLOCKED: kernel.apparmor_restrict_unprivileged_userns=%s%s\n' \
          "$RED" "$restrict" "$RESET"
        printf '%s  Every namespace demo will fail. See qemu/README.md.%s\n' \
          "$RED" "$RESET"
      else
        note "kernel.apparmor_restrict_unprivileged_userns = 0, as provisioned"
      fi
    else
      note "kernel.apparmor_restrict_unprivileged_userns: absent on this kernel"
    fi
    run unshare --user --map-root-user id
  fi

  # A previous run that was interrupted between the write and the cleanup
  # would leave this behind, and nothing else in the pre-flight would notice.
  if backdoor_present; then
    printf '%s  LEFTOVER: %s still contains a backdoor account from a\n' "$RED" "$PASSWD_FILE"
    printf '  previous run. Removing it now.%s\n' "$RESET"
    remove_backdoor
  fi

  run "$ENGINE" info --format \
    'cgroups={{.Host.CgroupsVersion}} controllers={{.Host.CgroupControllers}}' \
    2>/dev/null || run "$ENGINE" info --format '{{.CgroupDriver}} {{.CgroupVersion}}'

  say "Images must already be local, no pulls on stage"
  run "$ENGINE" images

  "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1 || \
    printf '%s  MISSING: %s pull %s%s\n' "$RED" "$ENGINE" "$IMAGE" "$RESET"

}

# ------------------------------------------------- 1: who am I, really? -----
#
# Both panes: identical commands. The container says root in both. The host
# says root in one pane and 'ajitem' in the other. That gap is the talk.

demo_1() {
  reset_env
  banner "DEMO 1: the same process, two answers"

  "$ENGINE" run -d --name whoami "$IMAGE" sleep 300 >/dev/null
  ctr exec whoami id
  note "The container is certain it is root. Both panes agree."

  local pid
  pid=$("$ENGINE" inspect whoami --format '{{.State.Pid}}')
  run ps -o user=,pid=,comm= -p "$pid"
  run grep -E '^Uid:' "/proc/$pid/status"

  if [[ "$SIDE" == "ROOTFUL" ]]; then
    note "Host says Uid: 0. The container was telling the literal truth."
  else
    note "Host says Uid: 1000. Same claim, different truth."
  fi

  ctr exec whoami cat /proc/self/uid_map
  note "Rootless: container 0 → host 1000 (you); container 1+ → 100000+."
  note "Rootful:  container 0 → host 0. No translation. No boundary."

  "$ENGINE" rm -f whoami >/dev/null
}

# --------------------------------------- 2: capabilities are real, local ----

demo_2() {
  reset_env
  banner "DEMO 2. CAP_SYS_ADMIN, and what it is worth"

  ctr run --rm "$IMAGE" sh -c \
    'mount -t tmpfs none /mnt && echo "tmpfs mount: OK"'
  note "Allowed on both sides, tmpfs carries FS_USERNS_MOUNT."

  ctr run --rm --privileged "$IMAGE" sh -c \
    'mount /dev/sda1 /mnt 2>&1 || echo "block mount: DENIED"'

  ctr run --rm --privileged "$IMAGE" sh -c \
    'mknod /dev/evil b 8 0 2>&1 && echo "mknod: OK" || echo "mknod: DENIED"'

  if [[ "$SIDE" == "ROOTFUL" ]]; then
    note "--privileged means privileged. Both succeed. This is a host device."
  else
    note "--privileged grants everything your namespace holds. Devices are not in it."
  fi
}

# ------------------------------------------------- 3: the blast radius ------

demo_3() {
  reset_env
  banner "DEMO 3: the same mistake, two outcomes"

  say "  (a) read the host's shadow file"
  ctr run --rm -v /etc:/host:ro "$IMAGE" sh -c \
    'head -1 /host/shadow 2>&1 || echo "DENIED"'

  # If the file does not already end in a newline, the container's append
  # concatenates the backdoor onto the previous account's shell field instead
  # of starting a line. That both corrupts the entry and defeats a
  # '^backdoor:' cleanup, so fix it before writing rather than after.
  if [[ $(id -u) -eq 0 && -s "$PASSWD_FILE" ]] && [[ -n "$(tail -c 1 "$PASSWD_FILE")" ]]; then
    printf '\n' >> "$PASSWD_FILE"
    note "(added a missing trailing newline to $PASSWD_FILE first)"
  fi

  say "  (b) append a root account to the host's passwd file"
  ctr run --rm -v /etc:/host "$IMAGE" sh -c \
    'echo "backdoor::0:0::/root:/bin/sh" >> /host/passwd 2>&1 && echo WROTE || echo "DENIED"'

  # Branch on what actually happened to the file, not on which pane this is.
  # The engine does the writing, so the pane cannot tell you the outcome.
  if backdoor_present; then
    note "That host now has an unauthenticated root account. One flag did it."
    remove_backdoor
    note "(cleaned up, but on a real host, nobody would have noticed)"
  else
    note "The mount succeeded. The write did not. Rootless did not prevent the"
    note "mistake, it made the mistake survivable."
  fi

  say "  (c) the honest half, your own data is in range either way"
  echo "aws_secret_access_key = not-a-real-key" > "$SCRATCH/credentials"
  ctr run --rm -v "$SCRATCH":/host:ro "$IMAGE" cat /host/credentials
  note "For a laptop or a CI runner, this is most of what an attacker wanted."
}

# ----------------------------------------------- 4: limits that are not -----

demo_4() {
  reset_env
  banner "DEMO 4: what you lose: cgroup limits"

  run "$ENGINE" info --format \
    'cgroups={{.Host.CgroupsVersion}} controllers={{.Host.CgroupControllers}}' \
    2>/dev/null || true

  say "  Ask for a limit, then ask the container whether it got one"
  ctr run --rm --memory=64m "$IMAGE" sh -c \
    'cat /sys/fs/cgroup/memory.max 2>/dev/null ||
     cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null ||
     echo "no memory controller visible"'

  note "67108864 means the limit applied. Anything else means it did not."
  note "Rootless on cgroup v1: a warning, not an error, and not a limit."
}

# ------------------------------------------- 5: the cost of the network -----

demo_5() {
  reset_env
  banner "DEMO 5: userspace networking, and its bill"

  run "$ENGINE" info --format 'network backend: {{.Host.NetworkBackend}}' 2>/dev/null || true

  say "  Publish a privileged port"
  ctr run --rm -p 80:80 "$IMAGE" true 2>&1 || true

  if [[ "$SIDE" == "ROOTFUL" ]]; then
    note "Fine. Port 80 is yours because everything is yours."
  else
    note "Fix: sysctl net.ipv4.ip_unprivileged_port_start=80, for EVERY process."
  fi

  # There are no recordings in this repo. Throughput is measured beforehand
  # with scripts/bench.sh and quoted from the slide, because benchmarking on
  # conference wifi proves nothing and takes minutes you do not have.
  if [[ "$SIDE" == "ROOTLESS" ]]; then
    say "  Which network helpers are available"
    run sh -c 'command -v pasta slirp4netns || true'
    note "Podman $(podman --version 2>/dev/null | cut -d\  -f3) defaults to slirp4netns here."
    note "pasta became the default in Podman 5.0, and is opt-in via --network=pasta."
  fi
  note "Throughput numbers come from scripts/bench.sh, run beforehand. See the slide."
}

# ----------------------------- A: build the mapping by hand (Go, rootless) ---

demo_a() {
  banner "DEMO A: build the mapping by hand (nsdemo, in Go)"

  local bin=./nsdemo/nsdemo
  if [[ ! -x "$bin" ]]; then
    printf '%s  Not built: (cd nsdemo && go build -o nsdemo .)%s\n' "$RED" "$RESET"
    return 1
  fi
  if [[ "$SIDE" == "ROOTFUL" ]]; then
    printf '%s  Wrong pane. This demo proves nothing as root.%s\n' "$RED" "$RESET"
    note "Optional contrast: run './nsdemo 3' here, as root the range map succeeds."
    return 1
  fi

  say "  Beat 1: a namespace with no map at all"
  run "$bin" 1
  note "Not root. Not you. Nobody, and holding a full capability set."
  pause

  say "  Beat 2: map yourself, become root, meet the boundary"
  run "$bin" 2
  # shellcheck disable=SC2016  # $HOME is the subject of the sentence, not a variable
  note 'Root on a host file: denied. Root in $HOME: allowed. Remember this.'
  pause

  say "  Beat 3: ask for a range unaided        [cut first if running long]"
  run "$bin" 3
  note "uid_map is written during process creation, so Start() is what fails."
  pause

  say "  Beat 4: the real dance: pause, newuidmap, resume"
  run "$bin" 4
  note "Same PID. No setuid call. The kernel changed its mind about who it is."
}

# ------------------------------------------------------------------- main ---

main() {
  local target="${1:-check}"
  case "$target" in
    check) demo_check ;;
    a|A)   demo_a ;;
    1|2|3|4|5) "demo_$target" ;;
    all)
      [[ "$SIDE" == "ROOTLESS" ]] && { demo_a; pause; }
      for n in 1 2 3 4 5; do "demo_$n"; pause; done
      ;;
    *)
      printf 'usage: %s {check|a|1|2|3|4|5|all}\n' "$0" >&2
      exit 2
      ;;
  esac
  say "done, $SIDE"
}

main "$@"
