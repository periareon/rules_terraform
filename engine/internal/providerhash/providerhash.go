// Package providerhash computes the `h1:` hash of an unpacked provider
// package, the scheme Terraform records in `.terraform.lock.hcl` for a
// package it verified on disk. The init tool uses it to make a staged tree's
// lock match the binaries it installed; the runner uses it to add the host
// platform's hash to a source lock that lacks it.
package providerhash

import (
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
)

// H1 computes the `h1:` hash of a provider directory with the algorithm of
// Terraform's getproviders.PackageHashV1. Paths are normalized to forward
// slashes so hashes computed on Windows and POSIX match, since Terraform's
// canonical form uses `/`.
func H1(providerDir string) (string, error) {
	// Map of forward-slash relpath -> native filesystem path, so we can
	// sort by canonical form but still open files portably.
	type entry struct{ rel, full string }
	var entries []entry

	err := filepath.Walk(providerDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(providerDir, path)
		if err != nil {
			return err
		}
		entries = append(entries, entry{rel: filepath.ToSlash(rel), full: path})
		return nil
	})
	if err != nil {
		return "", fmt.Errorf("failed to walk provider directory: %w", err)
	}

	sort.Slice(entries, func(i, j int) bool { return entries[i].rel < entries[j].rel })

	h := sha256.New()
	for _, e := range entries {
		f, err := os.Open(e.full)
		if err != nil {
			return "", fmt.Errorf("failed to open %s: %w", e.full, err)
		}
		fileHash := sha256.New()
		if _, err := io.Copy(fileHash, f); err != nil {
			f.Close()
			return "", fmt.Errorf("failed to hash %s: %w", e.full, err)
		}
		f.Close()
		fmt.Fprintf(h, "%x  %s\n", fileHash.Sum(nil), e.rel)
	}

	return "h1:" + base64.StdEncoding.EncodeToString(h.Sum(nil)), nil
}
