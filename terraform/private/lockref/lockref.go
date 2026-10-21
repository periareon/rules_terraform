// lockref writes a module's .terraform.lock.hcl by running the real
// `terraform providers lock` (or `tofu providers lock`) against the module's
// .tf source files and copying the resulting lock file back to the source
// tree. It backs the `terraform_providers_lock` / `tofu_providers_lock`
// updaters: the one path that writes a lock covering every platform at once,
// without an engine installed on the host.
//
// Invoked exclusively via those `bazel run` rules — reads its inputs from a
// multiline args file whose rlocationpath is delivered via
// `RULES_TERRAFORM_LOCKREF_ARGS_FILE`.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"rules_terraform/terraform/private/internal/argsfile"
)

const argsEnvVar = "RULES_TERRAFORM_LOCKREF_ARGS_FILE"

type srcFlag []string

func (s *srcFlag) String() string { return fmt.Sprintf("%v", []string(*s)) }
func (s *srcFlag) Set(v string) error {
	*s = append(*s, v)
	return nil
}

type platformFlag []string

func (p *platformFlag) String() string { return fmt.Sprintf("%v", []string(*p)) }
func (p *platformFlag) Set(v string) error {
	*p = append(*p, v)
	return nil
}

func main() {
	tokens, err := argsfile.ReadArgv(argsEnvVar)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	argsfile.Prepend(tokens)

	engine := flag.String("engine", "", "rlocationpath of the terraform/tofu binary from the toolchain")
	out := flag.String("out", "", "absolute path where the golden lock file should be written")
	root := flag.String("root", "", "absolute path to the root of the local module tree; each -src's path is placed in the temp dir at its position relative to this root")
	workdir := flag.String("workdir", "", "slash-relative path of the root module within -root; the engine runs there. Empty when the root module is the tree root")
	var srcs srcFlag
	var platforms platformFlag
	flag.Var(&srcs, "src", "absolute path to a .tf file to seed the temp dir. Placed at its relative-to-root position so `module \"foo\" { source = \"./sub\" }` references resolve. Repeatable.")
	flag.Var(&platforms, "platform", "os_arch platform to include in the lock. Repeatable.")
	flag.Parse()

	if *engine == "" || *out == "" || *root == "" || len(srcs) == 0 || len(platforms) == 0 {
		fmt.Fprintln(os.Stderr, "Error: -engine, -out, -root, at least one -src, and at least one -platform are required")
		os.Exit(1)
	}

	r, err := runfiles.New()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: init runfiles: %v\n", err)
		os.Exit(1)
	}
	enginePath, err := r.Rlocation(*engine)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: resolve engine %q: %v\n", *engine, err)
		os.Exit(1)
	}

	tmp, err := os.MkdirTemp("", "lockref-*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: create temp dir: %v\n", err)
		os.Exit(1)
	}
	defer os.RemoveAll(tmp)

	for _, src := range srcs {
		rel, err := filepath.Rel(*root, src)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: computing %s relative to %s: %v\n", src, *root, err)
			os.Exit(1)
		}
		if strings.HasPrefix(rel, "..") {
			// Source lies outside the root — can't reconstruct its position
			// in the temp dir; skip. This shouldn't normally happen because
			// the Starlark rule filters to workspace-local srcs.
			continue
		}
		dst := filepath.Join(tmp, rel)
		if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
			fmt.Fprintf(os.Stderr, "Error: mkdir for %s: %v\n", dst, err)
			os.Exit(1)
		}
		if err := copyFile(src, dst); err != nil {
			fmt.Fprintf(os.Stderr, "Error: copy %s: %v\n", src, err)
			os.Exit(1)
		}
	}

	// The engine runs in the root module, which sits inside the seeded tree
	// wherever it sits in the source tree.
	moduleDir := filepath.Join(tmp, filepath.FromSlash(*workdir))

	// `terraform providers lock` requires local modules to be installed
	// first; init handles both local modules and an initial provider
	// download (which the subsequent `providers lock -platform=<all>`
	// extends with the other platforms' hashes).
	initCmd := exec.Command(enginePath, "init", "-backend=false", "-input=false")
	initCmd.Dir = moduleDir
	initCmd.Stdout = os.Stdout
	initCmd.Stderr = os.Stderr
	if err := initCmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %s init: %v\n", filepath.Base(enginePath), err)
		os.Exit(1)
	}

	cmdArgs := []string{"providers", "lock"}
	for _, p := range platforms {
		cmdArgs = append(cmdArgs, "-platform="+p)
	}
	cmd := exec.Command(enginePath, cmdArgs...)
	cmd.Dir = moduleDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %s %v: %v\n", filepath.Base(enginePath), cmdArgs, err)
		os.Exit(1)
	}

	generated := filepath.Join(moduleDir, ".terraform.lock.hcl")
	data, err := os.ReadFile(generated)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: engine produced no lock file at %s: %v\n", generated, err)
		os.Exit(1)
	}

	if err := os.MkdirAll(filepath.Dir(*out), 0755); err != nil {
		fmt.Fprintf(os.Stderr, "Error: create parent of %s: %v\n", *out, err)
		os.Exit(1)
	}
	if err := os.WriteFile(*out, data, 0644); err != nil {
		fmt.Fprintf(os.Stderr, "Error: write %s: %v\n", *out, err)
		os.Exit(1)
	}
	fmt.Printf("Wrote %s\n", *out)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return nil
}
