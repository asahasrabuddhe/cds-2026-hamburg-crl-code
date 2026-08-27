#!/usr/bin/env bash
#
# bench.sh, the numbers for slide 32.
#
# Run this on the primary VM, well before the talk, and put the results on the
# slide. Do not run it on stage and do not run it over conference wifi: the
# point of the slide is that these are your numbers from your hardware, and a
# number measured over a hotel network is not a number.
#
#   ./scripts/bench.sh            # everything
#   ./scripts/bench.sh net        # just the iperf3 rows
#
# Rootful rows need root, so run the whole thing under sudo -i if you want the
# comparison column filled in.

set -uo pipefail

readonly IMAGE="${IMAGE:-docker.io/library/alpine:3.20}"
readonly IPERF_IMAGE="${IPERF_IMAGE:-docker.io/networkstatic/iperf3:latest}"
readonly DURATION="${DURATION:-10}"
readonly BENCH_IMAGE="${BENCH_IMAGE:-docker.io/library/golang:1.23}"

row()  { printf '  %-34s %s\n' "$1" "$2"; }
head_() { printf '\n== %s ==\n' "$1"; }

# --------------------------------------------------------------- network ---

bench_net() {
  head_ "iperf3, container to host, ${DURATION}s each"

  if ! command -v iperf3 >/dev/null; then
    row "iperf3" "NOT INSTALLED"
    return
  fi

  iperf3 --server --daemon --port 5201 >/dev/null 2>&1
  sleep 1

  local host_ip gw
  host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
  gw="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $3; exit}')"
  [[ -n "$host_ip" ]] || { row "host address" "UNKNOWN"; return; }

  # Each backend needs a different address for "the host", and the difference
  # is itself a finding. slirp4netns puts the container on its own subnet, so
  # host.containers.internal resolves and works. pasta copies the host's
  # addresses into the container, so the host's own IP points at the container
  # itself and connecting there is refused. Reaching the host under pasta
  # needs --map-gw and the gateway address.
  local tcp
  tcp="$(iperf_in slirp4netns '' host.containers.internal)"
  row "rootless slirp4netns, TCP" "${tcp:-failed}"

  tcp="$(iperf_in 'pasta:--map-gw' '' "$gw")"
  row "rootless pasta (--map-gw), TCP" "${tcp:-failed}"

  if [[ $(id -u) -eq 0 ]]; then
    tcp="$(iperf_in bridge '' "$host_ip")"
    row "rootful veth bridge, TCP" "${tcp:-failed}"
  else
    row "rootful veth bridge, TCP" "re-run this under sudo -i"
  fi

  pkill -f 'iperf3 --server' 2>/dev/null
}

# iperf_in runs the iperf3 client inside a container on a given network and
# prints the receiver-side throughput.
iperf_in() {
  local network="$1" _unused="$2" target="$3"
  podman run --rm --network="$network" "$IPERF_IMAGE" \
    -c "$target" -t "$DURATION" -f g 2>/dev/null \
    | awk '/receiver/ {print $(NF-2), $(NF-1)}'
}

# ------------------------------------------------------------ cold start ---

bench_start() {
  head_ "container start to echo, cold, best of 5"

  podman rmi "$IMAGE" >/dev/null 2>&1
  podman pull "$IMAGE" >/dev/null 2>&1

  local best="" start end ms
  for _ in $(seq 1 5); do
    start="$(date +%s%N)"
    podman run --rm "$IMAGE" echo hello >/dev/null 2>&1
    end="$(date +%s%N)"
    ms=$(( (end - start) / 1000000 ))
    [[ -z "$best" || $ms -lt $best ]] && best=$ms
  done
  row "rootless start to echo" "${best} ms"
}

# ----------------------------------------------------------------- build ---

# bench_build measures a cold image pull and extract, which is where the
# storage driver actually shows up. It does NOT try to compare native overlay
# against fuse-overlayfs: doing that correctly needs two separate stores and a
# cold page cache, and a careless version of it reports a two second "result"
# that is really just a cache hit. If you want that comparison, run it by hand
# with a dedicated --root for each driver and check the image was genuinely
# removed first.
bench_build() {
  head_ "cold pull and extract, $BENCH_IMAGE"

  local driver
  driver="$(podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null)"
  row "storage driver" "${driver:-unknown}"

  podman rmi "$BENCH_IMAGE" >/dev/null 2>&1
  local start end
  start="$(date +%s%N)"
  if ! podman pull -q "$BENCH_IMAGE" >/dev/null 2>&1; then
    row "cold pull and extract" "FAILED"
    return
  fi
  end="$(date +%s%N)"
  row "cold pull and extract" "$(( (end - start) / 1000000000 )) s"
  row "image size" "$(podman image inspect "$BENCH_IMAGE" --format '{{.Size}}' 2>/dev/null) bytes"
}

case "${1:-all}" in
  net)   bench_net ;;
  start) bench_start ;;
  build) bench_build ;;
  all)   bench_net; bench_start; bench_build ;;
  *)     echo "usage: bench.sh {all|net|start|build}" >&2; exit 2 ;;
esac

printf '\nPut these on slide 32. They are yours, so you can defend them.\n'
