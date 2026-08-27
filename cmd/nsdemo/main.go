//go:build linux

// nsdemo: the identity machinery behind rootless containers, by hand.
//
// Four beats, each one a subcommand:
//
//	nsdemo 1   a user namespace with no mapping at all
//	nsdemo 2   map yourself, become root, hit the boundary
//	nsdemo 3   try to map a range without help, and fail
//	nsdemo 4   the real dance: pause the child, run newuidmap, resume
//
// Run every beat as an ordinary user. If you run this as root you will prove
// nothing, because root proves nothing.
//
// One Go detail worth saying out loud on stage: CLONE_NEWUSER is only legal
// for a single-threaded process, and the Go runtime is multi-threaded before
// main() starts. So a Go program can never unshare itself into a new user
// namespace. It has to fork and exec, which is exactly what os/exec does when
// you set Cloneflags, and exactly why every beat below re-execs /proc/self/exe.
package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"

	"go.ajitem.com/crl/internal/subid"
)

const (
	// The child re-execs itself through these argv[1] values.
	modeChild     = "child"
	modeChildWait = "child-wait"

	// The barrier pipe arrives as fd 3 in the child: fds 0, 1 and 2 are
	// stdin, stdout and stderr, and ExtraFiles starts numbering after them.
	barrierFD = 3

	// The ready pipe is fd 4, and runs the other way: the child writes to it
	// to tell the parent it has reported and parked at the barrier.
	readyFD = 4
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}

	switch os.Args[1] {
	case modeChild:
		child(false)
	case modeChildWait:
		child(true)
	case "1":
		beat1()
	case "2":
		beat2()
	case "3":
		beat3()
	case "4":
		beat4()
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: nsdemo {1|2|3|4}")
	os.Exit(2)
}

// ---------------------------------------------------------------- beat 1 ---

// beat1 creates a user namespace and maps nothing into it.
//
// The child keeps the same credentials it always had, the kernel simply has
// no way to express them inside the new namespace, so every lookup returns the
// overflow ID. Not root. Not you. Nobody.
func beat1() {
	banner("BEAT 1: a namespace with no map at all")

	cmd := newChild(modeChild)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUSER | syscall.CLONE_NEWNS,
	}

	must(cmd.Run())
}

// ---------------------------------------------------------------- beat 2 ---

// beat2 maps exactly one ID: the caller's own UID becomes 0 inside.
//
// os/exec does the write for us. The parent waits for the child to be created,
// writes /proc/<pid>/uid_map and /proc/<pid>/gid_map, and only then lets the
// child exec. GidMappingsEnableSetgroups stays false, which makes os/exec
// write "deny" to /proc/<pid>/setgroups first, the kernel refuses an
// unprivileged gid_map otherwise, because setgroups() could be used to drop a
// group that a file's permissions relied on.
func beat2() {
	banner("BEAT 2: map yourself, and become root")

	uid, gid := os.Getuid(), os.Getgid()

	// snippet:start unshare-raw
	cmd := newChild(modeChild)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUSER | syscall.CLONE_NEWNS,
		UidMappings: []syscall.SysProcIDMap{
			{ContainerID: 0, HostID: uid, Size: 1},
		},
		GidMappings: []syscall.SysProcIDMap{
			{ContainerID: 0, HostID: gid, Size: 1},
		},
		GidMappingsEnableSetgroups: false,
	}
	// snippet:end unshare-raw

	fmt.Printf("  parent: uid %d → container uid 0, size 1\n", uid)
	must(cmd.Run())
}

// ---------------------------------------------------------------- beat 3 ---

// beat3 asks for the range a real container needs, and is refused.
//
// Writing more than one ID into uid_map requires CAP_SETUID in the *parent*
// user namespace, which an ordinary user does not have. The failure arrives
// from cmd.Start(), because the parent's write to /proc/<pid>/uid_map is part
// of process creation.
func beat3() {
	banner("BEAT 3: ask for a range, get told no")

	sub, err := subid.ForCurrentUser("/etc/subuid")
	if err != nil {
		fmt.Printf("  (no /etc/subuid entry: %v, using 100000/65536 for the demo)\n", err)
		sub = subid.Range{Start: 100000, Count: 65536}
	}

	cmd := newChild(modeChild)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUSER | syscall.CLONE_NEWNS,
		UidMappings: []syscall.SysProcIDMap{
			{ContainerID: 0, HostID: sub.Start, Size: sub.Count},
		},
	}

	fmt.Printf("  parent: asking for 0 → %d, size %d\n", sub.Start, sub.Count)

	if err := cmd.Start(); err != nil {
		fmt.Printf("\n  cmd.Start(): %v\n", err)
		fmt.Println("  The write to /proc/<pid>/uid_map was refused.")
		fmt.Println("  This is why /etc/subuid and the setuid helpers exist.")
		return
	}

	_ = cmd.Wait()
	fmt.Println("\n  That succeeded, are you running as root? Don't.")
}

// ---------------------------------------------------------------- beat 4 ---

// beat4 is what Podman, Docker rootless and runc actually do.
//
//  1. start the child in a new user namespace with no mapping
//  2. hold it at a barrier so it cannot run before the map exists
//  3. call newuidmap/newgidmap, setuid-root helpers that read /etc/subuid
//     and do the privileged write on our behalf
//  4. release the barrier
//
// The mapping deliberately has two lines. Container UID 0 maps to the caller's
// own host UID, so files a container writes as "root" land on disk owned by
// you. Container UIDs 1 and up map into the delegated /etc/subuid range.
func beat4() {
	banner("BEAT 4: what Podman really does")

	uid, gid := os.Getuid(), os.Getgid()

	// Same graceful fallback as beat 3. A missing /etc/subuid entry should
	// not kill the most important beat with a bare error.
	subUID := subIDsOrDefault("/etc/subuid")
	subGID := subIDsOrDefault("/etc/subgid")

	// Two pipes, because one is not enough. The barrier holds the child until
	// the map exists. The ready pipe holds the parent until the child has
	// reported that it is unmapped and parked. With only the barrier the
	// parent runs straight from Start() into newuidmap while the child is
	// still printing its "before" panel, and on stage the beat reads
	// backwards. The real implementations sync in both directions too.
	barrierRead, barrierWrite, err := os.Pipe()
	must(err)
	readyRead, readyWrite, err := os.Pipe()
	must(err)

	cmd := newChild(modeChildWait)
	cmd.ExtraFiles = []*os.File{barrierRead, readyWrite} // → fd 3 and fd 4
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUSER | syscall.CLONE_NEWNS,
	}

	// snippet:start barrier
	must(cmd.Start())
	_ = barrierRead.Close() // the child holds its own copies now
	_ = readyWrite.Close()

	pid := cmd.Process.Pid
	fmt.Printf("  parent: child is pid %d, currently unmapped\n", pid)

	// Block here until the child has reported and parked.
	if _, err := io.ReadFull(readyRead, make([]byte, 1)); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		must(fmt.Errorf("child never reached the barrier: %w", err))
	}

	// newuidmap <pid> <container> <host> <size> [<container> <host> <size>...]
	mapping := []string{
		"0", strconv.Itoa(uid), "1",
		"1", strconv.Itoa(subUID.Start), strconv.Itoa(subUID.Count),
	}
	mustHelper(cmd, "newuidmap", pid, mapping)

	mapping = []string{
		"0", strconv.Itoa(gid), "1",
		"1", strconv.Itoa(subGID.Start), strconv.Itoa(subGID.Count),
	}
	mustHelper(cmd, "newgidmap", pid, mapping)

	// Release the child.
	_, err = barrierWrite.Write([]byte{1})
	must(err)
	_ = barrierWrite.Close()
	// snippet:end barrier

	must(cmd.Wait())
}

// subIDsOrDefault reads a delegated range, falling back to the range Podman
// would have been given by a default useradd, so the beat still runs on a box
// where nobody set /etc/subuid up.
func subIDsOrDefault(path string) subid.Range {
	r, err := subid.ForCurrentUser(path)
	if err != nil {
		fmt.Printf("  parent: no usable %s entry (%v), assuming 100000/65536\n", path, err)
		return subid.Range{Start: 100000, Count: 65536}
	}
	return r
}

// mustHelper runs a setuid helper and, if it fails, takes the blocked child
// down with it. Exiting without this leaves the child parked on a barrier
// that will never be written to, so it reports a read error after the shell
// prompt has already come back.
func mustHelper(cmd *exec.Cmd, name string, pid int, mapping []string) {
	if err := runHelper(name, pid, mapping); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		must(err)
	}
}

func runHelper(name string, pid int, mapping []string) error {
	// These are the setuid-root helpers from shadow-utils. They are the whole
	// trust path: they read /etc/subuid, check the caller owns the range, and
	// do the privileged write we are not allowed to do ourselves.
	path, err := exec.LookPath(name)
	if err != nil {
		return fmt.Errorf("%s not found on PATH, install the uidmap package: %w", name, err)
	}

	args := append([]string{strconv.Itoa(pid)}, mapping...)
	fmt.Printf("  parent: %s %s\n", name, strings.Join(args, " "))

	out, err := exec.Command(path, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s failed: %v: %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// ----------------------------------------------------------------- child ---

// child runs inside the new namespace. It reports who the kernel thinks it is,
// optionally waits at the barrier, then reports again, and the second report
// is the point of the whole demo. No syscall changed this process's
// credentials. The kernel simply learned how to translate them.
func child(wait bool) {
	// Beats 1 and 2: no barrier. The namespace is already mapped (or
	// deliberately is not), so report, then answer what that root is worth.
	if !wait {
		makeRootPrivate()
		report("inside the new user namespace")
		probe()
		return
	}

	// Beat 4: the barrier case. Make nothing private yet, because an unmapped
	// process has no capabilities left after execve and the remount would
	// fail noisily in the middle of the first panel.
	reportIdentity("inside the new user namespace")
	fmt.Println("\n  child: blocked, the map does not exist yet")

	// Tell the parent we have reported and parked. Without this the parent
	// races ahead and announces newuidmap while this child is still printing
	// its "before" panel, so the beat tells its story backwards: the mapping
	// is announced, then a panel says no mapping exists. runc runs the same
	// handshake in the same direction and calls it procReady.
	ready := os.NewFile(readyFD, "ready")
	if _, err := ready.Write([]byte{1}); err != nil {
		fmt.Fprintf(os.Stderr, "  ready signal failed: %v\n", err)
		os.Exit(1)
	}
	_ = ready.Close()

	// Block until the parent has run newuidmap and newgidmap.
	barrier := os.NewFile(barrierFD, "barrier")
	if _, err := io.ReadFull(barrier, make([]byte, 1)); err != nil {
		fmt.Fprintf(os.Stderr, "  barrier read failed: %v\n", err)
		os.Exit(1)
	}

	makeRootPrivate()

	// Identity only. No syscall changed this process's credentials and no
	// probe follows: the point is that the kernel changed its mind about who
	// this process is, while the process itself carried on running.
	reportIdentity("same process, one moment later, after newuidmap ran")
}

// makeRootPrivate stops mounts made in this namespace propagating back to the
// host. runc does this on every container start. EPERM is expected and stays
// silent: beat 1 runs with no capabilities at all.
func makeRootPrivate() {
	err := syscall.Mount("", "/", "", syscall.MS_REC|syscall.MS_PRIVATE, "")
	if err != nil && err != syscall.EPERM {
		fmt.Fprintf(os.Stderr, "  warning: could not make / private: %v\n", err)
	}
}

// report prints who the kernel thinks this process is. Beats 1 and 2 also
// print the capability sets, because there they are the subject. Beat 4 does
// not: its point is that the identity changed underneath a running process,
// and three rows of hex that happen to be zero only invite a question about
// exec ordering that belongs in beat 1.
func report(label string) {
	reportIdentity(label)
	reportCaps()
}

func reportIdentity(label string) {
	fmt.Printf("\n  ── %s ──\n", label)
	fmt.Printf("  uid=%d  euid=%d  gid=%d\n", os.Getuid(), os.Geteuid(), os.Getgid())
	fmt.Printf("  uid_map: %s\n", oneLine("/proc/self/uid_map"))
	fmt.Printf("  gid_map: %s\n", oneLine("/proc/self/gid_map"))
}

func reportCaps() {
	// Three sets, not one. The kernel does grant a full capability set to the
	// first process in a new user namespace, but execve recalculates it, and
	// an unmapped process has euid 65534 rather than 0, so the kernel treats
	// the exec as unprivileged and the effective set arrives empty. The
	// bounding set survives untouched. That is why CapBnd reads full while
	// CapEff reads zero: the ceiling is unlimited, the current holding is
	// nothing. Map a uid 0 in, as beat 2 does, and the exec keeps the
	// capabilities instead of dropping them.
	fmt.Printf("  CapPrm:  %s\n", statusField("CapPrm"))
	fmt.Printf("  CapEff:  %s\n", statusField("CapEff"))
	fmt.Printf("  CapBnd:  %s\n", statusField("CapBnd"))
}

// probe answers the only question that matters: this process says it is root,
// so what can it actually do?
func probe() {
	fmt.Println("\n  ── what is this 'root' worth? ──")

	// Owned by real root on the host. Denied, whatever the container thinks.
	check("append to /etc/shadow", func() error {
		f, err := os.OpenFile("/etc/shadow", os.O_WRONLY|os.O_APPEND, 0)
		if err != nil {
			return err
		}
		return f.Close()
	})

	// tmpfs carries FS_USERNS_MOUNT, so the kernel allows it from inside a
	// user namespace. ext4 does not, which is Demo 2 on the slides.
	check("mount a tmpfs", func() error {
		dir, err := os.MkdirTemp("", "nsdemo")
		if err != nil {
			return err
		}
		defer os.RemoveAll(dir)
		return syscall.Mount("none", dir, "tmpfs", 0, "")
	})

	// Your own files are inside the blast radius. They always were.
	if home, err := os.UserHomeDir(); err == nil {
		check("write into $HOME", func() error {
			path := home + "/.nsdemo-probe"
			if err := os.WriteFile(path, []byte("reachable\n"), 0o600); err != nil {
				return err
			}
			return os.Remove(path)
		})
	}
}

func check(what string, fn func() error) {
	if err := fn(); err != nil {
		fmt.Printf("  DENIED   %-24s %v\n", what, err)
		return
	}
	fmt.Printf("  ALLOWED  %s\n", what)
}

// ----------------------------------------------------------------- utils ---

func newChild(mode string) *exec.Cmd {
	cmd := exec.Command("/proc/self/exe", mode)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd
}

func banner(s string) {
	fmt.Printf("\n%s\n%s\n", s, strings.Repeat("=", len(s)))
}

func oneLine(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return "unreadable: " + err.Error()
	}
	fields := strings.Fields(string(b))
	if len(fields) == 0 {
		return "(empty, no mapping exists)"
	}
	// Regroup into "container host size" triples for readability.
	var triples []string
	for i := 0; i+2 < len(fields); i += 3 {
		triples = append(triples, strings.Join(fields[i:i+3], " "))
	}
	return strings.Join(triples, "  |  ")
}

func statusField(name string) string {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return "unreadable"
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, name+":") {
			return strings.TrimSpace(strings.TrimPrefix(line, name+":"))
		}
	}
	return "not found"
}

func must(err error) {
	if err != nil {
		fmt.Fprintf(os.Stderr, "  error: %v\n", err)
		os.Exit(1)
	}
}
