package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"rules_terraform/terraform/private/internal/tfparse"
)

// candidate builds a dep whose files land as a one-file module holding
// `content`, the way the aspect emits a `terraform_module` dep. `dir` is where
// the dep's own package sits relative to the tree root.
func candidate(t *testing.T, pkg, dir, content string) LocalModuleInfo {
	t.Helper()

	src := filepath.Join(t.TempDir(), "main.tf")
	if err := os.WriteFile(src, []byte(content), 0644); err != nil {
		t.Fatalf("write %s: %v", src, err)
	}
	return LocalModuleInfo{
		Package: pkg,
		Dir:     dir,
		Files:   []FileEntry{{Src: src, Dst: "main.tf"}},
	}
}

// localModule is a leaf dep staged at its own package, declaring nothing.
func localModule(t *testing.T, pkg string) LocalModuleInfo {
	t.Helper()
	return candidate(t, pkg, pkg, "# "+pkg+"\n")
}

func block(key, source string) tfparse.ModuleBlock {
	return tfparse.ModuleBlock{Key: key, Source: source}
}

// moduleTF renders the `.tf` text declaring `blocks`.
func moduleTF(blocks ...tfparse.ModuleBlock) string {
	var b strings.Builder
	for _, blk := range blocks {
		fmt.Fprintf(&b, "module %q {\n  source = %q\n}\n", blk.Key, blk.Source)
	}
	return b.String()
}

// stagedTree creates a tree root holding one `main.tf` per entry of `modules`,
// keyed by slash-relative directory. `.` is the tree root itself.
func stagedTree(t *testing.T, modules map[string]string) string {
	t.Helper()

	root := t.TempDir()
	for dir, content := range modules {
		full := filepath.Join(root, filepath.FromSlash(dir))
		if err := os.MkdirAll(full, 0755); err != nil {
			t.Fatalf("mkdir %s: %v", full, err)
		}
		if err := os.WriteFile(filepath.Join(full, "main.tf"), []byte(content), 0644); err != nil {
			t.Fatalf("write %s/main.tf: %v", full, err)
		}
	}
	return root
}

// The whole point of dropping `module_sources`: the `.tf` file names the path
// and `deps` names the target, and nothing has to state the pairing a third
// time. A dep in an unrelated package still lands where its block asks.
func TestResolveLocalModulesInstallsByPackageTail(t *testing.T) {
	root := stagedTree(t, map[string]string{".": moduleTF(block("greeter", "./greeter"))})
	candidates := []LocalModuleInfo{localModule(t, "shared/terraform/greeter")}

	if err := resolveLocalModules(root, "", candidates); err != nil {
		t.Fatalf("resolveLocalModules: %v", err)
	}

	if _, err := os.Stat(filepath.Join(root, "greeter", "main.tf")); err != nil {
		t.Errorf("dep was not installed at the source path its module block names: %v", err)
	}
}

// A source can name more than the last package segment.
func TestResolveLocalModulesMatchesMultiSegmentSource(t *testing.T) {
	root := stagedTree(t, map[string]string{".": moduleTF(block("greeter", "./modules/greeter"))})
	candidates := []LocalModuleInfo{localModule(t, "shared/modules/greeter")}

	if err := resolveLocalModules(root, "", candidates); err != nil {
		t.Fatalf("resolveLocalModules: %v", err)
	}

	if _, err := os.Stat(filepath.Join(root, "modules", "greeter", "main.tf")); err != nil {
		t.Errorf("dep was not installed at ./modules/greeter: %v", err)
	}
}

// The bug this design exists for: a root module several directories deep
// reaching up into a shared module library. The tree is rooted at the ancestor
// they share, so `../` lands inside it.
func TestResolveLocalModulesInstallsParentRelativeSource(t *testing.T) {
	root := stagedTree(t, map[string]string{
		"envs/prod/app": moduleTF(block("network", "../../../modules/network")),
	})
	candidates := []LocalModuleInfo{
		localModule(t, "modules/network"),
	}

	if err := resolveLocalModules(root, "envs/prod/app", candidates); err != nil {
		t.Fatalf("resolveLocalModules: %v", err)
	}

	if _, err := os.Stat(filepath.Join(root, "modules", "network", "main.tf")); err != nil {
		t.Errorf("dep was not installed where the `../` source points: %v", err)
	}
}

// A shared library's members reference each other, and the root module names
// only the one it uses directly. Resolution has to read a dep's own blocks once
// that dep is staged, or the rest of the library never arrives.
func TestResolveLocalModulesResolvesTransitively(t *testing.T) {
	root := stagedTree(t, map[string]string{
		"envs/app": moduleTF(block("compute", "../../modules/compute")),
	})
	candidates := []LocalModuleInfo{
		candidate(t, "modules/compute", "modules/compute", moduleTF(block("network", "../network"))),
		localModule(t, "modules/network"),
	}

	if err := resolveLocalModules(root, "envs/app", candidates); err != nil {
		t.Fatalf("resolveLocalModules: %v", err)
	}

	for _, rel := range []string{"modules/compute/main.tf", "modules/network/main.tf"} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel))); err != nil {
			t.Errorf("%s not installed: %v", rel, err)
		}
	}
}

// Climbing past the tree root can't be satisfied by anything Bazel builds, and
// silently leaving it to the engine only moves the failure somewhere less
// legible.
func TestResolveLocalModulesRejectsSourceAboveTree(t *testing.T) {
	root := stagedTree(t, map[string]string{"app": moduleTF(block("network", "../../outside"))})

	err := resolveLocalModules(root, "app", nil)
	if err == nil {
		t.Fatal("resolveLocalModules accepted a source above the tree root; want an error")
	}
	if !strings.Contains(err.Error(), "../../outside") {
		t.Errorf("error = %v, want it to name the offending source", err)
	}
}

// A child module already staged inside the tree needs no dep, and must not be
// reported as an unsatisfied source.
func TestResolveLocalModulesLeavesNestedChildAlone(t *testing.T) {
	root := stagedTree(t, map[string]string{
		".":               moduleTF(block("greeter", "./modules/greeter")),
		"modules/greeter": "# nested\n",
	})

	if err := resolveLocalModules(root, "", nil); err != nil {
		t.Fatalf("resolveLocalModules: %v", err)
	}
}

// Registry and remote sources are installed under `.terraform/modules/`, not
// from `deps`, so they must not consume a candidate or demand one.
func TestResolveLocalModulesIgnoresNonLocalSources(t *testing.T) {
	root := stagedTree(t, map[string]string{".": moduleTF(
		block("vpc", "terraform-aws-modules/vpc/aws"),
		block("remote", "git::https://example.com/mod.git"),
	)})

	if err := resolveLocalModules(root, "", nil); err != nil {
		t.Fatalf("resolveLocalModules: %v", err)
	}
}

// Without this the module directory is quietly built without the child: the
// engine runs, and only terraform's own error (if any) hints at what happened.
func TestResolveLocalModulesRejectsUnsatisfiedSource(t *testing.T) {
	root := stagedTree(t, map[string]string{".": moduleTF(block("vpc", "./vpc"))})
	candidates := []LocalModuleInfo{localModule(t, "shared/greeter")}

	err := resolveLocalModules(root, "", candidates)
	if err == nil {
		t.Fatal("resolveLocalModules accepted a source no dep supplies; want an error")
	}
	for _, want := range []string{"./vpc", "shared/greeter"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error = %v, want it to mention %q", err, want)
		}
	}
}

// The mirror-image mistake: the dep is wired up but nothing references it.
func TestResolveLocalModulesRejectsUnreferencedDep(t *testing.T) {
	root := stagedTree(t, map[string]string{".": "# no module blocks\n"})
	candidates := []LocalModuleInfo{localModule(t, "shared/greeter")}

	err := resolveLocalModules(root, "", candidates)
	if err == nil {
		t.Fatal("resolveLocalModules accepted a dep no module block references; want an error")
	}
	if !strings.Contains(err.Error(), "shared/greeter") {
		t.Errorf("error = %v, want it to name the unreferenced dep", err)
	}
}

// Suffix matching can be genuinely ambiguous. Picking either one silently would
// build a module directory that depends on dep ordering.
func TestResolveLocalModulesRejectsAmbiguousMatch(t *testing.T) {
	root := stagedTree(t, map[string]string{".": moduleTF(block("greeter", "./greeter"))})
	candidates := []LocalModuleInfo{
		localModule(t, "team_a/greeter"),
		localModule(t, "team_b/greeter"),
	}

	err := resolveLocalModules(root, "", candidates)
	if err == nil {
		t.Fatal("resolveLocalModules picked one of two equally good matches; want an error")
	}
	for _, want := range []string{"team_a/greeter", "team_b/greeter"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error = %v, want it to name %q", err, want)
		}
	}
}

// A dep staged at exactly the directory a source resolves to is the unambiguous
// answer, even when some other dep's package would also tail-match.
func TestResolveLocalModulesPrefersExactDirOverTail(t *testing.T) {
	root := stagedTree(t, map[string]string{".": moduleTF(
		block("greeter", "./modules/greeter"),
		block("decoy", "./other/modules/greeter"),
	)})
	// The decoy's package tail-matches `./modules/greeter` too; only the
	// staged position tells the two apart.
	candidates := []LocalModuleInfo{
		candidate(t, "other/modules/greeter", "other/modules/greeter", "# wrong\n"),
		candidate(t, "shared/libs/greeter_impl", "modules/greeter", "# right\n"),
	}

	if err := resolveLocalModules(root, "", candidates); err != nil {
		t.Fatalf("resolveLocalModules: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(root, "modules", "greeter", "main.tf"))
	if err != nil {
		t.Fatalf("read installed module: %v", err)
	}
	if strings.TrimSpace(string(got)) != "# right" {
		t.Errorf("installed %q, want the dep staged at the exact directory", got)
	}
}

func TestLocalSourceDir(t *testing.T) {
	for _, tc := range []struct {
		source string
		want   string
		ok     bool
	}{
		{"./mymod", "mymod", true},
		{"./modules/greeter", "modules/greeter", true},
		{"./modules/../greeter", "greeter", true},
		// A shared library above the root module is the layout this supports.
		{"../sibling", "../sibling", true},
		{"../../../modules/network", "../../../modules/network", true},
		{"./", "", false},
		{"hashicorp/consul/aws", "", false},
		{"git::https://example.com/mod.git", "", false},
	} {
		got, ok := localSourceDir(tc.source)
		if got != tc.want || ok != tc.ok {
			t.Errorf("localSourceDir(%q) = (%q, %v), want (%q, %v)", tc.source, got, ok, tc.want, tc.ok)
		}
	}
}

func TestPackageProvides(t *testing.T) {
	for _, tc := range []struct {
		pkg, rel string
		want     bool
	}{
		{"tests/modules_lib/mymod", "mymod", true},
		{"tests/modules_lib/mymod", "modules_lib/mymod", true},
		{"mymod", "mymod", true},
		// A tail match has to be on a segment boundary, or `notmymod` would
		// answer for `./mymod`.
		{"tests/notmymod", "mymod", false},
		{"tests/mymod/inner", "mymod", false},
	} {
		if got := packageProvides(tc.pkg, tc.rel); got != tc.want {
			t.Errorf("packageProvides(%q, %q) = %v, want %v", tc.pkg, tc.rel, got, tc.want)
		}
	}
}

// Terraform keys a child module by the dot-joined path of `module` block names
// that reaches it, and records `Dir` relative to the root module. A child of a
// child appears in neither the root's blocks nor its `deps`.
func TestWalkModulesRecordsNestedChildren(t *testing.T) {
	root := stagedTree(t, map[string]string{
		".":               moduleTF(block("compute", "./modules/compute"), block("vpc", "terraform-aws-modules/vpc/aws")),
		"modules/compute": moduleTF(block("network", "../network")),
		"modules/network": "# leaf\n",
	})

	got, _, err := walkModules(root)
	if err != nil {
		t.Fatalf("walkModules: %v", err)
	}

	want := []moduleRecord{
		{Key: "compute", Source: "./modules/compute", Dir: "modules/compute"},
		{Key: "compute.network", Source: "../network", Dir: "modules/network"},
	}
	if len(got) != len(want) {
		t.Fatalf("walkModules returned %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("record %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

// The whole of bug 1a: a registry module referenced from a nested local module
// is addressed `wrapper.label`, and installing it under the bare block name
// puts it where the engine never looks. The walk is the only thing that knows
// the prefix — the Bazel dep carries a repository-level name instead.
func TestWalkModulesKeysExternalRefsByPosition(t *testing.T) {
	root := stagedTree(t, map[string]string{
		".":                 moduleTF(block("wrapper", "./modules/wrapper")),
		"modules/wrapper":   moduleTF(block("label", "cloudposse/label/null")),
		"modules/unrelated": "# leaf\n",
	})

	_, refs, err := walkModules(root)
	if err != nil {
		t.Fatalf("walkModules: %v", err)
	}

	if len(refs) != 1 {
		t.Fatalf("walkModules returned %d external refs, want 1: %+v", len(refs), refs)
	}
	if refs[0].Key != "wrapper.label" {
		t.Errorf("external ref key = %q, want %q", refs[0].Key, "wrapper.label")
	}
	if refs[0].Source != "cloudposse/label/null" {
		t.Errorf("external ref source = %q", refs[0].Source)
	}
}

// Two blocks may name the same directory. Terraform installs and keys it once
// per block, so deduplicating by directory would silently drop the second
// subtree — including any external module it references.
func TestWalkModulesRecordsSharedDirectoryUnderEachKey(t *testing.T) {
	root := stagedTree(t, map[string]string{
		".":      moduleTF(block("a", "./shared"), block("b", "./shared")),
		"shared": moduleTF(block("leaf", "../leaf")),
		"leaf":   "# leaf\n",
	})

	got, _, err := walkModules(root)
	if err != nil {
		t.Fatalf("walkModules: %v", err)
	}

	want := []moduleRecord{
		{Key: "a", Source: "./shared", Dir: "shared"},
		{Key: "a.leaf", Source: "../leaf", Dir: "leaf"},
		{Key: "b", Source: "./shared", Dir: "shared"},
		{Key: "b.leaf", Source: "../leaf", Dir: "leaf"},
	}
	if len(got) != len(want) {
		t.Fatalf("walkModules returned %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("record %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

// Allowing a directory to appear twice costs the cheap dedup that used to stop
// recursion, so a genuine cycle has to be caught on its own.
func TestWalkModulesRejectsCycle(t *testing.T) {
	root := stagedTree(t, map[string]string{
		".":   moduleTF(block("a", "./one")),
		"one": moduleTF(block("b", "../two")),
		"two": moduleTF(block("c", "../one")),
	})

	if _, _, err := walkModules(root); err == nil {
		t.Fatal("walkModules accepted a module cycle")
	} else if !strings.Contains(err.Error(), "cycle") {
		t.Errorf("error %q does not mention a cycle", err)
	}
}

// An external module nobody references is not an error the way an unreferenced
// local dep is. `terraform.modules` mints one target per `module` block in the
// directory it scans, so a dep on that group is a dep on a candidate pool and
// some of it going unused is the normal case.
func TestInstallExternalModulesSkipsUnreferencedDeps(t *testing.T) {
	moduleDir := t.TempDir()
	src := filepath.Join(t.TempDir(), "main.tf")
	if err := os.WriteFile(src, []byte("# label\n"), 0644); err != nil {
		t.Fatalf("write source: %v", err)
	}

	available := []ExternalModuleInfo{
		{Source: "cloudposse/label/null", Version: "0.25.0", Files: []FileEntry{{Src: src, Dst: "main.tf"}}},
		{Source: "terraform-aws-modules/vpc/aws", Version: "5.3.1", Files: []FileEntry{{Src: src, Dst: "main.tf"}}},
	}
	refs := []externalRef{
		{Key: "wrapper.label", Dir: "modules/wrapper", Source: "cloudposse/label/null"},
	}

	got, err := installExternalModules(moduleDir, refs, available)
	if err != nil {
		t.Fatalf("installExternalModules: %v", err)
	}
	if len(got) != 1 || got[0].Key != "wrapper.label" {
		t.Fatalf("installExternalModules returned %+v, want only wrapper.label", got)
	}

	// The referenced module is installed under its dotted key; the unreferenced
	// one is not installed anywhere.
	if _, err := os.Stat(filepath.Join(moduleDir, ".terraform", "modules", "wrapper.label", "main.tf")); err != nil {
		t.Errorf("referenced module was not installed: %v", err)
	}
	entries, err := os.ReadDir(filepath.Join(moduleDir, ".terraform", "modules"))
	if err != nil {
		t.Fatalf("read modules dir: %v", err)
	}
	if len(entries) != 1 {
		t.Errorf("modules dir holds %d entries, want only the referenced one", len(entries))
	}
}

func TestInstallExternalModulesRejectsUnsuppliedSource(t *testing.T) {
	refs := []externalRef{
		{Key: "wrapper.label", Dir: "modules/wrapper", Source: "cloudposse/label/null"},
	}

	_, err := installExternalModules(t.TempDir(), refs, nil)
	if err == nil {
		t.Fatal("installExternalModules accepted a reference no dep supplies")
	}
	for _, want := range []string{"label", "modules/wrapper", "cloudposse/label/null", "deps"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention %q", err, want)
		}
	}
}

func TestSameModuleSource(t *testing.T) {
	tests := []struct {
		block string
		dep   string
		want  bool
	}{
		{"cloudposse/label/null", "cloudposse/label/null", true},
		// Either end may name the public registry host, and the two engines
		// spell it differently. Stripping both sides makes all four agree.
		{"registry.terraform.io/cloudposse/label/null", "cloudposse/label/null", true},
		{"registry.opentofu.org/cloudposse/label/null", "cloudposse/label/null", true},
		{"cloudposse/label/null", "registry.terraform.io/cloudposse/label/null", true},
		{"registry.terraform.io/cloudposse/label/null", "registry.opentofu.org/cloudposse/label/null", true},
		// A private registry names a different module than the same path on
		// the public one, so its host stays part of the identity.
		{"app.terraform.io/acme/label/null", "acme/label/null", false},
		{"cloudposse/label/null", "label/null", false},
		{"terraform-aws-modules/vpc/aws", "cloudposse/label/null", false},
	}
	for _, tt := range tests {
		if got := sameModuleSource(tt.block, tt.dep); got != tt.want {
			t.Errorf("sameModuleSource(%q, %q) = %v, want %v", tt.block, tt.dep, got, tt.want)
		}
	}
}

// A block's `version` is a constraint and the dep's is the version actually
// resolved, so equality is evidence and inequality is not. Source alone still
// has to match something.
func TestMatchExternalPrefersExactVersion(t *testing.T) {
	available := []ExternalModuleInfo{
		{Source: "terraform-aws-modules/vpc/aws", Version: "5.1.0"},
		{Source: "terraform-aws-modules/vpc/aws", Version: "5.3.1"},
	}

	exact := matchExternal(externalRef{Source: "terraform-aws-modules/vpc/aws", Version: "5.3.1"}, available)
	if exact == nil || exact.Version != "5.3.1" {
		t.Errorf("exact version match = %+v, want 5.3.1", exact)
	}

	constraint := matchExternal(externalRef{Source: "terraform-aws-modules/vpc/aws", Version: "~> 5.0"}, available)
	if constraint == nil {
		t.Fatal("a version constraint matched nothing; source alone should still resolve")
	}

	if miss := matchExternal(externalRef{Source: "cloudposse/label/null"}, available); miss != nil {
		t.Errorf("unrelated source matched %+v", miss)
	}
}
