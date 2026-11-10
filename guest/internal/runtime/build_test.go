package runtime

import "testing"

func TestExplicitResolution(t *testing.T) {
	for _, requests := range [][]Request{nil, {{"node", "24"}}, {{"python", "3.13"}}, {{"node", "22"}, {"node", "22"}}} {
		if _, err := Resolve(requests, "aarch64"); err == nil {
			t.Fatalf("accepted %+v", requests)
		}
	}
	recipe, err := Resolve([]Request{{"node", "22"}}, "aarch64")
	if err != nil {
		t.Fatal(err)
	}
	if recipe.Tools["node"] != "v22.21.1" || recipe.Tools["npm"] != "10.9.4" || len(recipe.VerificationCommand) == 0 {
		t.Fatal(recipe)
	}
	for _, in := range recipe.Inputs {
		if len(in.SHA256) != 64 {
			t.Fatalf("unpinned input %+v", in)
		}
	}
}
