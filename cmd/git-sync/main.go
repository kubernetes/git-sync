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
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"net"
	"net/http"
	"net/http/pprof"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"k8s.io/git-sync/pkg/cmd"
	"k8s.io/git-sync/pkg/hook"
	"k8s.io/git-sync/pkg/logging"
	"k8s.io/git-sync/pkg/pid1"
	"k8s.io/git-sync/pkg/version"
)

var flVer = flag.Bool("version", false, "print the version and exit")

var flRepo = flag.String("repo", envString("GIT_SYNC_REPO", ""),
	"the git repository to clone")
var flBranch = flag.String("branch", envString("GIT_SYNC_BRANCH", "master"),
	"the git branch to check out")
var flRev = flag.String("rev", envString("GIT_SYNC_REV", "HEAD"),
	"the git revision (tag or hash) to check out")
var flDepth = flag.Int("depth", envInt("GIT_SYNC_DEPTH", 0),
	"use a shallow clone with a history truncated to the specified number of commits")
var flSubmodules = flag.String("submodules", envString("GIT_SYNC_SUBMODULES", "recursive"),
	"git submodule behavior: one of 'recursive', 'shallow', or 'off'")

var flRoot = flag.String("root", envString("GIT_SYNC_ROOT", envString("HOME", "")+"/git"),
	"the root directory for git-sync operations, under which --dest will be created")
var flDest = flag.String("dest", envString("GIT_SYNC_DEST", ""),
	"the path (absolute or relative to --root) at which to create a symlink to the directory holding the checked-out files (defaults to the leaf dir of --repo)")
var flErrorFile = flag.String("error-file", envString("GIT_SYNC_ERROR_FILE", ""),
	"the name of a file into which errors will be written under --root (defaults to \"\", disabling error reporting)")
var flWait = flag.Float64("wait", envFloat("GIT_SYNC_WAIT", 1),
	"the number of seconds between syncs")
var flSyncTimeout = flag.Int("timeout", envInt("GIT_SYNC_TIMEOUT", 120),
	"the max number of seconds allowed for a complete sync")
var flOneTime = flag.Bool("one-time", envBool("GIT_SYNC_ONE_TIME", false),
	"exit after the first sync")
var flMaxSyncFailures = flag.Int("max-sync-failures", envInt("GIT_SYNC_MAX_SYNC_FAILURES", 0),
	"the number of consecutive failures allowed before aborting (the first sync must succeed, -1 will retry forever after the initial sync)")
var flChmod = flag.Int("change-permissions", envInt("GIT_SYNC_PERMISSIONS", 0),
	"the file permissions to apply to the checked-out files (0 will not change permissions at all)")
var flSyncHookCommand = flag.String("sync-hook-command", envString("GIT_SYNC_HOOK_COMMAND", ""),
	"DEPRECATED: use --exechook-command instead")
var flExechookCommand = flag.String("exechook-command", envString("GIT_SYNC_EXECHOOK_COMMAND", ""),
	"a command to be executed (without arguments, with the syncing repository as its working directory) after syncing a new hash of the remote repository. "+
		"It is subject to --timeout out and will extend period between syncs.")
var flExechookTimeout = flag.Duration("exechook-timeout", envDuration("GIT_SYNC_EXECHOOK_TIMEOUT", time.Second*30),
	"the timeout for the command")
var flExechookBackoff = flag.Duration("exechook-backoff", envDuration("GIT_SYNC_EXECHOOK_BACKOFF", time.Second*3),
	"the time to wait before retrying a failed command")
var flSparseCheckoutFile = flag.String("sparse-checkout-file", envString("GIT_SYNC_SPARSE_CHECKOUT_FILE", ""),
	"the path to a sparse-checkout file.")

var flWebhookURL = flag.String("webhook-url", envString("GIT_SYNC_WEBHOOK_URL", ""),
	"the URL for a webhook notification when syncs complete (default is no webhook)")
var flWebhookMethod = flag.String("webhook-method", envString("GIT_SYNC_WEBHOOK_METHOD", "POST"),
	"the HTTP method for the webhook")
var flWebhookStatusSuccess = flag.Int("webhook-success-status", envInt("GIT_SYNC_WEBHOOK_SUCCESS_STATUS", 200),
	"the HTTP status code indicating a successful webhook (-1 disables success checks to make webhooks fire-and-forget)")
var flWebhookTimeout = flag.Duration("webhook-timeout", envDuration("GIT_SYNC_WEBHOOK_TIMEOUT", time.Second),
	"the timeout for the webhook")
var flWebhookBackoff = flag.Duration("webhook-backoff", envDuration("GIT_SYNC_WEBHOOK_BACKOFF", time.Second*3),
	"the time to wait before retrying a failed webhook")

var flUsername = flag.String("username", envString("GIT_SYNC_USERNAME", ""),
	"the username to use for git auth")
var flPassword = flag.String("password", envString("GIT_SYNC_PASSWORD", ""),
	"the password to use for git auth (prefer --password-file or this env var)")
var flPasswordFile = flag.String("password-file", envString("GIT_SYNC_PASSWORD_FILE", ""),
	"the file from which the password or personal access token for git auth will be sourced")

var flSSH = flag.Bool("ssh", envBool("GIT_SYNC_SSH", false),
	"use SSH for git operations")
var flSSHKeyFile = flag.String("ssh-key-file", envString("GIT_SSH_KEY_FILE", "/etc/git-secret/ssh"),
	"the SSH key to use")
var flSSHKnownHosts = flag.Bool("ssh-known-hosts", envBool("GIT_KNOWN_HOSTS", true),
	"enable SSH known_hosts verification")
var flSSHKnownHostsFile = flag.String("ssh-known-hosts-file", envString("GIT_SSH_KNOWN_HOSTS_FILE", "/etc/git-secret/known_hosts"),
	"the known_hosts file to use")
var flAddUser = flag.Bool("add-user", envBool("GIT_SYNC_ADD_USER", false),
	"add a record to /etc/passwd for the current UID/GID (needed to use SSH with a different UID)")

var flCookieFile = flag.Bool("cookie-file", envBool("GIT_COOKIE_FILE", false),
	"use git cookiefile")

var flAskPassURL = flag.String("askpass-url", envString("GIT_ASKPASS_URL", ""),
	"the URL for GIT_ASKPASS callback")

var flGitCmd = flag.String("git", envString("GIT_SYNC_GIT", "git"),
	"the git command to run (subject to PATH search, mostly for testing)")
var flGitConfig = flag.String("git-config", envString("GIT_SYNC_GIT_CONFIG", ""),
	"additional git config options in 'key1:val1,key2:val2' format")
var flGitGC = flag.String("git-gc", envString("GIT_SYNC_GIT_GC", "auto"),
	"git garbage collection behavior: one of 'auto', 'always', 'aggressive', or 'off'")

var flHTTPBind = flag.String("http-bind", envString("GIT_SYNC_HTTP_BIND", ""),
	"the bind address (including port) for git-sync's HTTP endpoint")
var flHTTPMetrics = flag.Bool("http-metrics", envBool("GIT_SYNC_HTTP_METRICS", true),
	"enable metrics on git-sync's HTTP endpoint")
var flHTTPprof = flag.Bool("http-pprof", envBool("GIT_SYNC_HTTP_PPROF", false),
	"enable the pprof debug endpoints on git-sync's HTTP endpoint")

var cmdRunner *cmd.Runner
var log *logging.Logger

// Total pull/error, summary on pull duration
var (
	// TODO: have a marker for "which" servergroup
	syncDuration = prometheus.NewSummaryVec(prometheus.SummaryOpts{
		Name: "git_sync_duration_seconds",
		Help: "Summary of git_sync durations",
	}, []string{"status"})

	syncCount = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "git_sync_count_total",
		Help: "How many git syncs completed, partitioned by state (success, error, noop)",
	}, []string{"status"})

	askpassCount = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "git_sync_askpass_calls",
		Help: "How many git askpass calls completed, partitioned by state (success, error)",
	}, []string{"status"})
)

const (
	metricKeySuccess = "success"
	metricKeyError   = "error"
	metricKeyNoOp    = "noop"
)

// initTimeout is a timeout for initialization, like git credentials setup.
const initTimeout = time.Second * 30

const (
	submodulesRecursive = "recursive"
	submodulesShallow   = "shallow"
	submodulesOff       = "off"

	gcAuto       = "auto"
	gcAlways     = "always"
	gcAggressive = "aggressive"
	gcOff        = "off"
)

func init() {
	prometheus.MustRegister(syncDuration)
	prometheus.MustRegister(syncCount)
	prometheus.MustRegister(askpassCount)
}

func envString(key, def string) string {
	if env := os.Getenv(key); env != "" {
		return env
	}
	return def
}

func envBool(key string, def bool) bool {
	if env := os.Getenv(key); env != "" {
		res, err := strconv.ParseBool(env)
		if err != nil {
			return def
		}

		return res
	}
	return def
}

func envInt(key string, def int) int {
	if env := os.Getenv(key); env != "" {
		val, err := strconv.ParseInt(env, 0, 0)
		if err != nil {
			fmt.Fprintf(os.Stderr, "WARNING: invalid env value (%v): using default, key=%s, val=%q, default=%d\n", err, key, env, def)
			return def
		}
		return int(val)
	}
	return def
}

func envFloat(key string, def float64) float64 {
	if env := os.Getenv(key); env != "" {
		val, err := strconv.ParseFloat(env, 64)
		if err != nil {
			fmt.Fprintf(os.Stderr, "WARNING: invalid env value (%v): using default, key=%s, val=%q, default=%f\n", err, key, env, def)
			return def
		}
		return val
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	if env := os.Getenv(key); env != "" {
		val, err := time.ParseDuration(env)
		if err != nil {
			fmt.Fprintf(os.Stderr, "WARNING: invalid env value (%v): using default, key=%s, val=%q, default=%d\n", err, key, env, def)
			return def
		}
		return val
	}
	return def
}

func setFlagDefaults() {
	// Force logging to stderr (from glog).
	stderrFlag := flag.Lookup("logtostderr")
	if stderrFlag == nil {
		handleError(false, "ERROR: can't find flag 'logtostderr'")
	}
	stderrFlag.Value.Set("true")
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

	setFlagDefaults()
	flag.Parse()

	log = logging.New(*flRoot, *flErrorFile)
	cmdRunner = cmd.NewRunner(log)

	if *flVer {
		fmt.Println(version.VERSION)
		os.Exit(0)
	}

	if *flRepo == "" {
		handleError(true, "ERROR: --repo must be specified")
	}

	if *flDepth < 0 { // 0 means "no limit"
		handleError(true, "ERROR: --depth must be greater than or equal to 0")
	}

	switch *flSubmodules {
	case submodulesRecursive, submodulesShallow, submodulesOff:
	default:
		handleError(true, "ERROR: --submodules must be one of %q, %q, or %q", submodulesRecursive, submodulesShallow, submodulesOff)
	}

	switch *flGitGC {
	case gcAuto, gcAlways, gcAggressive, gcOff:
	default:
		handleError(true, "ERROR: --git-gc must be one of %q, %q, %q, or %q", gcAuto, gcAlways, gcAggressive, gcOff)
	}

	if *flRoot == "" {
		handleError(true, "ERROR: --root must be specified")
	}

	if *flDest == "" {
		parts := strings.Split(strings.Trim(*flRepo, "/"), "/")
		*flDest = parts[len(parts)-1]
	}
	if !filepath.IsAbs(*flDest) {
		*flDest = filepath.Join(*flRoot, *flDest)
	}

	if *flWait < 0 {
		handleError(true, "ERROR: --wait must be greater than or equal to 0")
	}

	if *flSyncTimeout < 0 {
		handleError(true, "ERROR: --timeout must be greater than 0")
	}

	if *flWebhookURL != "" {
		if *flWebhookStatusSuccess < -1 {
			handleError(true, "ERROR: --webhook-success-status must be a valid HTTP code or -1")
		}
		if *flWebhookTimeout < time.Second {
			handleError(true, "ERROR: --webhook-timeout must be at least 1s")
		}
		if *flWebhookBackoff < time.Second {
			handleError(true, "ERROR: --webhook-backoff must be at least 1s")
		}
	}

	// Convert deprecated sync-hook-command flag to exechook-command flag
	if *flExechookCommand == "" && *flSyncHookCommand != "" {
		*flExechookCommand = *flSyncHookCommand
		log.Info("--sync-hook-command is deprecated, please use --exechook-command instead")
	}

	if *flExechookCommand != "" {
		if *flExechookTimeout < time.Second {
			handleError(true, "ERROR: --exechook-timeout must be at least 1s")
		}
		if *flExechookBackoff < time.Second {
			handleError(true, "ERROR: --exechook-backoff must be at least 1s")
		}
	}

	if _, err := exec.LookPath(*flGitCmd); err != nil {
		handleError(false, "ERROR: git executable %q not found: %v", *flGitCmd, err)
	}

	if *flPassword != "" && *flPasswordFile != "" {
		handleError(false, "ERROR: only one of --password and --password-file may be specified")
	}
	if *flUsername != "" {
		if *flPassword == "" && *flPasswordFile == "" {
			handleError(true, "ERROR: --password or --password-file must be set when --username is specified")
		}
	}

	if *flSSH {
		if *flUsername != "" {
			handleError(false, "ERROR: only one of --ssh and --username may be specified")
		}
		if *flPassword != "" {
			handleError(false, "ERROR: only one of --ssh and --password may be specified")
		}
		if *flPasswordFile != "" {
			handleError(false, "ERROR: only one of --ssh and --password-file may be specified")
		}
		if *flAskPassURL != "" {
			handleError(false, "ERROR: only one of --ssh and --askpass-url may be specified")
		}
		if *flCookieFile {
			handleError(false, "ERROR: only one of --ssh and --cookie-file may be specified")
		}
		if *flSSHKeyFile == "" {
			handleError(true, "ERROR: --ssh-key-file must be specified when --ssh is specified")
		}
		if *flSSHKnownHosts {
			if *flSSHKnownHostsFile == "" {
				handleError(true, "ERROR: --ssh-known-hosts-file must be specified when --ssh-known-hosts is specified")
			}
		}
	}

	if *flAddUser {
		if err := addUser(); err != nil {
			handleError(false, "ERROR: can't write to /etc/passwd: %v", err)
		}
	}

	// This context is used only for git credentials initialization. There are no long-running operations like
	// `git clone`, so initTimeout set to 30 seconds should be enough.
	ctx, cancel := context.WithTimeout(context.Background(), initTimeout)

	if *flUsername != "" {
		if *flPasswordFile != "" {
			passwordFileBytes, err := ioutil.ReadFile(*flPasswordFile)
			if err != nil {
				log.Error(err, "ERROR: can't read password file")
				os.Exit(1)
			}
			*flPassword = string(passwordFileBytes)
		}
		if err := setupGitAuth(ctx, *flUsername, *flPassword, *flRepo); err != nil {
			handleError(false, "ERROR: can't create .netrc file: %v", err)
		}
	}

	if *flSSH {
		if err := setupGitSSH(*flSSHKnownHosts); err != nil {
			handleError(false, "ERROR: can't configure SSH: %v", err)
		}
	}

	if *flCookieFile {
		if err := setupGitCookieFile(ctx); err != nil {
			handleError(false, "ERROR: can't set git cookie file: %v", err)
		}
	}

	if *flAskPassURL != "" {
		if err := callGitAskPassURL(ctx, *flAskPassURL); err != nil {
			askpassCount.WithLabelValues(metricKeyError).Inc()
			handleError(false, "ERROR: failed to call ASKPASS callback URL: %v", err)
		}
		askpassCount.WithLabelValues(metricKeySuccess).Inc()
	}

	// Set additional configs we want, but users might override.
	if err := setupDefaultGitConfigs(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: can't set default git configs: %v\n", err)
		os.Exit(1)
	}

	// This needs to be after all other git-related config flags.
	if *flGitConfig != "" {
		if err := setupExtraGitConfigs(ctx, *flGitConfig); err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: can't set additional git configs: %v\n", err)
			os.Exit(1)
		}
	}

	// The scope of the initialization context ends here, so we call cancel to release resources associated with it.
	cancel()

	if *flHTTPBind != "" {
		ln, err := net.Listen("tcp", *flHTTPBind)
		if err != nil {
			handleError(false, "ERROR: unable to bind HTTP endpoint: %v", err)
		}
		mux := http.NewServeMux()
		go func() {
			if *flHTTPMetrics {
				mux.Handle("/metrics", promhttp.Handler())
			}

			if *flHTTPprof {
				mux.HandleFunc("/debug/pprof/", pprof.Index)
				mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
				mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
				mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
				mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
			}

			// This is a dumb liveliness check endpoint. Currently this checks
			// nothing and will always return 200 if the process is live.
			mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
				if !getRepoReady() {
					http.Error(w, "repo is not ready", http.StatusServiceUnavailable)
				}
				// Otherwise success
			})
			http.Serve(ln, mux)
		}()
	}

	// From here on, output goes through logging.
	log.V(0).Info("starting up", "pid", os.Getpid(), "args", os.Args)

	// Startup webhooks goroutine
	var webhookRunner *hook.HookRunner
	if *flWebhookURL != "" {
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
		exechook := hook.NewExechook(
			cmd.NewRunner(log),
			*flExechookCommand,
			*flRoot,
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

	initialSync := true
	failCount := 0
	for {
		start := time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), time.Second*time.Duration(*flSyncTimeout))
		if changed, hash, err := syncRepo(ctx, *flRepo, *flBranch, *flRev, *flDepth, *flRoot, *flDest, *flAskPassURL, *flSubmodules); err != nil {
			updateSyncMetrics(metricKeyError, start)
			if *flMaxSyncFailures != -1 && failCount >= *flMaxSyncFailures {
				// Exit after too many retries, maybe the error is not recoverable.
				log.Error(err, "too many failures, aborting", "failCount", failCount)
				os.Exit(1)
			}

			failCount++
			log.Error(err, "unexpected error syncing repo, will retry")
			log.V(0).Info("waiting before retrying", "waitTime", waitTime(*flWait))
			cancel()
			time.Sleep(waitTime(*flWait))
			continue
		} else {
			// this might have been called before, but also might not have
			setRepoReady()
			if changed {
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
		}

		if initialSync {
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
				os.Exit(exitCode)
			}
			if isHash, err := revIsHash(ctx, *flRev, *flRoot); err != nil {
				log.Error(err, "can't tell if rev is a git hash, exiting", "rev", *flRev)
				os.Exit(1)
			} else if isHash {
				log.V(0).Info("rev appears to be a git hash, no further sync needed", "rev", *flRev)
				log.DeleteErrorFile()
				sleepForever()
			}
			initialSync = false
		}

		failCount = 0
		log.DeleteErrorFile()
		log.V(1).Info("next sync", "wait_time", waitTime(*flWait))
		cancel()
		time.Sleep(waitTime(*flWait))
	}
}

func removeDirContents(dir string, log *logging.Logger) error {
	dirents, err := ioutil.ReadDir(dir)
	if err != nil {
		return err
	}

	for _, fi := range dirents {
		p := filepath.Join(dir, fi.Name())
		if log != nil {
			log.V(2).Info("removing path recursively", "path", p, "isDir", fi.IsDir())
		}
		if err := os.RemoveAll(p); err != nil {
			return err
		}
	}

	return nil
}

func updateSyncMetrics(key string, start time.Time) {
	syncDuration.WithLabelValues(key).Observe(time.Since(start).Seconds())
	syncCount.WithLabelValues(key).Inc()
}

func waitTime(seconds float64) time.Duration {
	return time.Duration(int(seconds*1000)) * time.Millisecond
}

// Do no work, but don't do something that triggers go's runtime into thinking
// it is deadlocked.
func sleepForever() {
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt, os.Kill)
	<-c
	os.Exit(0)
}

// handleError prints the error to the standard error, prints the usage if the `printUsage` flag is true,
// exports the error to the error file and exits the process with the exit code.
func handleError(printUsage bool, format string, a ...interface{}) {
	s := fmt.Sprintf(format, a...)
	fmt.Fprintln(os.Stderr, s)
	if printUsage {
		flag.Usage()
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

// updateSymlink atomically swaps the symlink to point at the specified
// directory and cleans up the previous worktree.  If there was a previous
// worktree, this returns the path to it.
func updateSymlink(ctx context.Context, gitRoot, link, newDir string) (string, error) {
	linkDir, linkFile := filepath.Split(link)

	// Make sure the link directory exists. We do this here, rather than at
	// startup because it might be under --root and that gets wiped in some
	// circumstances.
	if err := os.MkdirAll(filepath.Dir(linkDir), os.FileMode(int(0755))); err != nil {
		return "", fmt.Errorf("error making symlink dir: %v", err)
	}

	// Get currently-linked repo directory (to be removed), unless it doesn't exist
	oldWorktreePath, err := filepath.EvalSymlinks(link)
	if err != nil && !os.IsNotExist(err) {
		return "", fmt.Errorf("error accessing current worktree: %v", err)
	}

	// newDir is absolute, so we need to change it to a relative path.  This is
	// so it can be volume-mounted at another path and the symlink still works.
	newDirRelative, err := filepath.Rel(linkDir, newDir)
	if err != nil {
		return "", fmt.Errorf("error converting to relative path: %v", err)
	}

	const tmplink = "tmp-link"
	log.V(1).Info("creating tmp symlink", "root", linkDir, "dst", newDirRelative, "src", tmplink)
	if _, err := cmdRunner.Run(ctx, linkDir, nil, "ln", "-snf", newDirRelative, tmplink); err != nil {
		return "", fmt.Errorf("error creating symlink: %v", err)
	}

	log.V(1).Info("renaming symlink", "root", linkDir, "old_name", tmplink, "new_name", linkFile)
	if _, err := cmdRunner.Run(ctx, linkDir, nil, "mv", "-T", tmplink, linkFile); err != nil {
		return "", fmt.Errorf("error replacing symlink: %v", err)
	}

	return oldWorktreePath, nil
}

// repoReady indicates that the repo has been cloned and synced.
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

// cleanupWorkTree() is used to remove a worktree and its folder
func cleanupWorkTree(ctx context.Context, gitRoot, worktree string) error {
	// Clean up worktree(s)
	log.V(1).Info("removing worktree", "path", worktree)
	if err := os.RemoveAll(worktree); err != nil {
		return fmt.Errorf("error removing directory: %v", err)
	} else if _, err := cmdRunner.Run(ctx, gitRoot, nil, *flGitCmd, "worktree", "prune"); err != nil {
		return err
	}
	return nil
}

// addWorktreeAndSwap creates a new worktree and calls updateSymlink to swap the symlink to point to the new worktree
func addWorktreeAndSwap(ctx context.Context, repo, gitRoot, dest, branch, rev string, depth int, hash string, submoduleMode string) error {
	log.V(0).Info("syncing git", "rev", rev, "hash", hash)

	args := []string{"fetch", "-f", "--tags"}
	if depth != 0 {
		args = append(args, "--depth", strconv.Itoa(depth))
	}
	args = append(args, repo, branch)

	// Update from the remote.
	if _, err := cmdRunner.Run(ctx, gitRoot, nil, *flGitCmd, args...); err != nil {
		return err
	}

	// With shallow fetches, it's possible to race with the upstream repo and
	// end up NOT fetching the hash we wanted. If we can't resolve that hash
	// to a commit we can just end early and leave it for the next sync period.
	if _, err := revIsHash(ctx, hash, gitRoot); err != nil {
		log.Error(err, "can't resolve commit, will retry", "rev", rev, "hash", hash)
		return nil
	}

	// Make a worktree for this exact git hash.
	worktreePath := filepath.Join(gitRoot, hash)

	// Avoid wedge cases where the worktree was created but this function error'd without cleaning the worktree.
	// Next timearound, the sync loop fails to create the worktree and bails out.
	// Error observed:
	//   " Run(git worktree add /repo/root/rev-nnnn origin/develop):
	//     exit status 128: { stdout: \"Preparing worktree (detached HEAD nnnn)\\n\", stderr: \"fatal: '/repo/root/rev-nnnn' already exists\\n\" }"
	//.  "
	if err := cleanupWorkTree(ctx, gitRoot, worktreePath); err != nil {
		return err
	}

	_, err := cmdRunner.Run(ctx, gitRoot, nil, *flGitCmd, "worktree", "add", "--detach", worktreePath, hash, "--no-checkout")
	log.V(0).Info("adding worktree", "path", worktreePath, "branch", fmt.Sprintf("origin/%s", branch))
	if err != nil {
		return err
	}

	// The .git file in the worktree directory holds a reference to
	// /git/.git/worktrees/<worktree-dir-name>. Replace it with a reference
	// using relative paths, so that other containers can use a different volume
	// mount name.
	worktreePathRelative, err := filepath.Rel(gitRoot, worktreePath)
	if err != nil {
		return err
	}
	gitDirRef := []byte(filepath.Join("gitdir: ../.git/worktrees", worktreePathRelative) + "\n")
	if err = ioutil.WriteFile(filepath.Join(worktreePath, ".git"), gitDirRef, 0644); err != nil {
		return err
	}

	if *flSparseCheckoutFile != "" {
		// This is required due to the undocumented behavior outlined here: https://public-inbox.org/git/CAPig+cSP0UiEBXSCi7Ua099eOdpMk8R=JtAjPuUavRF4z0R0Vg@mail.gmail.com/t/
		log.V(0).Info("configuring worktree sparse checkout")
		checkoutFile := *flSparseCheckoutFile

		gitInfoPath := filepath.Join(gitRoot, fmt.Sprintf(".git/worktrees/%s/info", hash))
		gitSparseConfigPath := filepath.Join(gitInfoPath, "sparse-checkout")

		source, err := os.Open(checkoutFile)
		if err != nil {
			return err
		}
		defer source.Close()

		if _, err := os.Stat(gitInfoPath); os.IsNotExist(err) {
			fileMode := os.FileMode(int(0755))
			err := os.Mkdir(gitInfoPath, fileMode)
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
		_, err = cmdRunner.Run(ctx, worktreePath, nil, *flGitCmd, args...)
		if err != nil {
			return err
		}
	}

	_, err = cmdRunner.Run(ctx, worktreePath, nil, *flGitCmd, "reset", "--hard", hash)
	if err != nil {
		return err
	}
	log.V(0).Info("reset worktree to hash", "path", worktreePath, "hash", hash)

	// Update submodules
	// NOTE: this works for repo with or without submodules.
	if submoduleMode != submodulesOff {
		log.V(0).Info("updating submodules")
		submodulesArgs := []string{"submodule", "update", "--init"}
		if submoduleMode == submodulesRecursive {
			submodulesArgs = append(submodulesArgs, "--recursive")
		}
		if depth != 0 {
			submodulesArgs = append(submodulesArgs, "--depth", strconv.Itoa(depth))
		}
		_, err = cmdRunner.Run(ctx, worktreePath, nil, *flGitCmd, submodulesArgs...)
		if err != nil {
			return err
		}
	}

	// Change the file permissions, if requested.
	if *flChmod != 0 {
		mode := fmt.Sprintf("%#o", *flChmod)
		log.V(0).Info("changing file permissions", "mode", mode)
		_, err = cmdRunner.Run(ctx, "", nil, "chmod", "-R", mode, worktreePath)
		if err != nil {
			return err
		}
	}

	// Flip the symlink.
	oldWorktree, err := updateSymlink(ctx, gitRoot, dest, worktreePath)
	if err != nil {
		return err
	}
	setRepoReady()

	// From here on we have to save errors until the end.
	var cleanupErrs multiError

	// Clean up previous worktree(s).
	if oldWorktree != "" {
		if err := cleanupWorkTree(ctx, gitRoot, oldWorktree); err != nil {
			cleanupErrs = append(cleanupErrs, err)
		}
	}

	// Run GC if needed.
	if *flGitGC != gcOff {
		args := []string{"gc"}
		switch *flGitGC {
		case gcAuto:
			args = append(args, "--auto")
		case gcAlways:
			// no extra flags
		case gcAggressive:
			args = append(args, "--aggressive")
		}
		if _, err := cmdRunner.Run(ctx, gitRoot, nil, *flGitCmd, args...); err != nil {
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

func cloneRepo(ctx context.Context, repo, branch, rev string, depth int, gitRoot string) error {
	args := []string{"clone", "-v", "--no-checkout", "-b", branch}
	if depth != 0 {
		args = append(args, "--depth", strconv.Itoa(depth))
	}
	args = append(args, repo, gitRoot)
	log.V(0).Info("cloning repo", "origin", repo, "path", gitRoot)

	_, err := cmdRunner.Run(ctx, "", nil, *flGitCmd, args...)
	if err != nil {
		if strings.Contains(err.Error(), "already exists and is not an empty directory") {
			// Maybe a previous run crashed?  Git won't use this dir.
			log.V(0).Info("git root exists and is not empty (previous crash?), cleaning up", "path", gitRoot)
			// We remove the contents rather than the dir itself, because a
			// common use-case is to have a volume mounted at git.root, which
			// makes removing it impossible.
			err := removeDirContents(gitRoot, log)
			if err != nil {
				return err
			}
			_, err = cmdRunner.Run(ctx, "", nil, *flGitCmd, args...)
			if err != nil {
				return err
			}
		} else {
			return err
		}
	}

	if *flSparseCheckoutFile != "" {
		log.V(0).Info("configuring sparse checkout")
		checkoutFile := *flSparseCheckoutFile

		gitRepoPath := filepath.Join(gitRoot, ".git")
		gitInfoPath := filepath.Join(gitRepoPath, "info")
		gitSparseConfigPath := filepath.Join(gitInfoPath, "sparse-checkout")

		source, err := os.Open(checkoutFile)
		if err != nil {
			return err
		}
		defer source.Close()

		if _, err := os.Stat(gitInfoPath); os.IsNotExist(err) {
			fileMode := os.FileMode(int(0755))
			err := os.Mkdir(gitInfoPath, fileMode)
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
		_, err = cmdRunner.Run(ctx, gitRoot, nil, *flGitCmd, args...)
		if err != nil {
			return err
		}
	}

	return nil
}

// localHashForRev returns the locally known hash for a given rev.
func localHashForRev(ctx context.Context, rev, gitRoot string) (string, error) {
	output, err := cmdRunner.Run(ctx, gitRoot, nil, *flGitCmd, "rev-parse", rev)
	if err != nil {
		return "", err
	}
	return strings.Trim(string(output), "\n"), nil
}

// remoteHashForRef returns the upstream hash for a given ref.
func remoteHashForRef(ctx context.Context, repo, ref, gitRoot string) (string, error) {
	output, err := cmdRunner.Run(ctx, gitRoot, nil, *flGitCmd, "ls-remote", "-q", repo, ref)
	if err != nil {
		return "", err
	}
	parts := strings.Split(string(output), "\t")
	return parts[0], nil
}

func revIsHash(ctx context.Context, rev, gitRoot string) (bool, error) {
	// If git doesn't identify rev as a commit, we're done.
	output, err := cmdRunner.Run(ctx, gitRoot, nil, *flGitCmd, "cat-file", "-t", rev)
	if err != nil {
		return false, err
	}
	o := strings.Trim(string(output), "\n")
	if o != "commit" {
		return false, nil
	}

	// `git cat-file -t` also returns "commit" for tags. If rev is already a git
	// hash, the output will be the same hash as the input.  Of course, a user
	// could specify "abc" and match "abcdef12345678", so we just do a prefix
	// match.
	output, err = localHashForRev(ctx, rev, gitRoot)
	if err != nil {
		return false, err
	}
	return strings.HasPrefix(output, rev), nil
}

// syncRepo syncs the branch of a given repository to the destination at the given rev.
// returns (1) whether a change occured, (2) the new hash, and (3) an error if one happened
func syncRepo(ctx context.Context, repo, branch, rev string, depth int, gitRoot, dest string, authURL string, submoduleMode string) (bool, string, error) {
	if authURL != "" {
		// For ASKPASS Callback URL, the credentials behind is dynamic, it needs to be
		// re-fetched each time.
		if err := callGitAskPassURL(ctx, authURL); err != nil {
			askpassCount.WithLabelValues(metricKeyError).Inc()
			return false, "", fmt.Errorf("failed to call GIT_ASKPASS_URL: %v", err)
		}
		askpassCount.WithLabelValues(metricKeySuccess).Inc()
	}

	currentWorktreeGit := filepath.Join(dest, ".git")
	var hash string
	_, err := os.Stat(currentWorktreeGit)
	switch {
	case os.IsNotExist(err):
		// First time. Just clone it and get the hash.
		err = cloneRepo(ctx, repo, branch, rev, depth, gitRoot)
		if err != nil {
			return false, "", err
		}
		hash, err = localHashForRev(ctx, rev, gitRoot)
		if err != nil {
			return false, "", err
		}
	case err != nil:
		return false, "", fmt.Errorf("error checking if a worktree exists %q: %v", currentWorktreeGit, err)
	default:
		// Not the first time. Figure out if the ref has changed.
		local, remote, err := getRevs(ctx, repo, dest, branch, rev)
		if err != nil {
			return false, "", err
		}
		if local == remote {
			log.V(1).Info("no update required", "rev", rev, "local", local, "remote", remote)
			return false, "", nil
		}
		log.V(0).Info("update required", "rev", rev, "local", local, "remote", remote)
		hash = remote
	}

	return true, hash, addWorktreeAndSwap(ctx, repo, gitRoot, dest, branch, rev, depth, hash, submoduleMode)
}

// getRevs returns the local and upstream hashes for rev.
func getRevs(ctx context.Context, repo, localDir, branch, rev string) (string, string, error) {
	// Ask git what the exact hash is for rev.
	local, err := localHashForRev(ctx, rev, localDir)
	if err != nil {
		return "", "", err
	}

	// Build a ref string, depending on whether the user asked to track HEAD or a tag.
	ref := ""
	if rev == "HEAD" {
		ref = "refs/heads/" + branch
	} else {
		ref = "refs/tags/" + rev
	}

	// Figure out what hash the remote resolves ref to.
	remote, err := remoteHashForRef(ctx, repo, ref, localDir)
	if err != nil {
		return "", "", err
	}

	return local, remote, nil
}

func setupGitAuth(ctx context.Context, username, password, gitURL string) error {
	log.V(1).Info("setting up git credential store")

	_, err := cmdRunner.Run(ctx, "", nil, *flGitCmd, "config", "--global", "credential.helper", "store")
	if err != nil {
		return fmt.Errorf("can't configure git credential helper: %w", err)
	}

	creds := fmt.Sprintf("url=%v\nusername=%v\npassword=%v\n", gitURL, username, password)
	_, err = cmdRunner.RunWithStdin(ctx, "", nil, creds, *flGitCmd, "credential", "approve")
	if err != nil {
		return fmt.Errorf("can't configure git credentials: %w", err)
	}

	return nil
}

func setupGitSSH(setupKnownHosts bool) error {
	log.V(1).Info("setting up git SSH credentials")

	var pathToSSHSecret = *flSSHKeyFile
	var pathToSSHKnownHosts = *flSSHKnownHostsFile

	_, err := os.Stat(pathToSSHSecret)
	if err != nil {
		return fmt.Errorf("can't access SSH key: %w", err)
	}

	if setupKnownHosts {
		_, err = os.Stat(pathToSSHKnownHosts)
		if err != nil {
			return fmt.Errorf("can't access SSH known_hosts: %w", err)
		}
		err = os.Setenv("GIT_SSH_COMMAND", fmt.Sprintf("ssh -o UserKnownHostsFile=%s -i %s", pathToSSHKnownHosts, pathToSSHSecret))
	} else {
		err = os.Setenv("GIT_SSH_COMMAND", fmt.Sprintf("ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i %s", pathToSSHSecret))
	}

	// set env variable GIT_SSH_COMMAND to force git use customized ssh command
	if err != nil {
		return fmt.Errorf("can't set $GIT_SSH_COMMAND: %w", err)
	}

	return nil
}

func setupGitCookieFile(ctx context.Context) error {
	log.V(1).Info("configuring git cookie file")

	var pathToCookieFile = "/etc/git-secret/cookie_file"

	_, err := os.Stat(pathToCookieFile)
	if err != nil {
		return fmt.Errorf("can't access git cookiefile: %w", err)
	}

	if _, err = cmdRunner.Run(ctx, "", nil, *flGitCmd, "config", "--global", "http.cookiefile", pathToCookieFile); err != nil {
		return fmt.Errorf("can't configure git cookiefile: %w", err)
	}

	return nil
}

// The expected ASKPASS callback output are below,
// see https://git-scm.com/docs/gitcredentials for more examples:
// username=xxx@example.com
// password=xxxyyyzzz
func callGitAskPassURL(ctx context.Context, url string) error {
	log.V(1).Info("calling GIT_ASKPASS URL to get credentials")

	var netClient = &http.Client{
		Timeout: time.Second * 1,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	httpReq, err := http.NewRequestWithContext(ctx, "GET", url, nil)
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
		errMessage, err := ioutil.ReadAll(resp.Body)
		if err != nil {
			return fmt.Errorf("auth URL returned status %d, failed to read body: %w", resp.StatusCode, err)
		}
		return fmt.Errorf("auth URL returned status %d, body: %q", resp.StatusCode, string(errMessage))
	}
	authData, err := ioutil.ReadAll(resp.Body)
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

	if err := setupGitAuth(ctx, username, password, *flRepo); err != nil {
		return err
	}

	return nil
}

func setupDefaultGitConfigs(ctx context.Context) error {
	configs := []keyVal{{
		// Never auto-detach GC runs.
		key: "gc.autoDetach",
		val: "false",
	}, {
		// Fairly aggressive GC.
		key: "gc.pruneExpire",
		val: "now",
	}}
	for _, kv := range configs {
		if _, err := cmdRunner.Run(ctx, "", nil, *flGitCmd, "config", "--global", kv.key, kv.val); err != nil {
			return fmt.Errorf("error configuring git %q %q: %v", kv.key, kv.val, err)
		}
	}
	return nil
}

func setupExtraGitConfigs(ctx context.Context, configsFlag string) error {
	log.V(1).Info("setting additional git configs")

	configs, err := parseGitConfigs(configsFlag)
	if err != nil {
		return fmt.Errorf("can't parse --git-config flag: %v", err)
	}
	for _, kv := range configs {
		if _, err := cmdRunner.Run(ctx, "", nil, *flGitCmd, "config", "--global", kv.key, kv.val); err != nil {
			return fmt.Errorf("error configuring additional git configs %q %q: %v", kv.key, kv.val, err)
		}
	}

	return nil
}

type keyVal struct {
	key string
	val string
}

func parseGitConfigs(configsFlag string) ([]keyVal, error) {
	ch := make(chan rune)
	stop := make(chan bool)
	go func() {
		for _, r := range configsFlag {
			select {
			case <-stop:
				break
			default:
				ch <- r
			}
		}
		close(ch)
		return
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
			cur.key, err = parseGitConfigKey(r, ch)
			if err != nil {
				return nil, err
			}
		}

		// Peek and see if we have a value.
		if r, ok := <-ch; !ok {
			return nil, fmt.Errorf("key %q: no value", cur.key)
		} else {
			if r == '"' {
				cur.val, err = parseGitConfigQVal(ch)
				if err != nil {
					return nil, fmt.Errorf("key %q: %v", cur.key, err)
				}
			} else {
				cur.val, err = parseGitConfigVal(r, ch)
				if err != nil {
					return nil, fmt.Errorf("key %q: %v", cur.key, err)
				}
			}
		}

		result = append(result, cur)
	}

	return result, nil
}

func parseGitConfigKey(r rune, ch <-chan rune) (string, error) {
	buf := make([]rune, 0, 64)
	buf = append(buf, r)

	for r := range ch {
		switch {
		case r == ':':
			return string(buf), nil
		default:
			// This can accumulate things that git doesn't allow, but we'll
			// just let git handle it, rather than try to pre-validate to their
			// spec.
			buf = append(buf, r)
		}
	}
	return "", fmt.Errorf("unexpected end of key: %q", string(buf))
}

func parseGitConfigQVal(ch <-chan rune) (string, error) {
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
			// Once we have a closing quote, the next must be either a comma or
			// end-of-string.  This helps reset the state for the next key, if
			// there is one.
			r, ok := <-ch
			if ok && r != ',' {
				return "", fmt.Errorf("unexpected trailing character '%c'", r)
			}
			return string(buf), nil
		default:
			buf = append(buf, r)
		}
	}
	return "", fmt.Errorf("unexpected end of value: %q", string(buf))
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
