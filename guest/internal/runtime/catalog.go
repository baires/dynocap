package runtime

import (
	"fmt"
	"sort"
	"strings"
)

// A language joins the catalog with one recipe file and its pins; daemon, task and egress code stay unchanged.
type recipeFunc func(arch string) (Recipe, error)

var catalog = map[string]map[string]recipeFunc{
	"node": {
		// Newest linux-arm64-musl builds; v22 satisfies lint-staged's >=22.22.1 engine range.
		"22": nodeRecipe("v22.23.4", "10.9.9", "ed505d3b41e7674fd20b864c544b6bcd177fd88cb00124a23d5ecd4874041b3a"),
		"24": nodeRecipe("v24.22.3", "11.19.1", "8f4a3003252ea38c48465ebffd61432f7e4f34e4574c4edd6d07fe4293ae00b0"),
	},
	"go":     {"1.27": goRecipe("1.27.4", "3392582988a273a87ab5043ee1b2c9c17a2c3c00580bf9326c47a2e0aaaeac92")},
	"python": {"3.14": pythonRecipe("3.14.10", "0.13.8", "0c6f8593fcf1eadfc60e663b685c408267559d7c5d61c689bbb9f3a7e369ba32")},
	"shell":  {"1": shellRecipe},
}

// Supported lists every selection as NAME:VERSION, sorted.
func Supported() []string {
	var names []string
	for name, versions := range catalog {
		for version := range versions {
			names = append(names, name+":"+version)
		}
	}
	sort.Strings(names)
	return names
}

func Resolve(requests []Request, arch string) (Recipe, error) {
	supported := strings.Join(Supported(), ", ")
	if len(requests) != 1 {
		return Recipe{}, fmt.Errorf("unsupported runtimes: select exactly one of %s", supported)
	}
	build, ok := catalog[requests[0].Name][requests[0].Version]
	if !ok {
		return Recipe{}, fmt.Errorf("unsupported runtime %s:%s; supported: %s", requests[0].Name, requests[0].Version, supported)
	}
	recipe, err := build(arch)
	if err != nil {
		return Recipe{}, err
	}
	recipe.Requests = requests
	return recipe, nil
}
