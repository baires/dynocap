package image

import (
	"fmt"
	"strings"
)

// modulePlan is the insmod order for virtio-net (NAT) and virtio-vsock.
type modulePlan struct {
	// Paths are relative to /lib/modules/<release>/ and end in .ko.
	Paths []string
}

// planModules reads modules.dep plus the kernel config and returns the
// modules that must be loaded for NAT and vsock. Built-ins are omitted.
func planModules(depText, config string) (modulePlan, error) {
	deps, paths, err := parseModulesDep(depText)
	if err != nil {
		return modulePlan{}, err
	}
	targets := []struct {
		name   string
		config string
	}{
		{"virtio_net", "CONFIG_VIRTIO_NET"},
		{"vmw_vsock_virtio_transport", "CONFIG_VIRTIO_VSOCKETS"},
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
	for _, target := range targets {
		if _, ok := paths[target.name]; ok {
			if err := walk(target.name); err != nil {
				return modulePlan{}, err
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
	return modulePlan{Paths: order}, nil
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
