package fsutil

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// Bazel hands the engine a read-only action output, and the engine writes into
// its working directory — `terraform test` rewrites `.terraform.lock.hcl` as
// part of the implicit init. POSIX hides the problem, because replacing a file
// only needs a writable parent; on Windows it fails with "Access is denied".
// Assert on the mode so the check holds on the platform that can't reproduce
// the failure.
func TestCopyDirectoryMakesReadOnlyFilesWritable(t *testing.T) {
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, ".terraform.lock.hcl"), []byte("# lock\n"), 0444); err != nil {
		t.Fatalf("write: %v", err)
	}
	nested := filepath.Join(src, ".terraform", "providers")
	if err := os.MkdirAll(nested, 0755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(nested, "terraform-provider-null"), []byte("binary"), 0555); err != nil {
		t.Fatalf("write: %v", err)
	}

	dst := filepath.Join(t.TempDir(), "module")
	if err := CopyDirectory(src, dst); err != nil {
		t.Fatalf("CopyDirectory: %v", err)
	}

	lock := filepath.Join(dst, ".terraform.lock.hcl")
	info, err := os.Stat(lock)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode().Perm()&0200 == 0 {
		t.Errorf("copied lock file has mode %v, want owner-writable", info.Mode().Perm())
	}

	// The engine replaces the lock rather than writing in place, which is the
	// operation Windows rejects.
	if err := os.WriteFile(lock, []byte("# rewritten\n"), 0644); err != nil {
		t.Errorf("rewriting the copied lock file failed: %v", err)
	}

	// Making files writable must not cost provider binaries their exec bit.
	provider, err := os.Stat(filepath.Join(dst, ".terraform", "providers", "terraform-provider-null"))
	if err != nil {
		t.Fatalf("stat provider: %v", err)
	}
	if provider.Mode().Perm()&0200 == 0 {
		t.Errorf("copied provider has mode %v, want owner-writable", provider.Mode().Perm())
	}
	// Skipped on Windows, where there is no exec bit to preserve: Go
	// synthesizes 0666/0444 from the read-only attribute, and whether a file
	// runs is decided by its extension. Asserting it there would only pin the
	// synthesized value.
	if runtime.GOOS != "windows" && provider.Mode().Perm()&0100 == 0 {
		t.Errorf("copied provider has mode %v, want owner-executable", provider.Mode().Perm())
	}
}
