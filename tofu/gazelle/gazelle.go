// Package gazelle is the Gazelle language for OpenTofu modules: the shared
// implementation in //engine/gazelle, told what makes a directory a
// tofu one. Load it into a gazelle_binary:
//
//	gazelle_binary(
//	    name = "gazelle",
//	    languages = ["@rules_terraform//tofu/gazelle"],
//	)
package gazelle

import (
	"github.com/bazelbuild/bazel-gazelle/language"

	engine "rules_terraform/engine/gazelle"
)

// NewLanguage is what gazelle_binary calls.
func NewLanguage() language.Language {
	return engine.NewLanguage(engine.Engine{
		Name:                  "tofu",
		ModuleName:            "rules_terraform",
		LoadFile:              "//tofu:defs.bzl",
		ModuleKind:            "tofu_module",
		BinaryKind:            "tofu_binary",
		ProvidersLockKind:     "tofu_providers_lock",
		ProvidersLockTestKind: "tofu_providers_lock_test",
		SourceExtensions:      []string{".tf", ".tf.json", ".tofu", ".tofu.json"},
	})
}
