package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"rules_terraform/terraform/private/internal/fsutil"
)

type ArgsFile struct {
	TerraformRlocationPath    string            `json:"terraform_rlocationpath"`
	Runfiles                  map[string]string `json:"runfiles"`
	LockRlocationPath         string            `json:"lock_rlocationpath,omitempty"`
	TerraformDirRlocationPath string            `json:"terraform_dir_rlocationpath,omitempty"`
}

type args struct {
	argsFilePath string
	lockPath     string
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

	var lockPath string
	flag.StringVar(&lockPath, "lock", "", "Path to the .terraform.lock.hcl file (rlocationpath)")
	flag.Parse()

	userArgs := flag.Args()
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
		lockPath:     lockPath,
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

	// `-lock` command-line flag takes precedence over the args-file default.
	lockRlocationPath := a.lockPath
	if lockRlocationPath == "" {
		lockRlocationPath = argsFile.LockRlocationPath
	}

	workDir, cleanup, err := setupWorkingDirectory(r, argsFile.Runfiles, lockRlocationPath)
	if err != nil {
		return fmt.Errorf("failed to setup working directory: %w", err)
	}

	hasTerraformDir := false
	if argsFile.TerraformDirRlocationPath != "" {
		terraformDirSrc, err := r.Rlocation(argsFile.TerraformDirRlocationPath)
		if err != nil {
			cleanup()
			return fmt.Errorf("failed to locate pre-constructed .terraform directory: %w", err)
		}

		terraformDirDst := filepath.Join(workDir, ".terraform")
		if err := fsutil.CopyDirectory(terraformDirSrc, terraformDirDst); err != nil {
			cleanup()
			return fmt.Errorf("failed to copy pre-constructed .terraform directory: %w", err)
		}
		hasTerraformDir = true

		// The init tool rewrites h1: hashes in the lock file inside .terraform/
		// to match the platform-specific provider binaries Bazel installed.
		// Prefer that copy over the source lock file so `terraform init` and
		// downstream commands accept the installed providers.
		initLock := filepath.Join(terraformDirDst, ".terraform.lock.hcl")
		if _, err := os.Stat(initLock); err == nil {
			lockDst := filepath.Join(workDir, ".terraform.lock.hcl")
			// If setupWorkingDirectory dropped a symlink at this path (pointing
			// back at the source lock), unlink it first — otherwise CopyFile
			// would follow the symlink and mutate the workspace source.
			if _, err := os.Lstat(lockDst); err == nil {
				if err := os.Remove(lockDst); err != nil {
					cleanup()
					return fmt.Errorf("failed to replace source lock symlink: %w", err)
				}
			}
			if err := fsutil.CopyFile(initLock, lockDst); err != nil {
				cleanup()
				return fmt.Errorf("failed to install rewritten lock file: %w", err)
			}
		}
	}

	return executeTerraform(terraformPath, workDir, a.userArgs, hasTerraformDir, cleanup)
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

func setupWorkingDirectory(r *runfiles.Runfiles, runfilesManifest map[string]string, lockRlocationPath string) (string, func(), error) {
	// Use a private temp dir rather than RUNFILES_DIR — terraform mutates
	// this tree (writes state, .terraform/, plan output).
	tempDir, err := os.MkdirTemp("", "terraform-runner-*")
	if err != nil {
		return "", nil, fmt.Errorf("failed to create temp directory: %w", err)
	}

	cleanup := func() {
		os.RemoveAll(tempDir)
	}

	for rlocationPath, workspaceRelPath := range runfilesManifest {
		srcPath, err := r.Rlocation(rlocationPath)
		if err != nil {
			cleanup()
			return "", nil, fmt.Errorf("failed to locate file %s: %w", rlocationPath, err)
		}

		dstPath := filepath.Join(tempDir, workspaceRelPath)

		if err := os.MkdirAll(filepath.Dir(dstPath), 0755); err != nil {
			cleanup()
			return "", nil, fmt.Errorf("failed to create directory for %s: %w", dstPath, err)
		}

		if err := fsutil.SymlinkFile(srcPath, dstPath); err != nil {
			cleanup()
			return "", nil, fmt.Errorf("failed to symlink %s to %s: %w", srcPath, dstPath, err)
		}
	}

	if lockRlocationPath != "" {
		lockSrcPath, err := r.Rlocation(lockRlocationPath)
		if err != nil {
			cleanup()
			return "", nil, fmt.Errorf("failed to locate lock file %s: %w", lockRlocationPath, err)
		}

		lockDstPath := filepath.Join(tempDir, ".terraform.lock.hcl")
		if err := fsutil.SymlinkFile(lockSrcPath, lockDstPath); err != nil {
			cleanup()
			return "", nil, fmt.Errorf("failed to symlink lock file %s to %s: %w", lockSrcPath, lockDstPath, err)
		}
	}

	return tempDir, cleanup, nil
}

func executeTerraform(terraformPath, workDir string, args []string, hasTerraformDir bool, cleanup func()) error {
	// Skip module/provider downloads when the aspect pre-populated .terraform.
	initArgs := []string{"init"}
	if hasTerraformDir {
		initArgs = append(initArgs,
			"-get=false",
			"-plugin-dir="+filepath.Join(workDir, ".terraform", "providers"),
		)
	}

	initCmd := exec.Command(terraformPath, initArgs...)
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
