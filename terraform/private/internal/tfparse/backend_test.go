package tfparse

import (
	"os"
	"path/filepath"
	"testing"
)

func writeDir(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestHasBackend(t *testing.T) {
	cases := []struct {
		name  string
		files map[string]string
		want  bool
	}{
		{"no terraform block", map[string]string{"main.tf": "resource \"null_resource\" \"x\" {}\n"}, false},
		{"terraform block without backend", map[string]string{"main.tf": "terraform {\n  required_version = \">= 1.0\"\n}\n"}, false},
		{"s3 backend", map[string]string{"main.tf": "terraform {\n  backend \"s3\" {\n    bucket = \"b\"\n  }\n}\n"}, true},
		{"cloud block", map[string]string{"main.tf": "terraform {\n  cloud {\n    organization = \"o\"\n  }\n}\n"}, true},
		{"backend in a second file", map[string]string{
			"main.tf":    "resource \"null_resource\" \"x\" {}\n",
			"backend.tf": "terraform {\n  backend \"gcs\" {}\n}\n",
		}, true},
		{"backend in .tofu file", map[string]string{"main.tofu": "terraform {\n  backend \"local\" {}\n}\n"}, true},
		{"commented out with hash", map[string]string{"main.tf": "terraform {\n  # backend \"s3\" {}\n}\n"}, false},
		{"commented out with slashes", map[string]string{"main.tf": "terraform {\n  // backend \"s3\" {}\n}\n"}, false},
		{"commented out in a block comment", map[string]string{"main.tf": "terraform {\n  /*\n  backend \"s3\" {\n    bucket = \"b\"\n  }\n  */\n}\n"}, false},
		{"hash inside a string does not hide the block", map[string]string{"main.tf": "terraform {\n  required_version = \"# not a comment\"\n  backend \"s3\" {}\n}\n"}, true},
		{"backend outside terraform block is not one", map[string]string{"main.tf": "backend \"s3\" {}\n"}, false},
		{"backend in a nested module directory is ignored", map[string]string{"main.tf": "terraform {}\n"}, false},
		{"json object form", map[string]string{"main.tf.json": `{"terraform": {"backend": {"s3": {"bucket": "b"}}}}`}, true},
		{"json list form with cloud", map[string]string{"main.tf.json": `{"terraform": [{"required_version": ">= 1.0"}, {"cloud": {"organization": "o"}}]}`}, true},
		{"json without backend", map[string]string{"main.tf.json": `{"terraform": {"required_version": ">= 1.0"}}`}, false},
		{"malformed json counts as none", map[string]string{"main.tf.json": `{"terraform": `}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := writeDir(t, tc.files)
			if tc.name == "backend in a nested module directory is ignored" {
				child := filepath.Join(dir, "modules", "x")
				if err := os.MkdirAll(child, 0755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(child, "main.tf"), []byte("terraform {\n  backend \"s3\" {}\n}\n"), 0644); err != nil {
					t.Fatal(err)
				}
			}
			if got := HasBackend(dir); got != tc.want {
				t.Errorf("HasBackend = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestHasBackendMissingDir(t *testing.T) {
	if HasBackend(filepath.Join(t.TempDir(), "nope")) {
		t.Error("a missing directory must count as having no backend")
	}
}
