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
	"rules_terraform/engine/internal/fsutil"
	"rules_terraform/engine/internal/lockparse"
	"rules_terraform/engine/internal/moduledir"
	"rules_terraform/engine/internal/providerhash"
	"rules_terraform/engine/internal/tfparse"
)

// ArgsFile mirrors the JSON `build_runner` writes in //engine:terraform.bzl.
type ArgsFile struct {
	TerraformRlocationPath string `json:"terraform_rlocationpath"`
	// ModuleDirRlocationPath locates the tree artifact `terraform_init_aspect`
	// builds: the module directory, complete with its `.tf` files, local child
	// modules at their `source` paths, `.terraform.lock.hcl`, and a populated
	// `.terraform/`. The runner copies it and runs the engine inside — the
	// layout is settled at analysis time, not reconstructed here.
	ModuleDirRlocationPath string `json:"module_dir_rlocationpath"`

	// DisposableState is the root module's `disposable_state`. True, the
	// engine keeps local state where it natively would, its working
	// directory, which here is the staged copy and goes with the run. False,
	// its local backend is pointed at LocalDir so the state outlasts it.
	DisposableState bool `json:"disposable_state"`
	// LocalDir is the module's directory under `bazel-out`, relative to the
	// execroot: what the native CLI would keep in the module directory
	// between runs lives there instead. It names the module, not the
	// configuration, so every binary over one module shares it.
	LocalDir string `json:"local_dir"`
	// ArgsFilePath is this file's own path relative to the execroot. The
	// runner resolves the file through runfiles and strips this off the end
	// to find the execroot, with no searching for a `bazel-out` directory.
	ArgsFilePath string `json:"args_file_path"`

	// Workspace is a test rule's `workspace` attribute: the Terraform
	// workspace the test runs in, set as TF_WORKSPACE over anything the test
	// environment carries. Never set for `bazel run`, which follows the
	// operator's environment.
	Workspace string `json:"workspace,omitempty"`

	// ModulePackage is the root module's package: the directory under
	// BUILD_WORKSPACE_DIRECTORY that `init` installs into. Nil for a root
	// module in another repository, which has no place in the checkout, and
	// for the test modes.
	ModulePackage *string `json:"module_package,omitempty"`

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

	// The module's local directory sits in the same execroot as the args
	// file just resolved. Outside one there is none.
	localDir := ""
	if root := execroot(argsResolved, argsFile.ArgsFilePath); root != "" && argsFile.LocalDir != "" {
		localDir = filepath.Join(root, filepath.FromSlash(argsFile.LocalDir))
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
		if argsFile.Workspace != "" {
			env = moduledir.SetEnv(env, "TF_WORKSPACE", argsFile.Workspace)
		}
	}

	e := engine{path: enginePath, workDir: workDir, env: env}

	var code int
	switch m {
	case modeTest:
		code = runTest(e)
	case modePlan:
		code = runPlanTest(e, argsFile.Plan)
	default:
		code, keep = runCommand(e, argsFile, localDir, os.Args[1:])
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
func runCommand(e engine, argsFile *ArgsFile, localDir string, userArgs []string) (int, bool) {
	args := userArgs
	if len(args) == 0 {
		// Match `terraform` with no args: print help via the CLI itself.
		args = []string{"--help"}
	}

	if isInPlaceInit(args) {
		return runInit(e, argsFile, args), false
	}

	// Where state goes when there is no backend is decided before anything
	// runs: the override has to be in place before `init`.
	hasBackend := tfparse.HasBackend(e.workDir)
	keepState := !argsFile.DisposableState
	if hasBackend && keepState {
		fmt.Fprintln(os.Stderr, "Error: disposable_state = False, but the configuration declares a backend; state belongs to the backend. Drop one or the other.")
		return 1, false
	}
	stateKept := !hasBackend && keepState && localDir != ""
	if !hasBackend && keepState {
		switch {
		case localDir != "":
			if err := os.MkdirAll(localDir, 0o755); err != nil {
				fmt.Fprintf(os.Stderr, "Error: creating the local state directory %s: %v\n", localDir, err)
				return 1, false
			}
			if err := os.WriteFile(filepath.Join(e.workDir, localBackendOverrideName), []byte(localBackendOverride(localDir)), 0o644); err != nil {
				fmt.Fprintf(os.Stderr, "Error: writing %s: %v\n", localBackendOverrideName, err)
				return 1, false
			}
		case needsBackend(args):
			// Only the commands that reach for the state need the directory;
			// `validate` and the other backend-free commands run anywhere.
			fmt.Fprintln(os.Stderr, "Error: disposable_state = False, but this runner is not executing from a Bazel execroot, so there is no bazel-out to keep the state in. Run it with `bazel run`.")
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

	if stateKept && mutatesState(args) {
		// Said whether or not the command succeeded: a failed apply has
		// usually still created something, and the state is the record of it.
		fmt.Fprintf(os.Stderr, "\nrules_terraform: local state is kept at %s (disposable_state is False; `bazel clean` removes it).\n", localDir)
	}

	if code == 0 && changesWorkspaceSelection(args) {
		// The native CLI records the selection in `.terraform/environment`
		// in the module directory. Here that is the staged copy, so the
		// selection is gone with it; a run picks its workspace up front.
		fmt.Fprintln(os.Stderr, "\nrules_terraform: the workspace selection does not outlive this run. Set TF_WORKSPACE in the environment to pick a workspace for a `bazel run`.")
	}

	if code != 0 {
		// Leak the temp dir on failure so users can inspect state/plan output.
		return code, true
	}

	// The working directory is a staged copy, so anything the engine wrote
	// there goes with it. State is the record of what a run created, so a
	// copy holding some is kept and named rather than deleted: the module
	// declared its state disposable, which is about the next run, not about
	// the one that just made resources.
	if state := moduledir.LocalStateFiles(e.workDir); len(state) > 0 {
		fmt.Fprintf(os.Stderr,
			"\nrules_terraform: the engine wrote local state in the staged working directory, "+
				"which has been kept:\n  %s\nThe next run starts from a fresh copy and will not see it. "+
				"For state that should outlive the run, configure a `backend` (or `cloud`) block, "+
				"or set `disposable_state = False` on the terraform_module to keep it under bazel-out.\n",
			strings.Join(state, "\n  "))
		return 0, true
	}
	return 0, false
}

// ---- bazel run: init -----------------------------------------------------------

// isInPlaceInit reports whether the invocation is an `init` to intercept. A
// help request for it is left to the engine.
func isInPlaceInit(args []string) bool {
	if subcommand(args) != "init" {
		return false
	}
	for _, arg := range args {
		switch arg {
		case "-h", "-help", "--help":
			return false
		}
	}
	return true
}

// initFlagRejections are the `init` flags that name something the Bazel
// build decides, each with the reason it is refused. `-chdir` is a global
// flag, before the subcommand, and is refused for the same reason.
var initFlagRejections = map[string]string{
	"chdir":       "the target names the module directory",
	"from-module": "a root module is a terraform_module target",
	"get":         "the build installs the modules",
	"plugin-dir":  "the build's providers are the plugin directory",
	"upgrade":     "providers and modules are what the build installed; change the lock or MODULE.bazel and rebuild",
}

// rejectedInitFlag returns the first flag of an `init` invocation that the
// in-place init refuses, with the reason, or "" when every flag passes
// through.
func rejectedInitFlag(args []string) (string, string) {
	for _, arg := range args {
		if !strings.HasPrefix(arg, "-") {
			continue
		}
		name := strings.TrimLeft(arg, "-")
		if i := strings.IndexByte(name, '='); i >= 0 {
			name = name[:i]
		}
		if why, ok := initFlagRejections[name]; ok {
			return arg, why
		}
	}
	return "", ""
}

// lockfileReadonly reports whether the invocation carries
// `-lockfile=readonly`, the engine's own way of forbidding lock writes,
// which the in-place init honours for the hash it would otherwise add.
func lockfileReadonly(args []string) bool {
	for i, arg := range args {
		name := strings.TrimLeft(arg, "-")
		if name == "lockfile=readonly" {
			return true
		}
		if name == "lockfile" && i+1 < len(args) && args[i+1] == "readonly" {
			return true
		}
	}
	return false
}

// runInit is `bazel run //pkg:terraform -- init`. Passed through, `init`
// would run in the staged copy and its work would be deleted with it, so
// under the binary it means the one thing it usefully can: install the
// Bazel-built `.terraform/` into the module's source directory and
// initialize the backend there. After it the native CLI works in that
// directory with no network for providers or modules.
//
// The directory is the root module's package under
// BUILD_WORKSPACE_DIRECTORY, wherever the command was run from. The
// providers and modules are replaced; `.terraform/environment` and the
// backend state are kept, as a native re-`init` keeps them. The lock is
// written only when the module has none of its own, so a native `init`
// does not create one next to the sources, and gains the host platform's
// `h1:` hash when it lacks one, since the engine cannot verify an unpacked
// package by anything else and would refuse to reuse it. The remaining
// arguments go to the in-place `init`, which is how `-reconfigure`,
// `-migrate-state` and `-backend-config` reach it.
func runInit(e engine, argsFile *ArgsFile, args []string) int {
	if flag, why := rejectedInitFlag(args); flag != "" {
		fmt.Fprintf(os.Stderr, "Error: `init` under this binary installs the Bazel-built .terraform/ into the module's source directory, so %s has no meaning here: %s.\n", flag, why)
		return 1
	}
	workspaceDir := os.Getenv("BUILD_WORKSPACE_DIRECTORY")
	if workspaceDir == "" {
		fmt.Fprintln(os.Stderr, "Error: `init` installs into the checkout, which only `bazel run` knows: BUILD_WORKSPACE_DIRECTORY is not set.")
		return 1
	}
	if argsFile.ModulePackage == nil {
		fmt.Fprintln(os.Stderr, "Error: the root module lives in another repository; there is no directory in this checkout to initialize.")
		return 1
	}
	dst := filepath.Join(workspaceDir, filepath.FromSlash(*argsFile.ModulePackage))
	if !moduledir.HasConfig(dst) {
		fmt.Fprintf(os.Stderr, "Error: %s holds no configuration files; expected the root module's sources there.\n", dst)
		return 1
	}

	for _, sub := range []string{"providers", "modules"} {
		src := filepath.Join(moduledir.TerraformDir(e.workDir), sub)
		target := filepath.Join(moduledir.TerraformDir(dst), sub)
		if _, err := os.Stat(src); os.IsNotExist(err) {
			if err := os.RemoveAll(target); err != nil {
				fmt.Fprintf(os.Stderr, "Error: removing %s: %v\n", target, err)
				return 1
			}
			continue
		}
		if err := fsutil.CopyDirectory(src, target); err != nil {
			fmt.Fprintf(os.Stderr, "Error: installing %s: %v\n", target, err)
			return 1
		}
	}

	lockWritten := false
	if _, err := os.Stat(moduledir.LockFile(dst)); os.IsNotExist(err) {
		if _, err := os.Stat(moduledir.LockFile(e.workDir)); err == nil {
			if err := fsutil.CopyFile(moduledir.LockFile(e.workDir), moduledir.LockFile(dst)); err != nil {
				fmt.Fprintf(os.Stderr, "Error: writing %s: %v\n", moduledir.LockFile(dst), err)
				return 1
			}
			lockWritten = true
		}
	}

	added, err := addHostHashes(dst, lockfileReadonly(args))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		return 1
	}

	initArgs := append([]string{"init", "-get=false", "-plugin-dir=" + moduledir.ProvidersDir(dst)}, args[indexOf(args, "init")+1:]...)
	code := engine{path: e.path, workDir: dst, env: e.env}.exec(initArgs...)
	if code != 0 {
		return code
	}
	fmt.Fprintf(os.Stderr, "\nrules_terraform: %s is initialized; the native CLI works there. .terraform/ is the engine's cache and belongs in .gitignore.\n", dst)
	if lockWritten {
		fmt.Fprintf(os.Stderr, "rules_terraform: the module had no .terraform.lock.hcl of its own, so the build's was written next to the sources.\n")
	}
	for _, line := range added {
		fmt.Fprintf(os.Stderr, "rules_terraform: .terraform.lock.hcl gained %s, the hash of the installed package, which it lacked for this platform; commit it, or regenerate the lock for every platform with the lock updater.\n", line)
	}
	return 0
}

// addHostHashes records in the module's lock the `h1:` hash of each
// installed provider package the lock does not already carry, and returns
// a description of each addition. An unpacked package can only be verified
// by its `h1:`, so a lock made on another platform, or natively with fewer
// `-platform`s than the updater uses, makes the engine refuse the package it
// is standing next to. The addition is what `providers lock -platform=<host>`
// would add and nothing else in the file moves. With readonly set, which is
// the engine's `-lockfile=readonly`, a missing hash is an error instead.
func addHostHashes(moduleDir string, readonly bool) ([]string, error) {
	lockPath := moduledir.LockFile(moduleDir)
	entries, err := lockparse.ReadProviderLock(lockPath)
	if err != nil {
		return nil, err
	}
	if entries == nil {
		// No lock: the engine writes one from the installed packages.
		return nil, nil
	}
	content, err := os.ReadFile(lockPath)
	if err != nil {
		return nil, err
	}

	var added []string
	// `<host>/<namespace>/<name>/<version>/<platform>` under the providers
	// directory; the tree holds the host platform only.
	packages, _ := filepath.Glob(filepath.Join(moduledir.ProvidersDir(moduleDir), "*", "*", "*", "*", "*"))
	for _, pkg := range packages {
		rel, err := filepath.Rel(moduledir.ProvidersDir(moduleDir), pkg)
		if err != nil {
			return nil, err
		}
		parts := strings.Split(filepath.ToSlash(rel), "/")
		host, source, version, platform := parts[0], parts[1]+"/"+parts[2], parts[3], parts[4]
		var entry *lockparse.ProviderEntry
		for i := range entries {
			if entries[i].RegistryHost == host && entries[i].Source == source && entries[i].Version == version {
				entry = &entries[i]
			}
		}
		if entry == nil {
			// Not the lock's provider at all; the engine reports that itself.
			continue
		}
		hash, err := providerhash.H1(pkg)
		if err != nil {
			return nil, err
		}
		if indexOf(entry.H1Hashes, hash) >= 0 {
			continue
		}
		address := host + "/" + source
		if readonly {
			return nil, fmt.Errorf("%s has no h1: hash for %s on %s, and -lockfile=readonly forbids adding one; regenerate the lock for every platform with the lock updater, or drop the flag", lockPath, address, platform)
		}
		content, _, err = lockparse.AddH1Hash(content, address, hash)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", lockPath, err)
		}
		added = append(added, fmt.Sprintf("%s for %s (%s)", hash, address, platform))
	}
	if len(added) > 0 {
		if err := os.WriteFile(lockPath, content, 0o644); err != nil {
			return nil, err
		}
	}
	return added, nil
}

// execroot returns the directory that resolved, a file's location on disk,
// is anchored at when the file's execroot-relative path is execrootRel, or
// "" when the file is not at that path under any directory. Under `bazel run`
// every runfile resolves into the execroot, through a symlink when a
// runfiles tree is built, so this finds it without the `bazel-out`
// convenience symlink, which `--symlink_prefix` moves or removes. A runner
// copied out of the output tree has no execroot, and with it no place for
// local state.
func execroot(resolved, execrootRel string) string {
	if r, err := filepath.EvalSymlinks(resolved); err == nil {
		resolved = r
	}
	suffix := string(filepath.Separator) + filepath.FromSlash(execrootRel)
	if execrootRel == "" || !strings.HasSuffix(resolved, suffix) {
		return ""
	}
	return strings.TrimSuffix(resolved, suffix)
}

// changesWorkspaceSelection reports whether the invocation is a `workspace`
// subcommand that selects a workspace: `select`, and `new`, which selects
// the workspace it creates.
func changesWorkspaceSelection(args []string) bool {
	if subcommand(args) != "workspace" {
		return false
	}
	verb := subcommand(args[indexOf(args, "workspace")+1:])
	return verb == "select" || verb == "new"
}

// localBackendOverrideName is an override file (`*_override.tf`), so it merges
// into the configuration without editing any of the user's files. It exists
// only in the staged copy.
const localBackendOverrideName = "rules_terraform_local_state_override.tf"

// localBackendOverride points the engine's local backend at the module's
// local directory: `terraform.tfstate` and, for workspaces,
// `terraform.tfstate.d/`, laid out as a native `terraform apply` lays them
// out in the module directory. Forward slashes throughout; the engine accepts
// them on every platform, and they need no escaping in HCL.
func localBackendOverride(dir string) string {
	d := filepath.ToSlash(dir)
	return fmt.Sprintf(`terraform {
  backend "local" {
    path          = %q
    workspace_dir = %q
  }
}
`, d+"/terraform.tfstate", d+"/terraform.tfstate.d")
}

// mutatingCommands are the subcommands that write state. After one of them,
// a run that keeps state under bazel-out says where.
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
