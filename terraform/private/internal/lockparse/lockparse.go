// Package lockparse reads the two lock file formats rules_terraform cares about:
//
//   - terraform_modules.lock.json — our own JSON format for external registry
//     modules
//   - .terraform.lock.hcl — Terraform's on-disk provider lock file
//
// Both parsers are lenient: they extract the fields we need for drift checks
// (source + version) and ignore everything else. They do not validate hashes.
package lockparse

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
)

// ModuleEntry is one row from terraform_modules.lock.json.
type ModuleEntry struct {
	Key       string
	Source    string
	Version   string
	URL       string
	Integrity string
	Subdir    string
}

type modulesLockDoc struct {
	Modules map[string]struct {
		Source    string `json:"source"`
		Version   string `json:"version"`
		URL       string `json:"url"`
		Integrity string `json:"integrity"`
		Subdir    string `json:"subdir,omitempty"`
	} `json:"modules"`
}

// ReadModulesLock parses a terraform_modules.lock.json file. A missing file
// yields an empty slice, no error, so drift tests can treat "no lock" as
// "no locked entries" and let the .tf source contents drive the decision.
func ReadModulesLock(path string) ([]ModuleEntry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var doc modulesLockDoc
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	out := make([]ModuleEntry, 0, len(doc.Modules))
	for key, info := range doc.Modules {
		out = append(out, ModuleEntry{
			Key:       key,
			Source:    info.Source,
			Version:   info.Version,
			URL:       info.URL,
			Integrity: info.Integrity,
			Subdir:    info.Subdir,
		})
	}
	return out, nil
}

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
