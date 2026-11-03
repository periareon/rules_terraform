package main

import (
	"encoding/xml"
	"strings"
	"testing"
)

const tofuStream = `{"@level":"info","@message":"OpenTofu 1.12.5","type":"version"}
{"@level":"info","@message":"Found 2 files","test_abstract":{"b.tftest.hcl":["only"],"a.tftest.hcl":["good","bad","never_reached"]},"type":"test_abstract"}
{"@level":"info","@message":"a.tftest.hcl... fail","@testfile":"a.tftest.hcl","test_file":{"path":"a.tftest.hcl","status":"fail"},"type":"test_file"}
{"@level":"info","@message":"  \"good\"... pass","@testfile":"a.tftest.hcl","@testrun":"good","test_run":{"path":"a.tftest.hcl","run":"good","status":"pass"},"type":"test_run"}
{"@level":"error","@message":"Error: Test assertion failed","@testfile":"a.tftest.hcl","@testrun":"bad","diagnostic":{"severity":"error","summary":"Test assertion failed","detail":"name did not flow through"},"type":"diagnostic"}
{"@level":"info","@message":"  \"bad\"... fail","@testfile":"a.tftest.hcl","@testrun":"bad","test_run":{"path":"a.tftest.hcl","run":"bad","status":"fail"},"type":"test_run"}
{"@level":"error","@message":"Error: file problem","@testfile":"a.tftest.hcl","diagnostic":{"severity":"error","summary":"file problem","detail":""},"type":"diagnostic"}
{"@level":"info","@message":"  \"only\"... pass","@testfile":"b.tftest.hcl","@testrun":"only","test_run":{"path":"b.tftest.hcl","run":"only","progress":"complete","status":"pass"},"type":"test_run"}
{"@level":"info","@message":"Failure! 2 passed, 1 failed.","test_summary":{"status":"fail","passed":2,"failed":1,"errored":0,"skipped":0},"type":"test_summary"}
`

func TestJSONToJUnit(t *testing.T) {
	data, err := jsonToJUnit(strings.NewReader(tofuStream))
	if err != nil {
		t.Fatalf("jsonToJUnit: %v", err)
	}
	if !strings.HasPrefix(string(data), xml.Header) {
		t.Errorf("missing XML header: %q", data[:40])
	}

	var got junitTestsuites
	if err := xml.Unmarshal(data, &got); err != nil {
		t.Fatalf("output is not valid XML: %v\n%s", err, data)
	}
	if len(got.Suites) != 2 {
		t.Fatalf("suites = %d, want 2\n%s", len(got.Suites), data)
	}

	a := got.Suites[0]
	if a.Name != "a.tftest.hcl" || a.Tests != 3 || a.Failures != 1 || a.Errors != 1 || a.Skipped != 0 {
		t.Errorf("suite a = %+v", a)
	}
	byName := map[string]junitTestcase{}
	for _, c := range a.Cases {
		byName[c.Name] = c
	}
	if c := byName["good"]; c.Failure != nil || c.Error != nil {
		t.Errorf("good must pass: %+v", c)
	}
	if c := byName["bad"]; c.Failure == nil || c.Failure.Message != "Test assertion failed" || !strings.Contains(c.Failure.Body, "name did not flow through") {
		t.Errorf("bad must fail with the diagnostic: %+v", c)
	}
	if c := byName["never_reached"]; c.Error == nil || c.Error.Message != "run did not complete" {
		t.Errorf("an abstracted run with no result must be an error: %+v", c)
	}
	if !strings.Contains(a.SystemErr, "file problem") {
		t.Errorf("file-level diagnostics belong on the suite: %q", a.SystemErr)
	}

	b := got.Suites[1]
	if b.Name != "b.tftest.hcl" || b.Tests != 1 || b.Failures != 0 || b.Errors != 0 {
		t.Errorf("suite b = %+v", b)
	}
}

func TestJSONToJUnitIgnoresNonEventLines(t *testing.T) {
	data, err := jsonToJUnit(strings.NewReader("not json\n\n{\"type\":\"test_summary\"}\n"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "<testsuites>") {
		t.Errorf("expected an empty testsuites document, got %s", data)
	}
}

func TestMutatesState(t *testing.T) {
	cases := []struct {
		args []string
		want bool
	}{
		{[]string{"apply"}, true},
		{[]string{"apply", "-auto-approve"}, true},
		{[]string{"-chdir=x", "destroy"}, true},
		{[]string{"import", "a.b", "id"}, true},
		{[]string{"taint", "a.b"}, true},
		{[]string{"refresh"}, true},
		{[]string{"state", "rm", "a.b"}, true},
		{[]string{"state", "mv", "a", "b"}, true},
		{[]string{"state", "push", "x"}, true},
		{[]string{"state", "list"}, false},
		{[]string{"state", "show", "a.b"}, false},
		{[]string{"plan"}, false},
		{[]string{"plan", "-out=x"}, false},
		{[]string{"show"}, false},
		{[]string{"output"}, false},
		{[]string{"validate"}, false},
		{[]string{"--help"}, false},
	}
	for _, tc := range cases {
		if got := mutatesState(tc.args); got != tc.want {
			t.Errorf("mutatesState(%q) = %v, want %v", tc.args, got, tc.want)
		}
	}
}

func TestProbeTestFlags(t *testing.T) {
	help := "Options:\n  -json  machine readable\n  -junit-xml=path  Saves a test report\n  -json-into=out.json  same as -json\n"
	got := parseTestHelp(help)
	if !got.junitXML || !got.jsonInto {
		t.Errorf("parseTestHelp = %+v, want both true", got)
	}
	got = parseTestHelp("  -json  machine readable\n")
	if got.junitXML || got.jsonInto {
		t.Errorf("parseTestHelp = %+v, want both false", got)
	}
}
