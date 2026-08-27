# The demo VMs

Three variants of one QEMU definition. See `../docs/environment.md` for why
QEMU rather than OrbStack, and for the recorded versions.

```bash
./vm.sh up primary      # everything except the two cases below
./vm.sh up cgroupv1     # demo 4's second half
./vm.sh up hardened     # the twist
./vm.sh ssh primary
./vm.sh status
./vm.sh down            # all of them, or name one
```

First boot fetches a 590 MB cloud image and provisions for a few minutes.
Later boots reuse the overlay disk.

## If a namespace demo fails

Check the sysctl before anything else:

```bash
sysctl kernel.apparmor_restrict_unprivileged_userns
```

It must read `0` on `primary` and `cgroupv1`. Ubuntu ships it as `1`, and
provisioning writes `/etc/sysctl.d/99-crl-demo.conf` to change that. If it
reads `1`, either provisioning did not finish or something restored the
default.

Beat 3 of `nsdemo` prints `operation not permitted` both when it is working
correctly and when the sysctl is blocking it, so it is the one beat that
cannot be used as a signal. Beats 1, 2 and 4 fail loudly. `./scripts/demo.sh
check` asserts the sysctl directly for this reason.

## Files

`vm.sh` is the definition and is committed. The images, disks, seeds, keys and
generated `ssh_config` are not, and are all gitignored: they are rebuilt from
the pinned image and checksum on demand.
