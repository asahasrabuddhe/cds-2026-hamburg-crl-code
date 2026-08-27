# The Reality of Rootless Containers

Companion code for **The Reality of Rootless Containers**, ContainerDays 2026,
Hamburg. Thirty minutes, plus five for questions.

The talk argues that rootless does not remove root. It moves the boundary,
shrinks the blast radius, and hands you a new set of problems, including a new
attack surface of its own. This repository is the proof: a Go program that
builds a user namespace and its ID mappings by hand, a demo driver that runs
identical commands as root and as an ordinary user, and a reproducible VM to
run both in.

The slides live in a sibling repository,
[`cds-2026-hamburg-crl-slides`](https://github.com/asahasrabuddhe/cds-2026-hamburg-crl-slides).

## Read this before running demo 3

> **Demo 3 writes an unauthenticated root account into `/etc/passwd`.**
>
> On the rootful side it succeeds. That is the entire point of the demo: a
> single `-v /etc:/host` gives a container the ability to append
> `backdoor::0:0::/root:/bin/sh` to the host's password file, and anyone can
> then become root on that machine with no password at all.
>
> `scripts/demo.sh` removes the line immediately, arms a trap so an
> interrupted run still cleans up, and refuses to stay quiet if it cannot
> clean up. It is still a real root account on a real machine for a real
> fraction of a second.
>
> **Run this on the throwaway VM in `qemu/` and nowhere else.** Not on your
> laptop, not on a shared box, not on anything you would mind rebuilding.
> If you want to check a machine by hand:
>
> ```bash
> grep '^backdoor:' /etc/passwd && sudo sed -i '/^backdoor:/d' /etc/passwd
> ```
>
> The pre-flight, `./scripts/demo.sh check`, also looks for a leftover line
> and removes it.

## Prerequisites

**Linux, and a real kernel.** User namespaces, `/etc/subuid`, the `newuidmap`
setuid helpers and cgroup delegation are Linux kernel features.

**macOS and WSL will not work for the namespace demos, and the reason is worth
knowing.** On macOS there is no Linux kernel at all: Docker Desktop, OrbStack
and Colima all run a Linux VM for you, so anything you measure is a property
of that VM rather than of your machine. WSL2 does run a real Linux kernel, but
it is Microsoft's kernel with its own configuration, and WSL1 is a syscall
translation layer with no namespace support worth the name. Since this talk
makes claims about what a specific distribution ships by default, running it
anywhere other than that distribution proves nothing. Use the VM in `qemu/`.

You need:

- A kernel with user namespaces enabled, and `kernel.apparmor_restrict_unprivileged_userns`
  set to `0` on Ubuntu 23.10 and later. Ubuntu ships it as `1`, which blocks
  every demo here.
- The `uidmap` package on Debian and Ubuntu, or `shadow-utils` on Fedora and
  RHEL, for `newuidmap` and `newgidmap`.
- An `/etc/subuid` and `/etc/subgid` entry for your user.
- cgroup v2 with systemd delegation, for demo 4's first half.
- Podman and Docker, `iperf3`, `tmux` and Go 1.27.

`qemu/vm.sh` provisions all of it.

## Quickstart

```bash
make vm                 # boot and provision the primary VM, a few minutes
./qemu/vm.sh ssh primary
```

Then, inside the VM:

```bash
make build              # produces ./nsdemo
make check              # gofmt, go vet, go test, shellcheck
./scripts/demo.sh check # pre-flight, run this the morning of the talk
```

## The VMs

Three variants of one definition, differing only in provisioning.

| Variant | What is different | Used for |
|---|---|---|
| `primary` | cgroup v2, userns permitted | Everything except the two below |
| `cgroupv1` | booted `systemd.unified_cgroup_hierarchy=0` | Demo 4's second half, live |
| `hardened` | `kernel.apparmor_restrict_unprivileged_userns` left at `1` | The twist, slide 36 |

```bash
./qemu/vm.sh up primary
./qemu/vm.sh status
./qemu/vm.sh down
```

The `hardened` box exists because the sysctl is the argument. Ubuntu enables
it by default, and with it enabled nothing in this repository works. Showing
that is more honest than describing it.

## The demos

One script drives both panes. It detects which side it is on and runs
identical commands either way, so the audience sees the same input and
different output.

```bash
# LEFT pane  (rootful)    sudo -i ; cd ~/crl ; ./scripts/demo.sh 3
# RIGHT pane (rootless)             cd ~/crl ; ./scripts/demo.sh 3
```

`ENGINE` and `IMAGE` are overridable, for example `ENGINE=docker ./scripts/demo.sh 2`.

### Demo A, `./nsdemo 1` to `./nsdemo 4`

The identity machinery by hand, in four beats. Full explanation in
[`docs/01-identity.md`](docs/01-identity.md).

Beat 1 creates a user namespace with no mapping, and the process becomes
nobody: `uid=65534`, an empty `uid_map`, and an empty effective capability set
sitting under a full bounding set. Beat 2 maps a single ID and the same
program comes back as `uid=0` with `uid_map: 0 1000 1`, able to mount a tmpfs
and still unable to touch `/etc/shadow`. Beat 3 asks for a 65536-wide range
and `cmd.Start()` fails with `operation not permitted`, which is why
`/etc/subuid` and the setuid helpers exist. Beat 4 is the one that matters: the
child starts unmapped, blocks at a barrier, `newuidmap` and `newgidmap` run
against its PID, and the same process resumes as `uid=0` with a two-line map.
That is what Podman does.

### Demos 1 to 5

| Demo | Question | Doc |
|---|---|---|
| 1 | Who am I? | [`docs/01-identity.md`](docs/01-identity.md) |
| 2 | If I have `CAP_SYS_ADMIN`, can I mount things? | [`docs/02-filesystem.md`](docs/02-filesystem.md) |
| 3 | Same mistake, two outcomes | [`docs/01-identity.md`](docs/01-identity.md) |
| 4 | What did I lose? | [`docs/03-cgroups.md`](docs/03-cgroups.md) |
| 5 | What does userspace networking cost? | [`docs/04-network.md`](docs/04-network.md) |

Measured numbers are in [`docs/benchmarks.md`](docs/benchmarks.md), produced by
`scripts/bench.sh`. Read the caveat at the top of that file before quoting the
absolute figures.

Each doc gives the expected output and what it proves.

## Layout

```
cmd/nsdemo/        the four beats, standard library only
internal/subid/    the /etc/subuid parser and its tests
scripts/demo.sh    the dual-mode demo driver
qemu/              the three VM variants
docs/              one explainer per subsystem, plus environment.md
                   and benchmarks.md
```

`nsdemo` stops at the ID mapping deliberately. It is not a container runtime,
there is no `pivot_root` and no rootfs, because the mapping is the part people
get wrong and the rest is a different talk.

## Licence

MIT. See [`LICENSE`](LICENSE).
