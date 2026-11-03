package gazelle

import (
	"flag"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// Directives. All start with `tf_` rather than an engine name because both
// engines' languages read them: a repository that loads both decides per
// directory which one owns it.
const (
	// `# gazelle:tf_engine terraform|tofu`: the engine whose rules a
	// directory tree gets. Unset, a directory holding `.tofu` files is
	// OpenTofu's and anything else is Terraform's.
	directiveEngine = "tf_engine"
	// `# gazelle:tf_kind root|module|auto`: whether the directory is a root
	// module, which gets a binary and lock targets, or a library. `auto`,
	// the default, reads it from the configuration: a `backend` or `cloud`
	// block makes a root.
	directiveKind = "tf_kind"
	// `# gazelle:tf_deps_hub NAME...`: the dependency hubs (`@NAME`) every
	// module under the directory depends on. Unset, a root with a
	// `.terraform.lock.hcl` depends on `@tf_<its path>`; a library depends
	// on none. An empty value clears an inherited one.
	directiveDepsHub = "tf_deps_hub"
	// `# gazelle:tf_default_visibility LABEL...`: visibility for library
	// modules generated under the directory. Applied when a rule is first
	// written; an existing rule keeps its own.
	directiveDefaultVisibility = "tf_default_visibility"
)

const (
	kindAuto   = "auto"
	kindRoot   = "root"
	kindModule = "module"

	defaultEngine = "terraform"
)

// tfConfig is the per-directory configuration, inherited down the tree.
type tfConfig struct {
	engine         string
	engineExplicit bool
	kind           string
	hubs           []string
	hubsSet        bool
	visibility     []string
}

func (c *tfConfig) clone() *tfConfig {
	d := *c
	d.hubs = append([]string(nil), c.hubs...)
	d.visibility = append([]string(nil), c.visibility...)
	return &d
}

func getConfig(c *config.Config, lang string) *tfConfig {
	if v, ok := c.Exts[lang].(*tfConfig); ok {
		return v
	}
	return &tfConfig{engine: defaultEngine, kind: kindAuto}
}

func (l *tfLang) RegisterFlags(fs *flag.FlagSet, cmd string, c *config.Config) {}

func (l *tfLang) CheckFlags(fs *flag.FlagSet, c *config.Config) error { return nil }

func (l *tfLang) KnownDirectives() []string {
	return []string{directiveEngine, directiveKind, directiveDepsHub, directiveDefaultVisibility}
}

func (l *tfLang) Configure(c *config.Config, rel string, f *rule.File) {
	cfg := getConfig(c, l.engine.Name).clone()
	if f != nil {
		for _, d := range f.Directives {
			value := strings.TrimSpace(d.Value)
			switch d.Key {
			case directiveEngine:
				cfg.engine = value
				cfg.engineExplicit = true
			case directiveKind:
				cfg.kind = value
			case directiveDepsHub:
				cfg.hubs = strings.Fields(value)
				cfg.hubsSet = true
			case directiveDefaultVisibility:
				cfg.visibility = strings.Fields(value)
			}
		}
	}
	c.Exts[l.engine.Name] = cfg
}
