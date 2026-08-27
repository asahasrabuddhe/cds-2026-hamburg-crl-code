# 04. Network

## What it shows

Rootless containers do not get a veth pair, so they get a userspace TCP/IP stack instead, and you pay for it. A veth pair has one end in the host's network namespace, and creating it there needs privileges you do not have. What you can create is a tap device inside your own namespace, with a userspace process, pasta or slirp4netns, reading packets off it and speaking to the outside world through an ordinary socket owned by your UID.

Rootful goes container netns, veth, host bridge, host netns, NIC. Rootless goes container netns, tap, pasta or slirp4netns, host socket, NIC. Every packet crosses into a userspace process and back.

Five costs follow:

- Packets are copied through a userspace process, so throughput and latency both suffer. Measure it on your own hardware rather than quoting anyone else's numbers.
- Ports below 1024 are refused unless the administrator lowers `net.ipv4.ip_unprivileged_port_start`.
- `ping` works only if your GID falls inside `net.ipv4.ping_group_range`.
- Depending on the port-forwarding driver, the container often sees the gateway as the source IP rather than the real client, which breaks IP allow-lists and access logs.
- Most CNI plugins assume host privileges and simply do not apply.

pasta, Podman's default since 5.0, is a real improvement on slirp4netns. It copies the host's addresses and routes rather than inventing a subnet, and it is faster. Docker's rootless mode still ships slirp4netns by default, with pasta available in recent versions.

One caveat about this box. Ubuntu 24.04 ships Podman 4.9.3, which predates
pasta becoming the default, so rootless containers here use slirp4netns unless
you ask for pasta with `--network=pasta`. Both binaries are installed, so the
three-way comparison still runs, but do not claim pasta is the default on the
machine in front of you when it is not.

## How to run it

```console
$ ./scripts/demo.sh 5        # right pane, rootless
# ./scripts/demo.sh 5        # left pane, after sudo -i
```

The script prints the network backend, then publishes port 80. Run `iperf3` separately through pasta, through slirp4netns, and rootful with a veth pair, and put your own figures on the slide.

## Expected output

The left pane publishes port 80 without comment, because everything on that box is root's. The right pane fails:

```console
Error: rootlessport cannot expose privileged port 80
```

The fix is `sysctl net.ipv4.ip_unprivileged_port_start=80`, and the caveat is that it lowers the floor for every process on the machine, not only yours.

## What it proves

The security boundary has a throughput bill attached, and it is charged per packet. For a laptop or a build runner that cost is invisible. For a proxy, an ingress or anything doing high packets per second, measure before you commit.
