package subid

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/user"
	"strconv"
	"strings"
)

// Range is one delegated block of IDs: "start here, for this many".
type Range struct {
	Start int
	Count int
}

// ForCurrentUser reads /etc/subuid or /etc/subgid and returns the range
// the administrator delegated to whoever is running this process.
func ForCurrentUser(path string) (Range, error) {
	f, err := os.Open(path)
	if err != nil {
		return Range{}, err
	}
	defer f.Close()

	u, err := user.Current()
	if err != nil {
		return Range{}, err
	}

	return parse(f, u.Username, u.Uid)
}

// parse scans subuid-format lines: "owner:start:count", where owner is
// either a username or a numeric ID. The first matching line wins, which is
// what shadow-utils does.
func parse(r io.Reader, username, uid string) (Range, error) {
	scanner := bufio.NewScanner(r)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.Split(line, ":")
		if len(parts) != 3 {
			continue
		}

		owner := strings.TrimSpace(parts[0])
		if owner != username && owner != uid {
			continue
		}

		start, err := strconv.Atoi(strings.TrimSpace(parts[1]))
		if err != nil {
			return Range{}, fmt.Errorf("bad start in %q: %w", line, err)
		}

		count, err := strconv.Atoi(strings.TrimSpace(parts[2]))
		if err != nil {
			return Range{}, fmt.Errorf("bad count in %q: %w", line, err)
		}

		// A negative start would produce a uid_map line the kernel cannot
		// use, and shadow-utils would refuse it anyway. Reject it here so the
		// error names the offending file rather than surfacing later as an
		// opaque newuidmap failure.
		if start < 0 {
			return Range{}, fmt.Errorf("negative start in %q", line)
		}

		if count < 1 {
			return Range{}, fmt.Errorf("empty range in %q", line)
		}

		return Range{Start: start, Count: count}, nil
	}

	if err := scanner.Err(); err != nil {
		return Range{}, err
	}

	return Range{}, fmt.Errorf("no entry for %q", username)
}
