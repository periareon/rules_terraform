package providerhash

import (
	"os"
	"path/filepath"
	"testing"
)

// The hash is over sorted slash-form paths and file contents, so the same
// files give the same hash regardless of creation order, and any content
// change moves it.
func TestH1(t *testing.T) {
	write := func(dir string, files map[string]string) {
		for rel, content := range files {
			p := filepath.Join(dir, filepath.FromSlash(rel))
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	a := t.TempDir()
	write(a, map[string]string{"terraform-provider-x_v1.0.0": "bin", "LICENSE": "mit"})
	b := t.TempDir()
	write(b, map[string]string{"LICENSE": "mit", "terraform-provider-x_v1.0.0": "bin"})
	c := t.TempDir()
	write(c, map[string]string{"LICENSE": "mit", "terraform-provider-x_v1.0.0": "bin2"})

	ha, err := H1(a)
	if err != nil {
		t.Fatal(err)
	}
	hb, _ := H1(b)
	hc, _ := H1(c)
	if ha != hb {
		t.Errorf("same files hashed differently: %s vs %s", ha, hb)
	}
	if ha == hc {
		t.Errorf("different contents hashed the same: %s", ha)
	}
	if len(ha) < 10 || ha[:3] != "h1:" {
		t.Errorf("hash %q is not an h1: value", ha)
	}
}
