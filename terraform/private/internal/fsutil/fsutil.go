// Package fsutil provides shared file system utilities for Terraform Bazel rules.
package fsutil

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// CopyFile copies a single file from src to dst.
func CopyFile(src, dst string) error {
	srcFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer srcFile.Close()

	dstFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer dstFile.Close()

	if _, err := io.Copy(dstFile, srcFile); err != nil {
		return err
	}

	return nil
}

// CopyDirectory recursively copies a directory from src to dst.
// If dst already exists, it is removed first.
func CopyDirectory(src, dst string) error {
	if _, err := os.Stat(dst); err == nil {
		if err := os.RemoveAll(dst); err != nil {
			return fmt.Errorf("failed to remove existing destination: %w", err)
		}
	}

	if err := os.MkdirAll(dst, 0755); err != nil {
		return fmt.Errorf("failed to create destination directory: %w", err)
	}

	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		relPath, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}

		if relPath == "." {
			return nil
		}

		dstPath := filepath.Join(dst, relPath)

		if info.IsDir() {
			// Always create writable directories, even if the source was
			// read-only (Bazel marks action-output trees 0555 which would
			// block subsequent writes into the copy).
			return os.MkdirAll(dstPath, 0755)
		}

		if err := os.MkdirAll(filepath.Dir(dstPath), 0755); err != nil {
			return err
		}

		if err := CopyFile(path, dstPath); err != nil {
			return err
		}

		// Owner-write on top of the source mode, for the same reason the
		// directories above are forced to 0755: Bazel marks action outputs
		// read-only, and the engine writes into its working directory —
		// `terraform test` rewrites `.terraform.lock.hcl` as part of the
		// implicit init. POSIX lets that through because replacing a file
		// only needs a writable parent directory, so the bug is invisible
		// there; Windows denies replacing a read-only file outright.
		//
		// OR rather than a fixed mode, so provider binaries keep their
		// executable bit.
		return os.Chmod(dstPath, info.Mode()|0200)
	})
}
