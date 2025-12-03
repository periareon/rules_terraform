// Package tfparse extracts Terraform module block metadata from .tf source
// files using a small line-oriented scanner. It handles the subset needed by
// rules_terraform's build-time tooling: enough to enumerate `module "name" {}`
// blocks and pull out their `source` and (optional) `version` attributes.
//
// This avoids a dependency on hashicorp/hcl for tools that only need to know
// what modules a Terraform file declares.
package tfparse

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// ModuleBlock is a single `module "..." {}` declaration extracted from a .tf file.
type ModuleBlock struct {
	Key     string
	Source  string
	Version string
}

var (
	moduleBlockRE            = regexp.MustCompile(`^\s*module\s+"([^"]+)"\s*\{`)
	sourceAttrRE             = regexp.MustCompile(`^\s*source\s*=\s*"([^"]+)"`)
	versionAttrRE            = regexp.MustCompile(`^\s*version\s*=\s*"([^"]+)"`)
	requiredProvidersBlockRE = regexp.MustCompile(`^\s*required_providers\s*\{`)
	providerLabelRE          = regexp.MustCompile(`^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*\{`)
)

// ParseFile scans a single .tf file for module blocks.
func ParseFile(path string) ([]ModuleBlock, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()

	var out []ModuleBlock
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)

	var current *ModuleBlock
	depth := 0

	for scanner.Scan() {
		line := scanner.Text()

		if current == nil {
			if m := moduleBlockRE.FindStringSubmatch(line); m != nil {
				current = &ModuleBlock{Key: m[1]}
				depth = 1
			}
			continue
		}

		if depth == 1 {
			if m := sourceAttrRE.FindStringSubmatch(line); m != nil {
				current.Source = m[1]
			} else if m := versionAttrRE.FindStringSubmatch(line); m != nil {
				current.Version = m[1]
			}
		}

		depth += strings.Count(line, "{") - strings.Count(line, "}")
		if depth <= 0 {
			out = append(out, *current)
			current = nil
			depth = 0
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan %s: %w", path, err)
	}
	return out, nil
}

// ParseDir scans every .tf file directly under dir (non-recursive) for module blocks.
func ParseDir(dir string) ([]ModuleBlock, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read dir %s: %w", dir, err)
	}

	var out []ModuleBlock
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".tf") {
			continue
		}
		blocks, err := ParseFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			return nil, err
		}
		out = append(out, blocks...)
	}
	return out, nil
}

// ParseFiles scans an explicit list of .tf files for module blocks.
func ParseFiles(paths []string) ([]ModuleBlock, error) {
	var out []ModuleBlock
	for _, p := range paths {
		blocks, err := ParseFile(p)
		if err != nil {
			return nil, err
		}
		out = append(out, blocks...)
	}
	return out, nil
}

// RequiredProvider is one entry from a `terraform { required_providers { ... } }` block.
type RequiredProvider struct {
	// Label is the local name Terraform will use for the provider ("aws").
	Label string
	// Source is the fully-qualified provider source ("hashicorp/aws"). May be
	// empty if the block only declared a version and let Terraform infer the source.
	Source string
	// Version is the constraint string ("~> 5.0"). May be empty.
	Version string
}

// ParseRequiredProvidersFromFiles collects every provider declared in a
// `terraform { required_providers { ... } }` block across the given files.
// Duplicate entries (same label declared in multiple files) are returned
// once, with the first-seen source/version.
func ParseRequiredProvidersFromFiles(paths []string) ([]RequiredProvider, error) {
	seen := map[string]bool{}
	var out []RequiredProvider

	for _, path := range paths {
		providers, err := parseRequiredProvidersFile(path)
		if err != nil {
			return nil, err
		}
		for _, p := range providers {
			if seen[p.Label] {
				continue
			}
			seen[p.Label] = true
			out = append(out, p)
		}
	}

	return out, nil
}

func parseRequiredProvidersFile(path string) ([]RequiredProvider, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()

	var out []RequiredProvider

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)

	// State machine:
	//   0: scanning for `terraform {` or `required_providers {`
	//   1: inside `required_providers { }`
	//   2: inside a per-provider `<label> { }` block
	state := 0
	blockDepth := 0
	var currentLabel string
	var currentSource, currentVersion string

	for scanner.Scan() {
		line := scanner.Text()

		switch state {
		case 0:
			if requiredProvidersBlockRE.MatchString(line) {
				state = 1
				blockDepth = 1
			}
		case 1:
			if m := providerLabelRE.FindStringSubmatch(line); m != nil {
				currentLabel = m[1]
				currentSource = ""
				currentVersion = ""
				state = 2
				blockDepth = 2
				// Fall through to the case-2 handler so `{` and `}` on the
				// SAME line (e.g. `aws = { source = "..." version = "..." }`)
				// get counted and any inline source/version attrs get read.
			} else {
				blockDepth += strings.Count(line, "{") - strings.Count(line, "}")
				if blockDepth <= 0 {
					state = 0
					blockDepth = 0
				}
				break
			}
			fallthrough
		case 2:
			if m := sourceAttrRE.FindStringSubmatch(line); m != nil {
				currentSource = m[1]
			}
			if m := versionAttrRE.FindStringSubmatch(line); m != nil {
				currentVersion = m[1]
			}
			// Same-line label + `{` was already counted (blockDepth = 2 above);
			// only count what's after the label's `{` to avoid double-counting.
			opens := strings.Count(line, "{")
			closes := strings.Count(line, "}")
			if providerLabelRE.MatchString(line) {
				opens--
			}
			blockDepth += opens - closes
			if blockDepth <= 1 {
				out = append(out, RequiredProvider{
					Label:   currentLabel,
					Source:  currentSource,
					Version: currentVersion,
				})
				currentLabel = ""
				state = 1
			}
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan %s: %w", path, err)
	}
	return out, nil
}
