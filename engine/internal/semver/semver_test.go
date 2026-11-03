package semver

import "testing"

func mustParse(t *testing.T, s string) Version {
	t.Helper()
	v, ok := Parse(s)
	if !ok {
		t.Fatalf("Parse(%q) failed", s)
	}
	return v
}

func TestParseAcceptsShortAndDecoratedForms(t *testing.T) {
	for _, tc := range []struct {
		in                  string
		major, minor, patch int
		pre                 string
	}{
		{"1", 1, 0, 0, ""},
		{"1.2", 1, 2, 0, ""},
		{"1.2.3", 1, 2, 3, ""},
		{"v1.2.3", 1, 2, 3, ""},
		{"1.2.3-rc.1", 1, 2, 3, "rc.1"},
		{"1.2.3+build.5", 1, 2, 3, ""},
		{"1.2.3-rc.1+build.5", 1, 2, 3, "rc.1"},
	} {
		v := mustParse(t, tc.in)
		if v.Major != tc.major || v.Minor != tc.minor || v.Patch != tc.patch || v.Prerelease != tc.pre {
			t.Errorf("Parse(%q) = %d.%d.%d-%q, want %d.%d.%d-%q",
				tc.in, v.Major, v.Minor, v.Patch, v.Prerelease, tc.major, tc.minor, tc.patch, tc.pre)
		}
		if v.Original != tc.in {
			t.Errorf("Parse(%q).Original = %q", tc.in, v.Original)
		}
	}
}

func TestParseRejectsNonVersions(t *testing.T) {
	for _, in := range []string{"", "x", "1.x", "1.2.3.4", "-1.0.0", "1..2", "latest"} {
		if v, ok := Parse(in); ok {
			t.Errorf("Parse(%q) accepted as %+v", in, v)
		}
	}
}

func TestCompareOrdersPrereleaseBelowRelease(t *testing.T) {
	for _, tc := range []struct {
		a, b string
		want int
	}{
		{"1.0.0", "1.0.1", -1},
		{"1.1.0", "1.0.9", 1},
		{"2.0.0", "2.0.0", 0},
		{"1.0.0-rc.1", "1.0.0", -1},
		{"1.0.0-rc.1", "1.0.0-rc.2", -1},
		{"1.0.0-rc.2", "1.0.0-rc.10", -1},
		{"1.0.0-alpha", "1.0.0-alpha.1", -1},
		{"1.0.0-1", "1.0.0-alpha", -1},
	} {
		if got := Compare(mustParse(t, tc.a), mustParse(t, tc.b)); got != tc.want {
			t.Errorf("Compare(%q, %q) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
	}
}

func TestCheckAppliesEveryClause(t *testing.T) {
	for _, tc := range []struct {
		constraint string
		version    string
		want       bool
	}{
		{"", "9.9.9", true},
		{"1.2.3", "1.2.3", true},
		{"= 1.2.3", "1.2.4", false},
		{"!= 1.2.3", "1.2.4", true},
		{">= 1.0, < 2.0", "1.9.9", true},
		{">= 1.0, < 2.0", "2.0.0", false},
		{">= 1.0, < 2.0", "0.9.0", false},

		// `~>` moves the rightmost written segment, so the segment count in
		// the written constraint decides the ceiling.
		{"~> 5.0", "5.9.9", true},
		{"~> 5.0", "6.0.0", false},
		{"~> 5.0", "4.9.9", false},
		{"~> 5.1.0", "5.1.9", true},
		{"~> 5.1.0", "5.2.0", false},
		{"~> 5", "5.9.9", true},
		{"~> 5", "6.0.0", true},
	} {
		cs, ok := ParseConstraints(tc.constraint)
		if !ok {
			t.Fatalf("ParseConstraints(%q) failed", tc.constraint)
		}
		if got := Check(cs, mustParse(t, tc.version)); got != tc.want {
			t.Errorf("Check(%q, %q) = %v, want %v", tc.constraint, tc.version, got, tc.want)
		}
	}
}

func TestParseConstraintsRejectsGarbage(t *testing.T) {
	for _, in := range []string{">= banana", "~>", "1.2.3 || 2.0.0"} {
		if cs, ok := ParseConstraints(in); ok {
			t.Errorf("ParseConstraints(%q) accepted as %+v", in, cs)
		}
	}
}

func TestHighestMatchingPrefersStable(t *testing.T) {
	versions := []Version{
		mustParse(t, "1.0.0"),
		mustParse(t, "1.2.0"),
		mustParse(t, "1.3.0-rc.1"),
		mustParse(t, "2.0.0"),
	}

	cs, _ := ParseConstraints("~> 1.0")
	got, ok := HighestMatching(versions, cs)
	if !ok || got.Original != "1.2.0" {
		t.Errorf("HighestMatching(~> 1.0) = %q (%v), want 1.2.0", got.Original, ok)
	}

	// Only a prerelease qualifies, so the stable-first preference has nothing
	// to prefer and the prerelease is returned rather than nothing.
	cs, _ = ParseConstraints("> 1.2.0, < 2.0.0")
	got, ok = HighestMatching(versions, cs)
	if !ok || got.Original != "1.3.0-rc.1" {
		t.Errorf("HighestMatching(> 1.2.0, < 2.0.0) = %q (%v), want 1.3.0-rc.1", got.Original, ok)
	}

	cs, _ = ParseConstraints(">= 3.0")
	if got, ok := HighestMatching(versions, cs); ok {
		t.Errorf("HighestMatching(>= 3.0) = %q, want no match", got.Original)
	}
}
