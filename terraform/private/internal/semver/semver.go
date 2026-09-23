// Package semver parses semantic versions and Terraform-style version
// constraints. It covers the operator set Terraform accepts in a `module`
// block's `version` attribute — `=`, `!=`, `>`, `>=`, `<`, `<=`, `~>`, and
// comma-separated conjunctions of those — with SemVer 2.0 §11 prerelease
// ordering.
//
// `//terraform/private:semver.bzl` is a Starlark port of this file, used by
// the bzlmod extension to resolve a constraint against the version list the
// registry returns. Keep the two in step: the extension picks the version and
// the init tool has to agree about which fetched module that constraint named.
//
// No dependency on a third-party semver library, for the same reason tfparse
// avoids hashicorp/hcl: these tools run as build actions and the subset of the
// grammar they need is small.
package semver

import (
	"strconv"
	"strings"
)

// ops are matched in order, so a two-character operator is tested before the
// one-character operator that prefixes it.
var ops = []string{">=", "<=", "~>", "!=", ">", "<", "="}

// Version is a parsed `major.minor.patch[-prerelease]`. Original is the string
// it was parsed from, kept because the registry addresses a module by the exact
// spelling it published (`v1.2.3` and `1.2.3` are both seen) and because the
// `~>` operator needs to know how many segments were written.
type Version struct {
	Major      int
	Minor      int
	Patch      int
	Prerelease string
	Original   string
}

func isNum(s string) (int, bool) {
	if s == "" {
		return 0, false
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 || strings.ContainsAny(s, "+-") {
		return 0, false
	}
	return n, true
}

func cmpInt(a, b int) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	default:
		return 0
	}
}

// compareIdent orders one dot-separated prerelease identifier against another:
// numeric identifiers compare numerically and rank below alphanumeric ones
// (SemVer 2.0 §11.4).
func compareIdent(a, b string) int {
	an, aok := isNum(a)
	bn, bok := isNum(b)
	switch {
	case aok && bok:
		return cmpInt(an, bn)
	case aok:
		return -1
	case bok:
		return 1
	case a < b:
		return -1
	case a > b:
		return 1
	default:
		return 0
	}
}

// comparePre orders two prerelease strings. The empty string is a release,
// which outranks every prerelease of the same major.minor.patch.
func comparePre(a, b string) int {
	if a == b {
		return 0
	}
	if a == "" {
		return 1
	}
	if b == "" {
		return -1
	}
	af := strings.Split(a, ".")
	bf := strings.Split(b, ".")
	limit := len(af)
	if len(bf) < limit {
		limit = len(bf)
	}
	for i := 0; i < limit; i++ {
		if c := compareIdent(af[i], bf[i]); c != 0 {
			return c
		}
	}
	return cmpInt(len(af), len(bf))
}

// Parse reads `major[.minor[.patch]][-prerelease][+build]`, tolerating a
// leading `v`. Build metadata is discarded: SemVer gives it no ordering.
// Returns false rather than an error because every caller's response to a
// malformed version is the same — treat it as no version at all.
func Parse(s string) (Version, bool) {
	original := s
	s = strings.TrimPrefix(s, "v")

	if plus := strings.Index(s, "+"); plus >= 0 {
		s = s[:plus]
	}

	pre := ""
	if dash := strings.Index(s, "-"); dash >= 0 {
		pre = s[dash+1:]
		s = s[:dash]
	}

	parts := strings.Split(s, ".")
	if len(parts) < 1 || len(parts) > 3 {
		return Version{}, false
	}

	nums := [3]int{}
	for i, p := range parts {
		n, ok := isNum(p)
		if !ok {
			return Version{}, false
		}
		nums[i] = n
	}

	return Version{
		Major:      nums[0],
		Minor:      nums[1],
		Patch:      nums[2],
		Prerelease: pre,
		Original:   original,
	}, true
}

// Compare returns -1, 0 or 1 ordering a against b.
func Compare(a, b Version) int {
	if c := cmpInt(a.Major, b.Major); c != 0 {
		return c
	}
	if c := cmpInt(a.Minor, b.Minor); c != 0 {
		return c
	}
	if c := cmpInt(a.Patch, b.Patch); c != 0 {
		return c
	}
	return comparePre(a.Prerelease, b.Prerelease)
}

// Constraint is one clause of a constraint expression, such as `>= 1.2` or the
// bare `1.2.3` that means `= 1.2.3`.
type Constraint struct {
	Op      string
	Version Version
}

func parseOne(raw string) (Constraint, bool) {
	for _, op := range ops {
		if strings.HasPrefix(raw, op) {
			v, ok := Parse(strings.TrimSpace(raw[len(op):]))
			if !ok {
				return Constraint{}, false
			}
			return Constraint{Op: op, Version: v}, true
		}
	}
	v, ok := Parse(raw)
	if !ok {
		return Constraint{}, false
	}
	return Constraint{Op: "=", Version: v}, true
}

// ParseConstraints reads a comma-separated constraint list. An empty string
// yields an empty list, which Check treats as matching anything — that is what
// a `module` block with no `version` attribute means.
func ParseConstraints(s string) ([]Constraint, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, true
	}
	var out []Constraint
	for _, raw := range strings.Split(s, ",") {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		c, ok := parseOne(raw)
		if !ok {
			return nil, false
		}
		out = append(out, c)
	}
	return out, true
}

func checkOne(c Constraint, v Version) bool {
	cmp := Compare(v, c.Version)
	switch c.Op {
	case "=":
		return cmp == 0
	case "!=":
		return cmp != 0
	case ">":
		return cmp > 0
	case ">=":
		return cmp >= 0
	case "<":
		return cmp < 0
	case "<=":
		return cmp <= 0
	case "~>":
		// Pessimistic operator. It allows the rightmost written segment to
		// move, so how many segments were written is the whole question and
		// the parsed struct (always three numbers) cannot answer it — count
		// them in the original text.
		if cmp < 0 {
			return false
		}
		base := strings.TrimPrefix(c.Version.Original, "v")
		base, _, _ = strings.Cut(base, "-")
		switch strings.Count(base, ".") + 1 {
		case 1:
			return true
		case 2:
			return v.Major == c.Version.Major
		default:
			return v.Major == c.Version.Major && v.Minor == c.Version.Minor
		}
	}
	return false
}

// Check reports whether v satisfies every constraint. An empty list matches.
func Check(constraints []Constraint, v Version) bool {
	for _, c := range constraints {
		if !checkOne(c, v) {
			return false
		}
	}
	return true
}

// HighestMatching picks the greatest version satisfying every constraint,
// preferring stable releases and falling back to prereleases only when no
// stable version qualifies. Returns false when nothing matches.
func HighestMatching(versions []Version, constraints []Constraint) (Version, bool) {
	var bestStable, bestPre Version
	haveStable, havePre := false, false
	for _, v := range versions {
		if !Check(constraints, v) {
			continue
		}
		if v.Prerelease != "" {
			if !havePre || Compare(v, bestPre) > 0 {
				bestPre, havePre = v, true
			}
		} else if !haveStable || Compare(v, bestStable) > 0 {
			bestStable, haveStable = v, true
		}
	}
	if haveStable {
		return bestStable, true
	}
	return bestPre, havePre
}
