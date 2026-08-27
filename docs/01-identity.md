# 01. Identity

## What it shows

A rootless container says `uid=0(root)` and the host says `uid=1000`, and both answers are true. The four beats of `nsdemo` then take that apart: a user namespace is created, an identity is written into it from outside, and the kernel changes its mind about who the process is without the process changing at all.

The mechanism is two files and two setuid helpers. On the demo box `/etc/subuid` and `/etc/subgid` both read `ajitem:100000:65536`, so the administrator has delegated 65,536 IDs starting at 100000. An unprivileged process may map only its own UID into a namespace it creates, one line, size one. Widening the map to the delegated range needs `newuidmap` and `newgidmap`, small setuid-root binaries from shadow-utils that read those files and write `/proc/<pid>/uid_map` on your behalf. Rootless describes the runtime, not the installation.

## How to run it

```console
$ ./scripts/demo.sh 1        # right pane, rootless
# ./scripts/demo.sh 1        # left pane, after sudo -i
$ ./nsdemo 1                 # then 2, 3, 4
```

Ubuntu 24.04 ships `kernel.apparmor_restrict_unprivileged_userns = 1`, which blocks unprivileged user namespaces and therefore blocks every demo here. Provisioning turns it off with a drop-in at `/etc/sysctl.d/99-crl-demo.conf`.

## Expected output

Demo 1 prints `uid=0(root)` inside the container in both panes. On the host, `/proc/<pid>/status` reads `Uid: 0` on the left and `Uid: 1000` on the right. Only the right pane has a `uid_map` worth reading: `0 1000 1`, then `1 100000 65536`.

The beats, on this box:

- Beat 1: `uid=65534`, empty `uid_map`, `CapPrm` and `CapEff` all zeroes, `CapBnd` `000001ffffffffff`.
- Beat 2: `uid=0`, `uid_map` `0 1000 1`, all three capability sets full. Denies `/etc/shadow`, allows a tmpfs mount and a write into `$HOME`.
- Beat 3: fails at `cmd.Start()` with `EPERM`, because `uid_map` is written during process creation.
- Beat 4: the child starts unmapped, blocks at a pipe barrier, `newuidmap` and `newgidmap` run, and the same process then reads `0 1000 1  |  1 100000 65536`.

Beat 1 is worth a second look. The kernel grants the full capability set to the first process in a new user namespace, but `execve` recalculates it, and an unmapped process has euid 65534 rather than 0. So the effective set arrives empty while the bounding set survives intact.

## What it proves

Container UID 0 is your own host UID, not the start of the delegated range. Root is a claim evaluated against a namespace, and the namespace got its identity from a text file and a setuid helper.
