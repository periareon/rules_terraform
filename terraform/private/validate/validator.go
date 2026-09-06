package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"rules_terraform/terraform/private/internal/moduledir"
)

type ArgsFile struct {
	Terraform string `json:"terraform"`
	Marker    string `json:"marker"`
	// ModuleDir is the tree artifact `terraform_init_aspect` builds: the whole
	// module directory, sources and `.terraform/` alike. Validate copies it and
	// runs inside — the layout was settled at analysis time.
	ModuleDir   string `json:"module_dir"`
	UseRunfiles bool   `json:"use_runfiles,omitempty"`
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

	// Test-mode: resolve rlocationpaths via runfiles.
	if argsFile.UseRunfiles && r != nil {
		resolved, err := r.Rlocation(argsFile.Terraform)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to resolve terraform: %v\n", err)
			os.Exit(1)
		}
		argsFile.Terraform = resolved

		resolved, err = r.Rlocation(argsFile.ModuleDir)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to resolve module_dir: %v\n", err)
			os.Exit(1)
		}
		argsFile.ModuleDir = resolved
	}

	resolvedTerraform, err := filepath.Abs(argsFile.Terraform)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: failed to get absolute path for terraform: %v\n", err)
		os.Exit(1)
	}
	if _, err := os.Stat(resolvedTerraform); err != nil {
		fmt.Fprintf(os.Stderr, "Error: terraform binary not found at %s: %v\n", resolvedTerraform, err)
		os.Exit(1)
	}

	resolvedModuleDir, err := filepath.Abs(argsFile.ModuleDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: failed to get absolute path for module_dir: %v\n", err)
		os.Exit(1)
	}

	workDir, cleanup, err := moduledir.Stage(resolvedModuleDir, "terraform-validate-*")
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

func loadArgsFile(path string) (*ArgsFile, error) {
	path, err := filepath.Abs(path)
	if err != nil {
		return nil, fmt.Errorf("failed to get absolute path: %w", err)
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
