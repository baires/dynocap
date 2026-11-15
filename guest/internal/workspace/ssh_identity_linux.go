//go:build linux

package workspace

import (
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// exposeSSHKey keeps key bytes in a memfd. The returned path names the owning process, so OpenSSH can close inherited fds.
// The key is not written to a named filesystem path.
func exposeSSHKey(material string) (string, func(), error) {
	fd, err := unix.MemfdCreate("dynocap-ssh", unix.MFD_CLOEXEC)
	if err != nil {
		return "", nil, fmt.Errorf("ssh key could not be held")
	}
	cleanup := func() { _ = unix.Close(fd) }
	// A new memfd is mode 0777. OpenSSH refuses ssh -i when group or world bits are set.
	if err := unix.Fchmod(fd, 0o600); err != nil {
		cleanup()
		return "", nil, fmt.Errorf("ssh key could not be held")
	}
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
	return fmt.Sprintf("/proc/%d/fd/%d", os.Getpid(), fd), cleanup, nil
}
