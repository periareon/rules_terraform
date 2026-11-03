package gazelle

import (
	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// importLang keys module directories in Gazelle's cross-resolution index.
const importLang = "tf"

type tfLang struct {
	engine Engine
}

// NewLanguage returns the Gazelle language for one engine.
func NewLanguage(engine Engine) language.Language {
	return &tfLang{engine: engine}
}

func (l *tfLang) Name() string { return l.engine.Name }

func (l *tfLang) Kinds() map[string]rule.KindInfo {
	return map[string]rule.KindInfo{
		l.engine.ModuleKind: {
			NonEmptyAttrs:  map[string]bool{"srcs": true},
			MergeableAttrs: map[string]bool{"srcs": true, "data": true},
			ResolveAttrs:   map[string]bool{"deps": true},
		},
		// `NonEmptyAttrs` is what lets Gazelle delete a stale rule: one whose
		// merge leaves none of these set is removed rather than kept bare.
		l.engine.BinaryKind: {
			NonEmptyAttrs:  map[string]bool{"root": true},
			MergeableAttrs: map[string]bool{"root": true},
		},
		l.engine.ProvidersLockKind: {
			NonEmptyAttrs:  map[string]bool{"target": true},
			MergeableAttrs: map[string]bool{"output": true, "target": true},
		},
		l.engine.ProvidersLockTestKind: {
			NonEmptyAttrs:  map[string]bool{"target": true},
			MergeableAttrs: map[string]bool{"lock": true, "target": true},
		},
	}
}

func (l *tfLang) symbols() []string {
	return []string{l.engine.BinaryKind, l.engine.ModuleKind, l.engine.ProvidersLockKind, l.engine.ProvidersLockTestKind}
}

func (l *tfLang) Loads() []rule.LoadInfo {
	return l.ApparentLoads(func(string) string { return "" })
}

func (l *tfLang) ApparentLoads(moduleToApparentName func(string) string) []rule.LoadInfo {
	repo := moduleToApparentName(l.engine.ModuleName)
	if repo == "" {
		repo = l.engine.ModuleName
	}
	return []rule.LoadInfo{{
		Name:    "@" + repo + l.engine.LoadFile,
		Symbols: l.symbols(),
	}}
}

func (l *tfLang) Fix(c *config.Config, f *rule.File) {}
