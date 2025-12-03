// Package argsjson reads the (template, paths) file pair written by the
// `write_json_args` Starlark helper in //terraform/private:args.bzl and
// resolves it into a fully-substituted JSON document.
//
// # Why split into two files
//
// Actions that need STRUCTURED input (nested objects containing File
// fields) can't cleanly express that shape via flat CLI flags. A
// hand-written JSON args file works but it defeats Bazel path mapping —
// the paths get baked into a text file at analysis time, bypassing
// `ctx.actions.args()`.
//
// The Starlark helper splits the payload:
//
//   - A JSON template with every File replaced by a `"<<RTF_PATH_N>>"`
//     placeholder string. Static text; written via `ctx.actions.write`.
//   - A paths file — one path per line, written from a
//     `ctx.actions.args()` object holding the Files in order. Line N
//     corresponds to placeholder `<<RTF_PATH_N>>`. Bazel path-maps every
//     entry when path mapping is on.
//
// This package loads both files and substitutes placeholders in the
// template, producing JSON bytes that unmarshal into whatever struct
// the caller expects.
package argsjson

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
)

var placeholderRE = regexp.MustCompile(`<<RTF_PATH_(\d+)>>`)

// Load reads the template + paths files and returns JSON bytes with every
// placeholder substituted for the corresponding path. Path values are
// JSON-string-escaped during substitution so backslashes on Windows and
// other special characters don't corrupt the resulting document.
func Load(templatePath, pathsPath string) ([]byte, error) {
	tpl, err := os.ReadFile(templatePath)
	if err != nil {
		return nil, fmt.Errorf("read template %s: %w", templatePath, err)
	}
	pathsData, err := os.ReadFile(pathsPath)
	if err != nil {
		return nil, fmt.Errorf("read paths %s: %w", pathsPath, err)
	}
	paths := splitPaths(string(pathsData))

	var missing []string
	resolved := placeholderRE.ReplaceAllStringFunc(string(tpl), func(match string) string {
		digits := match[len("<<RTF_PATH_") : len(match)-len(">>")]
		n, err := strconv.Atoi(digits)
		if err != nil || n < 0 || n >= len(paths) {
			missing = append(missing, match)
			return match
		}
		return jsonStringEscape(paths[n])
	})
	if len(missing) > 0 {
		return nil, fmt.Errorf("template %s references undefined placeholders %v (paths file has %d entries)", templatePath, missing, len(paths))
	}
	return []byte(resolved), nil
}

// LoadInto is Load + json.Unmarshal into dst.
func LoadInto(templatePath, pathsPath string, dst interface{}) error {
	data, err := Load(templatePath, pathsPath)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, dst); err != nil {
		return fmt.Errorf("unmarshal resolved args from %s: %w", templatePath, err)
	}
	return nil
}

func splitPaths(s string) []string {
	// Trim exactly one trailing newline (multiline param files end with
	// one) but preserve any intentional blank line internally.
	s = strings.TrimRight(s, "\n")
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

// jsonStringEscape returns the JSON-string form of s WITHOUT surrounding
// quotes. Used to substitute into an existing `"…"` context in the
// template where the placeholder already sits between the JSON quotes.
func jsonStringEscape(s string) string {
	encoded, err := json.Marshal(s)
	if err != nil {
		// json.Marshal of a string can only fail on invalid UTF-8, and
		// even then it substitutes replacement runes. Practically
		// unreachable; fall back to the raw string.
		return s
	}
	return string(encoded[1 : len(encoded)-1])
}
