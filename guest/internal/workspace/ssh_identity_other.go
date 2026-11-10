//go:build !linux

package workspace

import "fmt"

func exposeSSHKey(material string) (string, func(), error) {
	return "", nil, fmt.Errorf("ssh key material is only available in the guest")
}
