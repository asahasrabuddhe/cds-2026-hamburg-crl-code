# 03. cgroups

## What it shows

`--memory=64m` is not always a limit. Rootless resource control has three outcomes, and only one of them is the one you expected:

- cgroup v2 with systemd delegation: the limit applies.
- cgroup v2 without delegation: the limit is silently unavailable.
- cgroup v1 rootless: Podman prints `Resource limits are not supported and ignored on cgroups V1 rootless` and runs the container anyway.

The mechanism is delegation. systemd starts a `user@<uid>.service` slice and hands a subtree of the cgroup tree to it. Only the controllers named in `Delegate=` are yours to write, and cgroup v1 has no delegation model for unprivileged users at all, so there is nothing to hand over. Check what you actually hold:

```console
$ systemctl show user@$(id -u).service -p Delegate -p DelegateControllers
$ cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers
cpu memory pids
```

## How to run it

```console
$ ./scripts/demo.sh 4        # right pane, rootless
# ./scripts/demo.sh 4        # left pane, after sudo -i
```

Run it first on the primary VM, which is cgroup v2 with delegation, and then on the second VM, booted with `systemd.unified_cgroup_hierarchy=0` for cgroup v1. The v1 half is live, not pre-recorded. The script asks for `--memory=64m` and then asks the container itself what it got, by reading `/sys/fs/cgroup/memory.max` from inside.

## Expected output

On the v2 host both panes print `67108864`, and the two panes agree. On the v1 host they diverge: the left pane still reports the limit through `memory.limit_in_bytes`, and the right pane returns a warning and an unlimited container. Anything other than `67108864` means the limit did not apply.

## What it proves

The failure is quiet, which is the whole point. A no-op with a warning looks like success in a CI log and in a `docker run` exit code, so a container you believed was capped can consume the box. Check `podman info --format '{{.Host.CgroupsVersion}} {{.Host.CgroupControllers}}'` on every host you deploy to, rather than trusting that the flag you passed did something.
