package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

// args holds the parsed command-line arguments
type args struct {
	terraformBinary string
	bazelBinary     string
	checkMode       bool
	scope           []string
}

func parseArgs() args {
	var a args

	flag.StringVar(&a.terraformBinary, "terraform", "", "Path to the terraform binary")
	flag.StringVar(&a.bazelBinary, "bazel", "", "Path to the bazel binary (defaults to BAZEL_REAL env var or searches PATH)")
	flag.BoolVar(&a.checkMode, "check", false, "Check if files are formatted without modifying them")
	flag.Parse()

	// Get scope from remaining arguments (defaults to //...:all)
	a.scope = flag.Args()
	if len(a.scope) == 0 {
		a.scope = []string{"//...:all"}
	}

	// Find Bazel binary
	if a.bazelBinary == "" {
		var err error
		a.bazelBinary, err = findBazel()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	}

	// Find Terraform binary
	if a.terraformBinary == "" {
		var err error
		a.terraformBinary, err = findTerraform()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	} else {
		// If terraform binary path is provided, resolve it through runfiles if needed
		resolved, err := resolveRunfile(a.terraformBinary)
		if err == nil {
			a.terraformBinary = resolved
		}
	}

	return a
}

func main() {
	a := parseArgs()

	// Get workspace directory
	workspaceDir := os.Getenv("BUILD_WORKSPACE_DIRECTORY")
	if workspaceDir == "" {
		fmt.Fprintln(os.Stderr, "Error: BUILD_WORKSPACE_DIRECTORY is not set. Is the process running under Bazel?")
		os.Exit(1)
	}

	// Query for Terraform source files
	targets, err := queryTargets(a.scope, a.bazelBinary, workspaceDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error querying targets: %v\n", err)
		os.Exit(1)
	}

	if len(targets) == 0 {
		fmt.Println("No Terraform files found to format")
		return
	}

	// Convert labels to paths
	sources := make([]string, 0, len(targets))
	for _, target := range targets {
		path, err := pathify(target)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: skipping target %s: %v\n", target, err)
			continue
		}
		sources = append(sources, path)
	}

	// Run terraform fmt on the sources
	if err := runTerraformFmt(a.terraformBinary, sources, workspaceDir, a.checkMode); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

// findBazel locates a Bazel executable
func findBazel() (string, error) {
	// Check BAZEL_REAL environment variable first
	if bazelReal := os.Getenv("BAZEL_REAL"); bazelReal != "" {
		return bazelReal, nil
	}

	// Search PATH for bazel binaries
	for _, name := range []string{"bazel", "bazelisk"} {
		if path, err := exec.LookPath(name); err == nil {
			return path, nil
		}
	}

	return "", fmt.Errorf("could not locate a Bazel binary")
}

// findTerraform locates a Terraform executable
func findTerraform() (string, error) {
	// First, check if TERRAFORM_RLOCATIONPATH is set (for runfiles)
	if rlocationpath := os.Getenv("TERRAFORM_RLOCATIONPATH"); rlocationpath != "" {
		path, err := resolveRunfile(rlocationpath)
		if err == nil {
			return path, nil
		}
		fmt.Fprintf(os.Stderr, "Warning: failed to resolve TERRAFORM_RLOCATIONPATH %s: %v\n", rlocationpath, err)
	}

	// Search PATH for terraform binary
	if path, err := exec.LookPath("terraform"); err == nil {
		return path, nil
	}

	return "", fmt.Errorf("could not locate a Terraform binary")
}

// resolveRunfile resolves a runfile path to an actual filesystem path
func resolveRunfile(rlocationpath string) (string, error) {
	r, err := runfiles.New()
	if err != nil {
		return "", fmt.Errorf("failed to create runfiles: %w", err)
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

// queryTargets queries for all Terraform source files within the given scope
func queryTargets(scope []string, bazel, workspaceDir string) ([]string, error) {
	// Query explanation:
	// Filter targets down to anything beginning with `//` and ends with `.tf`.
	//       Collect source files.
	//           Collect dependencies of targets for a given scope.
	//           Except for targets tagged to ignore formatting
	//
	scopeStr := strings.Join(scope, " ")
	queryTemplate := fmt.Sprintf(
		`filter("^//.*\.tf$", kind("source file", deps(set(%s) except attr(tags, "(^\[|, )(noformat|no-format|no-terraform-format)(, |\]$)", set(%s)), 1)))`,
		scopeStr, scopeStr,
	)

	cmd := exec.Command(
		bazel,
		"query",
		queryTemplate,
		"--noimplicit_deps",
		"--keep_going",
	)
	cmd.Dir = workspaceDir

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		// If there are no matches, bazel query may return an error
		// Check if stdout is empty
		if stdout.Len() == 0 {
			return []string{}, nil
		}
		fmt.Fprintf(os.Stderr, "Warning: bazel query had issues: %v\n%s\n", err, stderr.String())
	}

	// Parse output
	output := strings.TrimSpace(stdout.String())
	if output == "" {
		return []string{}, nil
	}

	targets := strings.Split(output, "\n")
	return targets, nil
}

// pathify converts a Bazel label like `//foo:bar.tf` into `foo/bar.tf`
func pathify(label string) (string, error) {
	if strings.HasPrefix(label, "@") {
		return "", fmt.Errorf("external labels are unsupported")
	}

	// Handle //:file.tf -> file.tf
	if strings.HasPrefix(label, "//:") {
		return label[3:], nil
	}

	// Handle //foo:bar.tf -> foo/bar.tf
	path := strings.TrimPrefix(label, "//")
	path = strings.Replace(path, ":", "/", 1)

	return path, nil
}

// runTerraformFmt runs terraform fmt on the given sources
func runTerraformFmt(terraformBinary string, sources []string, workspaceDir string, checkMode bool) error {
	if len(sources) == 0 {
		return nil
	}

	exitCode := 0
	for _, source := range sources {
		fullPath := filepath.Join(workspaceDir, source)

		// Build terraform fmt arguments
		args := []string{"fmt"}

		if checkMode {
			args = append(args, "-check")
		}

		args = append(args, fullPath)

		// Execute terraform fmt
		cmd := exec.Command(terraformBinary, args...)
		cmd.Dir = workspaceDir
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr

		if err := cmd.Run(); err != nil {
			if exitErr, ok := err.(*exec.ExitError); ok {
				// terraform fmt returns exit code 3 when files are not formatted (in check mode)
				if exitErr.ExitCode() == 3 && checkMode {
					fmt.Fprintf(os.Stderr, "File is not formatted: %s\n", source)
					exitCode = 1
					continue
				}
			}
			fmt.Fprintf(os.Stderr, "Error formatting %s: %v\n", source, err)
			exitCode = 1
		}
	}

	if exitCode != 0 {
		return fmt.Errorf("terraform fmt failed for one or more files")
	}

	return nil
}
