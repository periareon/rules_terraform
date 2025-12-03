// cli is a thin `bazel run` wrapper: chdir to $BUILD_WORKING_DIRECTORY,
// then exec the toolchain-resolved terraform/tofu binary with the user's
// argv. Lets a downstream user drop into any subdirectory of their
// workspace and invoke `bazel run @terraform -- <cmd>` (or `@opentofu`)
// as they would run `terraform` / `tofu` natively — without wiring up a
// per-module `terraform_binary` target.
//
// Environment:
//
//   - TERRAFORM_RLOCATIONPATH: rlocationpath of the engine binary from the
//     resolved toolchain. Injected by the wrapper rule via
//     `RunEnvironmentInfo` — required.
//   - BUILD_WORKING_DIRECTORY: absolute path of the user's shell cwd when
//     `bazel run` was invoked. Bazel sets this automatically. Required —
//     the wrapper refuses to run without it, since the target is only
//     meaningful in a `bazel run` context.
package main

import (
	"fmt"
	"os"
	"os/exec"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

const (
	binaryRlocationEnvVar = "TERRAFORM_RLOCATIONPATH"
	workingDirEnvVar      = "BUILD_WORKING_DIRECTORY"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

func run() error {
	rloc := os.Getenv(binaryRlocationEnvVar)
	if rloc == "" {
		return fmt.Errorf("%s not set; the wrapper rule must inject it via RunEnvironmentInfo", binaryRlocationEnvVar)
	}
	workDir := os.Getenv(workingDirEnvVar)
	if workDir == "" {
		return fmt.Errorf("%s not set; this target must be invoked via `bazel run`", workingDirEnvVar)
	}

	r, err := runfiles.New()
	if err != nil {
		return fmt.Errorf("initialize runfiles: %w", err)
	}
	binPath, err := r.Rlocation(rloc)
	if err != nil {
		return fmt.Errorf("resolve %q via runfiles: %w", rloc, err)
	}

	// `cmd.Dir` sets the child's cwd — no need to chdir the wrapper itself.
	// Portable across Unix and Windows (syscall.Exec doesn't exist on
	// Windows, and a spawn-and-wait is fine for a short-lived CLI).
	cmd := exec.Command(binPath, os.Args[1:]...)
	cmd.Dir = workDir
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		return err
	}
	return nil
}
