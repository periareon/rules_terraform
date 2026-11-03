// Package gazelle is the engine-agnostic half of the rules_terraform Gazelle
// language. One directory of configuration files is one module target; a
// directory with a backend is a root and also gets its binary and lock
// targets. Which rule kinds those are, and which files count as
// configuration, is what an Engine says.
package gazelle

// Engine describes one engine to the shared language implementation. The
// Go counterpart of `engine_config` in //engine:engine.bzl: the Gazelle
// binary cannot read Starlark, so each engine's package restates the parts
// generation needs.
type Engine struct {
	// Name is the engine's name, `terraform` or `tofu`. It is the Gazelle
	// language name, the value a `tf_engine` directive takes, and the
	// generated binary target's name.
	Name string
	// ModuleName is the Bazel module the rules are loaded from.
	ModuleName string
	// LoadFile is the `.bzl` the generated load statement names, relative to
	// the module: `//terraform:defs.bzl`.
	LoadFile string
	// ModuleKind, BinaryKind, ProvidersLockKind and ProvidersLockTestKind are
	// the rule kinds generated for a directory.
	ModuleKind, BinaryKind, ProvidersLockKind, ProvidersLockTestKind string
	// SourceExtensions are the file extensions the engine loads as
	// configuration, in the order the module rule accepts them.
	SourceExtensions []string
}

func (e Engine) isSource(name string) bool {
	for _, ext := range e.SourceExtensions {
		if len(name) > len(ext) && name[len(name)-len(ext):] == ext {
			return true
		}
	}
	return false
}
