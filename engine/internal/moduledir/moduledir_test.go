package moduledir

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func envValue(env []string, key string) (string, bool) {
	for _, kv := range env {
		if strings.HasPrefix(kv, key+"=") {
			return kv[len(key)+1:], true
		}
	}
	return "", false
}

func TestHermeticEnvReplacesOperatorConfig(t *testing.T) {
	in := []string{
		"PATH=/usr/bin",
		"TF_CLI_CONFIG_FILE=/home/someone/.terraformrc",
		"TF_PLUGIN_CACHE_DIR=/home/someone/.terraform.d/plugin-cache",
		"CHECKPOINT_DISABLE=",
		"AWS_PROFILE=dev",
	}
	env, cleanup, err := HermeticEnv(in)
	if err != nil {
		t.Fatalf("HermeticEnv: %v", err)
	}
	defer cleanup()

	if v, ok := envValue(env, "PATH"); !ok || v != "/usr/bin" {
		t.Errorf("PATH not preserved: %v", env)
	}
	if v, ok := envValue(env, "AWS_PROFILE"); !ok || v != "dev" {
		t.Errorf("unrelated variables must pass through: %v", env)
	}
	if _, ok := envValue(env, "TF_PLUGIN_CACHE_DIR"); ok {
		t.Errorf("TF_PLUGIN_CACHE_DIR must be dropped: %v", env)
	}
	if v, _ := envValue(env, "CHECKPOINT_DISABLE"); v != "1" {
		t.Errorf("CHECKPOINT_DISABLE = %q, want 1", v)
	}
	if v, _ := envValue(env, "TF_IN_AUTOMATION"); v != "1" {
		t.Errorf("TF_IN_AUTOMATION = %q, want 1", v)
	}

	rc, ok := envValue(env, "TF_CLI_CONFIG_FILE")
	if !ok || rc == "/home/someone/.terraformrc" {
		t.Fatalf("TF_CLI_CONFIG_FILE must point at a fresh file, got %q", rc)
	}
	data, err := os.ReadFile(rc)
	if err != nil {
		t.Fatalf("the CLI config the engine is pointed at must exist: %v", err)
	}
	if len(data) != 0 {
		t.Errorf("CLI config must be empty, got %q", data)
	}

	cleanup()
	if _, err := os.Stat(rc); !os.IsNotExist(err) {
		t.Errorf("cleanup must remove the CLI config, stat err = %v", err)
	}
}

func TestLocalStateFiles(t *testing.T) {
	dir := t.TempDir()
	if got := LocalStateFiles(dir); len(got) != 0 {
		t.Fatalf("empty dir reported state: %v", got)
	}

	state := filepath.Join(dir, "terraform.tfstate")
	if err := os.WriteFile(state, []byte("{}"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "terraform.tfstate.d"), 0755); err != nil {
		t.Fatal(err)
	}
	got := LocalStateFiles(dir)
	if len(got) != 2 || got[0] != state {
		t.Errorf("LocalStateFiles = %v, want state file then workspace dir", got)
	}
}
