// lockcheck verifies that `.terraform.lock.hcl` is in sync with the
// `terraform { required_providers { … } }` blocks in the .tf sources.
// Presence-based: every declared provider must appear in the lock, and
// every lock entry must correspond to something in the sources. Hashes,
// URLs, and version resolution are NOT verified — that's what real
// `terraform providers lock` (via `terraform_providers_lock`) is for.
//
// Exits 0 on match; non-zero with a diff on mismatch.
package main

import (
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"rules_terraform/terraform/private/internal/argsfile"
	"rules_terraform/terraform/private/internal/lockparse"
	"rules_terraform/terraform/private/internal/tfparse"
)

const argsEnvVar = "RULES_TERRAFORM_LOCKCHECK_ARGS_FILE"

type srcFlag []string

func (s *srcFlag) String() string { return strings.Join(*s, ",") }
func (s *srcFlag) Set(v string) error {
	*s = append(*s, v)
	return nil
}

func main() {
	tokens, err := argsfile.ReadArgv(argsEnvVar)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(2)
	}
	argsfile.Prepend(tokens)

	lock := flag.String("lock", "", "Runfiles rlocationpath of the .terraform.lock.hcl file being checked")
	tidyHint := flag.String("tidy-hint", "", "Human-readable hint shown in the failure message telling the user how to fix drift")
	var srcs srcFlag
	flag.Var(&srcs, "src", "Runfiles rlocationpath of a .tf source file. Repeatable.")
	flag.Parse()

	if *lock == "" {
		fmt.Fprintln(os.Stderr, "Error: -lock is required")
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
	resolvedSrcs := make([]string, 0, len(srcs))
	for _, s := range srcs {
		p, err := r.Rlocation(s)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: resolve -src %q via runfiles: %v\n", s, err)
			os.Exit(2)
		}
		resolvedSrcs = append(resolvedSrcs, p)
	}

	problems, err := checkProviders(resolvedLock, resolvedSrcs)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(2)
	}

	if len(problems) == 0 {
		return
	}

	fmt.Fprintf(os.Stderr, "providers lock file %s is out of sync with sources:\n", resolvedLock)
	for _, p := range problems {
		fmt.Fprintf(os.Stderr, "  %s\n", p)
	}
	if *tidyHint != "" {
		fmt.Fprintf(os.Stderr, "\nRun: %s\n", *tidyHint)
	}
	os.Exit(1)
}

func checkProviders(lockPath string, srcs []string) ([]string, error) {
	locked, err := lockparse.ReadProviderLock(lockPath)
	if err != nil {
		return nil, err
	}
	declared, err := tfparse.ParseRequiredProvidersFromFiles(srcs)
	if err != nil {
		return nil, err
	}

	sourceBySource := map[string]bool{}
	for _, p := range declared {
		src := p.Source
		if src == "" {
			// No source given — Terraform infers `hashicorp/<label>`.
			src = "hashicorp/" + p.Label
		}
		sourceBySource[canonicalProviderSource(src)] = true
	}

	lockedSources := map[string]bool{}
	for _, e := range locked {
		// Prepend the host only when it's NOT one of the two default
		// registries — canonicalProviderSource strips both terraform.io
		// and opentofu.org so implicit-source required_providers blocks
		// compare equal against locks written by either engine.
		src := e.Source
		if e.RegistryHost != "" &&
			e.RegistryHost != "registry.terraform.io" &&
			e.RegistryHost != "registry.opentofu.org" {
			src = e.RegistryHost + "/" + e.Source
		}
		lockedSources[src] = true
	}

	var problems []string
	for _, s := range sortedStringSet(sourceBySource) {
		if !lockedSources[s] {
			problems = append(problems, fmt.Sprintf("required_providers references %q but the lock file has no entry for it", s))
		}
	}
	for _, s := range sortedStringSet(lockedSources) {
		if !sourceBySource[s] {
			problems = append(problems, fmt.Sprintf("lock file locks provider %q but no required_providers block references it", s))
		}
	}
	return problems, nil
}

// canonicalProviderSource strips the default registry hostname of whichever
// engine wrote the source. `hashicorp/null`, `registry.terraform.io/hashicorp/null`,
// and `registry.opentofu.org/hashicorp/null` all canonicalize to `hashicorp/null`
// so drift comparisons don't false-positive against implicit-source
// `required_providers` blocks when the lock came from tofu init.
// Non-default registries (private hosts, `app.terraform.io/...`) stay qualified.
func canonicalProviderSource(src string) string {
	for _, defaultHost := range []string{"registry.terraform.io/", "registry.opentofu.org/"} {
		if strings.HasPrefix(src, defaultHost) {
			return src[len(defaultHost):]
		}
	}
	return src
}

func sortedStringSet(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
