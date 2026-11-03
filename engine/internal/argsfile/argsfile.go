// Package argsfile reads the line-per-arg param files written by Starlark
// rules via `ctx.actions.args().set_param_file_format("multiline")` and
// exposes them as an argv-shaped []string ready to be prepended to os.Args.
//
// Each line becomes one argv token. `${VAR}` references (curly form only)
// expand from the process environment when VAR is set — so the Starlark
// rule can write, e.g., `-src=${BUILD_WORKSPACE_DIRECTORY}/tests/foo/main.tf`
// without knowing the value at build time. A bare `$VAR` is NEVER expanded,
// so shell-style dollar signs in Terraform variable defaults, regex
// patterns, and other legitimate literals pass through verbatim. An
// unresolved `${VAR}` (name not in env) is also passed through as-is
// rather than silently becoming empty. Blank lines are skipped.
//
// The Starlark rule passes the file's runfiles rlocationpath in an env var
// unique to each binary. `ReadArgv` resolves it via `runfiles.New`.
//
// Each Go binary owns its own flag definitions — this package only
// preprocesses argv. The convention every binary follows is:
//
//	tokens, err := argsfile.ReadArgv(argsEnvVar)
//	if err != nil { ... }
//	argsfile.Prepend(tokens)
//	flag.Parse()
//
// Args-file tokens land BEFORE any real argv, so an explicit `--flag=value`
// on the command line still wins (flag package uses last-set semantics).
package argsfile

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strings"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

// curlyEnvRE matches `${NAME}` where NAME is a POSIX-portable env var name
// (letters, digits, underscore; must not start with a digit). Bare `$NAME`
// is intentionally not matched so literal `$` characters survive.
var curlyEnvRE = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)\}`)

func expandCurly(s string) string {
	return curlyEnvRE.ReplaceAllStringFunc(s, func(ref string) string {
		name := ref[2 : len(ref)-1]
		if val, ok := os.LookupEnv(name); ok {
			return val
		}
		// Unset — keep the reference so callers see the failure, not an
		// empty string that silently corrupts the flag value.
		return ref
	})
}

// ReadArgv returns the argv tokens from the args file whose rlocationpath is
// in envVar. If envVar is unset, returns nil. Lines are trimmed and
// env-expanded; blank lines are dropped.
func ReadArgv(envVar string) ([]string, error) {
	rloc := os.Getenv(envVar)
	if rloc == "" {
		return nil, nil
	}
	r, err := runfiles.New()
	if err != nil {
		return nil, fmt.Errorf("init runfiles: %w", err)
	}
	path, err := r.Rlocation(rloc)
	if err != nil {
		return nil, fmt.Errorf("resolve %s=%q via runfiles: %w", envVar, rloc, err)
	}
	return ReadFile(path)
}

// ReadFile reads an args file at the given filesystem path.
func ReadFile(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open args file %s: %w", path, err)
	}
	defer f.Close()

	var out []string
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		out = append(out, expandCurly(line))
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan args file %s: %w", path, err)
	}
	return out, nil
}

// Prepend inserts tokens between os.Args[0] and the existing argv tail.
// Real CLI flags therefore win against args-file defaults.
func Prepend(tokens []string) {
	if len(tokens) == 0 {
		return
	}
	joined := make([]string, 0, len(tokens)+len(os.Args))
	joined = append(joined, os.Args[0])
	joined = append(joined, tokens...)
	joined = append(joined, os.Args[1:]...)
	os.Args = joined
}
