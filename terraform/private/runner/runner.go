package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"rules_terraform/terraform/private/internal/fsutil"
	"rules_terraform/terraform/private/internal/moduledir"
	"rules_terraform/terraform/private/internal/tfparse"
)

// ArgsFile mirrors the JSON `build_runner` writes in //terraform/private:terraform.bzl.
type ArgsFile struct {
	TerraformRlocationPath string `json:"terraform_rlocationpath"`
	// ModuleDirRlocationPath locates the tree artifact `terraform_init_aspect`
	// builds: the module directory, complete with its `.tf` files, local child
	// modules at their `source` paths, `.terraform.lock.hcl`, and a populated
	// `.terraform/`. The runner copies it and runs the engine inside — the
	// layout is settled at analysis time, not reconstructed here.
	ModuleDirRlocationPath string `json:"module_dir_rlocationpath"`

	// AllowEphemeralState is the root module's `allow_ephemeral_state`. With
	// no backend block, state written under `bazel run` lands in StateDir, a
	// directory under bazel-out that `bazel clean` removes; without the opt-in
	// the runner refuses the commands that would write it.
	AllowEphemeralState bool `json:"allow_ephemeral_state"`
	// StateDir is where local state is kept across `bazel run`s when the opt-in
	// is set: workspace-relative, joined with BUILD_WORKSPACE_DIRECTORY.
	StateDir string `json:"state_dir"`

	// Plan configures `terraform_plan_test`; nil for the other modes.
	Plan *PlanArgs `json:"plan,omitempty"`
}

// PlanArgs mirrors the `terraform_plan_test` attributes.
type PlanArgs struct {
	ExpectNoChanges bool     `json:"expect_no_changes"`
	Lock            bool     `json:"lock"`
	Args            []string `json:"args"`
}

// mode is what the rule that produced the runner wants from it, carried in
// RULES_TERRAFORM_MODE. Each is a different contract with Bazel: a binary
// passes argv through, a test rule decides the command itself and reports
// through XML_OUTPUT_FILE and TEST_UNDECLARED_OUTPUTS_DIR.
type mode string

const (
	modeRun  mode = ""
	modeTest mode = "test"
	modePlan mode = "plan"
)

// engine is everything needed to invoke the engine in the staged module
// directory.
type engine struct {
	path    string
	workDir string
	env     []string
}

func main() {
	os.Exit(run())
}

func run() int {
	m := mode(os.Getenv("RULES_TERRAFORM_MODE"))

	argsFilePath := os.Getenv("RULES_TERRAFORM_ARGS_FILE")
	if argsFilePath == "" {
		fmt.Fprintln(os.Stderr, "Error: RULES_TERRAFORM_ARGS_FILE environment variable not set")
		return 1
	}

	r, err := runfiles.New()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: failed to initialize runfiles: %v\n", err)
		return 1
	}

	// The env var carries an rlocationpath; resolve via runfiles so this
	// works in both `bazel run` and `bazel test` contexts.
	argsResolved, err := r.Rlocation(argsFilePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: failed to locate args file %q: %v\n", argsFilePath, err)
		return 1
	}
	argsFile, err := readArgsFile(argsResolved)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: failed to read args file: %v\n", err)
		return 1
	}

	enginePath, err := r.Rlocation(argsFile.TerraformRlocationPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: failed to locate terraform binary: %v\n", err)
		return 1
	}

	workDir, cleanup, err := setupWorkingDirectory(r, argsFile.ModuleDirRlocationPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: failed to setup working directory: %v\n", err)
		return 1
	}
	keep := false
	defer func() {
		if !keep {
			cleanup()
		}
	}()

	// `bazel run` inherits the operator's environment on purpose: credential
	// helpers and the like live in the CLI configuration. A Bazel test is a
	// check, and its outcome must not depend on whose machine it runs on.
	env := os.Environ()
	if m != modeRun {
		hermetic, envCleanup, err := moduledir.HermeticEnv(env)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			return 1
		}
		defer envCleanup()
		env = hermetic
	}

	e := engine{path: enginePath, workDir: workDir, env: env}

	var code int
	switch m {
	case modeTest:
		code = runTest(e)
	case modePlan:
		code = runPlanTest(e, argsFile.Plan)
	default:
		code, keep = runCommand(e, argsFile, os.Args[1:])
	}
	return code
}

func readArgsFile(path string) (*ArgsFile, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var argsFile ArgsFile
	if err := json.Unmarshal(data, &argsFile); err != nil {
		return nil, err
	}

	return &argsFile, nil
}

// setupWorkingDirectory resolves the module directory out of runfiles and
// stages a writable copy of it.
func setupWorkingDirectory(r *runfiles.Runfiles, moduleDirRlocationPath string) (string, func(), error) {
	if moduleDirRlocationPath == "" {
		return "", nil, fmt.Errorf("args file does not name the module directory")
	}

	moduleDirSrc, err := r.Rlocation(moduleDirRlocationPath)
	if err != nil {
		return "", nil, fmt.Errorf("failed to locate module directory %s: %w", moduleDirRlocationPath, err)
	}

	return moduledir.Stage(moduleDirSrc, "terraform-runner-*")
}

// exec runs the engine with args in the staged module directory, streams its
// output, and returns its exit code. A failure to start at all is reported
// as exit code 1 with the error printed.
func (e engine) exec(args ...string) int {
	cmd := exec.Command(e.path, args...)
	cmd.Dir = e.workDir
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = e.env
	return exitCode(cmd.Run())
}

// capture is exec with stdout collected instead of streamed.
func (e engine) capture(args ...string) ([]byte, int) {
	cmd := exec.Command(e.path, args...)
	cmd.Dir = e.workDir
	cmd.Stderr = os.Stderr
	cmd.Env = e.env
	out, err := cmd.Output()
	return out, exitCode(err)
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	fmt.Fprintf(os.Stderr, "Error: %v\n", err)
	return 1
}

// ---- bazel run -------------------------------------------------------------

// runCommand is the `terraform_binary` path: the user's argv goes to the
// engine untouched, after a backend `init` when the command needs one.
//
// The second result is whether the staged directory must survive the run,
// which it must when it holds the only copy of something the user needs.
func runCommand(e engine, argsFile *ArgsFile, userArgs []string) (int, bool) {
	args := userArgs
	if len(args) == 0 {
		// Match `terraform` with no args: print help via the CLI itself.
		args = []string{"--help"}
	}

	// Where state goes when there is no backend is decided before anything
	// runs: refusing after the engine has already written state would be
	// too late.
	hasBackend := tfparse.HasBackend(e.workDir)
	stateDir := ""
	if !hasBackend && mutatesState(args) {
		if !argsFile.AllowEphemeralState {
			fmt.Fprint(os.Stderr, ephemeralStateRefusal(subcommand(args), argsFile.StateDir))
			return 1, false
		}
	}
	if !hasBackend && argsFile.AllowEphemeralState && argsFile.StateDir != "" {
		root := os.Getenv("BUILD_WORKSPACE_DIRECTORY")
		if root == "" {
			fmt.Fprintln(os.Stderr, "Error: BUILD_WORKSPACE_DIRECTORY is not set; local state can only be kept under `bazel run`")
			return 1, false
		}
		stateDir = filepath.Join(root, filepath.FromSlash(argsFile.StateDir))
		if err := restoreLocalState(stateDir, e.workDir); err != nil {
			fmt.Fprintf(os.Stderr, "Error: restoring local state from %s: %v\n", stateDir, err)
			return 1, false
		}
	}

	if needsBackend(args) {
		if code := e.exec("init", "-get=false", "-plugin-dir="+moduledir.ProvidersDir(e.workDir)); code != 0 {
			// Init failures are not the user's command — we own the init
			// call, so nothing in the staged directory is worth keeping.
			return code, false
		}
	}

	code := e.exec(args...)

	if stateDir != "" {
		// Saved whether or not the command succeeded: a failed apply has
		// usually still created something, and the state is the record of it.
		if err := saveLocalState(e.workDir, stateDir); err != nil {
			fmt.Fprintf(os.Stderr, "Error: saving local state to %s: %v\n", stateDir, err)
			return 1, true
		}
		if len(moduledir.LocalStateFiles(e.workDir)) > 0 {
			fmt.Fprintf(os.Stderr, "\nrules_terraform: local state kept at %s (allow_ephemeral_state is set; `bazel clean` removes it).\n", stateDir)
		}
		return code, code != 0
	}

	if code != 0 {
		// Leak the temp dir on failure so users can inspect state/plan output.
		return code, true
	}

	// The working directory is a staged copy, so anything the engine wrote
	// there is about to vanish. The gate above stops the commands that write
	// state; this is the backstop for anything it did not anticipate.
	if state := moduledir.LocalStateFiles(e.workDir); len(state) > 0 {
		fmt.Fprintf(os.Stderr,
			"\nrules_terraform: the engine wrote local state in the staged working directory, "+
				"which has been kept:\n  %s\nA Bazel-run module has no durable local directory; "+
				"configure a `backend` (or `cloud`) block so state lives somewhere that outlasts this run.\n",
			strings.Join(state, "\n  "))
		return 0, true
	}
	return 0, false
}

// mutatingCommands are the subcommands that write state. Gated when the
// configuration has no backend, because then the state they write lives in a
// directory nothing durable owns.
var mutatingCommands = map[string]bool{
	"apply":   true,
	"destroy": true,
	"import":  true,
	"refresh": true,
	"taint":   true,
	"untaint": true,
}

// mutatingStateVerbs are the `state` subcommands that write.
var mutatingStateVerbs = map[string]bool{
	"mv":               true,
	"push":             true,
	"replace-provider": true,
	"rm":               true,
}

// mutatesState reports whether the engine invocation writes state.
func mutatesState(args []string) bool {
	cmd := subcommand(args)
	if mutatingCommands[cmd] {
		return true
	}
	if cmd == "state" {
		rest := args[indexOf(args, cmd)+1:]
		return mutatingStateVerbs[subcommand(rest)]
	}
	return false
}

func indexOf(args []string, s string) int {
	for i, a := range args {
		if a == s {
			return i
		}
	}
	return -1
}

func ephemeralStateRefusal(command, stateDir string) string {
	return fmt.Sprintf(`rules_terraform: refusing to run "%s": this module declares no state backend.

Without a backend block the engine keeps state in its working directory, and
under Bazel that directory is a staged copy that exists for one run. The only
place rules_terraform could keep it is

    %s

which sits under bazel-out: "bazel clean" deletes it, it is private to this
machine, and it forks with the build configuration. Losing it orphans every
resource the command creates.

Declare a backend in one of the root module's .tf files:

    terraform {
      backend "s3" {
        bucket = "my-state"
        key    = "app/terraform.tfstate"
      }
    }

Any backend, or a cloud {} block, will do; the runner then leaves state to it.

If disposable state is the point (a demo, a sandbox, or bootstrapping the bucket
that will hold real state), opt in on the terraform_module:

    allow_ephemeral_state = True

State is then kept at the path above between runs. "plan" is never gated.
`, command, stateDir)
}

// localStateNames are the local backend's files and the workspace directory.
var localStateNames = []string{"terraform.tfstate", "terraform.tfstate.backup", "terraform.tfstate.d"}

func restoreLocalState(stateDir, workDir string) error {
	for _, name := range localStateNames {
		src := filepath.Join(stateDir, name)
		info, err := os.Stat(src)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return err
		}
		dst := filepath.Join(workDir, name)
		if info.IsDir() {
			if err := fsutil.CopyDirectory(src, dst); err != nil {
				return err
			}
			continue
		}
		if err := fsutil.CopyFile(src, dst); err != nil {
			return err
		}
	}
	return nil
}

func saveLocalState(workDir, stateDir string) error {
	if err := os.MkdirAll(stateDir, 0755); err != nil {
		return err
	}
	for _, name := range localStateNames {
		src := filepath.Join(workDir, name)
		info, err := os.Stat(src)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return err
		}
		dst := filepath.Join(stateDir, name)
		if info.IsDir() {
			if err := fsutil.CopyDirectory(src, dst); err != nil {
				return err
			}
			continue
		}
		if err := fsutil.CopyFile(src, dst); err != nil {
			return err
		}
	}
	return nil
}

// backendFreeCommands are the subcommands that run correctly against the
// aspect-built tree with no `init` at all.
//
// The aspect installs the providers and the module manifest, so the only thing
// a runtime `init` still contributes is backend setup — and these do not touch
// the backend. Running it for them would demand credentials for the configured
// backend before `terraform version` could print a version string, and would
// let an unrelated `init` failure mask the real diagnostic.
//
// This is an allowlist rather than a list of state-touching subcommands
// because the two fail in very different ways. Something missing here keeps
// the old behaviour of initializing when it needn't; something missing from a
// denylist would break outright. The set is also smaller than it looks:
// `providers`, `graph`, `show`, `output`, `console`, `workspace` and
// `force-unlock` all refuse to run against an uninitialized backend, so they
// deliberately are not here.
var backendFreeCommands = map[string]bool{
	"fmt":      true,
	"metadata": true,
	"test":     true,
	"validate": true,
	"version":  true,
}

// subcommand returns the engine subcommand named in args. The engine accepts
// global options ahead of it (`-chdir=DIR`, `-help`, `-version`), so the first
// argument is not reliably the subcommand — the first one that isn't a flag
// is. An empty result means the arguments are global flags alone, which is a
// help or version request and needs no backend.
func subcommand(args []string) string {
	for _, arg := range args {
		if !strings.HasPrefix(arg, "-") {
			return arg
		}
	}
	return ""
}

// needsBackend reports whether the engine invocation requires an initialized
// backend, and so a preceding `init`. Unrecognized subcommands answer yes: a
// needless `init` is an inconvenience, a missing one is a failure.
func needsBackend(args []string) bool {
	cmd := subcommand(args)
	return cmd != "" && !backendFreeCommands[cmd]
}

// ---- bazel test: terraform_test ------------------------------------------------

// testFlags records which reporting flags this engine's `test` accepts.
// Terraform has had `-junit-xml` since 1.11; OpenTofu has `-json-into`
// instead. Neither is assumed: the help text is asked.
type testFlags struct {
	junitXML bool
	jsonInto bool
}

func parseTestHelp(help string) testFlags {
	return testFlags{
		junitXML: strings.Contains(help, "-junit-xml"),
		jsonInto: strings.Contains(help, "-json-into"),
	}
}

func (e engine) probeTestFlags() testFlags {
	cmd := exec.Command(e.path, "test", "-help")
	cmd.Dir = e.workDir
	cmd.Env = e.env
	out, _ := cmd.CombinedOutput()
	return parseTestHelp(string(out))
}

// runTest runs the engine's native test framework and reports it the way Bazel
// expects of a test: per-run results in XML_OUTPUT_FILE, the artefacts a
// reviewer would want in TEST_UNDECLARED_OUTPUTS_DIR.
//
// Bazel's --test_arg surface is deliberately ignored; every run executes the
// module's .tftest.hcl files.
func runTest(e engine) int {
	flags := e.probeTestFlags()
	xmlOut := os.Getenv("XML_OUTPUT_FILE")
	outputs := os.Getenv("TEST_UNDECLARED_OUTPUTS_DIR")

	args := []string{"test"}
	jsonPath := ""
	switch {
	case flags.junitXML && xmlOut != "":
		args = append(args, "-junit-xml="+xmlOut)
	case flags.jsonInto && xmlOut != "":
		// The JSON stream is kept as an artefact in its own right, and is what
		// the JUnit report is built from once the engine has exited.
		dir := outputs
		if dir == "" {
			dir = e.workDir
		}
		jsonPath = filepath.Join(dir, "test.json")
		args = append(args, "-json-into="+jsonPath)
	}

	code := e.exec(args...)

	if jsonPath != "" {
		if err := writeJUnitFromJSON(jsonPath, xmlOut); err != nil {
			fmt.Fprintf(os.Stderr, "rules_terraform: could not write JUnit report: %v\n", err)
		}
	}
	saveReviewArtefacts(e.workDir, outputs)
	return code
}

func writeJUnitFromJSON(jsonPath, xmlOut string) error {
	f, err := os.Open(jsonPath)
	if err != nil {
		return err
	}
	defer f.Close()
	data, err := jsonToJUnit(f)
	if err != nil {
		return err
	}
	return os.WriteFile(xmlOut, data, 0644)
}

// saveReviewArtefacts copies into the undeclared outputs directory the files
// that say what a test actually ran against: the lock the engine saw and the
// module manifest. Silent when there is no such directory, which is the case
// outside `bazel test`.
func saveReviewArtefacts(workDir, outputs string) {
	if outputs == "" {
		return
	}
	copies := map[string]string{
		moduledir.LockFile(workDir):        ".terraform.lock.hcl",
		moduledir.ModulesManifest(workDir): "modules.json",
	}
	for src, name := range copies {
		if _, err := os.Stat(src); err != nil {
			continue
		}
		if err := fsutil.CopyFile(src, filepath.Join(outputs, name)); err != nil {
			fmt.Fprintf(os.Stderr, "rules_terraform: could not save %s: %v\n", name, err)
		}
	}
}

// ---- bazel test: terraform_plan_test -------------------------------------------

// runPlanTest initializes the backend, plans, and leaves the plan behind in
// three forms a reviewer can open: the binary plan, `show -json`, and the
// human-readable `show`. The test passes when the plan succeeds, or, with
// `expect_no_changes`, only when it is empty.
func runPlanTest(e engine, plan *PlanArgs) int {
	if plan == nil {
		plan = &PlanArgs{}
	}
	outputs := os.Getenv("TEST_UNDECLARED_OUTPUTS_DIR")
	if outputs == "" {
		outputs = e.workDir
	}

	if code := e.exec("init", "-get=false", "-input=false", "-plugin-dir="+moduledir.ProvidersDir(e.workDir)); code != 0 {
		return code
	}

	planFile := filepath.Join(outputs, "plan.tfplan")
	args := []string{"plan", "-input=false", "-detailed-exitcode", "-out=" + planFile}
	if !plan.Lock {
		args = append(args, "-lock=false")
	}
	args = append(args, plan.Args...)

	// -detailed-exitcode: 0 is no changes, 2 is changes, anything else failed.
	code := e.exec(args...)
	if code != 0 && code != 2 {
		saveReviewArtefacts(e.workDir, outputs)
		return code
	}

	if out, showCode := e.capture("show", "-json", planFile); showCode == 0 {
		if err := os.WriteFile(filepath.Join(outputs, "plan.json"), out, 0644); err != nil {
			fmt.Fprintf(os.Stderr, "rules_terraform: could not save plan.json: %v\n", err)
		}
	}
	if out, showCode := e.capture("show", "-no-color", planFile); showCode == 0 {
		if err := os.WriteFile(filepath.Join(outputs, "plan.txt"), out, 0644); err != nil {
			fmt.Fprintf(os.Stderr, "rules_terraform: could not save plan.txt: %v\n", err)
		}
	}
	saveReviewArtefacts(e.workDir, outputs)

	if code == 2 && plan.ExpectNoChanges {
		fmt.Fprintf(os.Stderr, "\nrules_terraform: the plan proposes changes but expect_no_changes is set; see %s\n", filepath.Join(outputs, "plan.txt"))
		return 1
	}
	return 0
}
