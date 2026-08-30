# The demo environment

Everything in this repository runs on a QEMU virtual machine defined by
`qemu/vm.sh`. Nothing runs on the host, and nothing should: this talk makes
claims about what a specific distribution ships by default, so demonstrating
it anywhere else proves nothing.

## Why QEMU and not OrbStack or Lima

The obvious choice on a Mac is OrbStack, and it was the first thing tried.
It was rejected for one reason. OrbStack runs its own kernel, `7.0.14-orbstack`
at the time of writing, and that kernel carries neither
`kernel.apparmor_restrict_unprivileged_userns` nor
`kernel.unprivileged_userns_clone`. Both sysctls are the subject of a slide,
and on OrbStack both print "No such file or directory". A talk about kernel
behaviour demonstrated on a vendor kernel fork invites a question that has no
good answer.

QEMU boots the stock Ubuntu cloud image with the stock Ubuntu kernel, so every
result here is a result about Ubuntu. It also accepts kernel boot parameters,
which is what the cgroup v1 variant needs. The cost is that it is slower than
OrbStack and there is no automatic filesystem sharing, so code is copied in
over SSH rather than mounted. That is what `./qemu/vm.sh push` does, and it has
to be run before the demos: they all expect the repository at `~/crl`.

## The three variants

One definition, three variants, differing only in provisioning.

| Variant | Difference | Used for |
|---|---|---|
| `primary` | cgroup v2, `apparmor_restrict_unprivileged_userns` set to `0` | Demo A and demos 1, 2, 3, 5, and the first half of 4 |
| `cgroupv1` | booted with `systemd.unified_cgroup_hierarchy=0` | The second half of demo 4, live |
| `hardened` | the sysctl left exactly as Ubuntu ships it, `1` | The twist |

```bash
./qemu/vm.sh up primary
./qemu/vm.sh ssh primary
./qemu/vm.sh status
./qemu/vm.sh down
```

## Recorded versions

Measured on the `primary` variant. State these on stage rather than guessing,
and re-run the commands if this repository is more than a few months old.

| Component | Version |
|---|---|
| Base image | `ubuntu-24.04-server-cloudimg-arm64.img`, `release-20260826` |
| Distribution | Ubuntu 24.04.4 LTS |
| Kernel | 6.8.0-138-generic, aarch64 |
| Podman | 4.9.3 |
| Docker | 29.1.3 |
| shadow / uidmap | 1:4.13+dfsg1-4ubuntu3.2 |
| Go | 1.27.0 |
| iperf3 | 3.16 |
| passt / pasta | 0.0~git20240220.1e6f92b-1 |

The base image is pinned by checksum in `qemu/vm.sh`, so the same box builds
again later.

## The AppArmor restriction, and what it actually does

Ubuntu 23.10 introduced `kernel.apparmor_restrict_unprivileged_userns` and
24.04 ships it enabled. It is not an on/off switch for unprivileged user
namespaces. It is an allowlist.

On the `hardened` variant, with the sysctl at its shipped value of `1`:

```console
$ sysctl kernel.apparmor_restrict_unprivileged_userns
kernel.apparmor_restrict_unprivileged_userns = 1

$ unshare --user --map-root-user id
unshare: write failed /proc/self/uid_map: Operation not permitted

$ ./nsdemo 2
  error: fork/exec /proc/self/exe: permission denied

$ podman run --rm alpine id
uid=0(root) gid=0(root) ...
```

Podman works. `unshare` does not, and neither does the Go program in this
repository. The difference is an AppArmor profile: `/etc/apparmor.d/podman`
contains a `userns,` rule, and so do the profiles for `crun`, `buildah` and
others. On this image 91 profiles grant it. Anything without a profile is
refused.

That is worth being precise about, because the easy version of the argument is
wrong. Ubuntu did not break rootless containers. It permitted the runtimes it
knows about and refused everything else, which is a more careful piece of
engineering than it is usually given credit for. What it did break is the
ability to build a user namespace by hand, which is exactly what Demo A does.

The trade is still real, it has just moved: the allowlist is now the security
boundary, and it is 91 entries long.

## The delegated cgroup controllers

```console
$ cat /sys/fs/cgroup/user.slice/user-1000.slice/cgroup.controllers
cpu memory pids
```

Note that `io` is not delegated on this image, though `cpu`, `memory` and
`pids` are. Demo 4 uses `memory`, so it is unaffected, but do not claim `io`
works rootless on this box.

## Identity

The demo user is `ajitem`, uid 1000, and both `/etc/subuid` and `/etc/subgid`
read `ajitem:100000:65536`. That matches the mappings shown on the slides, so
the terminal and the deck agree.
