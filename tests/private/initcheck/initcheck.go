// initcheck asserts that the `.terraform` directory produced by
// `terraform_init_aspect` contains an expected set of files. It's the Go
// backing for `terraform_init_test` and reads its inputs from a multiline
// args file whose rlocationpath is supplied via
// RULES_TERRAFORM_INITCHECK_ARGS_FILE.
package main

import (
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"rules_terraform/terraform/private/internal/argsfile"
)

const argsEnvVar = "RULES_TERRAFORM_INITCHECK_ARGS_FILE"

type expectedFlag []string

func (e *expectedFlag) String() string { return fmt.Sprintf("%v", []string(*e)) }
func (e *expectedFlag) Set(v string) error {
	*e = append(*e, v)
	return nil
}

func main() {
	tokens, err := argsfile.ReadArgv(argsEnvVar)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(2)
	}
	argsfile.Prepend(tokens)

	dir := flag.String("dir", "", "Runfiles rlocationpath of the .terraform directory")
	var expected expectedFlag
	flag.Var(&expected, "expected", "Relative path inside the directory that must exist. Repeatable.")
	flag.Parse()

	if *dir == "" {
		fmt.Fprintln(os.Stderr, "Error: -dir is required (or set "+argsEnvVar+")")
		os.Exit(2)
	}

	r, err := runfiles.New()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: init runfiles: %v\n", err)
		os.Exit(2)
	}
	resolvedDir, err := r.Rlocation(*dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL: resolve .terraform dir %q via runfiles: %v\n", *dir, err)
		os.Exit(1)
	}

	info, err := os.Stat(resolvedDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL: cannot stat .terraform dir %s: %v\n", resolvedDir, err)
		os.Exit(1)
	}
	if !info.IsDir() {
		fmt.Fprintf(os.Stderr, "FAIL: %s is not a directory\n", resolvedDir)
		os.Exit(1)
	}
	*dir = resolvedDir

	failed := 0
	for _, rel := range expected {
		full := filepath.Join(*dir, rel)
		if _, err := os.Stat(full); err == nil {
			fmt.Printf("OK: %s\n", rel)
			continue
		}
		// Provider binaries land as `<name>.exe` on Windows (go_binary
		// output). Accept that suffix when the exact match is missing so
		// the same expected_files list works on every platform. Guard on
		// the actual `.exe` suffix rather than filepath.Ext, which reports
		// e.g. `.4_x5` for versioned names like `terraform-provider-null_v3.2.4_x5`.
		if runtime.GOOS == "windows" && !strings.HasSuffix(rel, ".exe") {
			if _, err := os.Stat(full + ".exe"); err == nil {
				fmt.Printf("OK: %s (matched %s.exe)\n", rel, rel)
				continue
			}
		}
		fmt.Fprintf(os.Stderr, "FAIL: expected %s not found (looked at %s)\n", rel, full)
		failed++
	}

	if failed > 0 {
		fmt.Fprintf(os.Stderr, "\n%d expected file(s) missing under %s. Directory contents:\n", failed, *dir)
		_ = filepath.WalkDir(*dir, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() {
				return nil
			}
			if rel, relErr := filepath.Rel(*dir, path); relErr == nil {
				fmt.Fprintf(os.Stderr, "  %s\n", rel)
			}
			return nil
		})
		os.Exit(1)
	}

	fmt.Println("PASS: all expected files present")
}
