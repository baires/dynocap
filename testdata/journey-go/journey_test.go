package journey

import "testing"

func TestAdd(t *testing.T) {
	if got := Add(2, 3); got != 5 {
		t.Fatalf("Add(2, 3) = %d", got)
	}
}

func TestDiffUsesTheDependency(t *testing.T) {
	if Diff([]int{1}, []int{1}) != "" || Diff([]int{1}, []int{2}) == "" {
		t.Fatal("cmp.Diff did not compare")
	}
}
