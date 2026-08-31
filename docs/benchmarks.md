# Benchmarks

Numbers for slide 32, produced by `scripts/bench.sh` on the `primary` VM.

## Read this before quoting them

These are measured inside a QEMU virtual machine on Apple silicon, so the
absolute figures are not physical network throughput. There is no wire. What
they measure honestly is the **relative** cost of each path, which is what the
slide is about: how much you pay to move packets through userspace instead of
through a veth pair.

Quote the ratios with confidence. Quote the absolute numbers only with the
caveat that they came from a VM, or re-run `scripts/bench.sh` on the hardware
you intend to talk about.

## Network, iperf3 TCP, container to host, 10 seconds

| Path | Throughput | Relative |
|---|---|---|
| Rootful, veth bridge | 125 Gbit/s | 1.00 |
| Rootless, pasta | 83.6 Gbit/s | 0.67 |
| Rootless, slirp4netns | 28.1 Gbit/s | 0.22 |

The shape is the finding: pasta costs about a third against a veth pair, and
slirp4netns costs about four fifths. Both are real, and the gap between the
two rootless options is larger than most people expect.

## Container start to echo, cold, best of five

| Path | Time |
|---|---|
| Rootless Podman | 191 ms |

## Filesystem

The rootless store on this box uses the **native `overlay`** driver, not
fuse-overlayfs, which the kernel has allowed inside a user namespace since
5.11. This box runs 6.8, so the filesystem penalty people remember from the
fuse-overlayfs years does not apply here. The cold pull and extract row uses
`golang:1.27.0`, which is 927 MB on disk and matches the Go the VM installs.

**The time on this row has not been re-measured and slide 32 is still carrying
the old one.** The 12 seconds on the slide was recorded against `golang:1.23`
on a fast link. On a slower link `golang:1.27.0` reports 93 seconds, and
`golang:1.23` re-pulled on that same slow link reports 69 seconds. That control
is the point: the row is bandwidth-bound, so it says more about the network
than about the storage driver. Re-run `./scripts/bench.sh build` on the link
you measured the original on and put that number on the slide. The 927 MB is a
property of the image and does not move.

There is deliberately no native-overlay against fuse-overlayfs comparison in
this document. Measuring it correctly needs a separate store per driver and a
cold page cache, and the first careless attempt produced a two second figure
that was really a cache hit against the default store. A wrong number in a
talk about honesty is worse than a missing one. If you want the row, run it by
hand with a dedicated `--root` per driver and confirm the image was actually
removed first.

## Reaching the host is not the same on both backends

Worth knowing before demo 5, because it bit this benchmark first.

Under slirp4netns the container sits on its own subnet and
`host.containers.internal` resolves to the host. Under pasta it does not work
that way: pasta copies the host's addresses into the container, so the host's
own IP now points at the container itself and connecting to it is refused.
Reaching the host under pasta needs `--map-gw` and the gateway address:

```console
$ podman run --network=pasta --rm alpine ping -c1 192.168.76.15
# connects to itself

$ podman run --network=pasta:--map-gw --rm alpine ping -c1 192.168.76.2
# reaches the host
```

That is the same property the talk describes as a cost, that the source
address a service sees is often not what you expect, seen from the other side.

## One environment note

QEMU's user-mode networking defaults to `10.0.2.0/24`, and so does
slirp4netns. `qemu/vm.sh` moves the VM onto `192.168.76.0/24` for this reason.
Without that, a rootless container on slirp4netns lands in the same range as
the VM itself and "the host" stops being a well-defined address.
