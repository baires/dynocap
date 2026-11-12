package runtime

// shellRecipe is the base toolchain alone: no language, no package manager, no registry egress.
func shellRecipe(arch string) (Recipe, error) {
	return withBase(arch, Recipe{}, "")
}
