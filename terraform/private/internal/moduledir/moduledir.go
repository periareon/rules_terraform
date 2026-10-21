// Package moduledir owns the on-disk layout of the module directory that
// //terraform/private/init builds and that the runner and validate tools
// consume — and the staging both of them do before running an engine.
//
// The layout is a contract between three binaries. Keeping the paths in one
// place is what stops the runner's `-plugin-dir` from quietly pointing at a
// directory the init tool no longer writes.
package moduledir

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"rules_terraform/terraform/private/internal/fsutil"
)

// workdirMarker names the file at the tree root recording where inside the
// tree the engine should run. The tree is rooted at the common ancestor of the
// root module and its local deps, which is above the root module whenever a
// `module` block reaches up with `../`. Writing the answer into the artifact
// keeps it self-describing: consumers `Stage` it and get a working directory
// back, with no second channel to keep in sync.
//
// Absent for a tree whose root module *is* the tree root, which is the common
// case.
const workdirMarker = ".rules_terraform_workdir"

// TerraformDir returns the engine's private cache directory inside moduleDir.
func TerraformDir(moduleDir string) string {
	return filepath.Join(moduleDir, ".terraform")
}

// WriteWorkdir records the engine's working directory, given relative to the
// tree root in slash form. Writing nothing for the root itself keeps the
// common-case tree free of the marker.
func WriteWorkdir(treeRoot, workdir string) error {
	if workdir == "" || workdir == "." {
		return nil
	}
	return os.WriteFile(filepath.Join(treeRoot, workdirMarker), []byte(workdir+"\n"), 0644)
}

// readWorkdir returns the slash-form working directory recorded in a tree, or
// "" when the tree root is itself the module directory.
func readWorkdir(treeRoot string) (string, error) {
	data, err := os.ReadFile(filepath.Join(treeRoot, workdirMarker))
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	workdir := strings.TrimSpace(string(data))
	if workdir == "" || strings.HasPrefix(workdir, "/") || workdir == ".." ||
		strings.HasPrefix(workdir, "../") || strings.Contains(workdir, "/../") {
		return "", fmt.Errorf("%s names %q, which is not a directory inside the tree", workdirMarker, workdir)
	}
	return workdir, nil
}

// ProvidersDir returns the provider install root. Its layout below this point
// (`<host>/<namespace>/<name>/<version>/<platform>`) is Terraform's, and is
// what the engine expects behind `-plugin-dir`.
func ProvidersDir(moduleDir string) string {
	return filepath.Join(TerraformDir(moduleDir), "providers")
}

// ModulesDir returns the directory holding installed external modules and the
// `modules.json` manifest that indexes every module block.
func ModulesDir(moduleDir string) string {
	return filepath.Join(TerraformDir(moduleDir), "modules")
}

// ModulesManifest returns the path of Terraform's `modules.json`.
func ModulesManifest(moduleDir string) string {
	return filepath.Join(ModulesDir(moduleDir), "modules.json")
}

// LockFile returns the dependency lock path. Terraform reads it from the
// module root — a copy under `.terraform/` is never consulted.
func LockFile(moduleDir string) string {
	return filepath.Join(moduleDir, ".terraform.lock.hcl")
}

// Stage copies a built module tree into a fresh temp dir and returns the
// directory the engine should run in, along with a cleanup func. The copy is
// not optional: an engine mutates its working directory (state, `.terraform/`,
// plan output) while the source is a Bazel output, which may be read-only or
// reached through a runfiles symlink tree.
//
// The whole tree is copied — a `../` module source resolves above the working
// directory — but the path returned is the working directory the tree names,
// so callers use it as both the engine's cwd and the root of the `.terraform`
// layout without knowing the tree is larger.
//
// It also rejects a working directory with no configuration in it. That case is
// the dangerous one: `init`, `plan` and `test` all exit 0 with nothing to read,
// so a broken build would look like a passing one.
func Stage(src, tempPrefix string) (string, func(), error) {
	if src == "" {
		return "", nil, fmt.Errorf("no module directory given")
	}
	if info, err := os.Stat(src); err != nil || !info.IsDir() {
		return "", nil, fmt.Errorf("module directory not found at %s", src)
	}

	tempDir, err := os.MkdirTemp("", tempPrefix)
	if err != nil {
		return "", nil, fmt.Errorf("failed to create temp directory: %w", err)
	}
	cleanup := func() {
		os.RemoveAll(tempDir)
	}

	treeRoot := filepath.Join(tempDir, "module")
	if err := fsutil.CopyDirectory(src, treeRoot); err != nil {
		cleanup()
		return "", nil, fmt.Errorf("failed to copy module directory from %s: %w", src, err)
	}

	workdir, err := readWorkdir(treeRoot)
	if err != nil {
		cleanup()
		return "", nil, fmt.Errorf("module tree at %s: %w", src, err)
	}
	workDir := filepath.Join(treeRoot, filepath.FromSlash(workdir))

	entries, err := os.ReadDir(workDir)
	if err != nil {
		cleanup()
		return "", nil, fmt.Errorf("failed to read module directory %s: %w", workDir, err)
	}
	if !hasConfigFile(entries) {
		cleanup()
		return "", nil, fmt.Errorf("module directory %s contains no .tf files", src)
	}

	return workDir, cleanup, nil
}

// hasConfigFile reports whether the directory holds anything Terraform or
// OpenTofu would load as configuration.
func hasConfigFile(entries []os.DirEntry) bool {
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		for _, suffix := range []string{".tf", ".tf.json", ".tofu", ".tofu.json"} {
			if strings.HasSuffix(name, suffix) {
				return true
			}
		}
	}
	return false
}

// HermeticEnv returns a copy of environ in which the engine's machine-wide
// configuration is switched off, for the checks that run under Bazel's
// sandbox: validate actions and `terraform test`.
//
// Without this, a developer's `~/.terraformrc` (or whatever
// `TF_CLI_CONFIG_FILE` names) still applies inside the sandbox. A
// `provider_installation` or `plugin_cache_dir` stanza there changes what the
// engine does with the providers the init aspect installed, so the same
// target can pass on one machine and fail on another. The engine is pointed at
// an empty configuration file instead, and told not to call home.
//
// `bazel run` deliberately does not go through here: that is where credential
// helpers and other operator configuration are supposed to apply.
//
// The returned cleanup removes the empty configuration file.
func HermeticEnv(environ []string) ([]string, func(), error) {
	rc, err := os.CreateTemp("", "rules_terraform-*.tfrc")
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create empty CLI config: %w", err)
	}
	rcPath := rc.Name()
	rc.Close()
	cleanup := func() { os.Remove(rcPath) }

	dropped := map[string]bool{
		"TF_CLI_CONFIG_FILE":                             true,
		"TERRAFORM_CONFIG":                               true,
		"TF_PLUGIN_CACHE_DIR":                            true,
		"TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE": true,
		"CHECKPOINT_DISABLE":                             true,
		"TF_IN_AUTOMATION":                               true,
	}
	out := make([]string, 0, len(environ)+3)
	for _, kv := range environ {
		key := kv
		if i := strings.IndexByte(kv, '='); i >= 0 {
			key = kv[:i]
		}
		if dropped[key] {
			continue
		}
		out = append(out, kv)
	}
	out = append(out,
		"TF_CLI_CONFIG_FILE="+rcPath,
		"CHECKPOINT_DISABLE=1",
		"TF_IN_AUTOMATION=1",
	)
	return out, cleanup, nil
}

// LocalStateFiles returns the local-backend state files present directly in
// workDir: `terraform.tfstate` and the `terraform.tfstate.d/` workspace
// directory. Both only exist when the engine was run against a configuration
// with no `backend` or `cloud` block, which in a staged copy of the module
// means the state lives nowhere durable.
func LocalStateFiles(workDir string) []string {
	var out []string
	for _, name := range []string{"terraform.tfstate", "terraform.tfstate.d"} {
		p := filepath.Join(workDir, name)
		if _, err := os.Stat(p); err == nil {
			out = append(out, p)
		}
	}
	return out
}
