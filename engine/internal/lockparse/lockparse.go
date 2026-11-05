// Package lockparse reads Terraform's `.terraform.lock.hcl` provider lock
// file.
//
// The parser is lenient: it extracts the fields rules_terraform needs
// (source, registry host, version, and the recorded hashes) and ignores
// everything else. It does not validate hashes.
package lockparse

import (
	"fmt"
	"os"
	"regexp"
	"strings"
)

// ProviderEntry is one `provider "..." {}` block from .terraform.lock.hcl.
type ProviderEntry struct {
	// Source is the fully-qualified provider source without the registry
	// prefix — "hashicorp/null", "carlpett/sops", etc.
	Source string
	// RegistryHost is the registry hostname the lock file declares this
	// provider under: "registry.terraform.io", "registry.opentofu.org", etc.
	// Terraform and OpenTofu key providers into `.terraform/providers/<host>/`
	// by this hostname, so the install path must match.
	RegistryHost string
	Version      string
	Constraints  string
	// H1Hashes are `h1:...` entries (PackageHashV1 — SHA256 over the
	// unpacked provider directory contents).
	H1Hashes []string
	// ZhHashes are `zh:...` entries (SHA256 hex over the release archive,
	// one per platform).
	ZhHashes []string
}

var (
	providerBlockRE = regexp.MustCompile(`^\s*provider\s+"([^"]+)"\s*\{`)
	versionRE       = regexp.MustCompile(`^\s*version\s*=\s*"([^"]+)"`)
	constraintsRE   = regexp.MustCompile(`^\s*constraints\s*=\s*"([^"]+)"`)
	registryHostRE  = regexp.MustCompile(`^(registry\.[^/]+)/`)
	hashRE          = regexp.MustCompile(`"((?:h1|zh):[^"]+)"`)
)

// ReadProviderLock parses a .terraform.lock.hcl file. Missing → empty slice.
func ReadProviderLock(path string) ([]ProviderEntry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read %s: %w", path, err)
	}

	var out []ProviderEntry
	var current *ProviderEntry
	depth := 0

	for _, line := range strings.Split(string(data), "\n") {
		if current == nil {
			if m := providerBlockRE.FindStringSubmatch(line); m != nil {
				raw := m[1]
				host := "registry.terraform.io"
				if hm := registryHostRE.FindStringSubmatch(raw); hm != nil {
					host = hm[1]
					raw = raw[len(hm[0]):]
				}
				current = &ProviderEntry{Source: raw, RegistryHost: host}
				depth = 1
			}
			continue
		}
		if m := versionRE.FindStringSubmatch(line); m != nil {
			current.Version = m[1]
		} else if m := constraintsRE.FindStringSubmatch(line); m != nil {
			current.Constraints = m[1]
		}
		for _, m := range hashRE.FindAllStringSubmatch(line, -1) {
			if strings.HasPrefix(m[1], "h1:") {
				current.H1Hashes = append(current.H1Hashes, m[1])
			} else if strings.HasPrefix(m[1], "zh:") {
				current.ZhHashes = append(current.ZhHashes, m[1])
			}
		}
		depth += strings.Count(line, "{") - strings.Count(line, "}")
		if depth <= 0 {
			out = append(out, *current)
			current = nil
			depth = 0
		}
	}

	return out, nil
}

// AddH1Hash returns content with hash added to the `hashes` list of the
// provider block for address (`<host>/<namespace>/<name>`), or content
// unchanged when the hash is already recorded. The line goes in sorted
// position among the block's `h1:` entries, which is where `terraform
// providers lock` would put it, and everything else in the file is kept
// byte for byte. The second result reports whether anything was added.
func AddH1Hash(content []byte, address, hash string) ([]byte, bool, error) {
	lines := strings.Split(string(content), "\n")
	inBlock := false
	inHashes := false
	indent := "    "
	for i, line := range lines {
		if !inBlock {
			if m := providerBlockRE.FindStringSubmatch(line); m != nil && m[1] == address {
				inBlock = true
			}
			continue
		}
		trimmed := strings.TrimSpace(line)
		if !inHashes {
			if strings.HasPrefix(trimmed, "hashes") && strings.HasSuffix(trimmed, "[") {
				inHashes = true
			} else if trimmed == "}" {
				return nil, false, fmt.Errorf("provider %q has no hashes list", address)
			}
			continue
		}
		if strings.Contains(line, "\""+hash+"\"") {
			return content, false, nil
		}
		isH1 := strings.Contains(line, "\"h1:")
		if isH1 {
			indent = line[:len(line)-len(strings.TrimLeft(line, " \t"))]
		}
		// Insert before the first entry that sorts after it, before the
		// first `zh:` entry, or before the closing bracket.
		if (isH1 && strings.TrimSpace(line) > "\""+hash+"\",") || strings.Contains(line, "\"zh:") || strings.HasPrefix(trimmed, "]") {
			if !isH1 && strings.HasPrefix(trimmed, "]") && indent == "    " {
				indent = line[:len(line)-len(strings.TrimLeft(line, " \t"))] + "  "
			}
			out := append([]string{}, lines[:i]...)
			out = append(out, indent+"\""+hash+"\",")
			out = append(out, lines[i:]...)
			return []byte(strings.Join(out, "\n")), true, nil
		}
	}
	return nil, false, fmt.Errorf("provider %q not found in the lock file", address)
}
