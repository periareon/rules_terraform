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
	"rules_terraform/terraform/private/internal/tfparse"
)

// registryPrefixRE matches any `registry.<host>/` prefix in a Terraform lock
// file provider source. Terraform lock files start with `registry.terraform.io/`;
// OpenTofu writes `registry.opentofu.org/`. We strip either.
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
	OutputDir       string               `json:"output_dir"`
	LockFile        string               `json:"lock_file,omitempty"`
	Providers       []ProviderInfo       `json:"providers,omitempty"`
	ExternalModules []ExternalModuleInfo `json:"external_modules,omitempty"`
	MappedModules   []MappedModuleInfo   `json:"mapped_modules,omitempty"`
	SourceFiles     []string             `json:"source_files,omitempty"`
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
type ExternalModuleInfo struct {
	Key     string      `json:"key"`
	Source  string      `json:"source"`
	Version string      `json:"version"`
	Files   []FileEntry `json:"files"`
	Subdir  string      `json:"subdir,omitempty"`
}

// MappedModuleInfo mirrors the Starlark side. `Files` is the copy manifest
// for a cross-package dep whose sources need to appear under `SourcePath`
// in the .terraform tree.
type MappedModuleInfo struct {
	SourcePath string      `json:"source_path"`
	Files      []FileEntry `json:"files"`
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

	if err := os.MkdirAll(argsFile.OutputDir, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "Error: failed to create output directory: %v\n", err)
		os.Exit(1)
	}

	// Determine per-provider registry hostname from the lock file BEFORE
	// installing providers, so the on-disk layout matches what terraform/tofu
	// look up (registry.terraform.io vs registry.opentofu.org).
	providerHosts := map[string]string{}
	if argsFile.LockFile != "" {
		lockSrcPath := argsFile.LockFile
		if !filepath.IsAbs(lockSrcPath) {
			var err error
			lockSrcPath, err = filepath.Abs(lockSrcPath)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: failed to get absolute path for lock file: %v\n", err)
				os.Exit(1)
			}
		}
		hosts, err := providerHostsFromLock(lockSrcPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to parse lock file hosts: %v\n", err)
			os.Exit(1)
		}
		providerHosts = hosts
	}

	if len(argsFile.Providers) > 0 {
		if err := extractProviders(argsFile.OutputDir, argsFile.Providers, providerHosts); err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to extract providers: %v\n", err)
			os.Exit(1)
		}
	}

	if argsFile.LockFile != "" {
		lockSrcPath := argsFile.LockFile
		if !filepath.IsAbs(lockSrcPath) {
			var err error
			lockSrcPath, err = filepath.Abs(lockSrcPath)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: failed to get absolute path for lock file: %v\n", err)
				os.Exit(1)
			}
		}

		lockContent, err := os.ReadFile(lockSrcPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: lock file not found at %s: %v\n", lockSrcPath, err)
			os.Exit(1)
		}

		// Rewrite h1: hashes in the lock file to match the installed provider binaries
		if len(argsFile.Providers) > 0 {
			lockContent, err = rewriteLockFileHashes(lockContent, argsFile.OutputDir, argsFile.Providers, providerHosts)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: failed to rewrite lock file hashes: %v\n", err)
				os.Exit(1)
			}
		}

		lockDstPath := filepath.Join(argsFile.OutputDir, ".terraform.lock.hcl")
		if err := os.WriteFile(lockDstPath, lockContent, 0644); err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to write lock file: %v\n", err)
			os.Exit(1)
		}
	}

	if len(argsFile.ExternalModules) > 0 {
		if err := extractExternalModules(argsFile.OutputDir, argsFile.ExternalModules); err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to extract external modules: %v\n", err)
			os.Exit(1)
		}
	}

	// Discover local module blocks from .tf source files and generate modules.json
	if len(argsFile.SourceFiles) > 0 {
		if err := generateLocalModulesManifest(argsFile.OutputDir, argsFile.SourceFiles, argsFile.MappedModules); err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to generate local modules manifest: %v\n", err)
			os.Exit(1)
		}
	}
}

func extractProviders(outputDir string, providers []ProviderInfo, providerHosts map[string]string) error {
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
		providerVersionDir := filepath.Join(outputDir, "providers", host, namespace, name, version, provider.Platform)

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
	absSrc, err := absPath(entry.Src)
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

// absPath returns filepath.Abs(p) if p is not already absolute.
func absPath(p string) (string, error) {
	if filepath.IsAbs(p) {
		return p, nil
	}
	return filepath.Abs(p)
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
func rewriteLockFileHashes(lockContent []byte, outputDir string, providers []ProviderInfo, providerHosts map[string]string) ([]byte, error) {
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
		providerDir := filepath.Join(outputDir, "providers", host,
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

// generateLocalModulesManifest scans source files for module blocks and creates
// modules.json entries. For mapped modules (module_sources), it also copies files
// into .terraform/modules/<key>/.
func generateLocalModulesManifest(outputDir string, sourceFiles []string, mappedModules []MappedModuleInfo) error {
	modules, err := tfparse.ParseFiles(sourceFiles)
	if err != nil {
		return fmt.Errorf("failed to discover module blocks: %w", err)
	}

	if len(modules) == 0 {
		return nil
	}

	modulesDir := filepath.Join(outputDir, "modules")
	if err := os.MkdirAll(modulesDir, 0755); err != nil {
		return fmt.Errorf("failed to create modules directory: %w", err)
	}

	// Load whatever extractExternalModules already wrote so we can append
	// (rather than clobber). A malformed pre-existing file is a real bug
	// somewhere upstream — fail loudly rather than silently overwrite with
	// the default single-root manifest.
	manifestPath := filepath.Join(modulesDir, "modules.json")
	manifest := modulesManifest{
		Modules: []moduleRecord{
			{Key: "", Source: "", Dir: "."},
		},
	}
	if data, err := os.ReadFile(manifestPath); err == nil {
		if err := json.Unmarshal(data, &manifest); err != nil {
			return fmt.Errorf("existing modules.json at %s is malformed: %w", manifestPath, err)
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("read %s: %w", manifestPath, err)
	}

	// source_path -> MappedModuleInfo lookup for the module_sources mapping.
	mappedInfo := make(map[string]MappedModuleInfo, len(mappedModules))
	for _, m := range mappedModules {
		mappedInfo[m.SourcePath] = m
	}

	// External registry modules were already added to modules.json by
	// extractExternalModules; skip them here to avoid duplicate entries.
	existingKeys := make(map[string]bool, len(manifest.Modules))
	for _, m := range manifest.Modules {
		existingKeys[m.Key] = true
	}

	for _, mod := range modules {
		if existingKeys[mod.Key] {
			continue
		}
		if mapped, isMapped := mappedInfo[mod.Source]; isMapped {
			// Cross-package module: copy files to .terraform/modules/<key>/
			dstDir := filepath.Join(modulesDir, mod.Key)
			if err := copyManifestAll(dstDir, mapped.Files); err != nil {
				return fmt.Errorf("failed to copy mapped module %s: %w", mod.Key, err)
			}

			manifest.Modules = append(manifest.Modules, moduleRecord{
				Key:    mod.Key,
				Source: mod.Source,
				Dir:    path.Join(".terraform", "modules", mod.Key),
			})
		} else {
			// Local module: Terraform records the source path (relative to
			// the root module) as `Dir`, canonicalized without a leading
			// `./`. `../` prefixes MUST be preserved verbatim — they're a
			// legitimate way to reference a sibling module tree. Use the
			// `path` package (always `/`) rather than `filepath` so the
			// manifest is portable — Terraform's own writer uses
			// `filepath.ToSlash` for the same reason.
			dir := path.Clean(mod.Source)
			manifest.Modules = append(manifest.Modules, moduleRecord{
				Key:    mod.Key,
				Source: mod.Source,
				Dir:    dir,
			})
		}
	}

	manifestData, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal modules.json: %w", err)
	}

	if err := os.WriteFile(manifestPath, manifestData, 0644); err != nil {
		return fmt.Errorf("failed to write modules.json: %w", err)
	}

	return nil
}

// extractExternalModules copies external module files into .terraform/modules/<key>/
// and generates Terraform's modules.json manifest.
func extractExternalModules(outputDir string, modules []ExternalModuleInfo) error {
	modulesDir := filepath.Join(outputDir, "modules")
	if err := os.MkdirAll(modulesDir, 0755); err != nil {
		return fmt.Errorf("failed to create modules directory: %w", err)
	}

	manifest := modulesManifest{
		Modules: []moduleRecord{
			{Key: "", Source: "", Dir: "."},
		},
	}

	for _, mod := range modules {
		dstDir := filepath.Join(modulesDir, mod.Key)
		if err := copyManifestAll(dstDir, mod.Files); err != nil {
			return fmt.Errorf("failed to copy module %s: %w", mod.Key, err)
		}

		manifest.Modules = append(manifest.Modules, moduleRecord{
			Key: mod.Key,
			// Use the bare `<namespace>/<name>/<provider>` form so both
			// Terraform and OpenTofu accept it — prefixing with the registry
			// host makes each engine see the module as installed from a
			// different registry than the .tf source declared.
			Source: mod.Source,
			// Forward slashes only — Terraform's own writer uses
			// `filepath.ToSlash` when serializing modules.json, and on
			// Windows a backslash-formatted Dir has been observed to make
			// the engine miss the installed module. Match the canonical form.
			Dir:     path.Join(".terraform", "modules", mod.Key),
			Version: mod.Version,
		})
	}

	manifestData, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal modules.json: %w", err)
	}

	manifestPath := filepath.Join(modulesDir, "modules.json")
	if err := os.WriteFile(manifestPath, manifestData, 0644); err != nil {
		return fmt.Errorf("failed to write modules.json: %w", err)
	}

	return nil
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
