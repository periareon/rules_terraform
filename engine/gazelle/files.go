package gazelle

import (
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"rules_terraform/engine/internal/tfparse"
)

const lockFileName = ".terraform.lock.hcl"

// isBuildFile reports whether name is a Bazel build file.
func isBuildFile(name string) bool {
	return name == "BUILD" || name == "BUILD.bazel"
}

// isStateFile reports whether name is local backend state, which belongs to
// a run, not to the module.
func isStateFile(name string) bool {
	return strings.HasPrefix(name, "terraform.tfstate")
}

// dataFiles returns the files a module directory holds besides its
// configuration: what a native run of the engine in that directory can
// read through `file()` and friends. Everything that is not a source, a
// build file, the lock, state, or a dotfile, including the contents of
// subdirectories that are not packages of their own. A subdirectory that
// holds a build file or configuration of its own is a package and is left
// alone, as are `.terraform` and the workspace state directory.
func dataFiles(dir string, regular []string, subdirs []string, isSource func(string) bool) []string {
	var out []string
	for _, name := range regular {
		if isSource(name) || isBuildFile(name) || name == lockFileName || isStateFile(name) || strings.HasPrefix(name, ".") {
			continue
		}
		out = append(out, name)
	}
	for _, sub := range subdirs {
		if strings.HasPrefix(sub, ".") || sub == "terraform.tfstate.d" {
			continue
		}
		out = append(out, walkData(dir, sub)...)
	}
	sort.Strings(out)
	return out
}

// walkData lists the files under dir/rel, stopping at any directory that is
// a package in its own right.
func walkData(dir, rel string) []string {
	entries, err := os.ReadDir(filepath.Join(dir, filepath.FromSlash(rel)))
	if err != nil {
		return nil
	}
	for _, e := range entries {
		if !e.IsDir() && (isBuildFile(e.Name()) || tfparse.IsConfigFile(e.Name()) || strings.HasSuffix(e.Name(), ".tf.json") || strings.HasSuffix(e.Name(), ".tofu.json")) {
			return nil
		}
	}
	var out []string
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		if e.IsDir() {
			out = append(out, walkData(dir, path.Join(rel, name))...)
			continue
		}
		if e.Type().IsRegular() && !isStateFile(name) {
			out = append(out, path.Join(rel, name))
		}
	}
	return out
}
