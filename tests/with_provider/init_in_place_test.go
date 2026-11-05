// `bazel run //pkg:terraform -- init` end to end: the runner installs the
// built `.terraform/` into a checkout, and the native engine then plans there
// with no network. The checkout is a temp copy of this fixture at its package
// path, which is what the runner derives from the args file and
// BUILD_WORKSPACE_DIRECTORY.
package initinplace

import (
	"errors"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"testing"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

const modulePackage = "tests/with_provider"

func rlocation(t *testing.T, r *runfiles.Runfiles, rpath string) string {
	t.Helper()
	p, err := r.Rlocation(rpath)
	if err != nil {
		t.Fatalf("Rlocation(%s): %v", rpath, err)
	}
	return p
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return -1
}

// engineBinary picks the engine executable out of the toolchain's files.
func engineBinary(t *testing.T, r *runfiles.Runfiles) string {
	t.Helper()
	want := os.Getenv("ENGINE")
	for _, rpath := range strings.Fields(os.Getenv("ENGINE_FILES")) {
		base := path.Base(rpath)
		if base == want || base == want+".exe" {
			return rlocation(t, r, rpath)
		}
	}
	t.Fatalf("no %s binary among ENGINE_FILES", want)
	return ""
}

// checkout is a temp copy of the fixture at its package path, with a
// `run` that invokes the binary against it the way `bazel run` would.
type checkout struct {
	moduleDir string
	run       func(args ...string) (string, int)
}

// newCheckout stages the fixture. With stripHostHash, every `h1:` line is
// dropped from the lock, which is what a lock made on another platform
// looks like to this one.
func newCheckout(t *testing.T, r *runfiles.Runfiles, stripH1 bool) checkout {
	t.Helper()
	runnerRpath := os.Getenv("RUNNER")
	runner := rlocation(t, r, runnerRpath)
	// The args file sits next to the binary, named after the target.
	target := strings.TrimSuffix(path.Base(runnerRpath), ".exe")
	argsFile := path.Join(path.Dir(runnerRpath), target+".terraform_args.json")

	root := t.TempDir()
	moduleDir := filepath.Join(root, filepath.FromSlash(modulePackage))
	if err := os.MkdirAll(moduleDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, rpath := range strings.Fields(os.Getenv("SRCS")) {
		data, err := os.ReadFile(rlocation(t, r, rpath))
		if err != nil {
			t.Fatal(err)
		}
		if stripH1 && path.Base(rpath) == ".terraform.lock.hcl" {
			var kept []string
			for _, line := range strings.Split(string(data), "\n") {
				if !strings.Contains(line, "\"h1:") {
					kept = append(kept, line)
				}
			}
			data = []byte(strings.Join(kept, "\n"))
		}
		if err := os.WriteFile(filepath.Join(moduleDir, path.Base(rpath)), data, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	env := append(os.Environ(),
		"RULES_TERRAFORM_ARGS_FILE="+argsFile,
		"BUILD_WORKSPACE_DIRECTORY="+root,
	)
	return checkout{moduleDir: moduleDir, run: func(args ...string) (string, int) {
		cmd := exec.Command(runner, args...)
		cmd.Env = env
		out, err := cmd.CombinedOutput()
		return string(out), exitCode(err)
	}}
}

// nativePlan runs the engine itself in the module directory, with the
// operator's configuration out of the way, and returns its output and code.
func nativePlan(t *testing.T, r *runfiles.Runfiles, moduleDir string) (string, int) {
	t.Helper()
	rc := filepath.Join(t.TempDir(), "empty.tfrc")
	if err := os.WriteFile(rc, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	plan := exec.Command(engineBinary(t, r), "plan", "-input=false", "-no-color")
	plan.Dir = moduleDir
	plan.Env = append(os.Environ(),
		"TF_CLI_CONFIG_FILE="+rc,
		"CHECKPOINT_DISABLE=1",
		"TF_IN_AUTOMATION=1",
	)
	out, err := plan.CombinedOutput()
	return string(out), exitCode(err)
}

func h1Lines(t *testing.T, moduleDir string) int {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(moduleDir, ".terraform.lock.hcl"))
	if err != nil {
		t.Fatal(err)
	}
	return strings.Count(string(data), "\"h1:")
}

func TestInitInPlace(t *testing.T) {
	r, err := runfiles.New()
	if err != nil {
		t.Fatal(err)
	}
	c := newCheckout(t, r, false)
	moduleDir, run := c.moduleDir, c.run

	if out, code := run("init", "-upgrade"); code == 0 || !strings.Contains(out, "-upgrade") {
		t.Fatalf("init -upgrade: exit %d, want a refusal naming the flag:\n%s", code, out)
	}
	if _, err := os.Stat(filepath.Join(moduleDir, ".terraform")); !os.IsNotExist(err) {
		t.Fatalf("a refused init wrote .terraform/: %v", err)
	}

	out, code := run("init", "-input=false")
	if code != 0 {
		t.Fatalf("init: exit %d:\n%s", code, out)
	}
	if !strings.Contains(out, moduleDir) {
		t.Errorf("init did not name the directory it initialized:\n%s", out)
	}
	providers := filepath.Join(moduleDir, ".terraform", "providers")
	if info, err := os.Stat(providers); err != nil || !info.IsDir() {
		t.Fatalf("no providers installed at %s: %v", providers, err)
	}

	// The native engine plans against what was installed: one resource to
	// add, no network.
	if out, code := nativePlan(t, r, moduleDir); code != 0 || !strings.Contains(out, "1 to add") {
		t.Fatalf("native plan after init: exit %d:\n%s", code, out)
	}

	// A re-run replaces providers and modules and keeps what the native CLI
	// recorded in between: the workspace selection here.
	environment := filepath.Join(moduleDir, ".terraform", "environment")
	if err := os.WriteFile(environment, []byte("dev"), 0o644); err != nil {
		t.Fatal(err)
	}
	if out, code := run("init", "-input=false"); code != 0 {
		t.Fatalf("second init: exit %d:\n%s", code, out)
	}
	if got, err := os.ReadFile(environment); err != nil || string(got) != "dev" {
		t.Fatalf(".terraform/environment after re-init = %q, %v; want it kept", got, err)
	}
}

// A lock without this platform's h1: cannot vouch for the installed
// package, so the runner adds the hash, one line, and the native engine
// then reuses the package. With -lockfile=readonly it refuses instead.
func TestInitInPlaceAddsHostHash(t *testing.T) {
	r, err := runfiles.New()
	if err != nil {
		t.Fatal(err)
	}

	readonly := newCheckout(t, r, true)
	if out, code := readonly.run("init", "-input=false", "-lockfile=readonly"); code == 0 || !strings.Contains(out, "h1: hash") {
		t.Fatalf("init -lockfile=readonly on a lock without the host hash: exit %d, want a refusal naming the hash:\n%s", code, out)
	}
	if n := h1Lines(t, readonly.moduleDir); n != 0 {
		t.Fatalf("readonly init wrote %d h1 lines", n)
	}

	c := newCheckout(t, r, true)
	out, code := c.run("init", "-input=false")
	if code != 0 {
		t.Fatalf("init: exit %d:\n%s", code, out)
	}
	if !strings.Contains(out, "gained h1:") {
		t.Errorf("init did not report the hash it added:\n%s", out)
	}
	if n := h1Lines(t, c.moduleDir); n != 1 {
		t.Fatalf("lock has %d h1 lines after init, want exactly the host's", n)
	}
	if out, code := nativePlan(t, r, c.moduleDir); code != 0 || !strings.Contains(out, "1 to add") {
		t.Fatalf("native plan after init: exit %d:\n%s", code, out)
	}
	// Settled: a second init adds nothing.
	if out, code := c.run("init", "-input=false"); code != 0 || strings.Contains(out, "gained h1:") {
		t.Fatalf("second init: exit %d, output:\n%s", code, out)
	}
}
