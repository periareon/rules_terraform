package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

// stageModuleDir writes `files` (module-relative path -> content) into a
// directory and returns a Runfiles backed by a manifest that maps
// "myrepo/simple.module" at it, mimicking how Bazel exposes the tree artifact
// `terraform_init_aspect` declares.
func stageModuleDir(t *testing.T, files map[string]string) *runfiles.Runfiles {
	t.Helper()

	moduleDir := filepath.Join(t.TempDir(), "simple.module")
	if err := os.MkdirAll(moduleDir, 0755); err != nil {
		t.Fatalf("mkdir %s: %v", moduleDir, err)
	}
	for rel, content := range files {
		abs := filepath.Join(moduleDir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(abs), 0755); err != nil {
			t.Fatalf("mkdir for %s: %v", rel, err)
		}
		if err := os.WriteFile(abs, []byte(content), 0644); err != nil {
			t.Fatalf("write %s: %v", rel, err)
		}
	}

	manifestPath := filepath.Join(t.TempDir(), "MANIFEST")
	manifest := "myrepo/simple.module " + moduleDir + "\n"
	if err := os.WriteFile(manifestPath, []byte(manifest), 0644); err != nil {
		t.Fatalf("write manifest: %v", err)
	}

	r, err := runfiles.New(runfiles.ManifestFile(manifestPath), runfiles.ProgramName("runner_test"))
	if err != nil {
		t.Fatalf("runfiles.New: %v", err)
	}
	return r
}

// The bug this guards: the runner used to reassemble the module from a flat
// runfiles manifest and got the working directory wrong, running terraform
// where no `.tf` file existed. `init`, `plan` and `test` all exit 0 in an
// empty directory, so every terraform_test passed while reading nothing.
// Assert the returned working directory actually holds the configuration.
func TestSetupWorkingDirectoryCopiesModule(t *testing.T) {
	r := stageModuleDir(t, map[string]string{
		"main.tf":                         "# root module\n",
		"variables.tf":                    "# vars\n",
		"mymod/main.tf":                   "# child module\n",
		".terraform/modules/modules.json": "{}\n",
		".terraform.lock.hcl":             "# lock\n",
	})

	workDir, cleanup, err := setupWorkingDirectory(r, "myrepo/simple.module")
	if err != nil {
		t.Fatalf("setupWorkingDirectory: %v", err)
	}
	defer cleanup()

	for _, rel := range []string{"main.tf", "variables.tf", "mymod/main.tf", ".terraform.lock.hcl", ".terraform/modules/modules.json"} {
		if _, err := os.Stat(filepath.Join(workDir, filepath.FromSlash(rel))); err != nil {
			t.Errorf("%s missing from working directory: %v", rel, err)
		}
	}
}

// Terraform must be able to write state and `.terraform/` where it runs, and
// the source tree artifact is a read-only build output.
func TestSetupWorkingDirectoryIsWritableAndSeparate(t *testing.T) {
	r := stageModuleDir(t, map[string]string{"main.tf": "# root\n"})

	workDir, cleanup, err := setupWorkingDirectory(r, "myrepo/simple.module")
	if err != nil {
		t.Fatalf("setupWorkingDirectory: %v", err)
	}
	defer cleanup()

	src, err := r.Rlocation("myrepo/simple.module")
	if err != nil {
		t.Fatalf("Rlocation: %v", err)
	}
	if workDir == src {
		t.Fatalf("workDir %q is the artifact itself; terraform would mutate a build output", workDir)
	}

	if err := os.WriteFile(filepath.Join(workDir, "terraform.tfstate"), []byte("{}"), 0644); err != nil {
		t.Errorf("working directory is not writable: %v", err)
	}
	if _, err := os.Stat(filepath.Join(src, "terraform.tfstate")); err == nil {
		t.Error("write leaked back into the source artifact")
	}
}

// An empty module directory is the vacuous-pass case: terraform reports
// success having read nothing. Fail instead.
func TestSetupWorkingDirectoryRejectsModuleWithoutConfig(t *testing.T) {
	r := stageModuleDir(t, map[string]string{".terraform/modules/modules.json": "{}\n"})

	_, cleanup, err := setupWorkingDirectory(r, "myrepo/simple.module")
	if cleanup != nil {
		cleanup()
	}
	if err == nil {
		t.Fatal("setupWorkingDirectory succeeded on a module with no .tf files; want an error")
	}
	if !strings.Contains(err.Error(), "no .tf files") {
		t.Errorf("error = %v, want it to name the missing configuration", err)
	}
}

func TestSetupWorkingDirectoryRequiresModuleDir(t *testing.T) {
	r := stageModuleDir(t, map[string]string{"main.tf": "# root\n"})

	_, cleanup, err := setupWorkingDirectory(r, "")
	if cleanup != nil {
		cleanup()
	}
	if err == nil {
		t.Fatal("setupWorkingDirectory succeeded without a module directory; want an error")
	}
}
