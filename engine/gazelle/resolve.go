package gazelle

import (
	"log"
	"sort"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/repo"
	"github.com/bazelbuild/bazel-gazelle/resolve"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// Imports registers a module rule under its directory, which is what a
// `module` block's local source names.
func (l *tfLang) Imports(c *config.Config, r *rule.Rule, f *rule.File) []resolve.ImportSpec {
	if r.Kind() != l.engine.ModuleKind {
		return nil
	}
	return []resolve.ImportSpec{{Lang: importLang, Imp: f.Pkg}}
}

func (l *tfLang) Embeds(r *rule.Rule, from label.Label) []label.Label { return nil }

// Resolve turns the directories a module's blocks name into the module
// targets that supply them, and appends the hubs. A directory nothing
// supplies is reported, not dropped: the init aspect would fail on it later
// with less context.
func (l *tfLang) Resolve(c *config.Config, ix *resolve.RuleIndex, rc *repo.RemoteCache, r *rule.Rule, imports interface{}, from label.Label) {
	mi, ok := imports.(moduleImports)
	if !ok {
		return
	}
	var deps []string
	for _, dir := range mi.dirs {
		results := ix.FindRulesByImportWithConfig(c, resolve.ImportSpec{Lang: importLang, Imp: dir}, l.engine.Name)
		switch len(results) {
		case 0:
			log.Printf("%s: a module block names %q, but no %s target supplies that directory", from, dir, l.engine.ModuleKind)
			continue
		case 1:
		default:
			log.Printf("%s: a module block names %q, which %d targets supply", from, dir, len(results))
			continue
		}
		deps = append(deps, results[0].Label.Rel(from.Repo, from.Pkg).String())
	}
	for _, hub := range mi.hubs {
		deps = append(deps, "@"+hub)
	}
	sort.Strings(deps)
	if len(deps) == 0 {
		r.DelAttr("deps")
		return
	}
	r.SetAttr("deps", deps)
}
