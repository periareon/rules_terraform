// Package gazelle is the Gazelle language for Terraform modules: the shared
// implementation in //engine/gazelle, told what makes a directory a
// terraform one. Load it into a gazelle_binary:
//
//	gazelle_binary(
//	    name = "gazelle",
//	    languages = ["@rules_terraform//terraform/gazelle"],
//	)
package gazelle

import (
	"github.com/bazelbuild/bazel-gazelle/language"

	engine "rules_terraform/engine/gazelle"
)

// NewLanguage is what gazelle_binary calls.
func NewLanguage() language.Language {
	return engine.NewLanguage(engine.Engine{
		Name:                  "terraform",
		ModuleName:            "rules_terraform",
		LoadFile:              "//terraform:defs.bzl",
		ModuleKind:            "terraform_module",
		BinaryKind:            "terraform_binary",
		ProvidersLockKind:     "terraform_providers_lock",
		ProvidersLockTestKind: "terraform_providers_lock_test",
		SourceExtensions:      []string{".tf", ".tf.json"},
	})
}
