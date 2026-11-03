package gazelle

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestDataFiles(t *testing.T) {
	dir := t.TempDir()
	write := func(rel string) {
		p := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, rel := range []string{
		"main.tf", "BUILD.bazel", ".terraform.lock.hcl", "terraform.tfstate", ".terraform-version", "README.md",
		"templates/user-data.yaml.tpl", "templates/nested/values.yaml",
		"child/main.tf", "child/data.json", // its own package once generated
		"pkg/BUILD.bazel", "pkg/file.txt", // already a package
		".terraform/providers/x", "terraform.tfstate.d/dev/terraform.tfstate",
	} {
		write(rel)
	}
	got := dataFiles(dir,
		[]string{"main.tf", "BUILD.bazel", ".terraform.lock.hcl", "terraform.tfstate", ".terraform-version", "README.md"},
		[]string{"templates", "child", "pkg", ".terraform", "terraform.tfstate.d"},
		func(name string) bool { return filepath.Ext(name) == ".tf" })
	want := []string{"README.md", "templates/nested/values.yaml", "templates/user-data.yaml.tpl"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("dataFiles = %v, want %v", got, want)
	}
}

func TestDefaultHub(t *testing.T) {
	if got := defaultHub("iac/terraform/aws/eis-dev"); got != "tf_iac_terraform_aws_eis_dev" {
		t.Errorf("defaultHub = %q", got)
	}
}

func TestIsEngineWorkDir(t *testing.T) {
	for rel, want := range map[string]bool{
		"envs/prod":                         false,
		"envs/prod/.terraform":              true,
		"envs/prod/.terraform/modules/x":    true,
		"envs/prod/terraform.tfstate.d/dev": true,
		"modules/terraform.tfstate.d-ish":   false,
	} {
		if got := isEngineWorkDir(rel); got != want {
			t.Errorf("isEngineWorkDir(%q) = %v, want %v", rel, got, want)
		}
	}
}
