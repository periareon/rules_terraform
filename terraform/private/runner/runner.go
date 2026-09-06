package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"syscall"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"rules_terraform/terraform/private/internal/moduledir"
)

// ArgsFile mirrors the JSON `build_runner` writes in //terraform/private:terraform.bzl.
type ArgsFile struct {
	TerraformRlocationPath string `json:"terraform_rlocationpath"`
	// ModuleDirRlocationPath locates the tree artifact `terraform_init_aspect`
	// builds: the module directory, complete with its `.tf` files, local child
	// modules at their `source` paths, `.terraform.lock.hcl`, and a populated
	// `.terraform/`. The runner copies it and runs the engine inside — the
	// layout is settled at analysis time, not reconstructed here.
	ModuleDirRlocationPath string `json:"module_dir_rlocationpath"`
}

type args struct {
	argsFilePath string
	userArgs     []string
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func parseArgs() args {
	argsFilePath := os.Getenv("RULES_TERRAFORM_ARGS_FILE")
	if argsFilePath == "" {
		fmt.Fprintln(os.Stderr, "Error: RULES_TERRAFORM_ARGS_FILE environment variable not set")
		os.Exit(1)
	}

	// The runner takes no flags of its own — everything reaches the engine
	// untouched, so `bazel run //x -- fmt -check` behaves like plain terraform.
	userArgs := os.Args[1:]
	// `terraform_test` sets this so the runner ignores user args and runs the
	// HCL native test framework. This keeps Bazel's --test_arg surface from
	// silently mutating what `terraform test` does.
	if os.Getenv("RULES_TERRAFORM_MODE") == "test" {
		userArgs = []string{"test"}
	} else if len(userArgs) == 0 {
		// Match `terraform` with no args: print help via the CLI itself.
		userArgs = []string{"--help"}
	}

	return args{
		argsFilePath: argsFilePath,
		userArgs:     userArgs,
	}
}

func run() error {
	a := parseArgs()

	// Initialize runfiles
	r, err := runfiles.New()
	if err != nil {
		return fmt.Errorf("failed to initialize runfiles: %w", err)
	}

	// The env var carries an rlocationpath; resolve via runfiles so this
	// works in both `bazel run` and `bazel test` contexts.
	argsResolved, err := r.Rlocation(a.argsFilePath)
	if err != nil {
		return fmt.Errorf("failed to locate args file %q: %w", a.argsFilePath, err)
	}
	argsFile, err := readArgsFile(argsResolved)
	if err != nil {
		return fmt.Errorf("failed to read args file: %w", err)
	}

	terraformPath, err := r.Rlocation(argsFile.TerraformRlocationPath)
	if err != nil {
		return fmt.Errorf("failed to locate terraform binary: %w", err)
	}

	workDir, cleanup, err := setupWorkingDirectory(r, argsFile.ModuleDirRlocationPath)
	if err != nil {
		return fmt.Errorf("failed to setup working directory: %w", err)
	}

	return executeTerraform(terraformPath, workDir, a.userArgs, cleanup)
}

func readArgsFile(path string) (*ArgsFile, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var argsFile ArgsFile
	if err := json.Unmarshal(data, &argsFile); err != nil {
		return nil, err
	}

	return &argsFile, nil
}

// setupWorkingDirectory resolves the module directory out of runfiles and
// stages a writable copy of it.
func setupWorkingDirectory(r *runfiles.Runfiles, moduleDirRlocationPath string) (string, func(), error) {
	if moduleDirRlocationPath == "" {
		return "", nil, fmt.Errorf("args file does not name the module directory")
	}

	moduleDirSrc, err := r.Rlocation(moduleDirRlocationPath)
	if err != nil {
		return "", nil, fmt.Errorf("failed to locate module directory %s: %w", moduleDirRlocationPath, err)
	}

	return moduledir.Stage(moduleDirSrc, "terraform-runner-*")
}

func executeTerraform(terraformPath, workDir string, args []string, cleanup func()) error {
	// Everything is already installed under `.terraform/`; the engine must not
	// reach the network to re-resolve any of it.
	initCmd := exec.Command(terraformPath, "init",
		"-get=false",
		"-plugin-dir="+moduledir.ProvidersDir(workDir),
	)
	initCmd.Dir = workDir
	initCmd.Stdin = os.Stdin
	initCmd.Stdout = os.Stdout
	initCmd.Stderr = os.Stderr
	initCmd.Env = os.Environ()

	if err := initCmd.Run(); err != nil {
		// Init failures are not the user's `terraform` command — we own the
		// init call, so clean the temp dir before propagating the exit code.
		if exitErr, ok := err.(*exec.ExitError); ok {
			if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
				if cleanup != nil {
					cleanup()
				}
				os.Exit(status.ExitStatus())
			}
		}
		if cleanup != nil {
			cleanup()
		}
		return fmt.Errorf("terraform init failed: %w", err)
	}

	cmd := exec.Command(terraformPath, args...)
	cmd.Dir = workDir
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()

	err := cmd.Run()
	if err != nil {
		// Leak the temp dir on failure so users can inspect state/plan output.
		if exitErr, ok := err.(*exec.ExitError); ok {
			if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
				os.Exit(status.ExitStatus())
			}
		}
		return err
	}

	if cleanup != nil {
		cleanup()
	}

	return nil
}
