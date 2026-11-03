// lockcheck verifies that `.terraform.lock.hcl` covers what the configuration
// requires, and nothing else. It reads the module directory the init aspect
// built, the way the engine would: every module the `modules.json` manifest
// lists, root, local children and installed external ones alike, and in each
// the providers `required_providers` declares plus the ones `resource`,
// `data`, `ephemeral` and `provider` blocks imply. Hashes, URLs and version
// resolution are not checked; `terraform providers lock`, run by the
// `terraform_providers_lock` updater, owns those.
//
// Exits 0 on match; 1 with the differences on mismatch.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"rules_terraform/engine/internal/argsfile"
	"rules_terraform/engine/internal/lockparse"
	"rules_terraform/engine/internal/moduledir"
	"rules_terraform/engine/internal/tfparse"
)

const argsEnvVar = "RULES_TERRAFORM_LOCKCHECK_ARGS_FILE"

func main() {
	tokens, err := argsfile.ReadArgv(argsEnvVar)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(2)
	}
	argsfile.Prepend(tokens)

	lock := flag.String("lock", "", "Runfiles rlocationpath of the .terraform.lock.hcl file being checked")
	moduleDir := flag.String("module-dir", "", "Runfiles rlocationpath of the module directory the init aspect built")
	tidyHint := flag.String("tidy-hint", "", "Human-readable hint shown in the failure message telling the user how to fix drift")
	flag.Parse()

	if *lock == "" || *moduleDir == "" {
		fmt.Fprintln(os.Stderr, "Error: -lock and -module-dir are required")
		os.Exit(2)
	}

	r, err := runfiles.New()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: init runfiles: %v\n", err)
		os.Exit(2)
	}
	resolvedLock, err := r.Rlocation(*lock)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: resolve -lock %q via runfiles: %v\n", *lock, err)
		os.Exit(2)
	}
	resolvedTree, err := r.Rlocation(*moduleDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: resolve -module-dir %q via runfiles: %v\n", *moduleDir, err)
		os.Exit(2)
	}

	problems, err := checkProviders(resolvedLock, resolvedTree)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(2)
	}
	if len(problems) == 0 {
		return
	}

	fmt.Fprintf(os.Stderr, "providers lock file %s does not match what the configuration requires:\n", resolvedLock)
	for _, p := range problems {
		fmt.Fprintf(os.Stderr, "  %s\n", p)
	}
	if *tidyHint != "" {
		fmt.Fprintf(os.Stderr, "\nRun: %s\n", *tidyHint)
	}
	os.Exit(1)
}

// manifest is the part of Terraform's modules.json this tool reads.
type manifest struct {
	Modules []struct {
		Key string `json:"Key"`
		Dir string `json:"Dir"`
	} `json:"Modules"`
}

// moduleDirs returns every module directory of the tree with its key, from
// the manifest the init aspect wrote; a module with no `module` blocks has
// no manifest and is its root alone.
func moduleDirs(root string) (map[string]string, error) {
	out := map[string]string{"": root}
	data, err := os.ReadFile(moduledir.ModulesManifest(root))
	if os.IsNotExist(err) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	var m manifest
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("parse %s: %w", moduledir.ModulesManifest(root), err)
	}
	for _, record := range m.Modules {
		out[record.Key] = filepath.Join(root, filepath.FromSlash(record.Dir))
	}
	return out, nil
}

// requiredProviders returns the canonical source of every provider one
// module directory requires, declared or implied.
func requiredProviders(dir string) ([]string, error) {
	files, err := tfparse.ConfigFiles(dir)
	if err != nil {
		return nil, err
	}
	declared, err := tfparse.ParseRequiredProvidersFromFiles(files)
	if err != nil {
		return nil, err
	}
	used, err := tfparse.ParseProviderUsageFromFiles(files)
	if err != nil {
		return nil, err
	}
	sources := map[string]bool{}
	byLocalName := map[string]string{}
	for _, p := range declared {
		src := p.Source
		if src == "" {
			src = "hashicorp/" + p.Label
		}
		byLocalName[p.Label] = src
		sources[canonicalProviderSource(src)] = true
	}
	for _, name := range used {
		if name == "terraform" {
			// terraform.io/builtin/terraform ships inside the engine.
			continue
		}
		src, ok := byLocalName[name]
		if !ok {
			src = "hashicorp/" + name
		}
		sources[canonicalProviderSource(src)] = true
	}
	return sortedStringSet(sources), nil
}

func checkProviders(lockPath, treeRoot string) ([]string, error) {
	locked, err := lockparse.ReadProviderLock(lockPath)
	if err != nil {
		return nil, err
	}
	root, err := moduledir.WorkDir(treeRoot)
	if err != nil {
		return nil, err
	}
	dirs, err := moduleDirs(root)
	if err != nil {
		return nil, err
	}

	// Provider source -> the modules that require it, for the message.
	requiredBy := map[string][]string{}
	for key, dir := range dirs {
		sources, err := requiredProviders(dir)
		if err != nil {
			return nil, err
		}
		where := "the root module"
		if key != "" {
			where = "module." + key
		}
		for _, s := range sources {
			requiredBy[s] = append(requiredBy[s], where)
		}
	}

	lockedSources := map[string]bool{}
	for _, e := range locked {
		// Keep the host only when it is not a default registry, so a lock
		// written by either engine compares equal to the sources.
		src := e.Source
		if e.RegistryHost != "" &&
			e.RegistryHost != "registry.terraform.io" &&
			e.RegistryHost != "registry.opentofu.org" {
			src = e.RegistryHost + "/" + e.Source
		}
		lockedSources[src] = true
	}

	var problems []string
	for _, s := range sortedStringSet(boolKeys(requiredBy)) {
		if !lockedSources[s] {
			by := requiredBy[s]
			sort.Strings(by)
			problems = append(problems, fmt.Sprintf("%s requires provider %q, which the lock file has no entry for", strings.Join(by, ", "), s))
		}
	}
	for _, s := range sortedStringSet(lockedSources) {
		if _, ok := requiredBy[s]; !ok {
			problems = append(problems, fmt.Sprintf("the lock file locks provider %q, which no module requires", s))
		}
	}
	return problems, nil
}

// canonicalProviderSource strips the default registry hostname of whichever
// engine wrote the source, so `hashicorp/null`,
// `registry.terraform.io/hashicorp/null` and
// `registry.opentofu.org/hashicorp/null` compare equal. Other hosts stay.
func canonicalProviderSource(src string) string {
	for _, defaultHost := range []string{"registry.terraform.io/", "registry.opentofu.org/"} {
		if strings.HasPrefix(src, defaultHost) {
			return src[len(defaultHost):]
		}
	}
	return src
}

func boolKeys(m map[string][]string) map[string]bool {
	out := make(map[string]bool, len(m))
	for k := range m {
		out[k] = true
	}
	return out
}

func sortedStringSet(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
