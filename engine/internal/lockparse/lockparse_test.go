package lockparse

import (
	"strings"
	"testing"
)

const lock = `# This file is maintained automatically by "terraform init".

provider "registry.terraform.io/hashicorp/null" {
  version     = "3.2.4"
  constraints = "3.2.4"
  hashes = [
    "h1:BBBB=",
    "h1:DDDD=",
    "zh:0000",
  ]
}

provider "registry.terraform.io/hashicorp/random" {
  version = "3.6.0"
  hashes = [
    "zh:1111",
  ]
}
`

func TestAddH1Hash(t *testing.T) {
	out, added, err := AddH1Hash([]byte(lock), "registry.terraform.io/hashicorp/null", "h1:CCCC=")
	if err != nil || !added {
		t.Fatalf("AddH1Hash: added=%v err=%v", added, err)
	}
	want := "    \"h1:BBBB=\",\n    \"h1:CCCC=\",\n    \"h1:DDDD=\",\n    \"zh:0000\","
	if !strings.Contains(string(out), want) {
		t.Errorf("hash not inserted in sorted position:\n%s", out)
	}
	if strings.Count(string(out), "\n") != strings.Count(lock, "\n")+1 {
		t.Errorf("more than one line changed:\n%s", out)
	}

	// Already recorded: nothing changes.
	same, added, err := AddH1Hash([]byte(lock), "registry.terraform.io/hashicorp/null", "h1:DDDD=")
	if err != nil || added || string(same) != lock {
		t.Errorf("re-adding an existing hash: added=%v err=%v changed=%v", added, err, string(same) != lock)
	}

	// A block with only zh: entries gets the h1 ahead of them, at their indent.
	out, added, err = AddH1Hash([]byte(lock), "registry.terraform.io/hashicorp/random", "h1:AAAA=")
	if err != nil || !added || !strings.Contains(string(out), "  hashes = [\n    \"h1:AAAA=\",\n    \"zh:1111\",") {
		t.Errorf("zh-only block: added=%v err=%v\n%s", added, err, out)
	}

	// The other block is untouched by a match in one.
	if strings.Contains(string(out), "\"h1:AAAA=\",\n    \"h1:BBBB=") {
		t.Errorf("hash leaked into the wrong block:\n%s", out)
	}

	if _, _, err := AddH1Hash([]byte(lock), "registry.terraform.io/hashicorp/aws", "h1:X="); err == nil {
		t.Error("unknown provider: want an error")
	}
}
