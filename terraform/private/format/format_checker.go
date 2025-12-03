package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

// ArgsFile represents the structure of the JSON args file
type ArgsFile struct {
	Terraform string   `json:"terraform"`
	Srcs      []string `json:"srcs"`
}

// arrayFlags is a custom flag type that allows multiple values for the same flag
type arrayFlags []string

func (a *arrayFlags) String() string {
	return ""
}

func (a *arrayFlags) Set(value string) error {
	*a = append(*a, value)
	return nil
}

// args holds the parsed command-line arguments
type args struct {
	terraformBinary string
	srcFiles        arrayFlags
	markerFile      string
	useRunfiles     bool
}

func parseArgs() args {
	var a args

	flag.Var(&a.srcFiles, "src", "Source Terraform file to format (can be specified multiple times)")
	flag.StringVar(&a.terraformBinary, "terraform", "", "Path to the terraform binary (rlocationpath)")
	flag.StringVar(&a.markerFile, "marker", "", "Marker file to create on success")
	flag.Parse()

	// Check if we should load args from a file (test mode with runfiles)
	if argsFilePath := os.Getenv("RULES_TERRAFORM_FORMAT_ARGS_FILE"); argsFilePath != "" {
		a.useRunfiles = true

		// Load args from JSON file
		argsFile, err := loadArgsFile(argsFilePath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error loading args file: %v\n", err)
			os.Exit(1)
		}

		a.terraformBinary = argsFile.Terraform
		a.srcFiles = argsFile.Srcs
	}

	// Validate args
	if a.terraformBinary == "" {
		fmt.Fprintln(os.Stderr, "Error: -terraform flag is required")
		os.Exit(1)
	}

	if len(a.srcFiles) == 0 {
		fmt.Fprintln(os.Stderr, "Error: at least one -src flag is required")
		os.Exit(1)
	}

	return a
}

func main() {
	a := parseArgs()

	var resolvedSrcFiles []string
	var resolvedTerraform string

	// Resolve terraform binary
	var err error
	if a.useRunfiles {
		// Test mode: resolve through runfiles
		resolvedTerraform, err = resolveRunfile(a.terraformBinary)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: failed to resolve terraform binary: %v\n", err)
			os.Exit(1)
		}
	} else {
		// Aspect mode: use path as-is and convert to absolute
		resolvedTerraform = a.terraformBinary
		if !filepath.IsAbs(resolvedTerraform) {
			resolvedTerraform, err = filepath.Abs(resolvedTerraform)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: failed to get absolute path for terraform binary: %v\n", err)
				os.Exit(1)
			}
		}
	}

	// Verify terraform binary exists
	if _, err := os.Stat(resolvedTerraform); err != nil {
		fmt.Fprintf(os.Stderr, "Error: terraform binary not found at %s: %v\n", resolvedTerraform, err)
		os.Exit(1)
	}

	// Resolve source files
	resolvedSrcFiles = make([]string, 0, len(a.srcFiles))
	for _, srcFile := range a.srcFiles {
		var resolved string

		if a.useRunfiles {
			// Test mode: resolve through runfiles
			resolved, err = resolveRunfile(srcFile)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: failed to resolve source file %s: %v\n", srcFile, err)
				os.Exit(1)
			}
		} else {
			// Aspect mode: use path as-is and convert to absolute
			resolved = srcFile
			if !filepath.IsAbs(resolved) {
				resolved, err = filepath.Abs(resolved)
				if err != nil {
					fmt.Fprintf(os.Stderr, "Error: failed to get absolute path for source file %s: %v\n", srcFile, err)
					os.Exit(1)
				}
			}
		}

		resolvedSrcFiles = append(resolvedSrcFiles, resolved)
	}

	// Format check each source file with implicit check and list modes
	exitCode := 0
	for _, srcFile := range resolvedSrcFiles {
		if err := formatFile(resolvedTerraform, srcFile); err != nil {
			fmt.Fprintf(os.Stderr, "Error formatting %s: %v\n", srcFile, err)
			exitCode = 1
		}
	}

	// Create marker file if specified and formatting succeeded
	if exitCode == 0 && a.markerFile != "" {
		if err := os.WriteFile(a.markerFile, []byte(""), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "Error creating marker file: %v\n", err)
			os.Exit(1)
		}
	}

	os.Exit(exitCode)
}

func formatFile(terraformBinary, srcFile string) error {
	// Verify source file exists
	if _, err := os.Stat(srcFile); err != nil {
		return fmt.Errorf("source file not found: %w", err)
	}

	// Build terraform fmt arguments with implicit check mode (no write)
	args := []string{"fmt", "-check"}

	// Get the directory containing the file for terraform fmt
	// terraform fmt works on files or directories
	absPath, err := filepath.Abs(srcFile)
	if err != nil {
		return fmt.Errorf("failed to get absolute path: %w", err)
	}

	args = append(args, absPath)

	// Execute terraform fmt
	cmd := exec.Command(terraformBinary, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			// terraform fmt returns exit code 3 when files are not formatted (in check mode)
			if exitErr.ExitCode() == 3 {
				fmt.Fprintf(os.Stderr, "File is not formatted: %s\n", srcFile)
				return fmt.Errorf("formatting check failed")
			}
		}
		return fmt.Errorf("terraform fmt failed: %w", err)
	}

	return nil
}

// loadArgsFile loads arguments from a JSON file
func loadArgsFile(path string) (*ArgsFile, error) {
	// Resolve the args file through runfiles
	resolvedArgsFile, err := resolveRunfile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to resolve args file: %w", err)
	}

	data, err := os.ReadFile(resolvedArgsFile)
	if err != nil {
		return nil, fmt.Errorf("failed to read args file: %w", err)
	}

	var argsFile ArgsFile
	if err := json.Unmarshal(data, &argsFile); err != nil {
		return nil, fmt.Errorf("failed to parse args file: %w", err)
	}

	return &argsFile, nil
}

// resolveRunfile resolves a runfile path to an actual filesystem path
func resolveRunfile(rlocationpath string) (string, error) {
	// If the path is already absolute, return it as-is
	if filepath.IsAbs(rlocationpath) {
		return rlocationpath, nil
	}

	r, err := runfiles.New()
	if err != nil {
		// If runfiles is not available, return the path as-is
		// This happens when not running under Bazel
		return rlocationpath, nil
	}

	path, err := r.Rlocation(rlocationpath)
	if err != nil {
		return "", fmt.Errorf("failed to locate runfile %s: %w", rlocationpath, err)
	}

	// Verify the file exists
	if _, err := os.Stat(path); err != nil {
		return "", fmt.Errorf("runfile does not exist at %s: %w", path, err)
	}

	return path, nil
}
