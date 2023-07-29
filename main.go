/*
Copyright 2014 The Kubernetes Authors All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// git-sync is a command that pulls a git repository to a local directory.

package main // import "k8s.io/git-sync/cmd/git-sync"

import (
	"context"
	"crypto/md5"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/http/pprof"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/spf13/pflag"
	"golang.org/x/sys/unix"
	"k8s.io/git-sync/pkg/cmd"
	"k8s.io/git-sync/pkg/hook"
	"k8s.io/git-sync/pkg/logging"
	"k8s.io/git-sync/pkg/pid1"
	"k8s.io/git-sync/pkg/version"
)

var (
	metricSyncDuration = prometheus.NewSummaryVec(prometheus.SummaryOpts{
		Name: "git_sync_duration_seconds",
		Help: "Summary of git_sync durations",
	}, []string{"status"})

	metricSyncCount = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "git_sync_count_total",
		Help: "How many git syncs completed, partitioned by state (success, error, noop)",
	}, []string{"status"})

	metricFetchCount = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "git_fetch_count_total",
		Help: "How many git fetches were run",
	})

	metricAskpassCount = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "git_sync_askpass_calls",
		Help: "How many git askpass calls completed, partitioned by state (success, error)",
	}, []string{"status"})
)

func init() {
	prometheus.MustRegister(metricSyncDuration)
	prometheus.MustRegister(metricSyncCount)
	prometheus.MustRegister(metricFetchCount)
	prometheus.MustRegister(metricAskpassCount)
}

const (
	metricKeySuccess = "success"
	metricKeyError   = "error"
	metricKeyNoOp    = "noop"
)

type submodulesMode string

const (
	submodulesRecursive submodulesMode = "recursive"
	submodulesShallow   submodulesMode = "shallow"
	submodulesOff       submodulesMode = "off"
)

type gcMode string

const (
	gcAuto       = "auto"
	gcAlways     = "always"
	gcAggressive = "aggressive"
	gcOff        = "off"
)

const defaultDirMode = os.FileMode(0775) // subject to umask

func envString(def string, key string, alts ...string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	for _, alt := range alts {
		if val := os.Getenv(alt); val != "" {
			fmt.Fprintf(os.Stderr, "env %s has been deprecated, use %s instead\n", alt, key)
			return val
		}
	}
	return def
}

func envBoolOrError(def bool, key string, alts ...string) (bool, error) {
	parse := func(val string) (bool, error) {
		parsed, err := strconv.ParseBool(val)
		if err == nil {
			return parsed, nil
		}
		return false, fmt.Errorf("ERROR: invalid bool env %s=%q: %w", key, val, err)
	}

	if val := os.Getenv(key); val != "" {
		return parse(val)
	}
	for _, alt := range alts {
		if val := os.Getenv(key); val != "" {
			fmt.Fprintf(os.Stderr, "env %s has been deprecated, use %s instead\n", alt, key)
			return parse(val)
		}
	}
	return def, nil
}
func envBool(def bool, key string, alts ...string) bool {
	val, err := envBoolOrError(def, key, alts...)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
		return false
	}
	return val
}

func envIntOrError(def int, key string, alts ...string) (int, error) {
	parse := func(val string) (int, error) {
		parsed, err := strconv.ParseInt(val, 0, 0)
		if err == nil {
			return int(parsed), nil
		}
		return 0, fmt.Errorf("ERROR: invalid int env %s=%q: %w", key, val, err)
	}

	if val := os.Getenv(key); val != "" {
		return parse(val)
	}
	for _, alt := range alts {
		if val := os.Getenv(key); val != "" {
			fmt.Fprintf(os.Stderr, "env %s has been deprecated, use %s instead\n", alt, key)
			return parse(val)
		}
	}
	return def, nil
}
func envInt(def int, key string, alts ...string) int {
	val, err := envIntOrError(def, key, alts...)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
		return 0
	}
	return val
}

func envFloatOrError(def float64, key string, alts ...string) (float64, error) {
	parse := func(val string) (float64, error) {
		parsed, err := strconv.ParseFloat(val, 64)
		if err == nil {
			return parsed, nil
		}
		return 0, fmt.Errorf("ERROR: invalid float env %s=%q: %w", key, val, err)
	}

	if val := os.Getenv(key); val != "" {
		return parse(val)
	}
	for _, alt := range alts {
		if val := os.Getenv(key); val != "" {
			fmt.Fprintf(os.Stderr, "env %s has been deprecated, use %s instead\n", alt, key)
			return parse(val)
		}
	}
	return def, nil
}
func envFloat(def float64, key string, alts ...string) float64 {
	val, err := envFloatOrError(def, key, alts...)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
		return 0
	}
	return val
}

func envDurationOrError(def time.Duration, key string, alts ...string) (time.Duration, error) {
	parse := func(val string) (time.Duration, error) {
		parsed, err := time.ParseDuration(val)
		if err == nil {
			return parsed, nil
		}
		return 0, fmt.Errorf("ERROR: invalid duration env %s=%q: %w", key, val, err)
	}

	if val := os.Getenv(key); val != "" {
		return parse(val)
	}
	for _, alt := range alts {
		if val := os.Getenv(key); val != "" {
			fmt.Fprintf(os.Stderr, "env %s has been deprecated, use %s instead\n", alt, key)
			return parse(val)
		}
	}
	return def, nil
}
func envDuration(def time.Duration, key string, alts ...string) time.Duration {
	val, err := envDurationOrError(def, key, alts...)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
		return 0
	}
	return val
}

// absPath is an absolute path string.  This type is intended to make it clear
// when strings are absolute paths vs something else.  This does not verify or
// mutate the input, so careless callers could make instances of this type that
// are not actually absolute paths, or even "".
type absPath string

// String returns abs as a string.
func (abs absPath) String() string {
	return string(abs)
}

// Canonical returns a canonicalized form of abs, similar to filepath.Abs
// (including filepath.Clean).  Unlike filepath.Clean, this preserves "" as a
// special case.
func (abs absPath) Canonical() (absPath, error) {
	if abs == "" {
		return abs, nil
	}

	result, err := filepath.Abs(abs.String())
	if err != nil {
		return "", err
	}
	return absPath(result), nil
}

// Join appends more path elements to abs, like filepath.Join.
func (abs absPath) Join(elems ...string) absPath {
	all := make([]string, 0, 1+len(elems))
	all = append(all, abs.String())
	all = append(all, elems...)
	return absPath(filepath.Join(all...))
}

// Split breaks abs into stem and leaf parts (often directory and file, but not
// necessarily), similar to filepath.Split.  Unlike filepath.Split, the
// resulting stem part does not have any trailing path separators.
func (abs absPath) Split() (string, string) {
	if abs == "" {
		return "", ""
	}

	// filepath.Split promises that dir+base == input, but trailing slashes on
	// the dir is confusing and ugly.
	pathSep := string(os.PathSeparator)
	dir, base := filepath.Split(strings.TrimRight(abs.String(), pathSep))
	dir = strings.TrimRight(dir, pathSep)
	if len(dir) == 0 {
		dir = string(os.PathSeparator)
	}

	return dir, base
}

// Dir returns the stem part of abs without the leaf, like filepath.Dir.
func (abs absPath) Dir() string {
	dir, _ := abs.Split()
	return dir
}

// Base returns the leaf part of abs without the stem, like filepath.Base.
func (abs absPath) Base() string {
	_, base := abs.Split()
	return base
}

// repoSync represents the remote repo and the local sync of it.
type repoSync struct {
	cmd          string         // the git command to run
	root         absPath        // absolute path to the root directory
	repo         string         // remote repo to sync
	ref          string         // the ref to sync
	depth        int            // for shallow sync
	submodules   submodulesMode // how to handle submodules
	gc           gcMode         // garbage collection
	link         absPath        // absolute path to the symlink to publish
	authURL      string         // a URL to re-fetch credentials, or ""
	sparseFile   string         // path to a sparse-checkout file
	syncCount    int            // how many times have we synced?
	log          *logging.Logger
	run          cmd.Runner
	staleTimeout time.Duration // time for worktrees to be cleaned up
}

func main() {
	// In case we come up as pid 1, act as init.
	if os.Getpid() == 1 {
		fmt.Fprintf(os.Stderr, "INFO: detected pid 1, running init handler\n")
		code, err := pid1.ReRun()
		if err == nil {
			os.Exit(code)
		}
		fmt.Fprintf(os.Stderr, "ERROR: unhandled pid1 error: %v\n", err)
		os.Exit(127)
	}

	//
	// Declare flags inside main() so they are not used as global variables.
	//

	flVersion := pflag.Bool("version", false, "print the version and exit")
	flHelp := pflag.BoolP("help", "h", false, "print help text and exit")
	flManual := pflag.Bool("man", false, "print the full manual and exit")

	flVerbose := pflag.IntP("verbose", "v", 0,
		"logs at this V level and lower will be printed")

	flRepo := pflag.String("repo",
		envString("", "GITSYNC_REPO", "GIT_SYNC_REPO"),
		"the git repository to sync (required)")
	flRef := pflag.String("ref",
		envString("HEAD", "GITSYNC_REF"),
		"the git revision (branch, tag, or hash) to sync")
	flDepth := pflag.Int("depth",
		envInt(1, "GITSYNC_DEPTH", "GIT_SYNC_DEPTH"),
		"create a shallow clone with history truncated to the specified number of commits")
	flSubmodules := pflag.String("submodules",
		envString("recursive", "GITSYNC_SUBMODULES", "GIT_SYNC_SUBMODULES"),
		"git submodule behavior: one of 'recursive', 'shallow', or 'off'")
	flSparseCheckoutFile := pflag.String("sparse-checkout-file",
		envString("", "GITSYNC_SPARSE_CHECKOUT_FILE", "GIT_SYNC_SPARSE_CHECKOUT_FILE"),
		"the path to a sparse-checkout file")

	flRoot := pflag.String("root",
		envString("", "GITSYNC_ROOT", "GIT_SYNC_ROOT"),
		"the root directory for git-sync operations (required)")
	flLink := pflag.String("link",
		envString("", "GITSYNC_LINK", "GIT_SYNC_LINK"),
		"the path (absolute or relative to --root) at which to create a symlink to the directory holding the checked-out files (defaults to the leaf dir of --repo)")
	flErrorFile := pflag.String("error-file",
		envString("", "GITSYNC_ERROR_FILE", "GIT_SYNC_ERROR_FILE"),
		"the path (absolute or relative to --root) to an optional file into which errors will be written (defaults to disabled)")
	flPeriod := pflag.Duration("period",
		envDuration(10*time.Second, "GITSYNC_PERIOD", "GIT_SYNC_PERIOD"),
		"how long to wait between syncs, must be >= 10ms; --wait overrides this")
	flSyncTimeout := pflag.Duration("sync-timeout",
		envDuration(120*time.Second, "GITSYNC_SYNC_TIMEOUT", "GIT_SYNC_SYNC_TIMEOUT"),
		"the total time allowed for one complete sync, must be >= 10ms; --timeout overrides this")
	flOneTime := pflag.Bool("one-time",
		envBool(false, "GITSYNC_ONE_TIME", "GIT_SYNC_ONE_TIME"),
		"exit after the first sync")
	flSyncOnSignal := pflag.String("sync-on-signal",
		envString("", "GITSYNC_SYNC_ON_SIGNAL", "GIT_SYNC_SYNC_ON_SIGNAL"),
		"sync on receipt of the specified signal (e.g. SIGHUP)")
	flMaxFailures := pflag.Int("max-failures",
		envInt(0, "GITSYNC_MAX_FAILURES", "GIT_SYNC_MAX_FAILURES"),
		"the number of consecutive failures allowed before aborting (-1 will retry forever")
	flTouchFile := pflag.String("touch-file",
		envString("", "GITSYNC_TOUCH_FILE", "GIT_SYNC_TOUCH_FILE"),
		"the path (absolute or relative to --root) to an optional file which will be touched whenever a sync completes (defaults to disabled)")
	flAddUser := pflag.Bool("add-user",
		envBool(false, "GITSYNC_ADD_USER", "GIT_SYNC_ADD_USER"),
		"add a record to /etc/passwd for the current UID/GID (needed to use SSH with an arbitrary UID)")
	flGroupWrite := pflag.Bool("group-write",
		envBool(false, "GITSYNC_GROUP_WRITE", "GIT_SYNC_GROUP_WRITE"),
		"ensure that all data (repo, worktrees, etc.) is group writable")
	flStaleWorktreeTimeout := pflag.Duration("stale-worktree-timeout", envDuration(0, "GITSYNC_STALE_WORKTREE_TIMEOUT"),
		"how long to retain non-current worktrees")

	flExechookCommand := pflag.String("exechook-command",
		envString("", "GITSYNC_EXECHOOK_COMMAND", "GIT_SYNC_EXECHOOK_COMMAND"),
		"an optional command to be run when syncs complete (must be idempotent)")
	flExechookTimeout := pflag.Duration("exechook-timeout",
		envDuration(30*time.Second, "GITSYNC_EXECHOOK_TIMEOUT", "GIT_SYNC_EXECHOOK_TIMEOUT"),
		"the timeout for the exechook")
	flExechookBackoff := pflag.Duration("exechook-backoff",
		envDuration(3*time.Second, "GITSYNC_EXECHOOK_BACKOFF", "GIT_SYNC_EXECHOOK_BACKOFF"),
		"the time to wait before retrying a failed exechook")

	flWebhookURL := pflag.String("webhook-url",
		envString("", "GITSYNC_WEBHOOK_URL", "GIT_SYNC_WEBHOOK_URL"),
		"a URL for optional webhook notifications when syncs complete (must be idempotent)")
	flWebhookMethod := pflag.String("webhook-method",
		envString("POST", "GITSYNC_WEBHOOK_METHOD", "GIT_SYNC_WEBHOOK_METHOD"),
		"the HTTP method for the webhook")
	flWebhookStatusSuccess := pflag.Int("webhook-success-status",
		envInt(200, "GITSYNC_WEBHOOK_SUCCESS_STATUS", "GIT_SYNC_WEBHOOK_SUCCESS_STATUS"),
		"the HTTP status code indicating a successful webhook (0 disables success checks")
	flWebhookTimeout := pflag.Duration("webhook-timeout",
		envDuration(1*time.Second, "GITSYNC_WEBHOOK_TIMEOUT", "GIT_SYNC_WEBHOOK_TIMEOUT"),
		"the timeout for the webhook")
	flWebhookBackoff := pflag.Duration("webhook-backoff",
		envDuration(3*time.Second, "GITSYNC_WEBHOOK_BACKOFF", "GIT_SYNC_WEBHOOK_BACKOFF"),
		"the time to wait before retrying a failed webhook")

	flUsername := pflag.String("username",
		envString("", "GITSYNC_USERNAME", "GIT_SYNC_USERNAME"),
		"the username to use for git auth")
	flPassword := pflag.String("password",
		envString("", "GITSYNC_PASSWORD", "GIT_SYNC_PASSWORD"),
		"the password or personal access token to use for git auth (prefer --password-file or this env var)")
	flPasswordFile := pflag.String("password-file",
		envString("", "GITSYNC_PASSWORD_FILE", "GIT_SYNC_PASSWORD_FILE"),
		"the file from which the password or personal access token for git auth will be sourced")

	flSSH := pflag.Bool("ssh",
		envBool(false, "GITSYNC_SSH", "GIT_SYNC_SSH"),
		"use SSH for git operations")
	flSSHKeyFile := pflag.String("ssh-key-file",
		envString("/etc/git-secret/ssh", "GITSYNC_SSH_KEY_FILE", "GIT_SYNC_SSH_KEY_FILE", "GIT_SSH_KEY_FILE"),
		"the SSH key to use")
	flSSHKnownHosts := pflag.Bool("ssh-known-hosts",
		envBool(true, "GITSYNC_SSH_KNOWN_HOSTS", "GIT_SYNC_KNOWN_HOSTS", "GIT_KNOWN_HOSTS"),
		"enable SSH known_hosts verification")
	flSSHKnownHostsFile := pflag.String("ssh-known-hosts-file",
		envString("/etc/git-secret/known_hosts", "GITSYNC_SSH_KNOWN_HOSTS_FILE", "GIT_SYNC_SSH_KNOWN_HOSTS_FILE", "GIT_SSH_KNOWN_HOSTS_FILE"),
		"the known_hosts file to use")

	flCookieFile := pflag.Bool("cookie-file",
		envBool(false, "GITSYNC_COOKIE_FILE", "GIT_SYNC_COOKIE_FILE", "GIT_COOKIE_FILE"),
		"use a git cookiefile (/etc/git-secret/cookie_file) for authentication")

	flAskPassURL := pflag.String("askpass-url",
		envString("", "GITSYNC_ASKPASS_URL", "GIT_SYNC_ASKPASS_URL", "GIT_ASKPASS_URL"),
		"a URL to query for git credentials (username=<value> and password=<value>)")

	flGitCmd := pflag.String("git",
		envString("git", "GITSYNC_GIT", "GIT_SYNC_GIT"),
		"the git command to run (subject to PATH search, mostly for testing)")
	flGitConfig := pflag.String("git-config",
		envString("", "GITSYNC_GIT_CONFIG", "GIT_SYNC_GIT_CONFIG"),
		"additional git config options in 'section.var1:val1,\"section.sub.var2\":\"val2\"' format")
	flGitGC := pflag.String("git-gc",
		envString("always", "GITSYNC_GIT_GC", "GIT_SYNC_GIT_GC"),
		"git garbage collection behavior: one of 'auto', 'always', 'aggressive', or 'off'")

	flHTTPBind := pflag.String("http-bind",
		envString("", "GITSYNC_HTTP_BIND", "GIT_SYNC_HTTP_BIND"),
		"the bind address (including port) for git-sync's HTTP endpoint")
	flHTTPMetrics := pflag.Bool("http-metrics",
		envBool(false, "GITSYNC_HTTP_METRICS", "GIT_SYNC_HTTP_METRICS"),
		"enable metrics on git-sync's HTTP endpoint")
	flHTTPprof := pflag.Bool("http-pprof",
		envBool(false, "GITSYNC_HTTP_PPROF", "GIT_SYNC_HTTP_PPROF"),
		"enable the pprof debug endpoints on git-sync's HTTP endpoint")

	// Obsolete flags, kept for compat.
	flDeprecatedBranch := pflag.String("branch", envString("", "GIT_SYNC_BRANCH"),
		"DEPRECATED: use --ref instead")
	mustMarkDeprecated("branch", "use --ref instead")
	flDeprecatedChmod := pflag.Int("change-permissions", envInt(0, "GIT_SYNC_PERMISSIONS"),
		"DEPRECATED: use --group-write instead")
	mustMarkDeprecated("change-permissions", "use --group-write instead")
	flDeprecatedDest := pflag.String("dest", envString("", "GIT_SYNC_DEST"),
		"DEPRECATED: use --link instead")
	mustMarkDeprecated("dest", "use --link instead")
	flDeprecatedMaxSyncFailures := pflag.Int("max-sync-failures", envInt(0, "GIT_SYNC_MAX_SYNC_FAILURES"),
		"DEPRECATED: use --max-failures instead")
	mustMarkDeprecated("max-sync-failures", "use --max-failures instead")
	flDeprecatedRev := pflag.String("rev", envString("", "GIT_SYNC_REV"),
		"DEPRECATED: use --ref instead")
	mustMarkDeprecated("rev", "use --ref instead")
	flDeprecatedSyncHookCommand := pflag.String("sync-hook-command", envString("", "GIT_SYNC_HOOK_COMMAND"),
		"DEPRECATED: use --exechook-command instead")
	mustMarkDeprecated("sync-hook-command", "use --exechook-command instead")
	flDeprecatedTimeout := pflag.Int("timeout", envInt(0, "GIT_SYNC_TIMEOUT"),
		"DEPRECATED: use --sync-timeout instead")
	mustMarkDeprecated("timeout", "use --sync-timeout instead")
	flDeprecatedV := pflag.Int("v", -1,
		"DEPRECATED: use -v or --verbose instead")
	mustMarkDeprecated("v", "use -v or --verbose instead")
	flDeprecatedWait := pflag.Float64("wait", envFloat(0, "GIT_SYNC_WAIT"),
		"DEPRECATED: use --period instead")
	mustMarkDeprecated("wait", "use --period instead")

	//
	// Parse and verify flags.  Errors here are fatal.
	//

	pflag.Parse()

	// Handle print-and-exit cases.
	if *flVersion {
		fmt.Println(version.VERSION)
		os.Exit(0)
	}
	if *flHelp {
		pflag.CommandLine.SetOutput(os.Stdout)
		pflag.PrintDefaults()
		os.Exit(0)
	}
	if *flManual {
		printManPage()
		os.Exit(0)
	}

	// Make sure we have a root dir in which to work.
	if *flRoot == "" {
		fmt.Fprintf(os.Stderr, "ERROR: --root must be specified\n")
		os.Exit(1)
	}
	var absRoot absPath
	if abs, err := absPath(*flRoot).Canonical(); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: can't absolutize --root: %v\n", err)
		os.Exit(1)
	} else {
		absRoot = abs
	}

	// Init logging very early, so most errors can be written to a file.
	if *flDeprecatedV >= 0 {
		// Back-compat
		*flVerbose = *flDeprecatedV
	}
	log := func() *logging.Logger {
		dir, file := makeAbsPath(*flErrorFile, absRoot).Split()
		return logging.New(dir, file, *flVerbose)
	}()
	cmdRunner := cmd.NewRunner(log)

	if *flRepo == "" {
		handleConfigError(log, true, "ERROR: --repo must be specified")
	}

	switch {
	case *flDeprecatedBranch != "" && (*flDeprecatedRev == "" || *flDeprecatedRev == "HEAD"):
		// Back-compat
		log.V(0).Info("setting --ref from deprecated --branch")
		*flRef = *flDeprecatedBranch
	case *flDeprecatedRev != "":
		// Back-compat
		log.V(0).Info("setting --ref from deprecated --rev")
		*flRef = *flDeprecatedRev
	case *flDeprecatedBranch != "" && *flDeprecatedRev != "":
		handleConfigError(log, true, "ERROR: can't set --ref from deprecated --branch and --rev")
	}

	if *flRef == "" {
		handleConfigError(log, true, "ERROR: --ref must be specified")
	}

	if *flDepth < 0 { // 0 means "no limit"
		handleConfigError(log, true, "ERROR: --depth must be greater than or equal to 0")
	}

	switch submodulesMode(*flSubmodules) {
	case submodulesRecursive, submodulesShallow, submodulesOff:
	default:
		handleConfigError(log, true, "ERROR: --submodules must be one of %q, %q, or %q", submodulesRecursive, submodulesShallow, submodulesOff)
	}

	switch *flGitGC {
	case gcAuto, gcAlways, gcAggressive, gcOff:
	default:
		handleConfigError(log, true, "ERROR: --git-gc must be one of %q, %q, %q, or %q", gcAuto, gcAlways, gcAggressive, gcOff)
	}

	if *flDeprecatedDest != "" {
		// Back-compat
		log.V(0).Info("setting --link from deprecated --dest")
		*flLink = *flDeprecatedDest
	}
	if *flLink == "" {
		parts := strings.Split(strings.Trim(*flRepo, "/"), "/")
		*flLink = parts[len(parts)-1]
	}

	if *flDeprecatedWait != 0 {
		// Back-compat
		log.V(0).Info("setting --period from deprecated --wait")
		*flPeriod = time.Duration(int(*flDeprecatedWait*1000)) * time.Millisecond
	}
	if *flPeriod < 10*time.Millisecond {
		handleConfigError(log, true, "ERROR: --period must be at least 10ms")
	}

	if *flDeprecatedChmod != 0 {
		handleConfigError(log, true, "ERROR: --change-permissions is no longer supported")
	}

	var syncSig syscall.Signal
	if *flSyncOnSignal != "" {
		if num, err := strconv.ParseInt(*flSyncOnSignal, 0, 0); err == nil {
			// sync-on-signal value is a number
			syncSig = syscall.Signal(num)
		} else {
			// sync-on-signal value is a name
			syncSig = unix.SignalNum(*flSyncOnSignal)
			if syncSig == 0 {
				// last resort - maybe they said "HUP", meaning "SIGHUP"
				syncSig = unix.SignalNum("SIG" + *flSyncOnSignal)
			}
		}
		if syncSig == 0 {
			handleConfigError(log, true, "ERROR: --sync-on-signal must be a valid signal name or number")
		}
	}

	if *flDeprecatedTimeout != 0 {
		// Back-compat
		log.V(0).Info("setting --sync-timeout from deprecated --timeout")
		*flSyncTimeout = time.Duration(*flDeprecatedTimeout) * time.Second
	}
	if *flSyncTimeout < 10*time.Millisecond {
		handleConfigError(log, true, "ERROR: --sync-timeout must be at least 10ms")
	}

	if *flDeprecatedMaxSyncFailures != 0 {
		// Back-compat
		log.V(0).Info("setting --max-failures from deprecated --max-sync-failures")
		*flMaxFailures = *flDeprecatedMaxSyncFailures
	}

	if *flDeprecatedSyncHookCommand != "" {
		// Back-compat
		log.V(0).Info("setting --exechook-command from deprecated --sync-hook-command")
		*flExechookCommand = *flDeprecatedSyncHookCommand
	}
	if *flExechookCommand != "" {
		if *flExechookTimeout < time.Second {
			handleConfigError(log, true, "ERROR: --exechook-timeout must be at least 1s")
		}
		if *flExechookBackoff < time.Second {
			handleConfigError(log, true, "ERROR: --exechook-backoff must be at least 1s")
		}
	}

	if *flWebhookURL != "" {
		if *flWebhookStatusSuccess == -1 {
			// Back-compat: -1 and 0 mean the same things
			*flWebhookStatusSuccess = 0
		}
		if *flWebhookStatusSuccess < 0 {
			handleConfigError(log, true, "ERROR: --webhook-success-status must be a valid HTTP code or 0")
		}
		if *flWebhookTimeout < time.Second {
			handleConfigError(log, true, "ERROR: --webhook-timeout must be at least 1s")
		}
		if *flWebhookBackoff < time.Second {
			handleConfigError(log, true, "ERROR: --webhook-backoff must be at least 1s")
		}
	}

	if *flPassword != "" && *flPasswordFile != "" {
		handleConfigError(log, true, "ERROR: only one of --password and --password-file may be specified")
	}
	if *flUsername != "" {
		if *flPassword == "" && *flPasswordFile == "" {
			handleConfigError(log, true, "ERROR: --password or --password-file must be set when --username is specified")
		}
	}

	if *flSSH {
		if *flUsername != "" {
			handleConfigError(log, true, "ERROR: only one of --ssh and --username may be specified")
		}
		if *flPassword != "" {
			handleConfigError(log, true, "ERROR: only one of --ssh and --password may be specified")
		}
		if *flPasswordFile != "" {
			handleConfigError(log, true, "ERROR: only one of --ssh and --password-file may be specified")
		}
		if *flAskPassURL != "" {
			handleConfigError(log, true, "ERROR: only one of --ssh and --askpass-url may be specified")
		}
		if *flCookieFile {
			handleConfigError(log, true, "ERROR: only one of --ssh and --cookie-file may be specified")
		}
		if *flSSHKeyFile == "" {
			handleConfigError(log, true, "ERROR: --ssh-key-file must be specified when --ssh is set")
		}
		if *flSSHKnownHosts {
			if *flSSHKnownHostsFile == "" {
				handleConfigError(log, true, "ERROR: --ssh-known-hosts-file must be specified when --ssh-known-hosts is set")
			}
		}
	}

	if *flHTTPBind == "" {
		if *flHTTPMetrics {
			handleConfigError(log, true, "ERROR: --http-bind must be specified when --http-metrics is set")
		}
		if *flHTTPprof {
			handleConfigError(log, true, "ERROR: --http-bind must be specified when --http-pprof is set")
		}
	}

	//
	// From here on, output goes through logging.
	//

	log.V(0).Info("starting up",
		"pid", os.Getpid(),
		"uid", os.Getuid(),
		"gid", os.Getgid(),
		"home", os.Getenv("HOME"),
		"flags", logSafeFlags())

	if _, err := exec.LookPath(*flGitCmd); err != nil {
		log.Error(err, "ERROR: git executable not found", "git", *flGitCmd)
		os.Exit(1)
	}

	// If the user asked for group-writable data, make sure the umask allows it.
	if *flGroupWrite {
		syscall.Umask(0002)
	} else {
		syscall.Umask(0022)
	}

	// Make sure the root exists.  defaultDirMode ensures that this is usable
	// as a volume when the consumer isn't running as the same UID.  We do this
	// very early so that we can normalize the path even when there are
	// symlinks in play.
	if err := os.MkdirAll(absRoot.String(), defaultDirMode); err != nil {
		log.Error(err, "ERROR: can't make root dir", "path", absRoot)
		os.Exit(1)
	}
	// Get rid of symlinks in the root path to avoid getting confused about
	// them later.  The path must exist for EvalSymlinks to work.
	if delinked, err := filepath.EvalSymlinks(absRoot.String()); err != nil {
		log.Error(err, "ERROR: can't normalize root path", "path", absRoot)
		os.Exit(1)
	} else {
		absRoot = absPath(delinked)
	}
	if absRoot.String() != *flRoot {
		log.V(0).Info("normalized root path", "root", *flRoot, "result", absRoot)
	}

	// Convert files into an absolute paths.
	absLink := makeAbsPath(*flLink, absRoot)
	absTouchFile := makeAbsPath(*flTouchFile, absRoot)

	if *flAddUser {
		if err := addUser(); err != nil {
			log.Error(err, "ERROR: can't add user")
			os.Exit(1)
		}
	}

	// Don't pollute the user's .gitconfig if this is being run directly.
	if f, err := os.CreateTemp("", "git-sync.gitconfig.*"); err != nil {
		log.Error(err, "ERROR: can't create gitconfig file")
		os.Exit(1)
	} else {
		gitConfig := f.Name()
		f.Close()
		os.Setenv("GIT_CONFIG_GLOBAL", gitConfig)
		os.Setenv("GIT_CONFIG_NOSYSTEM", "true")
		log.V(2).Info("created private gitconfig file", "path", gitConfig)
	}

	// Capture the various git parameters.
	git := &repoSync{
		cmd:          *flGitCmd,
		root:         absRoot,
		repo:         *flRepo,
		ref:          *flRef,
		depth:        *flDepth,
		submodules:   submodulesMode(*flSubmodules),
		gc:           gcMode(*flGitGC),
		link:         absLink,
		authURL:      *flAskPassURL,
		sparseFile:   *flSparseCheckoutFile,
		log:          log,
		run:          cmdRunner,
		staleTimeout: *flStaleWorktreeTimeout,
	}

	// This context is used only for git credentials initialization. There are
	// no long-running operations like `git fetch`, so hopefully 30 seconds will be enough.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)

	// Set various configs we want, but users might override.
	if err := git.SetupDefaultGitConfigs(ctx); err != nil {
		log.Error(err, "can't set default git configs")
		os.Exit(1)
	}

	if *flUsername != "" {
		if *flPasswordFile != "" {
			passwordFileBytes, err := os.ReadFile(*flPasswordFile)
			if err != nil {
				log.Error(err, "can't read password file", "file", *flPasswordFile)
				os.Exit(1)
			}
			*flPassword = string(passwordFileBytes)
		}
	}

	if *flSSH {
		if err := git.SetupGitSSH(*flSSHKnownHosts, *flSSHKeyFile, *flSSHKnownHostsFile); err != nil {
			log.Error(err, "can't set up git SSH", "keyFile", *flSSHKeyFile, "knownHosts", *flSSHKnownHosts, "knownHostsFile", *flSSHKnownHostsFile)
			os.Exit(1)
		}
	}

	if *flCookieFile {
		if err := git.SetupCookieFile(ctx); err != nil {
			log.Error(err, "can't set up git cookie file")
			os.Exit(1)
		}
	}

	// This needs to be after all other git-related config flags.
	if *flGitConfig != "" {
		if err := git.SetupExtraGitConfigs(ctx, *flGitConfig); err != nil {
			log.Error(err, "can't set additional git configs", "configs", *flGitConfig)
			os.Exit(1)
		}
	}

	// The scope of the initialization context ends here, so we call cancel to release resources associated with it.
	cancel()

	if *flHTTPBind != "" {
		ln, err := net.Listen("tcp", *flHTTPBind)
		if err != nil {
			log.Error(err, "can't bind HTTP endpoint", "endpoint", *flHTTPBind)
			os.Exit(1)
		}
		mux := http.NewServeMux()
		reasons := []string{}

		// This is a dumb liveliness check endpoint. Currently this checks
		// nothing and will always return 200 if the process is live.
		mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			if !getRepoReady() {
				http.Error(w, "repo is not ready", http.StatusServiceUnavailable)
			}
			// Otherwise success
		})
		reasons = append(reasons, "liveness")

		if *flHTTPMetrics {
			mux.Handle("/metrics", promhttp.Handler())
			reasons = append(reasons, "metrics")
		}

		if *flHTTPprof {
			mux.HandleFunc("/debug/pprof/", pprof.Index)
			mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
			mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
			mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
			mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
			reasons = append(reasons, "pprof")
		}

		log.V(0).Info("serving HTTP", "endpoint", *flHTTPBind, "reasons", reasons)
		go func() {
			err := http.Serve(ln, mux)
			log.Error(err, "HTTP server terminated")
			os.Exit(1)
		}()
	}

	// Startup webhooks goroutine
	var webhookRunner *hook.HookRunner
	if *flWebhookURL != "" {
		log := log.WithName("webhook")
		webhook := hook.NewWebhook(
			*flWebhookURL,
			*flWebhookMethod,
			*flWebhookStatusSuccess,
			*flWebhookTimeout,
			log,
		)
		webhookRunner = hook.NewHookRunner(
			webhook,
			*flWebhookBackoff,
			hook.NewHookData(),
			log,
			*flOneTime,
		)
		go webhookRunner.Run(context.Background())
	}

	// Startup exechooks goroutine
	var exechookRunner *hook.HookRunner
	if *flExechookCommand != "" {
		log := log.WithName("exechook")
		exechook := hook.NewExechook(
			cmd.NewRunner(log),
			*flExechookCommand,
			func(hash string) string {
				return git.worktreeFor(hash).Path().String()
			},
			[]string{},
			*flExechookTimeout,
			log,
		)
		exechookRunner = hook.NewHookRunner(
			exechook,
			*flExechookBackoff,
			hook.NewHookData(),
			log,
			*flOneTime,
		)
		go exechookRunner.Run(context.Background())
	}

	// Setup signal notify channel
	sigChan := make(chan os.Signal, 1)
	if syncSig != 0 {
		log.V(1).Info("installing signal handler", "signal", unix.SignalName(syncSig))
		signal.Notify(sigChan, syncSig)
	}

	// Craft a function that can be called to refresh credentials when needed.
	refreshCreds := func(ctx context.Context) error {
		// These should all be mutually-exclusive configs.
		if *flUsername != "" {
			if err := git.StoreCredentials(ctx, *flUsername, *flPassword); err != nil {
				return err
			}
		}
		if *flAskPassURL != "" {
			// When using an auth URL, the credentials can be dynamic, and need
			// to be re-fetched each time.
			if err := git.CallAskPassURL(ctx); err != nil {
				metricAskpassCount.WithLabelValues(metricKeyError).Inc()
				return err
			}
			metricAskpassCount.WithLabelValues(metricKeySuccess).Inc()
		}
		return nil
	}

	failCount := 0
	firstLoop := true
	for {
		start := time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), *flSyncTimeout)

		if changed, hash, err := git.SyncRepo(ctx, refreshCreds); err != nil {
			failCount++
			updateSyncMetrics(metricKeyError, start)
			if *flMaxFailures >= 0 && failCount >= *flMaxFailures {
				// Exit after too many retries, maybe the error is not recoverable.
				log.Error(err, "too many failures, aborting", "failCount", failCount)
				os.Exit(1)
			}
			log.Error(err, "error syncing repo, will retry", "failCount", failCount)
		} else {
			// this might have been called before, but also might not have
			setRepoReady()
			// We treat the first loop as a sync, including sending hooks.
			if changed || firstLoop {
				if absTouchFile != "" {
					if err := touch(absTouchFile); err != nil {
						log.Error(err, "failed to touch touch-file", "path", absTouchFile)
					} else {
						log.V(3).Info("touched touch-file", "path", absTouchFile)
					}
				}
				if webhookRunner != nil {
					webhookRunner.Send(hash)
				}
				if exechookRunner != nil {
					exechookRunner.Send(hash)
				}
				updateSyncMetrics(metricKeySuccess, start)
			} else {
				updateSyncMetrics(metricKeyNoOp, start)
			}
			firstLoop = false

			// Clean up old worktree(s) and run GC.
			if err := git.cleanup(ctx); err != nil {
				log.Error(err, "git cleanup failed")
			}

			// Determine if git-sync should terminate for one of several reasons
			if *flOneTime {
				// Wait for hooks to complete at least once, if not nil, before
				// checking whether to stop program.
				// Assumes that if hook channels are not nil, they will have at
				// least one value before getting closed
				exitCode := 0 // is 0 if all hooks succeed, else is 1
				if exechookRunner != nil {
					if err := exechookRunner.WaitForCompletion(); err != nil {
						exitCode = 1
					}
				}
				if webhookRunner != nil {
					if err := webhookRunner.WaitForCompletion(); err != nil {
						exitCode = 1
					}
				}
				log.DeleteErrorFile()
				log.V(0).Info("exiting after one sync", "status", exitCode)
				os.Exit(exitCode)
			}

			if isHash, err := git.IsKnownHash(ctx, git.ref); err != nil {
				log.Error(err, "can't tell if ref is a git hash, exiting", "ref", git.ref)
				os.Exit(1)
			} else if isHash {
				log.V(0).Info("ref appears to be a git hash, no further sync needed", "ref", git.ref)
				log.DeleteErrorFile()
				sleepForever()
			}

			if failCount > 0 {
				log.V(4).Info("resetting failure count", "failCount", failCount)
				failCount = 0
			}
			log.DeleteErrorFile()
		}

		log.V(3).Info("next sync", "waitTime", flPeriod.String())
		cancel()

		// Sleep until the next sync. If syncSig is set then the sleep may
		// be interrupted by that signal.
		t := time.NewTimer(*flPeriod)
		select {
		case <-t.C:
		case <-sigChan:
			log.V(1).Info("caught signal", "signal", unix.SignalName(syncSig))
			t.Stop()
		}
	}
}

// mustMarkDeprecated is a helper around pflag.CommandLine.MarkDeprecated.
// It panics if there is an error (as these indicate a coding issue).
// This makes it easier to keep the linters happy.
func mustMarkDeprecated(name string, usageMessage string) {
	err := pflag.CommandLine.MarkDeprecated(name, usageMessage)
	if err != nil {
		panic(fmt.Sprintf("error marking flag %q as deprecated: %v", name, err))
	}
}

// makeAbsPath makes an absolute path from a path which might be absolute
// or relative.  If the path is already absolute, it will be used.  If it is
// not absolute, it will be joined with the provided root. If the path is
// empty, the result will be empty.
func makeAbsPath(path string, root absPath) absPath {
	if path == "" {
		return ""
	}
	if filepath.IsAbs(path) {
		return absPath(path)
	}
	return root.Join(path)
}

// touch will try to ensure that the file at the specified path exists and that
// its timestamps are updated.
func touch(path absPath) error {
	dir := path.Dir()
	if err := os.MkdirAll(dir, defaultDirMode); err != nil {
		return err
	}
	if err := os.Chtimes(path.String(), time.Now(), time.Now()); errors.Is(err, fs.ErrNotExist) {
		file, createErr := os.Create(path.String())
		if createErr != nil {
			return createErr
		}
		return file.Close()
	} else {
		return err
	}
}

const redactedString = "REDACTED"

func redactURL(urlstr string) string {
	u, err := url.Parse(urlstr)
	if err != nil {
		return err.Error()
	}
	if u.User != nil {
		u.User = url.UserPassword(u.User.Username(), redactedString)
	}
	return u.String()
}

// logSafeFlags makes sure any sensitive args (e.g. passwords) are redacted
// before logging.  This returns a slice rather than a map so it is always
// sorted.
func logSafeFlags() []string {
	ret := []string{}
	pflag.VisitAll(func(fl *pflag.Flag) {
		arg := fl.Name
		val := fl.Value.String()

		// Handle --password
		if arg == "password" {
			val = redactedString
		}
		// Handle password embedded in --repo
		if arg == "repo" {
			val = redactURL(val)
		}
		// Don't log empty values
		if val == "" {
			return
		}

		ret = append(ret, "--"+arg+"="+val)
	})
	return ret
}

func updateSyncMetrics(key string, start time.Time) {
	metricSyncDuration.WithLabelValues(key).Observe(time.Since(start).Seconds())
	metricSyncCount.WithLabelValues(key).Inc()
}

// repoReady indicates that the repo has been synced.
var readyLock sync.Mutex
var repoReady = false

func getRepoReady() bool {
	readyLock.Lock()
	defer readyLock.Unlock()
	return repoReady
}

func setRepoReady() {
	readyLock.Lock()
	defer readyLock.Unlock()
	repoReady = true
}

// Do no work, but don't do something that triggers go's runtime into thinking
// it is deadlocked.
func sleepForever() {
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt)
	<-c
	os.Exit(0)
}

// handleConfigError prints the error to the standard error, prints the usage
// if the `printUsage` flag is true, exports the error to the error file and
// exits the process with the exit code.
func handleConfigError(log *logging.Logger, printUsage bool, format string, a ...interface{}) {
	s := fmt.Sprintf(format, a...)
	fmt.Fprintln(os.Stderr, s)
	if printUsage {
		pflag.Usage()
	}
	log.ExportError(s)
	os.Exit(1)
}

// Put the current UID/GID into /etc/passwd so SSH can look it up.  This
// assumes that we have the permissions to write to it.
func addUser() error {
	// Skip if the UID already exists. The Dockerfile already adds the default UID/GID.
	if _, err := user.LookupId(strconv.Itoa(os.Getuid())); err == nil {
		return nil
	}
	home := os.Getenv("HOME")
	if home == "" {
		cwd, err := os.Getwd()
		if err != nil {
			return fmt.Errorf("can't get working directory and $HOME is not set: %w", err)
		}
		home = cwd
	}

	f, err := os.OpenFile("/etc/passwd", os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()

	str := fmt.Sprintf("git-sync:x:%d:%d::%s:/sbin/nologin\n", os.Getuid(), os.Getgid(), home)
	_, err = f.WriteString(str)
	return err
}

// Run runs `git` with the specified args.
func (git *repoSync) Run(ctx context.Context, cwd absPath, args ...string) (string, string, error) {
	return git.run.WithCallDepth(1).Run(ctx, cwd.String(), nil, git.cmd, args...)
}

// Run runs `git` with the specified args and stdin.
func (git *repoSync) RunWithStdin(ctx context.Context, cwd absPath, stdin string, args ...string) (string, string, error) {
	return git.run.WithCallDepth(1).RunWithStdin(ctx, cwd.String(), nil, stdin, git.cmd, args...)
}

// initRepo examines the git repo and determines if it is usable or not.  If
// not, it will (re)initialize it.  After running this function, callers can
// assume the repo is valid, though maybe empty.
func (git *repoSync) initRepo(ctx context.Context) error {
	needGitInit := false

	// Check out the git root, and see if it is already usable.
	_, err := os.Stat(git.root.String())
	switch {
	case os.IsNotExist(err):
		// Probably the first sync.  defaultDirMode ensures that this is usable
		// as a volume when the consumer isn't running as the same UID.
		git.log.V(1).Info("repo directory does not exist, creating it", "path", git.root)
		if err := os.MkdirAll(git.root.String(), defaultDirMode); err != nil {
			return err
		}
		needGitInit = true
	case err != nil:
		return err
	default:
		// Make sure the directory we found is actually usable.
		git.log.V(3).Info("repo directory exists", "path", git.root)
		if git.sanityCheckRepo(ctx) {
			git.log.V(4).Info("repo directory is valid", "path", git.root)
		} else {
			// Maybe a previous run crashed?  Git won't use this dir.  We remove
			// the contents rather than the dir itself, because a common use-case
			// is to have a volume mounted at git.root, which makes removing it
			// impossible.
			git.log.V(0).Info("repo directory failed checks or was empty", "path", git.root)
			if err := removeDirContents(git.root, git.log); err != nil {
				return fmt.Errorf("can't wipe unusable root directory: %w", err)
			}
			needGitInit = true
		}
	}

	if needGitInit {
		// Running `git init` in an existing repo is safe (according to git docs).
		git.log.V(0).Info("initializing repo directory", "path", git.root)
		if _, _, err := git.Run(ctx, git.root, "init", "-b", "git-sync"); err != nil {
			return err
		}
		if !git.sanityCheckRepo(ctx) {
			return fmt.Errorf("can't initialize git repo directory")
		}
	}

	// The "origin" remote has special meaning, like in relative-path
	// submodules.
	if stdout, stderr, err := git.Run(ctx, git.root, "remote", "get-url", "origin"); err != nil {
		if !strings.Contains(stderr, "No such remote") {
			return err
		}
		// It doesn't exist - make it.
		if _, _, err := git.Run(ctx, git.root, "remote", "add", "origin", git.repo); err != nil {
			return err
		}
	} else if strings.TrimSpace(stdout) != git.repo {
		// It exists, but is wrong.
		if _, _, err := git.Run(ctx, git.root, "remote", "set-url", "origin", git.repo); err != nil {
			return err
		}
	}

	return nil
}

func (git *repoSync) removeStaleWorktrees() (int, error) {
	currentWorktree, err := git.currentWorktree()
	if err != nil {
		return 0, err
	}

	git.log.V(3).Info("cleaning up stale worktrees", "currentHash", currentWorktree.Hash())

	count := 0
	err = removeDirContentsIf(git.worktreeFor("").Path(), git.log, func(fi os.FileInfo) (bool, error) {
		// delete files that are over the stale time out, and make sure to never delete the current worktree
		if fi.Name() != currentWorktree.Hash() && time.Since(fi.ModTime()) > git.staleTimeout {
			count++
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		return 0, err
	}
	return count, nil
}

// sanityCheckRepo tries to make sure that the repo dir is a valid git repository.
func (git *repoSync) sanityCheckRepo(ctx context.Context) bool {
	git.log.V(3).Info("sanity-checking git repo", "repo", git.root)
	// If it is empty, we are done.
	if empty, err := dirIsEmpty(git.root); err != nil {
		git.log.Error(err, "can't list repo directory", "path", git.root)
		return false
	} else if empty {
		git.log.V(3).Info("repo directory is empty", "path", git.root)
		return false
	}

	// Check that this is actually the root of the repo.
	if root, _, err := git.Run(ctx, git.root, "rev-parse", "--show-toplevel"); err != nil {
		git.log.Error(err, "can't get repo toplevel", "path", git.root)
		return false
	} else {
		root = strings.TrimSpace(root)
		if root != git.root.String() {
			git.log.Error(nil, "repo directory is under another repo", "path", git.root, "parent", root)
			return false
		}
	}

	// Consistency-check the repo.  Don't use --verbose because it can be
	// REALLY verbose.
	if _, _, err := git.Run(ctx, git.root, "fsck", "--no-progress", "--connectivity-only"); err != nil {
		git.log.Error(err, "repo fsck failed", "path", git.root)
		return false
	}

	return true
}

// sanityCheckWorktree tries to make sure that the dir is a valid git
// repository.  Note that this does not guarantee that the worktree has all the
// files checked out - git could have died halfway through and the repo will
// still pass this check.
func (git *repoSync) sanityCheckWorktree(ctx context.Context, worktree worktree) bool {
	git.log.V(3).Info("sanity-checking worktree", "repo", git.root, "worktree", worktree)

	// If it is empty, we are done.
	if empty, err := dirIsEmpty(worktree.Path()); err != nil {
		git.log.Error(err, "can't list worktree directory", "path", worktree.Path())
		return false
	} else if empty {
		git.log.V(0).Info("worktree is empty", "path", worktree.Path())
		return false
	}

	// Consistency-check the worktree.  Don't use --verbose because it can be
	// REALLY verbose.
	if _, _, err := git.Run(ctx, worktree.Path(), "fsck", "--no-progress", "--connectivity-only"); err != nil {
		git.log.Error(err, "worktree fsck failed", "path", worktree.Path())
		return false
	}

	return true
}

func dirIsEmpty(dir absPath) (bool, error) {
	dirents, err := os.ReadDir(dir.String())
	if err != nil {
		return false, err
	}
	return len(dirents) == 0, nil
}

// removeDirContents iterated the specified dir and removes all contents
func removeDirContents(dir absPath, log *logging.Logger) error {
	return removeDirContentsIf(dir, log, func(fi os.FileInfo) (bool, error) {
		return true, nil
	})
}

func removeDirContentsIf(dir absPath, log *logging.Logger, fn func(fi os.FileInfo) (bool, error)) error {
	dirents, err := os.ReadDir(dir.String())
	if err != nil {
		return err
	}

	// Save errors until the end.
	var errs multiError
	for _, fi := range dirents {
		name := fi.Name()
		p := filepath.Join(dir.String(), name)
		stat, err := os.Stat(p)
		if err != nil {
			log.Error(err, "failed to stat path, skipping", "path", p)
			continue
		}
		if shouldDelete, err := fn(stat); err != nil {
			log.Error(err, "predicate function failed for path, skipping", "path", p)
			continue
		} else if !shouldDelete {
			log.V(4).Info("skipping path", "path", p)
			continue
		}
		if log != nil {
			log.V(4).Info("removing path recursively", "path", p, "isDir", fi.IsDir())
		}
		if err := os.RemoveAll(p); err != nil {
			errs = append(errs, err)
		}
	}

	if len(errs) != 0 {
		return errs
	}
	return nil
}

// publishSymlink atomically sets link to point at the specified target.  If the
// link existed, this returns the previous target.
func (git *repoSync) publishSymlink(ctx context.Context, worktree worktree) error {
	targetPath := worktree.Path()
	linkDir, linkFile := git.link.Split()

	// Make sure the link directory exists.
	if err := os.MkdirAll(linkDir, defaultDirMode); err != nil {
		return fmt.Errorf("error making symlink dir: %w", err)
	}

	// newDir is absolute, so we need to change it to a relative path.  This is
	// so it can be volume-mounted at another path and the symlink still works.
	targetRelative, err := filepath.Rel(linkDir, targetPath.String())
	if err != nil {
		return fmt.Errorf("error converting to relative path: %w", err)
	}

	const tmplink = "tmp-link"
	git.log.V(2).Info("creating tmp symlink", "dir", linkDir, "link", tmplink, "target", targetRelative)
	if err := os.Symlink(targetRelative, filepath.Join(linkDir, tmplink)); err != nil {
		return fmt.Errorf("error creating symlink: %w", err)
	}

	git.log.V(2).Info("renaming symlink", "root", linkDir, "oldName", tmplink, "newName", linkFile)
	if err := os.Rename(filepath.Join(linkDir, tmplink), git.link.String()); err != nil {
		return fmt.Errorf("error replacing symlink: %w", err)
	}

	return nil
}

// removeWorktree is used to remove a worktree and its folder
func (git *repoSync) removeWorktree(ctx context.Context, worktree worktree) error {
	// Clean up worktree, if needed.
	_, err := os.Stat(worktree.Path().String())
	switch {
	case os.IsNotExist(err):
		return nil
	case err != nil:
		return err
	}
	git.log.V(1).Info("removing worktree", "path", worktree.Path())
	if err := os.RemoveAll(worktree.Path().String()); err != nil {
		return fmt.Errorf("error removing directory: %w", err)
	}
	if _, _, err := git.Run(ctx, git.root, "worktree", "prune", "--verbose"); err != nil {
		return err
	}
	return nil
}

// createWorktree creates a new worktree and checks out the given hash.  This
// returns the path to the new worktree.
func (git *repoSync) createWorktree(ctx context.Context, hash string) (worktree, error) {
	// Make a worktree for this exact git hash.
	worktree := git.worktreeFor(hash)

	// Avoid wedge cases where the worktree was created but this function
	// error'd without cleaning up.  The next time thru the sync loop fails to
	// create the worktree and bails out. This manifests as:
	//     "fatal: '/repo/root/nnnn' already exists"
	if err := git.removeWorktree(ctx, worktree); err != nil {
		return "", err
	}

	git.log.V(1).Info("adding worktree", "path", worktree.Path(), "hash", hash)
	_, _, err := git.Run(ctx, git.root, "worktree", "add", "--force", "--detach", worktree.Path().String(), hash, "--no-checkout")
	if err != nil {
		return "", err
	}

	return worktree, nil
}

// configureWorktree applies some configuration (e.g. sparse checkout) to
// the specified worktree and checks out the specified hash and submodules.
func (git *repoSync) configureWorktree(ctx context.Context, worktree worktree) error {
	hash := worktree.Hash()

	// The .git file in the worktree directory holds a reference to
	// /git/.git/worktrees/<worktree-dir-name>. Replace it with a reference
	// using relative paths, so that other containers can use a different volume
	// mount name.
	rootDotGit := ""
	if rel, err := filepath.Rel(worktree.Path().String(), git.root.String()); err != nil {
		return err
	} else {
		rootDotGit = filepath.Join(rel, ".git")
	}
	gitDirRef := []byte("gitdir: " + filepath.Join(rootDotGit, "worktrees", hash) + "\n")
	if err := os.WriteFile(worktree.Path().Join(".git").String(), gitDirRef, 0644); err != nil {
		return err
	}

	// If sparse checkout is requested, configure git for it, otherwise
	// unconfigure it.
	gitInfoPath := filepath.Join(git.root.String(), ".git/worktrees", hash, "info")
	gitSparseConfigPath := filepath.Join(gitInfoPath, "sparse-checkout")
	if git.sparseFile == "" {
		os.RemoveAll(gitSparseConfigPath)
	} else {
		// This is required due to the undocumented behavior outlined here:
		// https://public-inbox.org/git/CAPig+cSP0UiEBXSCi7Ua099eOdpMk8R=JtAjPuUavRF4z0R0Vg@mail.gmail.com/t/
		git.log.V(1).Info("configuring worktree sparse checkout")
		checkoutFile := git.sparseFile

		source, err := os.Open(checkoutFile)
		if err != nil {
			return err
		}
		defer source.Close()

		if _, err := os.Stat(gitInfoPath); os.IsNotExist(err) {
			err := os.Mkdir(gitInfoPath, defaultDirMode)
			if err != nil {
				return err
			}
		}

		destination, err := os.Create(gitSparseConfigPath)
		if err != nil {
			return err
		}
		defer destination.Close()

		_, err = io.Copy(destination, source)
		if err != nil {
			return err
		}

		args := []string{"sparse-checkout", "init"}
		if _, _, err = git.Run(ctx, worktree.Path(), args...); err != nil {
			return err
		}
	}

	// Reset the worktree's working copy to the specific ref.
	git.log.V(1).Info("setting worktree HEAD", "hash", hash)
	if _, _, err := git.Run(ctx, worktree.Path(), "reset", "--hard", hash, "--"); err != nil {
		return err
	}

	// Update submodules
	// NOTE: this works for repo with or without submodules.
	if git.submodules != submodulesOff {
		git.log.V(1).Info("updating submodules")
		submodulesArgs := []string{"submodule", "update", "--init"}
		if git.submodules == submodulesRecursive {
			submodulesArgs = append(submodulesArgs, "--recursive")
		}
		if git.depth != 0 {
			submodulesArgs = append(submodulesArgs, "--depth", strconv.Itoa(git.depth))
		}
		if _, _, err := git.Run(ctx, worktree.Path(), submodulesArgs...); err != nil {
			return err
		}
	}

	return nil
}

// cleanup removes old worktrees and runs git's garbage collection.  The
// specified worktree is preserved.
func (git *repoSync) cleanup(ctx context.Context) error {
	// Save errors until the end.
	var cleanupErrs multiError

	// Clean up previous worktree(s).
	if n, err := git.removeStaleWorktrees(); err != nil {
		cleanupErrs = append(cleanupErrs, err)
	} else if n == 0 {
		// We didn't clean up any worktrees, so the rest of this is moot.
		return nil
	}

	// Let git know we don't need those old commits any more.
	git.log.V(3).Info("pruning worktrees")
	if _, _, err := git.Run(ctx, git.root, "worktree", "prune", "--verbose"); err != nil {
		cleanupErrs = append(cleanupErrs, err)
	}

	// Expire old refs.
	git.log.V(3).Info("expiring unreachable refs")
	if _, _, err := git.Run(ctx, git.root, "reflog", "expire", "--expire-unreachable=all", "--all"); err != nil {
		cleanupErrs = append(cleanupErrs, err)
	}

	// Run GC if needed.
	if git.gc != gcOff {
		args := []string{"gc"}
		switch git.gc {
		case gcAuto:
			args = append(args, "--auto")
		case gcAlways:
			// no extra flags
		case gcAggressive:
			args = append(args, "--aggressive")
		}
		git.log.V(3).Info("running git garbage collection")
		if _, _, err := git.Run(ctx, git.root, args...); err != nil {
			cleanupErrs = append(cleanupErrs, err)
		}
	}

	if len(cleanupErrs) > 0 {
		return cleanupErrs
	}
	return nil
}

type multiError []error

func (m multiError) Error() string {
	if len(m) == 0 {
		return "<no error>"
	}
	if len(m) == 1 {
		return m[0].Error()
	}
	strs := make([]string, 0, len(m))
	for _, e := range m {
		strs = append(strs, e.Error())
	}
	return strings.Join(strs, "; ")
}

// remoteHashForRef returns the upstream hash for a given ref.
func (git *repoSync) remoteHashForRef(ctx context.Context, ref string) (string, error) {
	// Fetch both the bare and dereferenced ref. git sorts the results and
	// prints the dereferenced result, if present, after the bare result, so we
	// always want the last result it produces.
	output, _, err := git.Run(ctx, git.root, "ls-remote", "-q", git.repo, ref, ref+"^{}")
	if err != nil {
		return "", err
	}
	line := lastNonEmptyLine(output)
	parts := strings.Split(line, "\t") // guaranteed to have at least 1 element
	return parts[0], nil
}

func lastNonEmptyLine(text string) string {
	lines := strings.Split(text, "\n") // guaranteed to have at least 1 element
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line != "" {
			return line
		}
	}
	return ""
}

// IsKnownHash returns true if ref is the hash of a commit which is known to this
// repo.  In the event that ref is an abbreviated hash (e.g. "abcd" which
// resolves to "abcdef1234567890"), this will return true by prefix-matching.
// If ref is ambiguous, it will consider whatever result git returns.  If ref
// is not a hash or is not known to this repo, even if it appears to be a hash,
// this will return false.
func (git *repoSync) IsKnownHash(ctx context.Context, ref string) (bool, error) {
	stdout, stderr, err := git.Run(ctx, git.root, "rev-parse", ref+"^{commit}")
	if err != nil {
		if strings.Contains(stderr, "unknown revision") {
			return false, nil
		}
		return false, err
	}
	line := lastNonEmptyLine(stdout)
	return strings.HasPrefix(line, ref), nil
}

// worktree represents a git worktree (which may or may not exist on disk).
type worktree absPath

// Hash returns the intended commit hash for this worktree.
func (wt worktree) Hash() string {
	if wt == "" {
		return ""
	}
	return absPath(wt).Base()
}

// path returns the absolute path to this worktree (which may not actually
// exist on disk).
func (wt worktree) Path() absPath {
	return absPath(wt)
}

// worktreeFor returns a worktree value for the given hash, which can be used
// to find the on-disk path of that worktree.  Caller should not make
// assumptions about the on-disk location where worktrees are stored.  If hash
// is "", this returns the base worktree directory.
func (git *repoSync) worktreeFor(hash string) worktree {
	return worktree(git.root.Join(".worktrees", hash))
}

// currentWorktree reads the repo's link and returns a worktree value for it.
func (git *repoSync) currentWorktree() (worktree, error) {
	target, err := os.Readlink(git.link.String())
	if err != nil && !os.IsNotExist(err) {
		return "", err
	}
	if target == "" {
		return "", nil
	}
	if filepath.IsAbs(target) {
		return worktree(target), nil
	}
	return worktree(git.root.Join(target)), nil
}

// SyncRepo syncs the repository to the desired ref, publishes it via the link,
// and tries to clean up any detritus.  This function returns whether the
// current hash has changed and what the new hash is.
func (git *repoSync) SyncRepo(ctx context.Context, refreshCreds func(context.Context) error) (bool, string, error) {
	git.log.V(3).Info("syncing", "repo", git.repo)

	if err := refreshCreds(ctx); err != nil {
		return false, "", fmt.Errorf("credential refresh failed: %w", err)
	}

	// Initialize the repo directory if needed.
	if err := git.initRepo(ctx); err != nil {
		return false, "", err
	}

	// Figure out what hash the remote resolves to.
	remoteHash, err := git.remoteHashForRef(ctx, git.ref)
	if err != nil {
		return false, "", err
	}

	// If we couldn't find a remote commit, it might have been a hash literal.
	if remoteHash == "" {
		// If git thinks it tastes like a hash, we just use that and if it
		// is wrong, we will fail later.
		output, _, err := git.Run(ctx, git.root, "rev-parse", git.ref)
		if err != nil {
			return false, "", err
		}
		result := strings.Trim(output, "\n")
		if result == git.ref {
			remoteHash = git.ref
		}
	}

	// Find out what we currently have synced, if anything.
	var currentWorktree worktree
	if wt, err := git.currentWorktree(); err != nil {
		return false, "", err
	} else {
		currentWorktree = wt
	}
	currentHash := currentWorktree.Hash()
	git.log.V(3).Info("current hash", "hash", currentHash)

	if currentHash == remoteHash {
		// We seem to have the right hash already.  Let's be sure it's good.
		git.log.V(3).Info("current hash is same as remote", "hash", currentHash)
		if !git.sanityCheckWorktree(ctx, currentWorktree) {
			// Sanity check failed, nuke it and start over.
			git.log.V(0).Info("worktree failed checks or was empty", "path", currentWorktree)
			if err := git.removeWorktree(ctx, currentWorktree); err != nil {
				return false, "", err
			}
			currentHash = ""
		}
	}

	// This catches in-place upgrades from older versions where the worktree
	// path was different.
	changed := (currentHash != remoteHash) || (currentWorktree != git.worktreeFor(currentHash))

	// We have to do at least one fetch, to ensure that parameters like depth
	// are set properly.  This is cheap when we already have the target hash.
	if changed || git.syncCount == 0 {
		git.log.V(0).Info("update required", "ref", git.ref, "local", currentHash, "remote", remoteHash, "syncCount", git.syncCount)

		// Parameters like depth are set at fetch time.
		if err := git.fetch(ctx, remoteHash); err != nil {
			return false, "", err
		}
		metricFetchCount.Inc()

		// Reset the repo (note: not the worktree - that happens later) to the new
		// ref.  This makes subsequent fetches much less expensive.  It uses --soft
		// so no files are checked out.
		if _, _, err := git.Run(ctx, git.root, "reset", "--soft", "FETCH_HEAD"); err != nil {
			return false, "", err
		}

		// If we have a new hash, make a new worktree
		newWorktree := currentWorktree
		if changed {
			// Create a worktree for this hash in git.root.
			if wt, err := git.createWorktree(ctx, remoteHash); err != nil {
				return false, "", err
			} else {
				newWorktree = wt
			}
		}

		// Even if this worktree existed and passes sanity, it might not have all
		// the correct settings (e.g. sparse checkout).  The best way to get
		// it all set is just to re-run the configuration,
		if err := git.configureWorktree(ctx, newWorktree); err != nil {
			return false, "", err
		}

		// If we have a new hash, update the symlink to point to the new worktree.
		if changed {
			err := git.publishSymlink(ctx, newWorktree)
			if err != nil {
				return false, "", err
			}
			if currentWorktree != "" {
				// Start the stale worktree removal timer.
				err = touch(currentWorktree.Path())
				if err != nil {
					git.log.Error(err, "can't change stale worktree mtime", "path", currentWorktree.Path())
				}
			}
		}

		// Mark ourselves as "ready".
		setRepoReady()
		git.syncCount++
		git.log.V(0).Info("updated successfully", "ref", git.ref, "remote", remoteHash, "syncCount", git.syncCount)

		// Regular cleanup will happen in the outer loop, to catch stale
		// worktrees.

		if currentWorktree != git.worktreeFor(currentHash) {
			// The old worktree might have come from a prior version, and so
			// not get caught by the normal cleanup.
			os.RemoveAll(currentWorktree.Path().String())
		}
	} else {
		git.log.V(2).Info("update not required", "ref", git.ref, "remote", remoteHash, "syncCount", git.syncCount)
	}

	return changed, remoteHash, nil
}

// fetch retrieves the specified ref from the upstream repo.
func (git *repoSync) fetch(ctx context.Context, ref string) error {
	git.log.V(1).Info("fetching", "ref", ref, "repo", git.repo)

	// Fetch the ref and do some cleanup, setting or un-setting the repo's
	// shallow flag as appropriate.
	args := []string{"fetch", git.repo, ref, "--verbose", "--no-progress", "--prune", "--no-auto-gc"}
	if git.depth > 0 {
		args = append(args, "--depth", strconv.Itoa(git.depth))
	} else {
		// If the local repo is shallow and we're not using depth any more, we
		// need a special case.
		shallow, err := git.isShallow(ctx)
		if err != nil {
			return err
		}
		if shallow {
			args = append(args, "--unshallow")
		}
	}
	if _, _, err := git.Run(ctx, git.root, args...); err != nil {
		return err
	}

	return nil
}

func (git *repoSync) isShallow(ctx context.Context) (bool, error) {
	boolStr, _, err := git.Run(ctx, git.root, "rev-parse", "--is-shallow-repository")
	if err != nil {
		return false, fmt.Errorf("can't determine repo shallowness: %w", err)
	}
	boolStr = strings.TrimSpace(boolStr)
	switch boolStr {
	case "true":
		return true, nil
	case "false":
		return false, nil
	}
	return false, fmt.Errorf("unparseable bool: %q", boolStr)
}

func md5sum(s string) string {
	h := md5.New()
	if _, err := io.WriteString(h, s); err != nil {
		// Documented as never failing, so panic
		panic(fmt.Sprintf("md5 WriteString failed: %v", err))
	}
	return fmt.Sprintf("%x", h.Sum(nil))
}

// StoreCredentials stores the username and password for later use.
func (git *repoSync) StoreCredentials(ctx context.Context, username, password string) error {
	git.log.V(1).Info("storing git credentials")
	git.log.V(9).Info("md5 of credentials", "username", md5sum(username), "password", md5sum(password))

	creds := fmt.Sprintf("url=%v\nusername=%v\npassword=%v\n", git.repo, username, password)
	_, _, err := git.RunWithStdin(ctx, "", creds, "credential", "approve")
	if err != nil {
		return fmt.Errorf("can't configure git credentials: %w", err)
	}

	return nil
}

func (git *repoSync) SetupGitSSH(setupKnownHosts bool, pathToSSHSecret, pathToSSHKnownHosts string) error {
	git.log.V(1).Info("setting up git SSH credentials")

	// If the user sets GIT_SSH_COMMAND we try to respect it.
	sshCmd := os.Getenv("GIT_SSH_COMMAND")
	if sshCmd == "" {
		sshCmd = "ssh"
	}

	if _, err := os.Stat(pathToSSHSecret); err != nil {
		return fmt.Errorf("can't access SSH key file %s: %w", pathToSSHSecret, err)
	}
	sshCmd += fmt.Sprintf(" -i %s", pathToSSHSecret)

	if setupKnownHosts {
		if _, err := os.Stat(pathToSSHKnownHosts); err != nil {
			return fmt.Errorf("can't access SSH known_hosts file %s: %w", pathToSSHKnownHosts, err)
		}
		sshCmd += fmt.Sprintf(" -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s", pathToSSHKnownHosts)
	} else {
		sshCmd += " -o StrictHostKeyChecking=no"
	}

	git.log.V(9).Info("setting GIT_SSH_COMMAND", "value", sshCmd)
	if err := os.Setenv("GIT_SSH_COMMAND", sshCmd); err != nil {
		return fmt.Errorf("can't set $GIT_SSH_COMMAND: %w", err)
	}

	return nil
}

func (git *repoSync) SetupCookieFile(ctx context.Context) error {
	git.log.V(1).Info("configuring git cookie file")

	var pathToCookieFile = "/etc/git-secret/cookie_file"

	_, err := os.Stat(pathToCookieFile)
	if err != nil {
		return fmt.Errorf("can't access git cookiefile: %w", err)
	}

	if _, _, err = git.Run(ctx, "", "config", "--global", "http.cookiefile", pathToCookieFile); err != nil {
		return fmt.Errorf("can't configure git cookiefile: %w", err)
	}

	return nil
}

// CallAskPassURL consults the specified URL looking for git credentials in the
// response.
//
// The expected URL callback output is below,
// see https://git-scm.com/docs/gitcredentials for more examples:
//
//	username=xxx@example.com
//	password=xxxyyyzzz
func (git *repoSync) CallAskPassURL(ctx context.Context) error {
	git.log.V(3).Info("calling auth URL to get credentials")

	var netClient = &http.Client{
		Timeout: time.Second * 1,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	httpReq, err := http.NewRequestWithContext(ctx, "GET", git.authURL, nil)
	if err != nil {
		return fmt.Errorf("can't create auth request: %w", err)
	}
	resp, err := netClient.Do(httpReq)
	if err != nil {
		return fmt.Errorf("can't access auth URL: %w", err)
	}
	defer func() {
		_ = resp.Body.Close()
	}()
	if resp.StatusCode != 200 {
		errMessage, err := io.ReadAll(resp.Body)
		if err != nil {
			return fmt.Errorf("auth URL returned status %d, failed to read body: %w", resp.StatusCode, err)
		}
		return fmt.Errorf("auth URL returned status %d, body: %q", resp.StatusCode, string(errMessage))
	}
	authData, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("can't read auth response: %w", err)
	}

	username := ""
	password := ""
	for _, line := range strings.Split(string(authData), "\n") {
		keyValues := strings.SplitN(line, "=", 2)
		if len(keyValues) != 2 {
			continue
		}
		switch keyValues[0] {
		case "username":
			username = keyValues[1]
		case "password":
			password = keyValues[1]
		}
	}

	if err := git.StoreCredentials(ctx, username, password); err != nil {
		return err
	}

	return nil
}

// SetupDefaultGitConfigs configures the global git environment with some
// default settings that we need.
func (git *repoSync) SetupDefaultGitConfigs(ctx context.Context) error {
	configs := []keyVal{{
		// Never auto-detach GC runs.
		key: "gc.autoDetach",
		val: "false",
	}, {
		// Fairly aggressive GC.
		key: "gc.pruneExpire",
		val: "now",
	}, {
		// How to manage credentials (for those modes that need it).
		key: "credential.helper",
		val: "cache --timeout 3600",
	}, {
		// Mark repos as safe (avoid a "dubious ownership" error).
		key: "safe.directory",
		val: "*",
	}}

	for _, kv := range configs {
		if _, _, err := git.Run(ctx, "", "config", "--global", kv.key, kv.val); err != nil {
			return fmt.Errorf("error configuring git %q %q: %w", kv.key, kv.val, err)
		}
	}
	return nil
}

// SetupExtraGitConfigs configures the global git environment with user-provided
// override settings.
func (git *repoSync) SetupExtraGitConfigs(ctx context.Context, configsFlag string) error {
	configs, err := parseGitConfigs(configsFlag)
	if err != nil {
		return fmt.Errorf("can't parse --git-config flag: %w", err)
	}
	git.log.V(1).Info("setting additional git configs", "configs", configs)
	for _, kv := range configs {
		if _, _, err := git.Run(ctx, "", "config", "--global", kv.key, kv.val); err != nil {
			return fmt.Errorf("error configuring additional git configs %q %q: %w", kv.key, kv.val, err)
		}
	}

	return nil
}

type keyVal struct {
	key string
	val string
}

func parseGitConfigs(configsFlag string) ([]keyVal, error) {
	// Use a channel as a FIFO.  We don't expect the input strings to be very
	// large, so this simple model should suffice.
	ch := make(chan rune, len(configsFlag))
	go func() {
		for _, r := range configsFlag {
			ch <- r
		}
		close(ch)
	}()

	result := []keyVal{}

	// This assumes it is at the start of a key.
	for {
		cur := keyVal{}
		var err error

		// Peek and see if we have a key.
		if r, ok := <-ch; !ok {
			break
		} else {
			// This can accumulate things that git doesn't allow, but we'll
			// just let git handle it, rather than try to pre-validate to their
			// spec.
			if r == '"' {
				cur.key, err = parseGitConfigQKey(ch)
				if err != nil {
					return nil, err
				}
			} else {
				cur.key, err = parseGitConfigKey(r, ch)
				if err != nil {
					return nil, err
				}
			}
		}

		// Peek and see if we have a value.
		if r, ok := <-ch; !ok {
			return nil, fmt.Errorf("key %q: no value", cur.key)
		} else {
			if r == '"' {
				cur.val, err = parseGitConfigQVal(ch)
				if err != nil {
					return nil, fmt.Errorf("key %q: %w", cur.key, err)
				}
			} else {
				cur.val, err = parseGitConfigVal(r, ch)
				if err != nil {
					return nil, fmt.Errorf("key %q: %w", cur.key, err)
				}
			}
		}

		result = append(result, cur)
	}

	return result, nil
}

func parseGitConfigQKey(ch <-chan rune) (string, error) {
	str, err := parseQString(ch)
	if err != nil {
		return "", err
	}

	// The next character must be a colon.
	r, ok := <-ch
	if !ok {
		return "", fmt.Errorf("unexpected end of key: %q", str)
	}
	if r != ':' {
		return "", fmt.Errorf("unexpected character after quoted key: %q%c", str, r)
	}
	return str, nil
}

func parseGitConfigKey(r rune, ch <-chan rune) (string, error) {
	buf := make([]rune, 0, 64)
	buf = append(buf, r)

	for r := range ch {
		switch {
		case r == ':':
			return string(buf), nil
		default:
			buf = append(buf, r)
		}
	}
	return "", fmt.Errorf("unexpected end of key: %q", string(buf))
}

func parseGitConfigQVal(ch <-chan rune) (string, error) {
	str, err := parseQString(ch)
	if err != nil {
		return "", err
	}

	// If there is a next character, it must be a comma.
	r, ok := <-ch
	if ok && r != ',' {
		return "", fmt.Errorf("unexpected character after quoted value %q%c", str, r)
	}
	return str, nil
}

func parseGitConfigVal(r rune, ch <-chan rune) (string, error) {
	buf := make([]rune, 0, 64)
	buf = append(buf, r)

	for r := range ch {
		switch r {
		case '\\':
			if r, err := unescape(ch); err != nil {
				return "", err
			} else {
				buf = append(buf, r)
			}
		case ',':
			return string(buf), nil
		default:
			buf = append(buf, r)
		}
	}
	// We ran out of characters, but that's OK.
	return string(buf), nil
}

func parseQString(ch <-chan rune) (string, error) {
	buf := make([]rune, 0, 64)

	for r := range ch {
		switch r {
		case '\\':
			if e, err := unescape(ch); err != nil {
				return "", err
			} else {
				buf = append(buf, e)
			}
		case '"':
			return string(buf), nil
		default:
			buf = append(buf, r)
		}
	}
	return "", fmt.Errorf("unexpected end of quoted string: %q", string(buf))
}

// unescape processes most of the documented escapes that git config supports.
func unescape(ch <-chan rune) (rune, error) {
	r, ok := <-ch
	if !ok {
		return 0, fmt.Errorf("unexpected end of escape sequence")
	}
	switch r {
	case 'n':
		return '\n', nil
	case 't':
		return '\t', nil
	case '"', ',', '\\':
		return r, nil
	}
	return 0, fmt.Errorf("unsupported escape character: '%c'", r)
}

// This string is formatted for 80 columns.  Please keep it that way.
// DO NOT USE TABS.
var manual = `
GIT-SYNC

NAME
    git-sync - sync a remote git repository

SYNOPSIS
    git-sync --repo=<repo> --root=<path> [OPTIONS]...

DESCRIPTION

    Fetch a remote git repository to a local directory, poll the remote for
    changes, and update the local copy.

    This is a perfect "sidecar" container in Kubernetes.  For example, it can
    periodically pull files down from a repository so that an application can
    consume them.

    git-sync can pull one time, or on a regular interval.  It can read from the
    HEAD of a branch, from a git tag, or from a specific git hash.  It will only
    re-pull if the target has changed in the remote repository.  When it
    re-pulls, it updates the destination directory atomically.  In order to do
    this, it uses a git worktree in a subdirectory of the --root and flips a
    symlink.

    git-sync can pull over HTTP(S) (with authentication or not) or SSH.

    git-sync can also be configured to make a webhook call upon successful git
    repo synchronization.  The call is made after the symlink is updated.

OPTIONS

    Many options can be specified as either a commandline flag or an environment
    variable, but flags are preferred because a misspelled flag is a fatal
    error while a misspelled environment variable is silently ignored.

    --add-user, $GITSYNC_ADD_USER
            Add a record to /etc/passwd for the current UID/GID.  This is
            needed to use SSH with an arbitrary UID (see --ssh).  This assumes
            that /etc/passwd is writable by the current UID.

    --askpass-url <string>, $GITSYNC_ASKPASS_URL
            A URL to query for git credentials.  The query must return success
            (200) and produce a series of key=value lines, including
            "username=<value>" and "password=<value>".

    --cookie-file <string>, $GITSYNC_COOKIE_FILE
            Use a git cookiefile (/etc/git-secret/cookie_file) for
            authentication.

    --depth <int>, $GITSYNC_DEPTH
            Create a shallow clone with history truncated to the specified
            number of commits.  If not specified, this defaults to syncing a
            single commit.  Setting this to 0 will sync the full history of the
            repo.

    --error-file <string>, $GITSYNC_ERROR_FILE
            The path to an optional file into which errors will be written.
            This may be an absolute path or a relative path, in which case it
            is relative to --root.

    --exechook-backoff <duration>, $GITSYNC_EXECHOOK_BACKOFF
            The time to wait before retrying a failed --exechook-command.  If
            not specified, this defaults to 3 seconds ("3s").

    --exechook-command <string>, $GITSYNC_EXECHOOK_COMMAND
            An optional command to be executed after syncing a new hash of the
            remote repository.  This command does not take any arguments and
            executes with the synced repo as its working directory.  The
            $GITSYNC_HASH environment variable will be set to the git hash that
            was synced.  If, at startup, git-sync finds that the --root already
            has the correct hash, this hook will still be invoked.  This means
            that hooks can be invoked more than one time per hash, so they
            must be idempotent.  This flag obsoletes --sync-hook-command, but
            if sync-hook-command is specified, it will take precedence.

    --exechook-timeout <duration>, $GITSYNC_EXECHOOK_TIMEOUT
            The timeout for the --exechook-command.  If not specifid, this
            defaults to 30 seconds ("30s").

    --git <string>, $GITSYNC_GIT
            The git command to run (subject to PATH search, mostly for
            testing).  This defaults to "git".

    --git-config <string>, $GITSYNC_GIT_CONFIG
            Additional git config options in a comma-separated 'key:val'
            format.  The parsed keys and values are passed to 'git config' and
            must be valid syntax for that command.

            Both keys and values can be either quoted or unquoted strings.
            Within quoted keys and all values (quoted or not), the following
            escape sequences are supported:
                '\n' => [newline]
                '\t' => [tab]
                '\"' => '"'
                '\,' => ','
                '\\' => '\'
            To include a colon within a key (e.g. a URL) the key must be
            quoted.  Within unquoted values commas must be escaped.  Within
            quoted values commas may be escaped, but are not required to be.
            Any other escape sequence is an error.

    --git-gc <string>, $GITSYNC_GIT_GC
            The git garbage collection behavior: one of "auto", "always",
            "aggressive", or "off".  If not specified, this defaults to
            "auto".

            - auto: Run "git gc --auto" once per successful sync.  This mode
              respects git's gc.* config params.
            - always: Run "git gc" once per successful sync.
            - aggressive: Run "git gc --aggressive" once per successful sync.
              This mode can be slow and may require a longer --sync-timeout value.
            - off: Disable explicit git garbage collection, which may be a good
              fit when also using --one-time.

    --group-write, $GITSYNC_GROUP_WRITE
            Ensure that data written to disk (including the git repo metadata,
            checked out files, worktrees, and symlink) are all group writable.
            This corresponds to git's notion of a "shared repository".  This is
            useful in cases where data produced by git-sync is used by a
            different UID.  This replaces the older --change-permissions flag.

    -h, --help
            Print help text and exit.

    --http-bind <string>, $GITSYNC_HTTP_BIND
            The bind address (including port) for git-sync's HTTP endpoint.
            The '/' URL of this endpoint is suitable for Kubernetes startup and
            liveness probes, returning a 5xx error until the first sync is
            complete, and a 200 status thereafter. If not specified, the HTTP
            endpoint is not enabled.

            Examples:
              ":1234": listen on any IP, port 1234
              "127.0.0.1:1234": listen on localhost, port 1234

    --http-metrics, $GITSYNC_HTTP_METRICS
            Enable metrics on git-sync's HTTP endpoint at /metrics.  Requires
            --http-bind to be specified.

    --http-pprof, $GITSYNC_HTTP_PPROF
            Enable the pprof debug endpoints on git-sync's HTTP endpoint at
            /debug/pprof.  Requires --http-bind to be specified.

    --link <string>, $GITSYNC_LINK
            The path to at which to create a symlink which points to the
            current git directory, at the currently synced hash.  This may be
            an absolute path or a relative path, in which case it is relative
            to --root.  Consumers of the synced files should always use this
            link - it is updated atomically and should always be valid.  The
            basename of the target of the link is the current hash.  If not
            specified, this defaults to the leaf dir of --repo.

    --man
            Print this manual and exit.

    --max-failures <int>, $GITSYNC_MAX_FAILURES
            The number of consecutive failures allowed before aborting.
            Setting this to a negative value will retry forever.  If not
            specified, this defaults to 0, meaning any sync failure will
            terminate git-sync.

    --one-time, $GITSYNC_ONE_TIME
            Exit after one sync.

    --password <string>, $GITSYNC_PASSWORD
            The password or personal access token (see github docs) to use for
            git authentication (see --username).  NOTE: for security reasons,
            users should prefer --password-file or $GITSYNC_PASSWORD_FILE for
            specifying the password.

    --password-file <string>, $GITSYNC_PASSWORD_FILE
            The file from which the password or personal access token (see
            github docs) to use for git authentication (see --username) will be
            read.

    --period <duration>, $GITSYNC_PERIOD
            How long to wait between sync attempts.  This must be at least
            10ms.  This flag obsoletes --wait, but if --wait is specified, it
            will take precedence.  If not specified, this defaults to 10
            seconds ("10s").

    --ref <string>, $GITSYNC_REF
            The git revision (branch, tag, or hash) to check out.  If not
            specified, this defaults to "HEAD" (of the upstream repo's default
            branch).

    --repo <string>, $GITSYNC_REPO
            The git repository to sync.  This flag is required.

    --root <string>, $GITSYNC_ROOT
            The root directory for git-sync operations, under which --link will
            be created.  This must be a path that either a) does not exist (it
            will be created); b) is an empty directory; or c) is a directory
            which can be emptied by removing all of the contents.  This flag is
            required.

    --sparse-checkout-file <string>, $GITSYNC_SPARSE_CHECKOUT_FILE
            The path to a git sparse-checkout file (see git documentation for
            details) which controls which files and directories will be checked
            out.  If not specified, the default is to check out the entire repo.

    --ssh, $GITSYNC_SSH
            Use SSH for git authentication and operations.

    --ssh-key-file <string>, $GITSYNC_SSH_KEY_FILE
            The SSH key to use when using --ssh.  If not specified, this
            defaults to "/etc/git-secret/ssh".

    --ssh-known-hosts, $GITSYNC_SSH_KNOWN_HOSTS
            Enable SSH known_hosts verification when using --ssh.  If not
            specified, this defaults to true.

    --ssh-known-hosts-file <string>, $GITSYNC_SSH_KNOWN_HOSTS_FILE
            The known_hosts file to use when --ssh-known-hosts is specified.
            If not specified, this defaults to "/etc/git-secret/known_hosts".

    --stale-worktree-timeout <duration>, $GITSYNC_STALE_WORKTREE_TIMEOUT
            The length of time to retain stale (not the current link target)
            worktrees before being removed. Once this duration has elapsed,
            a stale worktree will be removed during the next sync attempt
            (as determined by --sync-timeout). If not specified, this defaults
            to 0, meaning that stale worktrees will be removed immediately.

    --submodules <string>, $GITSYNC_SUBMODULES
            The git submodule behavior: one of "recursive", "shallow", or
            "off".  If not specified, this defaults to "recursive".

    --sync-on-signal <string>, $GITSYNC_SYNC_ON_SIGNAL
            Indicates that a sync attempt should occur upon receipt of the
            specified signal name (e.g. SIGHUP) or number (e.g. 1). If a sync
            is already in progress, another sync will be triggered as soon as
            the current one completes. If not specified, signals will not
            trigger syncs.

    --sync-timeout <duration>, $GITSYNC_SYNC_TIMEOUT
            The total time allowed for one complete sync.  This must be at least
            10ms.  This flag obsoletes --timeout, but if --timeout is specified,
            it will take precedence.  If not specified, this defaults to 120
            seconds ("120s").

    --touch-file <string>, $GITSYNC_TOUCH_FILE
            The path to an optional file which will be touched whenever a sync
            completes.  This may be an absolute path or a relative path, in
            which case it is relative to --root.

    --username <string>, $GITSYNC_USERNAME
            The username to use for git authentication (see --password-file or
            --password).

    -v, --verbose <int>
            Set the log verbosity level.  Logs at this level and lower will be
            printed.  Logs follow these guidelines:

            - 0: Minimal, just log updates
            - 1: More details about updates
            - 2: Log the sync loop
            - 3: More details about the sync loop
            - 4: More details
            - 5: Log all executed commands
            - 6: Log stdout/stderr of all executed commands
            - 9: Tracing and debug messages

    --version
            Print the version and exit.

    --webhook-backoff <duration>, $GITSYNC_WEBHOOK_BACKOFF
            The time to wait before retrying a failed --webhook-url.  If not
            specified, this defaults to 3 seconds ("3s").

    --webhook-method <string>, $GITSYNC_WEBHOOK_METHOD
            The HTTP method for the --webhook-url.  If not specified, this defaults to "POST".

    --webhook-success-status <int>, $GITSYNC_WEBHOOK_SUCCESS_STATUS
            The HTTP status code indicating a successful --webhook-url.  Setting
            this to 0 disables success checks, which makes webhooks
            "fire-and-forget".  If not specified, this defaults to 200.

    --webhook-timeout <duration>, $GITSYNC_WEBHOOK_TIMEOUT
            The timeout for the --webhook-url.  If not specified, this defaults
            to 1 second ("1s").

    --webhook-url <string>, $GITSYNC_WEBHOOK_URL
            A URL for optional webhook notifications when syncs complete.  The
            header 'Gitsync-Hash' will be set to the git hash that was synced.
            If, at startup, git-sync finds that the --root already has the
            correct hash, this hook will still be invoked.  This means that
            hooks can be invoked more than one time per hash, so they must be
            idempotent.

EXAMPLE USAGE

    git-sync \
        --repo=https://github.com/kubernetes/git-sync \
        --ref=HEAD \
        --period=10s \
        --root=/mnt/git

AUTHENTICATION

    Git-sync offers several authentication options to choose from.  If none of
    the following are specified, git-sync will try to access the repo in the
    "natural" manner.  For example, "https://repo" will try to use plain HTTPS
    and "git@example.com:repo" will try to use SSH.

    username/password
            The --username (GITSYNC_USERNAME) and --password-file
            (GITSYNC_PASSWORD_FILE) or --password (GITSYNC_PASSWORD) flags
            will be used.  To prevent password leaks, the --password-file flag
            or GITSYNC_PASSWORD environment variable is almost always
            preferred to the --password flag.

            A variant of this is --askpass-url (GITSYNC_ASKPASS_URL), which
            consults a URL (e.g. http://metadata) to get credentials on each
            sync.

    SSH
            When --ssh (GITSYNC_SSH) is specified, the --ssh-key-file
            (GITSYNC_SSH_KEY_FILE) will be used.  Users are strongly advised
            to also use --ssh-known-hosts (GITSYNC_SSH_KNOWN_HOSTS) and
            --ssh-known-hosts-file (GITSYNC_SSH_KNOWN_HOSTS_FILE) when using
            SSH.

    cookies
            When --cookie-file (GITSYNC_COOKIE_FILE) is specified, the
            associated cookies can contain authentication information.

HOOKS

    Webhooks and exechooks are executed asynchronously from the main git-sync
    process.  If a --webhook-url or --exechook-command is configured, they will
    be invoked whenever a new hash is synced, including when git-sync starts up
    and find that the --root directory already has the correct hash.  For
    exechook, that means the command is exec()'ed, and for webhooks that means
    an HTTP request is sent using the method defined in --webhook-method.
    Git-sync will retry both forms of hooks until they succeed (exit code 0 for
    exechooks, or --webhook-success-status for webhooks).  If unsuccessful,
    git-sync will wait --exechook-backoff or --webhook-backoff (as appropriate)
    before re-trying the hook.  Git-sync does not ensure that hooks are invoked
    exactly once, so hooks must be idempotent.

    Hooks are not guaranteed to succeed on every single hash change.  For example,
    if a hook fails and a new hash is synced during the backoff period, the
    retried hook will fire for the newest hash.
`

func printManPage() {
	fmt.Print(manual)
}
