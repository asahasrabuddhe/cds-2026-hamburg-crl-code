# 02. Filesystem

## What it shows

The capability is genuine; the set of objects it applies to is not. Rootless `CAP_SYS_ADMIN` mounts a tmpfs without complaint, then fails on a real block device and on `mknod`. Rootful does all three.

The kernel decides this per filesystem type. A filesystem may be mounted inside a user namespace only if it is flagged `FS_USERNS_MOUNT`. tmpfs carries the flag, ext4 does not, because ext4 parses attacker-controlled on-disk metadata and that parser has never been considered safe to expose to unprivileged users. Device nodes are refused for the same reason: `mknod` inside a user namespace cannot hand you access the namespace does not already hold.

The related story is storage layout. Image layers on disk belong to 100000 and upwards, not to root. Before kernel 5.11 rootless overlays ran through `fuse-overlayfs`, so every metadata operation crossed into userspace and builds were slow. Kernel 5.11 made overlayfs mountable inside a user namespace, and kernel 5.12 added idmapped mounts, which present the same directory as owned by 0 in the container and 100000 on the host with no on-disk change. That removed the recursive `chown` on first extraction, and it is the same feature that made stateful pods practical for KEP-127.

## How to run it

```console
$ ./scripts/demo.sh 2        # right pane, rootless
# ./scripts/demo.sh 2        # left pane, after sudo -i
```

The script runs three commands identically in both panes: mount a tmpfs, mount a real unmounted block device, and `mknod /dev/evil b 8 0`. All three run with `--privileged` on purpose, so the flags are identical and the pane is the only variable. A default container holds no CAP_SYS_ADMIN in either engine, and `--cap-add SYS_ADMIN` alone is not enough on the rootful side, where both engines confine the container with an AppArmor profile that denies `mount(2)` whatever capabilities it holds. The device is discovered rather than hardcoded: `lsblk -pnro NAME,FSTYPE,MOUNTPOINT` and the first row with a filesystem and no mountpoint, which on the primary VM is `/dev/vdb`, the cloud-init seed ISO.

## Expected output

Both panes print `tmpfs mount: OK`. The left pane then prints `block mount: OK` and `mknod: OK`. The right pane prints `block mount: DENIED` and `mknod: DENIED`.

## What it proves

`--privileged` in rootless mode does not mean what people assume. On the left it means what it says. On the right it grants everything your user namespace holds, which never included the disk or the device node. The boundary is not the capability bit, it is the ownership of the object the capability is checked against.
