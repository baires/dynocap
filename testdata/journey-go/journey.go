// Package journey is the go runtime fixture: one module dependency and a test.
package journey

import "github.com/google/go-cmp/cmp"

func Add(a, b int) int { return a + b }

// Diff reports how two values differ, using a downloaded module.
func Diff(want, got any) string { return cmp.Diff(want, got) }
