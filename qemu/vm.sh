#!/usr/bin/env bash
#
# vm.sh, the demo environment for "The Reality of Rootless Containers".
#
# One definition, three variants. They differ only in provisioning, so the
# thing you rehearse on and the thing you present from are the same machine
# with one setting changed:
#
#   primary    cgroup v2, unprivileged user namespaces permitted.
#              Everything except the cgroup v1 half of demo 4 runs here.
#
#   cgroupv1   booted with systemd.unified_cgroup_hierarchy=0, so rootless
#              resource limits are silently ignored. This is the second half
#              of demo 4, and it is live, not recorded.
#
#   hardened   kernel.apparmor_restrict_unprivileged_userns left exactly as
#              Ubuntu ships it, which is 1. Nothing rootless works here, and
#              that is the point: it is the proof for the twist.
#
#   ./qemu/vm.sh up primary
#   ./qemu/vm.sh push primary
#   ./qemu/vm.sh ssh primary
#   ./qemu/vm.sh status
#   ./qemu/vm.sh down [variant]

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Pinned so this repo still builds the same box in a year. The checksum is
# from the release directory's own SHA256SUMS.
readonly RELEASE="release-20260826"
readonly IMAGE_NAME="ubuntu-24.04-server-cloudimg-arm64.img"
readonly IMAGE_URL="https://cloud-images.ubuntu.com/releases/noble/${RELEASE}/${IMAGE_NAME}"
readonly IMAGE_SHA="afa139bac6f2629c1e1f2f8f34215f3a9ad9779801bcb945521ba1a45016743f"

readonly DEMO_USER="ajitem"
readonly DEMO_IMAGE="docker.io/library/alpine:3.20"
readonly GO_VERSION="1.27.0"
readonly KEY="crl_key"

# QEMU's user-mode network defaults to 10.0.2.0/24, and so does slirp4netns.
# Left alone they collide: a rootless container on slirp4netns gets an address
# in the same range as the VM itself, so "the host" is ambiguous from inside
# the container and demo 5's throughput test has nowhere coherent to point.
# Moving the VM's own network out of the way keeps the two distinct.
readonly GUEST_NET="192.168.76.0/24"
readonly GUEST_GW="192.168.76.2"

usage() { echo "usage: vm.sh {up|push|ssh|down|status} [primary|cgroupv1|hardened]" >&2; exit 2; }

variant_port() {
  case "$1" in
    primary)  echo 2222 ;;
    cgroupv1) echo 2223 ;;
    hardened) echo 2224 ;;
    *) echo "unknown variant: $1" >&2; exit 2 ;;
  esac
}

fetch_image() {
  if [[ -f "$IMAGE_NAME" ]] && [[ "$(shasum -a 256 "$IMAGE_NAME" | cut -d' ' -f1)" == "$IMAGE_SHA" ]]; then
    return 0
  fi
  echo "fetching $IMAGE_NAME ($RELEASE)"
  curl -fSL -o "$IMAGE_NAME" "$IMAGE_URL"
  local got
  got="$(shasum -a 256 "$IMAGE_NAME" | cut -d' ' -f1)"
  if [[ "$got" != "$IMAGE_SHA" ]]; then
    echo "checksum mismatch: got $got, want $IMAGE_SHA" >&2
    exit 1
  fi
}

ensure_key() {
  [[ -f "$KEY" ]] || ssh-keygen -t ed25519 -N '' -f "$KEY" -C 'crl-demo-vm' >/dev/null
}

# The only difference between the variants lives here.
variant_runcmd() {
  case "$1" in
    primary|cgroupv1)
      cat <<'EOF'
  # Ubuntu 24.04 ships kernel.apparmor_restrict_unprivileged_userns = 1, which
  # blocks unprivileged user namespaces and therefore blocks every demo in
  # this repo. Turning it off is the trade the talk is about, so it is written
  # down in a file rather than typed and forgotten.
  - |
    cat > /etc/sysctl.d/99-crl-demo.conf <<'CONF'
    # Required by the rootless container demos. Ubuntu ships this as 1.
    # See docs/environment.md for why, and what it costs.
    kernel.apparmor_restrict_unprivileged_userns = 0
    CONF
  - sysctl --system
EOF
      ;;
    hardened)
      cat <<'EOF'
  # Deliberately does NOT relax the sysctl. This box exists to show the value
  # Ubuntu ships and the failure it causes.
  - sysctl kernel.apparmor_restrict_unprivileged_userns
EOF
      ;;
  esac

  if [[ "$1" == "cgroupv1" ]]; then
    cat <<'EOF'
  # cgroup v1, so that rootless resource limits are accepted and ignored.
  - sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"$/GRUB_CMDLINE_LINUX="\1 systemd.unified_cgroup_hierarchy=0"/' /etc/default/grub
  - update-grub
  - reboot
EOF
  fi
}

write_seed() {
  local variant="$1"
  rm -rf "seed-$variant"; mkdir -p "seed-$variant"

  cat > "seed-$variant/meta-data" <<EOF
instance-id: crl-$variant
local-hostname: crl-$variant
EOF

  {
    cat <<EOF
#cloud-config
users:
  - name: $DEMO_USER
    groups: [sudo]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - $(cat "$KEY.pub")

package_update: true
packages:
  - uidmap
  - podman
  - docker.io
  - iperf3
  - tmux
  - iproute2
  - shellcheck
  - make
  - git
  - curl
  - ca-certificates

runcmd:
  # The delegated range. Without this, beats 3 and 4 have nothing to map.
  - usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $DEMO_USER
  - loginctl enable-linger $DEMO_USER

  - curl -fsSL -o /tmp/go.tgz https://go.dev/dl/go$GO_VERSION.linux-arm64.tar.gz
  - tar -C /usr/local -xzf /tmp/go.tgz
  - printf 'export PATH=\$PATH:/usr/local/go/bin\n' > /etc/profile.d/go.sh

  # No pulling on stage. Pull for both the user and root, because the two
  # panes use different stores.
  - runuser -u $DEMO_USER -- podman pull $DEMO_IMAGE
  - podman pull $DEMO_IMAGE
  - systemctl enable --now docker
  - docker pull $DEMO_IMAGE
  - usermod -aG docker $DEMO_USER
EOF
    variant_runcmd "$variant"
  } > "seed-$variant/user-data"

  # hdiutil refuses to overwrite, so clear the previous seed first.
  rm -f "seed-$variant.iso"
  hdiutil makehybrid -iso -joliet -joliet-volume-name CIDATA \
    -iso-volume-name CIDATA -o "seed-$variant.iso" "seed-$variant" >/dev/null
}

up() {
  local variant="${1:-primary}" port
  port="$(variant_port "$variant")"

  if [[ -f "$variant.pid" ]] && kill -0 "$(cat "$variant.pid")" 2>/dev/null; then
    echo "$variant already running (pid $(cat "$variant.pid"), ssh port $port)"
    return 0
  fi

  ensure_key
  fetch_image
  write_seed "$variant"

  [[ -f "$variant.qcow2" ]] || \
    qemu-img create -f qcow2 -F qcow2 -b "$PWD/$IMAGE_NAME" "$variant.qcow2" 40G >/dev/null
  [[ -f "$variant-efi.fd" ]] || \
    cp "$(brew --prefix qemu)/share/qemu/edk2-arm-vars.fd" "$variant-efi.fd"

  echo "booting $variant on ssh port $port"
  qemu-system-aarch64 \
    -name "crl-$variant" -machine virt,accel=hvf -cpu host -smp 4 -m 4096 \
    -drive "if=pflash,format=raw,readonly=on,file=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd" \
    -drive "if=pflash,format=raw,file=$variant-efi.fd" \
    -drive "if=virtio,format=qcow2,file=$variant.qcow2" \
    -drive "if=virtio,format=raw,file=seed-$variant.iso" \
    -netdev "user,id=n0,net=$GUEST_NET,host=$GUEST_GW,hostfwd=tcp:127.0.0.1:$port-:22" \
    -device virtio-net-pci,netdev=n0 \
    -display none -serial "file:$variant-console.log" \
    -pidfile "$variant.pid" -daemonize

  write_ssh_config
  echo "waiting for cloud-init"
  for _ in $(seq 1 90); do
    if ssh -F ssh_config "crl-$variant" 'cloud-init status --wait >/dev/null 2>&1' 2>/dev/null; then
      echo "$variant ready: ssh -F qemu/ssh_config crl-$variant"
      return 0
    fi
    sleep 10
  done
  echo "timed out, see $variant-console.log" >&2
  return 1
}

write_ssh_config() {
  : > ssh_config
  local v
  for v in primary cgroupv1 hardened; do
    cat >> ssh_config <<EOF
Host crl-$v
  HostName 127.0.0.1
  Port $(variant_port "$v")
  User $DEMO_USER
  IdentityFile $PWD/$KEY
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR

EOF
  done
}

down() {
  local v vs=("$@")
  # "${@:-a b c}" would expand to one argument containing all three names,
  # so the default has to be built as a real array.
  [[ ${#vs[@]} -eq 0 ]] && vs=(primary cgroupv1 hardened)
  for v in "${vs[@]}"; do
    if [[ -f "$v.pid" ]] && kill -0 "$(cat "$v.pid")" 2>/dev/null; then
      kill "$(cat "$v.pid")" && echo "stopped $v"
    fi
    rm -f "$v.pid"
  done
}

status() {
  local v
  for v in primary cgroupv1 hardened; do
    if [[ -f "$v.pid" ]] && kill -0 "$(cat "$v.pid")" 2>/dev/null; then
      printf '  %-9s running   ssh port %s\n' "$v" "$(variant_port "$v")"
    else
      printf '  %-9s stopped\n' "$v"
    fi
  done
}

# The VM has no filesystem share, so the repository has to be copied in. tar
# over ssh rather than rsync: the cloud image does not ship rsync, and
# installing it at the venue would need a network the venue may not give you.
# tar is in the base image and needs nothing at either end.
#
# ~/crl is replaced rather than merged, so a push always leaves the VM holding
# exactly what the laptop holds. Run make build afterwards: the nsdemo binary
# goes with it.
push() {
  local variant="${1:-primary}"
  variant_port "$variant" >/dev/null   # rejects an unknown name before we dial
  write_ssh_config

  # qemu/ is excluded because it is several gigabytes of disk image, and .git/
  # because nothing in the VM reads the history.
  tar -cf - -C .. --exclude './.git' --exclude './qemu' . \
    | ssh -F ssh_config "crl-$variant" \
        'rm -rf ~/crl && mkdir -p ~/crl && tar -xf - -C ~/crl'

  echo "pushed to crl-$variant:~/crl"
}

case "${1:-}" in
  up)     shift; up "${1:-primary}" ;;
  push)   shift; push "${1:-primary}" ;;
  ssh)    shift; write_ssh_config; exec ssh -F ssh_config "crl-${1:-primary}" ;;
  down)   shift; down "$@" ;;
  status) status ;;
  *)      usage ;;
esac
