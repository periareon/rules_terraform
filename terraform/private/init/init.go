package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"rules_terraform/terraform/private/internal/argsjson"
	"rules_terraform/terraform/private/internal/fsutil"
	"rules_terraform/terraform/private/internal/lockparse"
	"rules_terraform/terraform/private/internal/moduledir"
	"rules_terraform/terraform/private/internal/tfparse"
)

// registryPrefixRE matches the default public registry's `registry.<host>/`
// prefix on a provider or module source. Terraform writes
// `registry.terraform.io/`; OpenTofu writes `registry.opentofu.org/`. We strip
// either, so the two engines' spellings of one source compare equal.
var registryPrefixRE = regexp.MustCompile(`^registry\.[^/]+/`)

const defaultRegistryHost = "registry.terraform.io"

// providerHostsFromLock returns a map of "<namespace>/<name>" → registry
// hostname, parsed from the lock file. Providers not listed default to
// registry.terraform.io.
func providerHostsFromLock(lockPath string) (map[string]string, error) {
	entries, err := lockparse.ReadProviderLock(lockPath)
	if err != nil {
		return nil, err
	}
	out := make(map[string]string, len(entries))
	for _, e := range entries {
		host := e.RegistryHost
		if host == "" {
			host = defaultRegistryHost
		}
		out[e.Source] = host
	}
	return out, nil
}

// ArgsFile mirrors the structure Starlark builds in `init.bzl` and hands
// off through //terraform/private:args.bzl's `write_json_args` helper.
// See //terraform/private/internal/argsjson for why File values arrive as
// resolved absolute paths (Bazel path-maps the paths file, we substitute
// placeholders in the template).
type ArgsFile struct {
	// OutputDir is the tree root — the common ancestor of the root module and
	// its local module deps. It is the module directory only when Workdir is
	// empty.
	OutputDir string `json:"output_dir"`
	// Workdir locates the root module inside the tree, forward-slash and
	// relative to OutputDir. Empty when the root module is the tree root, which
	// is every module whose deps all nest under it.
	Workdir string `json:"workdir,omitempty"`
	// ModuleFiles places the root module's own files at their paths relative to
	// the module directory.
	ModuleFiles     []FileEntry          `json:"module_files,omitempty"`
	LockFile        string               `json:"lock_file,omitempty"`
	Providers       []ProviderInfo       `json:"providers,omitempty"`
	ExternalModules []ExternalModuleInfo `json:"external_modules,omitempty"`
	LocalModules    []LocalModuleInfo    `json:"local_modules,omitempty"`
}

// FileEntry is one row of the copy manifest Starlark emits. `Src` is the
// action-root path of an input file (Bazel path-maps it via the paths
// file); `Dst` is the forward-slash position it should occupy under the
// install root the tool builds. See args.bzl's `build_file_manifest`.
type FileEntry struct {
	Src string `json:"src"`
	Dst string `json:"dst"`
}

// ProviderInfo carries one provider's install info. `Files` is the copy
// manifest — every declared input file paired with its position under the
// provider install directory.
type ProviderInfo struct {
	Source   string      `json:"source"`
	Version  string      `json:"version"`
	Files    []FileEntry `json:"files"`
	Platform string      `json:"platform"`
}

// ExternalModuleInfo mirrors the Starlark side; `Files` is the copy
// manifest for the module's install directory.
//
// There is deliberately no key here. Where a fetched module is installed is
// decided by the `module` block that references it, not by the Bazel dep that
// supplied it — see `externalRef`.
type ExternalModuleInfo struct {
	Source  string      `json:"source"`
	Version string      `json:"version"`
	Files   []FileEntry `json:"files"`
	Subdir  string      `json:"subdir,omitempty"`
}

// LocalModuleInfo is one `terraform_module` dep, offered to resolveLocalModules
// as a candidate rather than placed by path. Only this tool can know where a
// dep belongs: the `source` strings that name it live inside the `.tf` files.
//
// `Dir` is where the dep's own package sits relative to the tree root, which is
// what a `../` source resolves to. `Package` is its full Bazel package, used
// for tail matching and error messages.
type LocalModuleInfo struct {
	Package string      `json:"package"`
	Dir     string      `json:"dir"`
	Files   []FileEntry `json:"files"`
}

// Terraform's modules.json format
type modulesManifest struct {
	Modules []moduleRecord `json:"Modules"`
}

type moduleRecord struct {
	Key     string `json:"Key"`
	Source  string `json:"Source"`
	Dir     string `json:"Dir"`
	Version string `json:"Version,omitempty"`
}

// externalRef is a `module` block whose source names a registry or remote
// module, paired with the position in the staged tree it was found at.
type externalRef struct {
	// Key is the dot-joined path of `module` block names reaching this block,
	// which is where installExternalModules puts the fetched files.
	Key string
	// Dir is the referencing directory, for error messages.
	Dir string
	// Source and Version are as written in the `.tf` file. Version may be a
	// constraint (`~> 5.0`) rather than the exact version that was fetched.
	Source  string
	Version string
}

func main() {
	// `-args` and `-paths` are the two-file pair emitted by
	// //terraform/private:args.bzl's `write_json_args`. See that file and
	// //terraform/private/internal/argsjson for the design rationale (in
	// short: splitting the JSON template from the Args-backed paths file
	// lets Bazel path-map every File under `--experimental_output_paths`).
	argsFilePath := flag.String("args", "", "Path to JSON args template")
	pathsFilePath := flag.String("paths", "", "Path to the Args-backed paths file that resolves <<RTF_PATH_N>> placeholders in -args")
	flag.Parse()

	if *argsFilePath == "" || *pathsFilePath == "" {
		fmt.Fprintln(os.Stderr, "Error: both -args and -paths are required")
		os.Exit(1)
	}

	var argsFile ArgsFile
	if err := argsjson.LoadInto(*argsFilePath, *pathsFilePath, &argsFile); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	// The engine runs in the module directory, which is the tree root unless a
	// `../` module source forced the tree to be rooted higher.
	moduleDir := filepath.Join(argsFile.OutputDir, filepath.FromSlash(argsFile.Workdir))

	// Everything terraform discovers by path lives under the module directory;
	// `.terraform/` is the engine's private cache within it. Creating it also
	// creates the module directory.
	if err := os.MkdirAll(moduledir.TerraformDir(moduleDir), 0755); err != nil {
		fmt.Fprintf(os.Stderr, "Error: failed to create .terraform directory: %v\n", err)
		os.Exit(1)
	}

	if err := moduledir.WriteWorkdir(argsFile.OutputDir, argsFile.Workdir); err != nil {
		fmt.Fprintf(os.Stderr, "Error: failed to record the module working directory: %v\n", err)
		os.Exit(1)
	}

	// The root module's own .tf files. Its child modules arrive as deps and are
	// placed below, at whatever path their `module` blocks name.
	if err := copyManifestAll(moduleDir, argsFile.ModuleFiles); err != nil {
		fmt.Fprintf(os.Stderr, "Error: failed to assemble module directory: %v\n", err)
		os.Exit(1)
	}

	if err := resolveLocalModules(argsFile.OutputDir, argsFile.Workdir, argsFile.LocalModules); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	// Determine per-provider registry hostname from the lock file BEFORE
	// installing providers, so the on-disk layout matches what terraform/tofu
	// look up (registry.terraform.io vs registry.opentofu.org).
	providerHosts := map[string]string{}
	if argsFile.LockFile != "" {
		lockSrcPath, err := filepath.Abs(argsFile.LockFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to get absolute path for lock file: %v\n", err)
			os.Exit(1)
		}
		hosts, err := providerHostsFromLock(lockSrcPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to parse lock file hosts: %v\n", err)
			os.Exit(1)
		}
		providerHosts = hosts
	}

	if len(argsFile.Providers) > 0 {
		if err := extractProviders(moduleDir, argsFile.Providers, providerHosts); err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to extract providers: %v\n", err)
			os.Exit(1)
		}
	}

	if argsFile.LockFile != "" {
		lockSrcPath, err := filepath.Abs(argsFile.LockFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to get absolute path for lock file: %v\n", err)
			os.Exit(1)
		}

		lockContent, err := os.ReadFile(lockSrcPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: lock file not found at %s: %v\n", lockSrcPath, err)
			os.Exit(1)
		}

		// Rewrite h1: hashes in the lock file to match the installed provider binaries
		if len(argsFile.Providers) > 0 {
			lockContent, err = rewriteLockFileHashes(lockContent, moduleDir, argsFile.Providers, providerHosts)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: failed to rewrite lock file hashes: %v\n", err)
				os.Exit(1)
			}
		}

		// Terraform reads the lock from the module directory. Providers were
		// installed from Bazel-built binaries whose h1: hashes differ from the
		// registry's, which is why the content is rewritten above.
		if err := os.WriteFile(moduledir.LockFile(moduleDir), lockContent, 0644); err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to write lock file: %v\n", err)
			os.Exit(1)
		}
	}

	// Local and external modules land in one manifest pass, because both are
	// keyed by where the walk finds them and only one walk should decide that.
	if err := generateModulesManifest(moduleDir, argsFile.ExternalModules); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

// resolveLocalModules installs every `terraform_module` dep at the path a
// `module` block asks for it.
//
// This is the job an import system does. The `.tf` file names a path, `deps` is
// the search path, and the match is by name — the way `import mymod` finds
// whichever entry on `sys.path` ends in a `mymod`. Declaring the path twice,
// once in HCL and once in Bazel, is what this avoids.
//
// Resolution walks the tree rather than reading a fixed list of blocks: a dep's
// own `module` blocks only become readable once the dep is staged. That is what
// lets a shared library whose members reference each other resolve without the
// root module naming every transitive piece.
func resolveLocalModules(treeRoot, workdir string, candidates []LocalModuleInfo) error {
	used := make([]bool, len(candidates))
	visited := map[string]bool{}

	if err := resolveModuleDir(treeRoot, workdir, candidates, used, visited); err != nil {
		return err
	}

	// An unreferenced dep would otherwise vanish without a trace: the build
	// succeeds, the engine runs, and the module the user wired up simply isn't
	// there. Terraform would only complain if some `module` block missed it.
	for i, c := range candidates {
		if !used[i] {
			return fmt.Errorf(
				"dep %s is in `deps` but no `module` block references it.\n"+
					"Add `module \"...\" { source = %q }` to the module that needs it, or drop the dep",
				c.Package, "./"+path.Base(c.Package))
		}
	}

	return nil
}

// resolveModuleDir places the deps named by the `module` blocks of one staged
// module, then recurses into each one it placed. `dir` is slash-relative to the
// tree root; `visited` stops a cycle of `module` blocks from spinning.
func resolveModuleDir(treeRoot, dir string, candidates []LocalModuleInfo, used []bool, visited map[string]bool) error {
	if visited[dir] {
		return nil
	}
	visited[dir] = true

	blocks, err := tfparse.ParseDir(filepath.Join(treeRoot, filepath.FromSlash(dir)))
	if err != nil {
		return fmt.Errorf("failed to read module directory %s: %w", displayDir(dir), err)
	}

	for _, block := range blocks {
		rel, ok := localSourceDir(block.Source)
		if !ok {
			continue
		}

		// Resolved against the directory holding the `.tf` file, the way
		// Terraform resolves it. `path.Join` cleans, so a `../` source that
		// stays inside the tree comes back as a plain relative path.
		target := path.Join(dir, rel)
		if target == ".." || strings.HasPrefix(target, "../") {
			return fmt.Errorf(
				"module %q in %s has source %q, which points above the module tree.\n"+
					"The tree reaches up as far as the deepest package shared by this module and "+
					"its `deps`, so add the terraform_module the source names to `deps`",
				block.Key, displayDir(dir), block.Source)
		}

		i, err := matchCandidate(block, rel, target, candidates)
		if err != nil {
			return err
		}

		dst := filepath.Join(treeRoot, filepath.FromSlash(target))
		staged := isDir(dst)
		switch {
		case i >= 0:
			used[i] = true
			if !staged {
				if err := copyManifestAll(dst, candidates[i].Files); err != nil {
					return fmt.Errorf("failed to install module %q from %s: %w", block.Key, candidates[i].Package, err)
				}
			}
		case !staged:
			return fmt.Errorf(
				"module %q in %s has source %q, but no dep supplies that directory.\n"+
					"Add the terraform_module for it to `deps`.%s",
				block.Key, displayDir(dir), block.Source, unmatchedHint(candidates, used))
		}

		if err := resolveModuleDir(treeRoot, target, candidates, used, visited); err != nil {
			return err
		}
	}

	return nil
}

// matchCandidate picks the dep that supplies a `module` block's source, or -1
// when none does.
//
// Two ways to match. A dep staged at exactly the directory the source resolves
// to matches outright — that is a child module nested under its parent, and a
// `../` reference into a shared library. Otherwise the source is matched
// against the tail of each dep's package, which is what lets
// `source = "./mymod"` be answered by a dep from any package ending in `mymod`.
// Tail matching is only offered to a source that doesn't climb: once a source
// says `../`, the directory it names is the only sensible answer, and guessing
// past that would install a module somewhere its own relative sources break.
func matchCandidate(block tfparse.ModuleBlock, rel, target string, candidates []LocalModuleInfo) (int, error) {
	for i, c := range candidates {
		if c.Dir == target {
			return i, nil
		}
	}

	if strings.HasPrefix(rel, "../") {
		return -1, nil
	}

	var matched []int
	for i, c := range candidates {
		if packageProvides(c.Package, rel) {
			matched = append(matched, i)
		}
	}

	switch len(matched) {
	case 0:
		return -1, nil
	case 1:
		return matched[0], nil
	default:
		var pkgs []string
		for _, i := range matched {
			pkgs = append(pkgs, candidates[i].Package)
		}
		return -1, fmt.Errorf(
			"module %q has source %q, which more than one dep could supply: %s.\n"+
				"A relative source is matched against the tail of each dep's package, so "+
				"give the directories distinct names or nest one under this module's package",
			block.Key, block.Source, strings.Join(pkgs, ", "))
	}
}

// localSourceDir reports whether a `module` block's source is a local path this
// tool can supply, and returns it cleaned. Terraform treats a source as local
// only when it starts with `./` or `../`; anything else is a registry address
// or a remote URL, installed under `.terraform/modules/` instead.
//
// A `../` source is kept — a monorepo's shared module library commonly sits
// above the root module, and reaching up into it is the standard way to say so.
// Whether the cleaned path stays inside the tree is the caller's to check,
// since only it knows where in the tree the referencing module sits.
func localSourceDir(source string) (string, bool) {
	if !strings.HasPrefix(source, "./") && !strings.HasPrefix(source, "../") {
		return "", false
	}
	rel := path.Clean(source)
	if rel == "." {
		return "", false
	}
	return rel, true
}

// packageProvides reports whether a Bazel package supplies the directory a
// relative `module` source names. The match is on the tail, so package
// `tests/modules_lib/mymod` answers both `./mymod` and `./modules_lib/mymod`.
func packageProvides(pkg, rel string) bool {
	return pkg == rel || strings.HasSuffix(pkg, "/"+rel)
}

// displayDir names a tree-relative directory for an error message, giving the
// tree root itself something better to be called than the empty string.
func displayDir(dir string) string {
	if dir == "" {
		return "the root module"
	}
	return dir
}

func isDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

// unmatchedHint lists the deps still looking for a `module` block, so the
// "no dep supplies that directory" error can show what is actually on offer —
// usually the user misspelled one of the two ends of the same pairing.
func unmatchedHint(candidates []LocalModuleInfo, used []bool) string {
	var pkgs []string
	for i, c := range candidates {
		if !used[i] {
			pkgs = append(pkgs, c.Package)
		}
	}
	if len(pkgs) == 0 {
		return ""
	}
	return "\nDeps not yet matched to a module block: " + strings.Join(pkgs, ", ")
}

func extractProviders(moduleDir string, providers []ProviderInfo, providerHosts map[string]string) error {
	for _, provider := range providers {
		parts := strings.Split(provider.Source, "/")
		if len(parts) != 2 {
			return fmt.Errorf("invalid provider source format: %s (expected namespace/name)", provider.Source)
		}
		namespace := parts[0]
		name := parts[1]

		version := provider.Version
		if version == "" {
			version = "0.0.0"
		}

		host, ok := providerHosts[provider.Source]
		if !ok {
			host = defaultRegistryHost
		}
		providerVersionDir := filepath.Join(moduledir.ProvidersDir(moduleDir), host, namespace, name, version, provider.Platform)

		// Provider archives ship the binary as `terraform-provider-<name>`,
		// often with a version suffix (`terraform-provider-null_v3.2.4_x5`)
		// or `.exe` on Windows. Prefix-match so every variant sets the
		// exec bit.
		providerBinaryPrefix := fmt.Sprintf("terraform-provider-%s", name)

		found := false
		for _, entry := range provider.Files {
			destPath, err := copyManifestEntry(providerVersionDir, entry)
			if err != nil {
				return fmt.Errorf("provider %s: %w", provider.Source, err)
			}
			// Dst is forward-slash regardless of host OS, so path.Base is
			// the right choice (never filepath.Base).
			if strings.HasPrefix(path.Base(entry.Dst), providerBinaryPrefix) {
				if err := os.Chmod(destPath, 0755); err != nil {
					return fmt.Errorf("failed to make provider binary executable: %w", err)
				}
				found = true
			}
		}
		if !found {
			return fmt.Errorf("failed to find provider binary %s in files for %s", providerBinaryPrefix, provider.Source)
		}
	}

	return nil
}

// copyManifestEntry copies one manifest row into installDir and returns
// the on-disk destination path. Dst is a forward-slash relative position
// under installDir; `filepath.FromSlash` reshapes it to native separators.
func copyManifestEntry(installDir string, entry FileEntry) (string, error) {
	// Clean before checking so mid-path `..` segments (e.g. `foo/../../etc`)
	// can't slip past a prefix-only guard.
	cleaned := path.Clean(entry.Dst)
	if strings.HasPrefix(cleaned, "/") || strings.HasPrefix(cleaned, "../") || cleaned == ".." {
		return "", fmt.Errorf("manifest dst %q escapes install dir", entry.Dst)
	}
	absSrc, err := filepath.Abs(entry.Src)
	if err != nil {
		return "", fmt.Errorf("abspath %s: %w", entry.Src, err)
	}
	destPath := filepath.Join(installDir, filepath.FromSlash(entry.Dst))
	if err := os.MkdirAll(filepath.Dir(destPath), 0755); err != nil {
		return "", fmt.Errorf("mkdir %s: %w", filepath.Dir(destPath), err)
	}
	if err := fsutil.CopyFile(absSrc, destPath); err != nil {
		return "", fmt.Errorf("copy %s to %s: %w", absSrc, destPath, err)
	}
	return destPath, nil
}

// computeProviderH1Hash computes the h1: hash for a provider directory,
// using the same algorithm as Terraform's getproviders.PackageHashV1.
// Paths are normalized to forward slashes so hashes computed on Windows
// and POSIX match — Terraform's canonical form uses `/`.
func computeProviderH1Hash(providerDir string) (string, error) {
	// Map of forward-slash relpath -> native filesystem path, so we can
	// sort by canonical form but still open files portably.
	type entry struct{ rel, full string }
	var entries []entry

	err := filepath.Walk(providerDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(providerDir, path)
		if err != nil {
			return err
		}
		entries = append(entries, entry{rel: filepath.ToSlash(rel), full: path})
		return nil
	})
	if err != nil {
		return "", fmt.Errorf("failed to walk provider directory: %w", err)
	}

	sort.Slice(entries, func(i, j int) bool { return entries[i].rel < entries[j].rel })

	h := sha256.New()
	for _, e := range entries {
		rel := e.rel
		fullPath := e.full
		f, err := os.Open(fullPath)
		if err != nil {
			return "", fmt.Errorf("failed to open %s: %w", fullPath, err)
		}
		fileHash := sha256.New()
		if _, err := io.Copy(fileHash, f); err != nil {
			f.Close()
			return "", fmt.Errorf("failed to hash %s: %w", fullPath, err)
		}
		f.Close()
		fmt.Fprintf(h, "%x  %s\n", fileHash.Sum(nil), rel)
	}

	return "h1:" + base64.StdEncoding.EncodeToString(h.Sum(nil)), nil
}

// rewriteLockFileHashes replaces h1: hashes in the lock file content with
// hashes computed from the actual installed provider binaries.
func rewriteLockFileHashes(lockContent []byte, moduleDir string, providers []ProviderInfo, providerHosts map[string]string) ([]byte, error) {
	// Build a map of provider source -> computed h1: hash
	h1Hashes := make(map[string]string)

	for _, provider := range providers {
		parts := strings.Split(provider.Source, "/")
		if len(parts) != 2 {
			continue
		}
		namespace, name := parts[0], parts[1]

		host, ok := providerHosts[provider.Source]
		if !ok {
			host = defaultRegistryHost
		}
		providerDir := filepath.Join(moduledir.ProvidersDir(moduleDir), host,
			namespace, name, provider.Version, provider.Platform)

		hash, err := computeProviderH1Hash(providerDir)
		if err != nil {
			return nil, fmt.Errorf("failed to compute h1 hash for %s: %w", provider.Source, err)
		}
		h1Hashes[provider.Source] = hash
	}

	// Parse lock file and replace h1: hashes
	lines := strings.Split(string(lockContent), "\n")
	var result []string
	var currentProvider string

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)

		if strings.HasPrefix(trimmed, "provider ") {
			parts := strings.Split(trimmed, "\"")
			if len(parts) >= 2 {
				currentProvider = registryPrefixRE.ReplaceAllString(parts[1], "")
			}
		}

		if trimmed == "}" {
			currentProvider = ""
		}

		// Replace h1: hash lines with the computed hash
		if currentProvider != "" && strings.Contains(trimmed, "\"h1:") {
			if computedHash, ok := h1Hashes[currentProvider]; ok {
				indent := line[:len(line)-len(strings.TrimLeft(line, " \t"))]
				result = append(result, fmt.Sprintf("%s\"%s\",", indent, computedHash))
				continue
			}
		}

		result = append(result, line)
	}

	return []byte(strings.Join(result, "\n")), nil
}

// walkModules enumerates every module reachable from the module directory,
// depth first: local ones as modules.json records, external ones as references
// for installExternalModules to place.
//
// Terraform's key for a child module is the dot-joined path of `module` block
// names that reaches it — `compute.network` for the `network` block inside the
// module the root calls `compute` — and a local module's `Dir` is relative to
// the root module, `../` and all. Recording only the root's own blocks would
// leave the engine unable to find anything a child module declares.
//
// External modules come back as references rather than records because they
// still have to be installed, and where they are installed is decided by the
// same key. Both kinds fall out of one walk for that reason.
func walkModules(moduleDir string) ([]moduleRecord, []externalRef, error) {
	var local []moduleRecord
	var external []externalRef

	// Dirs on the current recursion path, not dirs already seen: two `module`
	// blocks may name the same directory, and Terraform installs and keys that
	// directory once per block. Only a directory that reaches itself is a
	// cycle, and only that would fail to terminate.
	onPath := map[string]bool{}

	// Visiting a directory once per key is the point; *reading* it once per key
	// is not. A shared library reached from several blocks would otherwise be
	// re-scanned per path that arrives at it, and the duplication compounds
	// with depth. The staged tree does not change under us, so one parse per
	// directory is enough for all of them.
	parsed := map[string][]tfparse.ModuleBlock{}
	parseDir := func(dir string) ([]tfparse.ModuleBlock, error) {
		if blocks, ok := parsed[dir]; ok {
			return blocks, nil
		}
		blocks, err := tfparse.ParseDir(filepath.Join(moduleDir, filepath.FromSlash(dir)))
		if err != nil {
			return nil, fmt.Errorf("failed to read module directory %s: %w", displayDir(dir), err)
		}
		parsed[dir] = blocks
		return blocks, nil
	}

	// Slash-relative to moduleDir, so `Dir` comes out portable — Terraform's
	// own writer uses `filepath.ToSlash` for the same reason.
	var walk func(prefix, dir string) error
	walk = func(prefix, dir string) error {
		if onPath[dir] {
			return fmt.Errorf("module %s is reached from itself through %q; `module` blocks may not form a cycle",
				displayDir(dir), prefix)
		}
		onPath[dir] = true
		defer delete(onPath, dir)

		blocks, err := parseDir(dir)
		if err != nil {
			return err
		}

		for _, block := range blocks {
			// A block with no source is invalid Terraform. Leave it to the
			// engine, which reports it far better than a resolution failure.
			if block.Source == "" {
				continue
			}

			key := block.Key
			if prefix != "" {
				key = prefix + "." + block.Key
			}

			rel, ok := localSourceDir(block.Source)
			if !ok {
				external = append(external, externalRef{
					Key:     key,
					Dir:     dir,
					Source:  block.Source,
					Version: block.Version,
				})
				continue
			}

			childDir := path.Join(dir, rel)
			local = append(local, moduleRecord{
				Key:    key,
				Source: block.Source,
				Dir:    childDir,
			})
			if err := walk(key, childDir); err != nil {
				return err
			}
		}
		return nil
	}

	if err := walk("", "."); err != nil {
		return nil, nil, err
	}
	return local, external, nil
}

// generateModulesManifest installs every external module the staged tree
// references and writes the one modules.json describing the whole tree.
//
// resolveLocalModules has already placed the local deps, so the tree is the
// authority on what exists — walking it also picks up the child modules of
// child modules, which no single list of blocks would name.
func generateModulesManifest(moduleDir string, available []ExternalModuleInfo) error {
	local, refs, err := walkModules(moduleDir)
	if err != nil {
		return err
	}

	installed, err := installExternalModules(moduleDir, refs, available)
	if err != nil {
		return err
	}

	if len(local) == 0 && len(installed) == 0 {
		return nil
	}

	if err := os.MkdirAll(moduledir.ModulesDir(moduleDir), 0755); err != nil {
		return fmt.Errorf("failed to create modules directory: %w", err)
	}

	// The root module is its own first entry, with the empty key.
	modules := []moduleRecord{{Key: "", Source: "", Dir: "."}}
	modules = append(modules, installed...)
	modules = append(modules, local...)
	manifest := modulesManifest{Modules: modules}

	manifestData, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal modules.json: %w", err)
	}

	if err := os.WriteFile(moduledir.ModulesManifest(moduleDir), manifestData, 0644); err != nil {
		return fmt.Errorf("failed to write modules.json: %w", err)
	}

	return nil
}

// installExternalModules copies each referenced external module into
// `.terraform/modules/<dotted key>/` and returns its manifest record.
//
// The key is the dotted path of `module` block names reaching the reference,
// not the name of the Bazel dep that supplied the files. Terraform addresses a
// nested module as `eks.this`, so a registry module referenced from a shared
// library installed at `eks` has to land under that prefix — installing it at
// the top level puts it somewhere the engine never looks.
//
// A dep that no `module` block references is simply not installed, where the
// same situation with a local dep is a hard error. The asymmetry is about how
// the two are declared, not about transitivity: `terraform.modules` scans a
// directory and mints one target per `module` block it finds there, so a dep
// on that group is a dep on a candidate pool. Some of the pool going unused is
// the normal case, not a mistake to report.
//
// Not handled: `module` blocks *inside* a fetched module. A registry module
// that is itself composed of others needs its own resolution pass rooted at
// its install directory, including `../`-relative sources that climb out of
// it, and further registry modules Bazel was never asked to fetch. Such a
// module resolves to the key below and then fails on its own children.
func installExternalModules(moduleDir string, refs []externalRef, available []ExternalModuleInfo) ([]moduleRecord, error) {
	var out []moduleRecord
	for _, ref := range refs {
		mod := matchExternal(ref, available)
		if mod == nil {
			return nil, fmt.Errorf(
				"module %q in %s has source %q, but no dep supplies that module.\n"+
					"Add the external module for it to `deps` — `terraform.modules` "+
					"generates one target per registry module it finds.%s",
				ref.Key, displayDir(ref.Dir), ref.Source, externalHint(available))
		}

		dstDir := filepath.Join(moduledir.ModulesDir(moduleDir), ref.Key)
		if err := copyManifestAll(dstDir, mod.Files); err != nil {
			return nil, fmt.Errorf("failed to install module %q from %s: %w", ref.Key, mod.Source, err)
		}

		out = append(out, moduleRecord{
			Key: ref.Key,
			// Use the bare `<namespace>/<name>/<provider>` form so both
			// Terraform and OpenTofu accept it — prefixing with the registry
			// host makes each engine see the module as installed from a
			// different registry than the .tf source declared.
			Source: mod.Source,
			// Forward slashes only — Terraform's own writer uses
			// `filepath.ToSlash` when serializing modules.json, and on
			// Windows a backslash-formatted Dir has been observed to make
			// the engine miss the installed module. Match the canonical form.
			Dir:     path.Join(".terraform", "modules", ref.Key),
			Version: mod.Version,
		})
	}

	return out, nil
}

// matchExternal picks the dep supplying a reference, or nil when none does.
//
// Source is the identity; version only breaks a tie. A block's `version` is a
// constraint (`~> 5.0`) while the dep records the exact version resolved for
// it, so an equal version is good evidence and an unequal one is no evidence
// at all.
func matchExternal(ref externalRef, available []ExternalModuleInfo) *ExternalModuleInfo {
	var fallback *ExternalModuleInfo
	for i := range available {
		mod := &available[i]
		if !sameModuleSource(ref.Source, mod.Source) {
			continue
		}
		if ref.Version == "" || ref.Version == mod.Version {
			return mod
		}
		if fallback == nil {
			fallback = mod
		}
	}
	return fallback
}

// sameModuleSource reports whether a `module` block's source names the module a
// dep supplies. Either may spell a public-registry source with the registry
// host in front, so both are stripped before comparing — the dep's source is
// itself copied out of a `module` block, so neither end is the canonical one.
//
// Only the default public registries are stripped. A source on a private
// registry (`app.terraform.io/...`) names a different module than the same
// path on the public one, so there the host is part of the identity.
func sameModuleSource(blockSource, depSource string) bool {
	return registryPrefixRE.ReplaceAllString(blockSource, "") ==
		registryPrefixRE.ReplaceAllString(depSource, "")
}

// externalHint lists the external modules on offer, so the "no dep supplies
// that module" error can show what `deps` actually brought — usually the user
// pointed `terraform.modules` at a different root module than the one holding
// the block.
func externalHint(available []ExternalModuleInfo) string {
	if len(available) == 0 {
		return "\nNo external modules are in `deps`."
	}
	sources := make([]string, 0, len(available))
	for _, mod := range available {
		sources = append(sources, mod.Source)
	}
	return "\nExternal modules in `deps`: " + strings.Join(sources, ", ")
}

// copyManifestAll materializes every entry of a copy manifest under
// installDir. Nothing walks the filesystem — the manifest, built by
// Starlark from the action's declared inputs, is the authoritative list of
// what to copy and where. See args.bzl's `build_file_manifest`.
func copyManifestAll(installDir string, entries []FileEntry) error {
	if err := os.MkdirAll(installDir, 0755); err != nil {
		return fmt.Errorf("mkdir %s: %w", installDir, err)
	}
	for _, entry := range entries {
		if _, err := copyManifestEntry(installDir, entry); err != nil {
			return err
		}
	}
	return nil
}
