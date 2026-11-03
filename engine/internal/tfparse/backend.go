package tfparse

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var (
	terraformBlockRE = regexp.MustCompile(`^\s*terraform\s*\{`)
	backendBlockRE   = regexp.MustCompile(`^\s*backend\s+"[^"]+"\s*\{`)
	cloudBlockRE     = regexp.MustCompile(`^\s*cloud\s*\{`)
)

// HasBackend reports whether the root module in dir configures somewhere
// durable for its state: a `backend "<type>" {}` or `cloud {}` block inside a
// top-level `terraform {}` block, in any `.tf`, `.tofu`, `.tf.json` or
// `.tofu.json` file directly in dir.
//
// Only the root module's own directory is read. That is the only place the
// engine takes backend configuration from; a backend block in a child module
// is ignored by the engine and so is ignored here.
//
// Native syntax is scanned line by line with comments removed, the same
// approach as the rest of this package: a `backend` block that is commented
// out must not count, since that is exactly the state a module is in while
// someone is still deciding where its state should live. An unreadable file
// counts as having no backend.
func HasBackend(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		path := filepath.Join(dir, name)
		switch {
		case strings.HasSuffix(name, ".tf.json") || strings.HasSuffix(name, ".tofu.json"):
			if jsonHasBackend(path) {
				return true
			}
		case IsConfigFile(name):
			if hclHasBackend(path) {
				return true
			}
		}
	}
	return false
}

func hclHasBackend(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	// Depth within a `terraform {}` block; 0 means outside one.
	depth := 0
	inBlockComment := false
	for _, raw := range strings.Split(string(data), "\n") {
		line, stillIn := stripComments(raw, inBlockComment)
		inBlockComment = stillIn
		if strings.TrimSpace(line) == "" {
			continue
		}
		if depth == 0 {
			if terraformBlockRE.MatchString(line) {
				depth = 1 + strings.Count(line, "{") - 1 - strings.Count(line, "}")
				if depth <= 0 {
					depth = 0
				}
			}
			continue
		}
		if depth == 1 && (backendBlockRE.MatchString(line) || cloudBlockRE.MatchString(line)) {
			return true
		}
		depth += strings.Count(line, "{") - strings.Count(line, "}")
		if depth < 0 {
			depth = 0
		}
	}
	return false
}

// stripComments removes `#`, `//` and `/* */` comments from one line. It
// returns the remaining text and whether a block comment is still open at the
// end of the line. Quoted strings are respected for the line comment markers,
// so a `#` inside a string does not truncate the line.
func stripComments(line string, inBlockComment bool) (string, bool) {
	var out strings.Builder
	inString := false
	for i := 0; i < len(line); i++ {
		c := line[i]
		if inBlockComment {
			if c == '*' && i+1 < len(line) && line[i+1] == '/' {
				inBlockComment = false
				i++
			}
			continue
		}
		if inString {
			out.WriteByte(c)
			if c == '\\' && i+1 < len(line) {
				i++
				out.WriteByte(line[i])
			} else if c == '"' {
				inString = false
			}
			continue
		}
		switch {
		case c == '"':
			inString = true
			out.WriteByte(c)
		case c == '#':
			return out.String(), false
		case c == '/' && i+1 < len(line) && line[i+1] == '/':
			return out.String(), false
		case c == '/' && i+1 < len(line) && line[i+1] == '*':
			inBlockComment = true
			i++
		default:
			out.WriteByte(c)
		}
	}
	return out.String(), inBlockComment
}

// jsonHasBackend reads JSON-syntax configuration. The `terraform` key holds
// either one object or a list of them, and a backend is a `backend` key
// (itself an object keyed by backend type) or a `cloud` key inside.
func jsonHasBackend(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(data, &top); err != nil {
		return false
	}
	raw, ok := top["terraform"]
	if !ok {
		return false
	}
	var blocks []map[string]json.RawMessage
	var single map[string]json.RawMessage
	if err := json.Unmarshal(raw, &single); err == nil {
		blocks = append(blocks, single)
	} else if err := json.Unmarshal(raw, &blocks); err != nil {
		return false
	}
	for _, block := range blocks {
		if _, ok := block["backend"]; ok {
			return true
		}
		if _, ok := block["cloud"]; ok {
			return true
		}
	}
	return false
}
