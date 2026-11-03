package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"strings"
)

// The engines' `test -json` streams are one JSON object per line, each tagged
// with a `type`. The events this converter reads:
//
//	test_abstract  {"<file>": ["<run>", ...]}         every file and run, up front
//	test_run       {path, run, [progress], status}    a run's outcome
//	diagnostic     {severity, summary, detail}         with @testfile / @testrun
//	test_summary   {status, passed, failed, ...}
//
// OpenTofu reports a run once, with `status` set. Terraform reports it twice,
// `progress: starting` and then `progress: complete` with `status`. Both are
// handled by treating any `test_run` event carrying a `status` as final.
type testEvent struct {
	Type     string `json:"type"`
	Message  string `json:"@message"`
	TestFile string `json:"@testfile"`
	TestRun  string `json:"@testrun"`

	TestAbstract map[string][]string `json:"test_abstract"`
	Run          *struct {
		Path   string `json:"path"`
		Run    string `json:"run"`
		Status string `json:"status"`
	} `json:"test_run"`
	Diagnostic *struct {
		Severity string `json:"severity"`
		Summary  string `json:"summary"`
		Detail   string `json:"detail"`
	} `json:"diagnostic"`
}

type junitTestsuites struct {
	XMLName xml.Name         `xml:"testsuites"`
	Suites  []junitTestsuite `xml:"testsuite"`
}

type junitTestsuite struct {
	Name      string          `xml:"name,attr"`
	Tests     int             `xml:"tests,attr"`
	Skipped   int             `xml:"skipped,attr"`
	Failures  int             `xml:"failures,attr"`
	Errors    int             `xml:"errors,attr"`
	Cases     []junitTestcase `xml:"testcase"`
	SystemErr string          `xml:"system-err,omitempty"`
}

type junitTestcase struct {
	Name      string        `xml:"name,attr"`
	Classname string        `xml:"classname,attr"`
	Failure   *junitMessage `xml:"failure,omitempty"`
	Error     *junitMessage `xml:"error,omitempty"`
	Skipped   *junitMessage `xml:"skipped,omitempty"`
}

type junitMessage struct {
	Message string `xml:"message,attr"`
	Body    string `xml:",chardata"`
}

// runResult is one run's outcome as the stream reported it, plus the
// diagnostics addressed to it.
type runResult struct {
	status string
	diags  []string
}

// jsonToJUnit converts an engine `test -json` stream into the JUnit XML
// Terraform's own `-junit-xml` writes: one testsuite per `.tftest.hcl` file,
// one testcase per `run` block. It exists for OpenTofu, which has the JSON
// stream but not the XML flag.
//
// A run listed in `test_abstract` that never reports a status — the engine
// stopped before reaching it, or it was cancelled — is recorded as an error
// rather than dropped, so the suite's count still matches the file.
func jsonToJUnit(stream io.Reader) ([]byte, error) {
	var fileOrder []string
	runOrder := map[string][]string{}
	results := map[string]map[string]*runResult{}
	fileDiags := map[string][]string{}

	ensureRun := func(file, run string) *runResult {
		if _, ok := results[file]; !ok {
			results[file] = map[string]*runResult{}
			fileOrder = append(fileOrder, file)
		}
		r, ok := results[file][run]
		if !ok {
			r = &runResult{}
			results[file][run] = r
			runOrder[file] = append(runOrder[file], run)
		}
		return r
	}

	scanner := bufio.NewScanner(stream)
	scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 || line[0] != '{' {
			continue
		}
		var ev testEvent
		if err := json.Unmarshal(line, &ev); err != nil {
			// Not every line the engine prints is an event; human-readable
			// stragglers are not an error.
			continue
		}
		switch ev.Type {
		case "test_abstract":
			for file, runs := range ev.TestAbstract {
				for _, run := range runs {
					ensureRun(file, run)
				}
			}
		case "test_run":
			if ev.Run == nil || ev.Run.Status == "" {
				continue
			}
			ensureRun(ev.Run.Path, ev.Run.Run).status = ev.Run.Status
		case "diagnostic":
			if ev.Diagnostic == nil || ev.Diagnostic.Severity != "error" {
				continue
			}
			text := ev.Diagnostic.Summary
			if ev.Diagnostic.Detail != "" {
				text += "\n" + ev.Diagnostic.Detail
			}
			switch {
			case ev.TestFile != "" && ev.TestRun != "":
				r := ensureRun(ev.TestFile, ev.TestRun)
				r.diags = append(r.diags, text)
			case ev.TestFile != "":
				fileDiags[ev.TestFile] = append(fileDiags[ev.TestFile], text)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("reading test event stream: %w", err)
	}

	// test_abstract is a map, so the order files were discovered in is not the
	// engine's order. Sort for a stable report.
	sortStrings(fileOrder)

	var out junitTestsuites
	for _, file := range fileOrder {
		suite := junitTestsuite{Name: file, SystemErr: strings.Join(fileDiags[file], "\n\n")}
		runs := runOrder[file]
		sortStrings(runs)
		for _, run := range runs {
			r := results[file][run]
			tc := junitTestcase{Name: run, Classname: file}
			body := strings.Join(r.diags, "\n\n")
			switch r.status {
			case "pass":
			case "fail":
				suite.Failures++
				tc.Failure = &junitMessage{Message: firstLine(body, "assertion failed"), Body: body}
			case "skip":
				suite.Skipped++
				tc.Skipped = &junitMessage{Message: "skipped"}
			case "error":
				suite.Errors++
				tc.Error = &junitMessage{Message: firstLine(body, "run errored"), Body: body}
			default:
				suite.Errors++
				tc.Error = &junitMessage{
					Message: "run did not complete",
					Body:    strings.TrimSpace("The engine reported no result for this run; it was cancelled or an earlier run stopped the file.\n\n" + body),
				}
			}
			suite.Tests++
			suite.Cases = append(suite.Cases, tc)
		}
		out.Suites = append(out.Suites, suite)
	}

	data, err := xml.MarshalIndent(out, "", "  ")
	if err != nil {
		return nil, err
	}
	return append([]byte(xml.Header), data...), nil
}

func firstLine(s, fallback string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return fallback
	}
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j-1] > s[j]; j-- {
			s[j-1], s[j] = s[j], s[j-1]
		}
	}
}
