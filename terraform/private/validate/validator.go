package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"rules_terraform/terraform/private/internal/fsutil"
)

type ArgsFile struct {
	Terraform    string            `json:"terraform"`
	Marker       string            `json:"marker"`
	TerraformDir string            `json:"terraform_dir"`
	Files        map[string]string `json:"files"`
	UseRunfiles  bool              `json:"use_runfiles,omitempty"`
	// RootFile is the rlocationpath of a representative source file inside
	// the module. We anchor the module root to an actual runfile (rather
	// than a computed directory-string prefix) because runfiles is a flat
	// manifest of files — directory prefixes have no independent identity.
	RootFile      string            `json:"root_file,omitempty"`
	ModuleSources map[string]string `json:"module_sources,omitempty"`
}

type args struct {
	argsFilePath string
}

func parseArgs() args {
	var a args
	// -args is optional at parse time; test invocations pass the path via
	// RULES_TERRAFORM_VALIDATE_ARGS_FILE instead.
	flag.StringVar(&a.argsFilePath, "args", "", "Path to JSON args file (optional if RULES_TERRAFORM_VALIDATE_ARGS_FILE is set)")
	flag.Parse()
	return a
}

func main() {
	a := parseArgs()

	var argsFile *ArgsFile
	var r *runfiles.Runfiles

	if a.argsFilePath != "" {
		// Aspect (build action) mode: -args is an action-root path.
		var err error
		argsFile, err = loadArgsFile(a.argsFilePath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error loading args file: %v\n", err)
			os.Exit(1)
		}
	} else if argsFilePath := os.Getenv("RULES_TERRAFORM_VALIDATE_ARGS_FILE"); argsFilePath != "" {
		var err error
		r, err = runfiles.New()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to initialize runfiles: %v\n", err)
			os.Exit(1)
		}
		resolvedArgsPath, err := r.Rlocation(argsFilePath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to resolve args file path %s: %v\n", argsFilePath, err)
			os.Exit(1)
		}
		argsFile, err = loadArgsFile(resolvedArgsPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error loading args file from environment: %v\n", err)
			os.Exit(1)
		}
	} else {
		fmt.Fprintln(os.Stderr, "Error: either -args flag or RULES_TERRAFORM_VALIDATE_ARGS_FILE environment variable must be set")
		os.Exit(1)
	}

	// Test-mode: resolve all rlocationpaths via runfiles.
	if argsFile.UseRunfiles && r != nil {
		resolved, err := r.Rlocation(argsFile.Terraform)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to resolve terraform: %v\n", err)
			os.Exit(1)
		}
		argsFile.Terraform = resolved

		if argsFile.TerraformDir != "" {
			resolved, err := r.Rlocation(argsFile.TerraformDir)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: failed to resolve terraform_dir: %v\n", err)
				os.Exit(1)
			}
			argsFile.TerraformDir = resolved
		}

		resolvedFiles := make(map[string]string, len(argsFile.Files))
		for key, val := range argsFile.Files {
			resolved, err := r.Rlocation(val)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: failed to resolve file %s: %v\n", val, err)
				os.Exit(1)
			}
			resolvedFiles[key] = resolved
		}
		argsFile.Files = resolvedFiles
	}

	resolvedTerraform := argsFile.Terraform
	if !filepath.IsAbs(resolvedTerraform) {
		abs, err := filepath.Abs(resolvedTerraform)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to get absolute path for terraform: %v\n", err)
			os.Exit(1)
		}
		resolvedTerraform = abs
	}
	if _, err := os.Stat(resolvedTerraform); err != nil {
		fmt.Fprintf(os.Stderr, "Error: terraform binary not found at %s: %v\n", resolvedTerraform, err)
		os.Exit(1)
	}

	resolvedTerraformDir := argsFile.TerraformDir
	if resolvedTerraformDir != "" && !filepath.IsAbs(resolvedTerraformDir) {
		abs, err := filepath.Abs(resolvedTerraformDir)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to get absolute path for terraform_dir: %v\n", err)
			os.Exit(1)
		}
		resolvedTerraformDir = abs
	}

	workDir, cleanup, err := setupWorkingDirectory(argsFile.Files, resolvedTerraformDir, argsFile.RootFile, argsFile.ModuleSources)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: failed to setup working directory: %v\n", err)
		os.Exit(1)
	}
	defer cleanup()

	// Buffer the engine's output so the "Success! The configuration is
	// valid." chatter doesn't surface as `INFO: From TerraformValidate …`
	// noise for every clean target. On failure, flush both streams so the
	// actual error is visible in the CI log.
	var stdout, stderr bytes.Buffer
	cmd := exec.Command(resolvedTerraform, "validate")
	cmd.Dir = workDir
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	exitCode := 0
	if err := cmd.Run(); err != nil {
		os.Stdout.Write(stdout.Bytes())
		os.Stderr.Write(stderr.Bytes())
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() != 0 {
			exitCode = 1
		} else {
			fmt.Fprintf(os.Stderr, "Error: terraform validate failed: %v\n", err)
			exitCode = 1
		}
	}

	if exitCode == 0 && argsFile.Marker != "" {
		if err := os.WriteFile(argsFile.Marker, []byte(""), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "Error creating marker file: %v\n", err)
			os.Exit(1)
		}
	}

	os.Exit(exitCode)
}

// setupWorkingDirectory creates a temporary directory structure for
// terraform validate. filesMap maps rlocationpaths (keys) to actual file
// paths (values). rootFile is the rlocationpath of a representative
// source file — moduleDir is derived as `filepath.Dir` of where that file
// lands in tempDir. moduleSources maps Terraform source paths to Bazel
// label strings for cross-package module deps.
func setupWorkingDirectory(filesMap map[string]string, terraformDirPath string, rootFile string, moduleSources map[string]string) (string, func(), error) {
	tempDir, err := os.MkdirTemp("", "terraform-validate-*")
	if err != nil {
		return "", nil, fmt.Errorf("failed to create temp directory: %w", err)
	}

	cleanup := func() {
		os.RemoveAll(tempDir)
	}

	for relPath, srcPath := range filesMap {
		// Lock files land at moduleDir root below (via the init-rewritten
		// copy) — skip them here to avoid clobbering with the source lock.
		if filepath.Base(relPath) == ".terraform.lock.hcl" {
			continue
		}

		absSrc := srcPath
		if !filepath.IsAbs(absSrc) {
			var err error
			absSrc, err = filepath.Abs(absSrc)
			if err != nil {
				cleanup()
				return "", nil, fmt.Errorf("failed to get absolute path for %s: %w", srcPath, err)
			}
		}

		dstPath := filepath.Join(tempDir, relPath)

		if err := os.MkdirAll(filepath.Dir(dstPath), 0755); err != nil {
			cleanup()
			return "", nil, fmt.Errorf("failed to create directory for %s: %w", dstPath, err)
		}

		if err := fsutil.SymlinkFile(absSrc, dstPath); err != nil {
			cleanup()
			return "", nil, fmt.Errorf("failed to symlink %s to %s: %w", absSrc, dstPath, err)
		}
	}

	moduleDir := tempDir
	if rootFile != "" {
		// rootFile is a runfile rlocationpath; symlinks above materialize
		// it at tempDir/<rootFile>, so dirname of that landing spot is the
		// module directory.
		moduleDir = filepath.Dir(filepath.Join(tempDir, rootFile))
	}

	if terraformDirPath != "" {
		if _, err := os.Stat(terraformDirPath); err != nil {
			cleanup()
			return "", nil, fmt.Errorf("terraform directory not found at %s: %w", terraformDirPath, err)
		}
		terraformDst := filepath.Join(moduleDir, ".terraform")
		if err := fsutil.CopyDirectory(terraformDirPath, terraformDst); err != nil {
			cleanup()
			return "", nil, fmt.Errorf("failed to copy .terraform directory: %w", err)
		}
	}

	// Copy the lock file from the init-generated .terraform/ directory to
	// the module root (where terraform expects it). The init tool rewrites
	// h1: hashes to match the actual installed provider binaries, so we
	// must use the copy from .terraform/ rather than the original source.
	initLockFile := filepath.Join(moduleDir, ".terraform", ".terraform.lock.hcl")
	if _, err := os.Stat(initLockFile); err == nil {
		lockDst := filepath.Join(moduleDir, ".terraform.lock.hcl")
		if err := fsutil.CopyFile(initLockFile, lockDst); err != nil {
			cleanup()
			return "", nil, fmt.Errorf("failed to copy lock file from init output: %w", err)
		}
	}

	if len(moduleSources) > 0 {
		for sourcePath, label := range moduleSources {
			depDir := labelToWorkspacePath(label)
			if depDir == "" {
				continue
			}

			absSrcDir := findDepDir(tempDir, depDir)
			if absSrcDir == "" {
				continue
			}

			linkPath := filepath.Join(moduleDir, sourcePath)
			if err := os.MkdirAll(filepath.Dir(linkPath), 0755); err != nil {
				cleanup()
				return "", nil, fmt.Errorf("failed to create dir for module source %s: %w", sourcePath, err)
			}
			if err := os.Symlink(absSrcDir, linkPath); err != nil && !os.IsExist(err) {
				cleanup()
				return "", nil, fmt.Errorf("failed to create module source symlink %s -> %s: %w", linkPath, absSrcDir, err)
			}
		}
	}

	return moduleDir, cleanup, nil
}

// labelToWorkspacePath converts `//foo/bar[:target]` to `foo/bar`.
// External-repo labels (`@…`) return empty — module_sources doesn't
// support them.
func labelToWorkspacePath(label string) string {
	l := label
	if strings.HasPrefix(l, "@") {
		return ""
	}
	l = strings.TrimPrefix(l, "//")
	if idx := strings.Index(l, ":"); idx >= 0 {
		l = l[:idx]
	}
	return l
}

// findDepDir locates a dependency directory. Files land under either
// {tempDir}/{workspaceName}/{depPath}/ (main-repo deps go through the
// workspace-name prefix) or {tempDir}/{depPath}/ (external deps and the
// bare fallback), so try both.
func findDepDir(tempDir string, depPath string) string {
	entries, err := os.ReadDir(tempDir)
	if err != nil {
		return ""
	}
	for _, entry := range entries {
		if entry.IsDir() {
			candidate := filepath.Join(tempDir, entry.Name(), depPath)
			if info, err := os.Stat(candidate); err == nil && info.IsDir() {
				return candidate
			}
		}
	}
	candidate := filepath.Join(tempDir, depPath)
	if info, err := os.Stat(candidate); err == nil && info.IsDir() {
		return candidate
	}
	return ""
}

func loadArgsFile(path string) (*ArgsFile, error) {
	if !filepath.IsAbs(path) {
		var err error
		path, err = filepath.Abs(path)
		if err != nil {
			return nil, fmt.Errorf("failed to get absolute path: %w", err)
		}
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read args file: %w", err)
	}

	var argsFile ArgsFile
	if err := json.Unmarshal(data, &argsFile); err != nil {
		return nil, fmt.Errorf("failed to parse args file: %w", err)
	}

	return &argsFile, nil
}
