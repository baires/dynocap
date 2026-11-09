package image

import (
	"fmt"
	"strings"
)

// modulePlan is the insmod order for virtio-vsock and virtio-net (NAT).
// Vsock is loaded before the agent listens. Net is loaded after.
type modulePlan struct {
	// Paths is Vsock then Net, relative to /lib/modules/<release>/, ending in .ko.
	Paths []string
	Vsock []string
	Net   []string
}

// planModules reads modules.dep plus the kernel config and returns the
// modules that must be loaded for NAT and vsock. Built-ins are omitted.
func planModules(depText, config string) (modulePlan, error) {
	deps, paths, err := parseModulesDep(depText)
	if err != nil {
		return modulePlan{}, err
	}
	// vsock before virtio-net so PID 1 can start the agent before NAT comes up.
	targets := []struct {
		name   string
		config string
	}{
		{"vmw_vsock_virtio_transport", "CONFIG_VIRTIO_VSOCKETS"},
		{"virtio_net", "CONFIG_VIRTIO_NET"},
	}
	seen := map[string]bool{}
	var order []string
	var walk func(name string) error
	walk = func(name string) error {
		if seen[name] {
			return nil
		}
		seen[name] = true
		for _, dep := range deps[name] {
			if err := walk(dep); err != nil {
				return err
			}
		}
		rel, ok := paths[name]
		if !ok {
			return fmt.Errorf("module %s missing from modules.dep", name)
		}
		order = append(order, rel)
		return nil
	}
	var vsock, net []string
	for _, target := range targets {
		before := len(order)
		if _, ok := paths[target.name]; ok {
			if err := walk(target.name); err != nil {
				return modulePlan{}, err
			}
			added := append([]string(nil), order[before:]...)
			if target.name == "vmw_vsock_virtio_transport" {
				vsock = append(vsock, added...)
			} else {
				net = append(net, added...)
			}
			continue
		}
		switch configValue(config, target.config) {
		case "y":
			continue
		case "m":
			return modulePlan{}, fmt.Errorf("%s=%s but %s is not in modules.dep", target.config, "m", target.name)
		default:
			return modulePlan{}, fmt.Errorf("kernel has no %s (%s)", target.name, target.config)
		}
	}
	return modulePlan{Paths: order, Vsock: vsock, Net: net}, nil
}

func configValue(config, key string) string {
	for _, line := range strings.Split(config, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, key+"=") {
			return strings.TrimPrefix(line, key+"=")
		}
	}
	return ""
}

func parseModulesDep(text string) (deps map[string][]string, paths map[string]string, err error) {
	deps = map[string][]string{}
	paths = map[string]string{}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || !strings.Contains(line, ":") {
			continue
		}
		left, right, _ := strings.Cut(line, ":")
		base, stored := moduleName(left)
		if base == "" {
			continue
		}
		paths[base] = stored
		var ds []string
		for _, field := range strings.Fields(right) {
			depName, _ := moduleName(field)
			if depName != "" {
				ds = append(ds, depName)
			}
		}
		deps[base] = ds
	}
	if len(paths) == 0 {
		return nil, nil, fmt.Errorf("modules.dep is empty")
	}
	return deps, paths, nil
}

// moduleName returns the module base name and the archive-relative path
// with a trailing .gz removed (so insmod can load the uncompressed object).
func moduleName(p string) (base, stored string) {
	p = strings.TrimSpace(p)
	stored = strings.TrimSuffix(p, ".gz")
	base = strings.TrimSuffix(stored, ".ko")
	if i := strings.LastIndex(base, "/"); i >= 0 {
		base = base[i+1:]
	}
	return base, stored
}
