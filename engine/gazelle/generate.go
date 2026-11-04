package gazelle

import (
	"log"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"

	"rules_terraform/engine/internal/tfparse"
)

const (
	providersLockTestName   = "providers_lock"
	providersLockUpdateName = "providers_lock.update"
)

// moduleImports is what a module rule needs resolved: the directories its
// `module` blocks name with a local source, and the hubs it depends on.
type moduleImports struct {
	dirs []string
	hubs []string
}

func hasTofuSources(files []string) bool {
	for _, f := range files {
		if strings.HasSuffix(f, ".tofu") || strings.HasSuffix(f, ".tofu.json") {
			return true
		}
	}
	return false
}

// owner is the engine a directory belongs to: the `tf_engine` directive, or
// the files themselves when none is set.
func owner(cfg *tfConfig, files []string) string {
	if cfg.engineExplicit {
		return cfg.engine
	}
	if hasTofuSources(files) {
		return "tofu"
	}
	return cfg.engine
}

func (l *tfLang) moduleName(args language.GenerateArgs) string {
	if args.Rel == "" {
		return filepath.Base(args.Dir)
	}
	return path.Base(args.Rel)
}

// defaultHub is the hub a root with a lock file depends on when no
// `tf_deps_hub` directive names one: `tf_` plus its path, the way
// `terraform.deps(name = ...)` tags are conventionally named.
func defaultHub(rel string) string {
	replacer := strings.NewReplacer("/", "_", "-", "_", ".", "_")
	return "tf_" + replacer.Replace(rel)
}

// isEngineWorkDir reports whether rel lies inside a directory the engine
// itself writes: a native `.terraform/` cache, with the modules `init`
// downloaded into it, or the workspace state directory. Nothing there is a
// module of the repository, however much it looks like one.
func isEngineWorkDir(rel string) bool {
	for _, part := range strings.Split(rel, "/") {
		if part == ".terraform" || part == "terraform.tfstate.d" {
			return true
		}
	}
	return false
}

func (l *tfLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
	if isEngineWorkDir(args.Rel) {
		return language.GenerateResult{}
	}
	cfg := getConfig(args.Config, l.engine.Name)
	name := l.moduleName(args)

	var srcs []string
	for _, f := range args.RegularFiles {
		if l.engine.isSource(f) {
			srcs = append(srcs, f)
		}
	}
	sort.Strings(srcs)

	empty := []*rule.Rule{
		rule.NewRule(l.engine.ModuleKind, name),
		rule.NewRule(l.engine.BinaryKind, l.engine.Name),
		rule.NewRule(l.engine.ProvidersLockKind, providersLockUpdateName),
		rule.NewRule(l.engine.ProvidersLockTestKind, providersLockTestName),
	}
	if len(srcs) == 0 || owner(cfg, args.RegularFiles) != l.engine.Name {
		return language.GenerateResult{Empty: empty}
	}

	kind := cfg.kind
	if kind == kindAuto {
		kind = kindModule
		if tfparse.HasBackend(args.Dir) {
			kind = kindRoot
		}
	}
	hasLock := false
	for _, f := range args.RegularFiles {
		if f == lockFileName {
			hasLock = true
		}
	}

	blocks, err := tfparse.ParseDir(args.Dir)
	if err != nil {
		log.Printf("%s: reading module blocks: %v", args.Rel, err)
	}
	imports := moduleImports{}
	seen := map[string]bool{}
	for _, b := range blocks {
		if !strings.HasPrefix(b.Source, "./") && !strings.HasPrefix(b.Source, "../") {
			continue
		}
		target := path.Clean(path.Join(args.Rel, b.Source))
		if target == ".." || strings.HasPrefix(target, "../") {
			log.Printf("%s: module %q has source %q, which leaves the repository", args.Rel, b.Key, b.Source)
			continue
		}
		if !seen[target] {
			seen[target] = true
			imports.dirs = append(imports.dirs, target)
		}
	}
	sort.Strings(imports.dirs)
	if cfg.hubsSet {
		imports.hubs = append(imports.hubs, cfg.hubs...)
	} else if kind == kindRoot && hasLock {
		imports.hubs = []string{defaultHub(args.Rel)}
	}

	module := rule.NewRule(l.engine.ModuleKind, name)
	module.SetAttr("srcs", srcs)
	if data := dataFiles(args.Dir, args.RegularFiles, args.Subdirs, l.engine.isSource); len(data) > 0 {
		module.SetAttr("data", data)
	}
	if kind == kindModule && len(cfg.visibility) > 0 {
		module.SetAttr("visibility", cfg.visibility)
	}

	gen := []*rule.Rule{module}
	genImports := []interface{}{imports}
	if kind == kindRoot {
		binary := rule.NewRule(l.engine.BinaryKind, l.engine.Name)
		binary.SetAttr("root", ":"+name)
		gen = append(gen, binary)
		genImports = append(genImports, nil)
	}
	// A lock file belongs to the directory, root or not: a library that
	// validates on its own against a shared lock keeps that lock with the
	// same two targets a root does. The updater also comes with being a
	// root, since that is where a first lock gets written from.
	if hasLock {
		lockTest := rule.NewRule(l.engine.ProvidersLockTestKind, providersLockTestName)
		lockTest.SetAttr("lock", lockFileName)
		lockTest.SetAttr("target", ":"+name)
		gen = append(gen, lockTest)
		genImports = append(genImports, nil)
	}
	if hasLock || kind == kindRoot {
		update := rule.NewRule(l.engine.ProvidersLockKind, providersLockUpdateName)
		update.SetAttr("output", lockFileName)
		update.SetAttr("target", ":"+name)
		gen = append(gen, update)
		genImports = append(genImports, nil)
	}

	// Whatever this directory does not produce is stale if it exists.
	var stale []*rule.Rule
	for _, e := range empty {
		produced := false
		for _, g := range gen {
			if g.Kind() == e.Kind() && g.Name() == e.Name() {
				produced = true
			}
		}
		if !produced {
			stale = append(stale, e)
		}
	}
	return language.GenerateResult{Gen: gen, Imports: genImports, Empty: stale}
}
