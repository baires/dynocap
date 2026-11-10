//go:build linux

package workspace

import (
	"fmt"

	"golang.org/x/sys/unix"
)

// exposeSSHKey keeps key bytes in a memfd. The returned path is /proc/self/fd/N.
// The key is not written to a named filesystem path.
func exposeSSHKey(material string) (string, func(), error) {
	fd, err := unix.MemfdCreate("microvm-ssh", 0)
	if err != nil {
		return "", nil, fmt.Errorf("ssh key could not be held")
	}
	cleanup := func() { _ = unix.Close(fd) }
	data := []byte(material)
	if len(data) == 0 || data[len(data)-1] != '\n' {
		data = append(data, '\n')
	}
	n, err := unix.Write(fd, data)
	if err != nil || n != len(data) {
		cleanup()
		return "", nil, fmt.Errorf("ssh key could not be held")
	}
	if _, err := unix.Seek(fd, 0, 0); err != nil {
		cleanup()
		return "", nil, fmt.Errorf("ssh key could not be held")
	}
	// A new memfd is mode 0777. OpenSSH refuses ssh -i when group or world bits are set.
	if err := unix.Fchmod(fd, 0o600); err != nil {
		cleanup()
		return "", nil, fmt.Errorf("ssh key could not be held")
	}
	return fmt.Sprintf("/proc/self/fd/%d", fd), cleanup, nil
}
