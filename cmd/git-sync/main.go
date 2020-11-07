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
	"bytes"
	"context"
	"flag"
	"fmt"
	"io/ioutil"
	"net"
	"net/http"
	"net/http/pprof"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/go-logr/glogr"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/spf13/pflag"
	"k8s.io/git-sync/pkg/pid1"
	"k8s.io/git-sync/pkg/version"
)

var flVersion = pflag.Bool("version", false, "print the version and exit")
var flHelp = pflag.BoolP("help", "h", false, "print help text and exit")
var flManual = pflag.Bool("man", false, "print the full manual and exit")

var flVerbose = pflag.IntP("verbose", "v", 0,
	"logs at this V level and lower will be printed")

var flRepo = pflag.String("repo", envString("GIT_SYNC_REPO", ""),
	"the git repository to clone")
var flBranch = pflag.String("branch", envString("GIT_SYNC_BRANCH", "master"),
	"the git branch to check out")
var flRev = pflag.String("rev", envString("GIT_SYNC_REV", "HEAD"),
	"the git revision (tag or hash) to check out")
var flDepth = pflag.Int("depth", envInt("GIT_SYNC_DEPTH", 0),
	"create a shallow clone with history truncated to the specified number of commits")
var flSubmodules = pflag.String("submodules", envString("GIT_SYNC_SUBMODULES", "recursive"),
	"git submodule behavior: one of 'recursive', 'shallow', or 'off'")

var flRoot = pflag.String("root", envString("GIT_SYNC_ROOT", ""),
	"the root directory for git-sync operations, under which --link will be created")
var flLink = pflag.String("link", envString("GIT_SYNC_LINK", ""),
	"the name of a symlink, under --root, which points to a directory in which --repo is checked out (defaults to the leaf dir of --repo)")
var flPeriod = pflag.Duration("period", envDuration("GIT_SYNC_PERIOD", 10*time.Second),
	"how long to wait between syncs, must be >= 10ms; --wait overrides this")
var flSyncTimeout = pflag.Duration("sync-timeout", envDuration("GIT_SYNC_SYNC_TIMEOUT", 120*time.Second),
	"the total time allowed for one complete sync, must be >= 10ms; --timeout overrides this")
var flOneTime = pflag.Bool("one-time", envBool("GIT_SYNC_ONE_TIME", false),
	"exit after the first sync")
var flMaxSyncFailures = pflag.Int("max-sync-failures", envInt("GIT_SYNC_MAX_SYNC_FAILURES", 0),
	"the number of consecutive failures allowed before aborting (the first sync must succeed, -1 will retry forever")
var flChmod = pflag.Int("change-permissions", envInt("GIT_SYNC_PERMISSIONS", 0),
	"optionally change permissions on the checked-out files to the specified mode")

var flSyncHookCommand = pflag.String("sync-hook-command", envString("GIT_SYNC_HOOK_COMMAND", ""),
	"an optional command to be executed after syncing a new hash of the remote repository")

var flWebhookURL = pflag.String("webhook-url", envString("GIT_SYNC_WEBHOOK_URL", ""),
	"a URL for optional webhook notifications when syncs complete")
var flWebhookMethod = pflag.String("webhook-method", envString("GIT_SYNC_WEBHOOK_METHOD", "POST"),
	"the HTTP method for the webhook")
var flWebhookStatusSuccess = pflag.Int("webhook-success-status", envInt("GIT_SYNC_WEBHOOK_SUCCESS_STATUS", 200),
	"the HTTP status code indicating a successful webhook (-1 disables success checks")
var flWebhookTimeout = pflag.Duration("webhook-timeout", envDuration("GIT_SYNC_WEBHOOK_TIMEOUT", time.Second),
	"the timeout for the webhook")
var flWebhookBackoff = pflag.Duration("webhook-backoff", envDuration("GIT_SYNC_WEBHOOK_BACKOFF", time.Second*3),
	"the time to wait before retrying a failed webhook")

var flUsername = pflag.String("username", envString("GIT_SYNC_USERNAME", ""),
	"the username to use for git auth")
var flPassword = pflag.String("password", envString("GIT_SYNC_PASSWORD", ""),
	"the password or personal access token to use for git auth (prefer env vars for passwords)")

var flSSH = pflag.Bool("ssh", envBool("GIT_SYNC_SSH", false),
	"use SSH for git operations")
var flSSHKeyFile = pflag.String("ssh-key-file", envString("GIT_SSH_KEY_FILE", "/etc/git-secret/ssh"),
	"the SSH key to use")
var flSSHKnownHosts = pflag.Bool("ssh-known-hosts", envBool("GIT_KNOWN_HOSTS", true),
	"enable SSH known_hosts verification")
var flSSHKnownHostsFile = pflag.String("ssh-known-hosts-file", envString("GIT_SSH_KNOWN_HOSTS_FILE", "/etc/git-secret/known_hosts"),
	"the known_hosts file to use")
var flAddUser = pflag.Bool("add-user", envBool("GIT_SYNC_ADD_USER", false),
	"add a record to /etc/passwd for the current UID/GID (needed to use SSH with an arbitrary UID)")

var flCookieFile = pflag.Bool("cookie-file", envBool("GIT_COOKIE_FILE", false),
	"use a git cookiefile (/etc/git-secret/cookie_file) for authentication")

var flAskPassURL = pflag.String("askpass-url", envString("GIT_ASKPASS_URL", ""),
	"a URL to query for git credentials (username=<value> and password=<value>")

var flGitCmd = pflag.String("git", envString("GIT_SYNC_GIT", "git"),
	"the git command to run (subject to PATH search, mostly for testing)")

var flHTTPBind = pflag.String("http-bind", envString("GIT_SYNC_HTTP_BIND", ""),
	"the bind address (including port) for git-sync's HTTP endpoint")
var flHTTPMetrics = pflag.Bool("http-metrics", envBool("GIT_SYNC_HTTP_METRICS", true),
	"enable metrics on git-sync's HTTP endpoint")
var flHTTPprof = pflag.Bool("http-pprof", envBool("GIT_SYNC_HTTP_PPROF", false),
	"enable the pprof debug endpoints on git-sync's HTTP endpoint")

// Obsolete flags, kept for compat.
var flWait = pflag.Float64("wait", envFloat("GIT_SYNC_WAIT", 0),
	"DEPRECATED: use --period instead")
var flTimeout = pflag.Int("timeout", envInt("GIT_SYNC_TIMEOUT", 0),
	"DEPRECATED: use --sync-timeout instead")
var flDest = pflag.String("dest", envString("GIT_SYNC_DEST", ""),
	"DEPRECATED: use --link instead")

func init() {
	pflag.CommandLine.MarkDeprecated("wait", "use --period instead")
	pflag.CommandLine.MarkDeprecated("timeout", "use --sync-timeout instead")
	pflag.CommandLine.MarkDeprecated("dest", "use --link instead")
}

var log = glogr.New()

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

const (
	submodulesRecursive = "recursive"
	submodulesShallow   = "shallow"
	submodulesOff       = "off"
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
		val, err := strconv.Atoi(env)
		if err != nil {
			log.Error(err, "invalid env value, using default", "key", key, "val", os.Getenv(key), "default", def)
			return def
		}
		return val
	}
	return def
}

func envFloat(key string, def float64) float64 {
	if env := os.Getenv(key); env != "" {
		val, err := strconv.ParseFloat(env, 64)
		if err != nil {
			log.Error(err, "invalid env value, using default", "key", key, "val", os.Getenv(key), "default", def)
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
			log.Error(err, "invalid env value, using default", "key", key, "val", os.Getenv(key), "default", def)
			return def
		}
		return val
	}
	return def
}

func setGlogFlags() {
	// Force logging to stderr.
	stderrFlag := flag.Lookup("logtostderr")
	if stderrFlag == nil {
		fmt.Fprintf(os.Stderr, "ERROR: can't find glog flag 'logtostderr'\n")
		os.Exit(1)
	}
	stderrFlag.Value.Set("true")

	// Set verbosity from flag.
	vFlag := flag.Lookup("v")
	if vFlag == nil {
		fmt.Fprintf(os.Stderr, "ERROR: can't find glog flag 'v'\n")
		os.Exit(1)
	}
	vFlag.Value.Set(strconv.Itoa(*flVerbose))
}

// repoSync represents the remote repo and the local sync of it.
type repoSync struct {
	cmd  string // the git command to run
	root string // absolute path to the root directory
}

func main() {
	// In case we come up as pid 1, act as init.
	if os.Getpid() == 1 {
		fmt.Fprintf(os.Stderr, "INFO: detected pid 1, running init handler\n")
		err := pid1.ReRun()
		if err == nil {
			os.Exit(0)
		}
		if exerr, ok := err.(*exec.ExitError); ok {
			os.Exit(exerr.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "ERROR: unhandled pid1 error: %v\n", err)
		os.Exit(127)
	}

	//
	// Parse and verify flags.  Errors here are fatal.
	//

	pflag.Parse()
	flag.CommandLine.Parse(nil) // Otherwise glog complains
	setGlogFlags()

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

	if *flRepo == "" {
		fmt.Fprintf(os.Stderr, "ERROR: --repo must be specified\n")
		pflag.Usage()
		os.Exit(1)
	}

	if *flDepth < 0 { // 0 means "no limit"
		fmt.Fprintf(os.Stderr, "ERROR: --depth must be greater than or equal to 0\n")
		pflag.Usage()
		os.Exit(1)
	}

	switch *flSubmodules {
	case submodulesRecursive, submodulesShallow, submodulesOff:
	default:
		fmt.Fprintf(os.Stderr, "ERROR: --submodules must be one of %q, %q, or %q", submodulesRecursive, submodulesShallow, submodulesOff)
		pflag.Usage()
		os.Exit(1)
	}

	if *flRoot == "" {
		fmt.Fprintf(os.Stderr, "ERROR: --root must be specified\n")
		pflag.Usage()
		os.Exit(1)
	}

	if *flDest != "" {
		*flLink = *flDest
	}
	if *flLink == "" {
		parts := strings.Split(strings.Trim(*flRepo, "/"), "/")
		*flLink = parts[len(parts)-1]
	}
	if strings.Contains(*flLink, "/") {
		fmt.Fprintf(os.Stderr, "ERROR: --link must not contain '/'\n")
		pflag.Usage()
		os.Exit(1)
	}
	if strings.HasPrefix(*flLink, ".") {
		fmt.Fprintf(os.Stderr, "ERROR: --link must not start with '.'\n")
		pflag.Usage()
		os.Exit(1)
	}

	if *flWait != 0 {
		*flPeriod = time.Duration(int(*flWait*1000)) * time.Millisecond
	}
	if *flPeriod < 10*time.Millisecond {
		fmt.Fprintf(os.Stderr, "ERROR: --period must be at least 10ms\n")
		pflag.Usage()
		os.Exit(1)
	}

	if *flTimeout != 0 {
		*flSyncTimeout = time.Duration(*flTimeout) * time.Second
	}
	if *flSyncTimeout < 10*time.Millisecond {
		fmt.Fprintf(os.Stderr, "ERROR: --sync-timeout must be at least 10ms\n")
		pflag.Usage()
		os.Exit(1)
	}

	if *flWebhookURL != "" {
		if *flWebhookStatusSuccess < -1 {
			fmt.Fprintf(os.Stderr, "ERROR: --webhook-success-status must be a valid HTTP code or -1\n")
			pflag.Usage()
			os.Exit(1)
		}
		if *flWebhookTimeout < time.Second {
			fmt.Fprintf(os.Stderr, "ERROR: --webhook-timeout must be at least 1s\n")
			pflag.Usage()
			os.Exit(1)
		}
		if *flWebhookBackoff < time.Second {
			fmt.Fprintf(os.Stderr, "ERROR: --webhook-backoff must be at least 1s\n")
			pflag.Usage()
			os.Exit(1)
		}
	}

	if *flSSH {
		if *flUsername != "" {
			fmt.Fprintf(os.Stderr, "ERROR: only one of --ssh and --username may be specified\n")
			os.Exit(1)
		}
		if *flPassword != "" {
			fmt.Fprintf(os.Stderr, "ERROR: only one of --ssh and --password may be specified\n")
			os.Exit(1)
		}
		if *flAskPassURL != "" {
			fmt.Fprintf(os.Stderr, "ERROR: only one of --ssh and --askpass-url may be specified\n")
			os.Exit(1)
		}
		if *flCookieFile {
			fmt.Fprintf(os.Stderr, "ERROR: only one of --ssh and --cookie-file may be specified\n")
			os.Exit(1)
		}
		if *flSSHKeyFile == "" {
			fmt.Fprintf(os.Stderr, "ERROR: --ssh-key-file must be specified when --ssh is specified\n")
			pflag.Usage()
			os.Exit(1)
		}
		if *flSSHKnownHosts {
			if *flSSHKnownHostsFile == "" {
				fmt.Fprintf(os.Stderr, "ERROR: --ssh-known-hosts-file must be specified when --ssh-known-hosts is specified\n")
				pflag.Usage()
				os.Exit(1)
			}
		}
	}

	// From here on, output goes through logging.
	log.V(0).Info("starting up", "pid", os.Getpid(), "args", os.Args)

	if _, err := exec.LookPath(*flGitCmd); err != nil {
		log.Error(err, "ERROR: git executable not found", "git", *flGitCmd)
		os.Exit(1)
	}

	if err := os.MkdirAll(*flRoot, 0700); err != nil {
		log.Error(err, "ERROR: can't make root dir", "path", *flRoot)
		os.Exit(1)
	}
	absRoot, err := normalizePath(*flRoot)
	if err != nil {
		log.Error(err, "ERROR: can't normalize root path", "path", *flRoot)
		os.Exit(1)
	}
	if absRoot != *flRoot {
		log.V(0).Info("normalized root path", "path", *flRoot, "result", absRoot)
	}

	if *flAddUser {
		if err := addUser(); err != nil {
			log.Error(err, "ERROR: can't add user")
			os.Exit(1)
		}
	}

	// Capture the various git parameters.
	git := &repoSync{
		cmd:  *flGitCmd,
		root: absRoot,
	}

	// This context is used only for git credentials initialization. There are no long-running operations like
	// `git clone`, so hopefully 30 seconds will be enough.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)

	if *flUsername != "" && *flPassword != "" {
		if err := git.SetupAuth(ctx, *flUsername, *flPassword, *flRepo); err != nil {
			log.Error(err, "ERROR: can't set up git auth")
			os.Exit(1)
		}
	}

	if *flSSH {
		if err := setupGitSSH(*flSSHKnownHosts); err != nil {
			log.Error(err, "ERROR: can't set up git SSH")
			os.Exit(1)
		}
	}

	if *flCookieFile {
		if err := git.SetupCookieFile(ctx); err != nil {
			log.Error(err, "ERROR: can't set up git cookie file")
			os.Exit(1)
		}
	}

	if *flAskPassURL != "" {
		if err := git.CallAskPassURL(ctx, *flAskPassURL); err != nil {
			askpassCount.WithLabelValues(metricKeyError).Inc()
			log.Error(err, "ERROR: failed to call ASKPASS callback URL", "url", *flAskPassURL)
			os.Exit(1)
		}
		askpassCount.WithLabelValues(metricKeySuccess).Inc()
	}

	// The scope of the initialization context ends here, so we call cancel to release resources associated with it.
	cancel()

	if *flHTTPBind != "" {
		ln, err := net.Listen("tcp", *flHTTPBind)
		if err != nil {
			log.Error(err, "ERROR: failed to bind HTTP endpoint", "endpoint", *flHTTPBind)
			os.Exit(1)
		}
		mux := http.NewServeMux()
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
		log.V(0).Info("serving HTTP", "endpoint", *flHTTPBind)
		go func() {
			err := http.Serve(ln, mux)
			log.Error(err, "HTTP server terminated")
			os.Exit(1)
		}()
	}

	// Startup webhooks goroutine
	var webhook *Webhook
	if *flWebhookURL != "" {
		webhook = &Webhook{
			URL:     *flWebhookURL,
			Method:  *flWebhookMethod,
			Success: *flWebhookStatusSuccess,
			Timeout: *flWebhookTimeout,
			Backoff: *flWebhookBackoff,
			Data:    NewWebhookData(),
		}
		go webhook.run()
	}

	initialSync := true
	failCount := 0
	for {
		start := time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), *flSyncTimeout)
		if changed, hash, err := git.SyncRepo(ctx, *flRepo, *flBranch, *flRev, *flDepth, *flLink, *flAskPassURL, *flSubmodules); err != nil {
			updateSyncMetrics(metricKeyError, start)
			if *flMaxSyncFailures != -1 && failCount >= *flMaxSyncFailures {
				// Exit after too many retries, maybe the error is not recoverable.
				log.Error(err, "too many failures, aborting", "failCount", failCount)
				os.Exit(1)
			}

			failCount++
			log.Error(err, "unexpected error syncing repo, will retry")
			log.V(0).Info("waiting before retrying", "waitTime", flPeriod.String())
			cancel()
			time.Sleep(*flPeriod)
			continue
		} else if changed {
			if webhook != nil {
				webhook.Send(hash)
			}
			updateSyncMetrics(metricKeySuccess, start)
		} else {
			updateSyncMetrics(metricKeyNoOp, start)
		}

		if initialSync {
			if *flOneTime {
				os.Exit(0)
			}
			if isHash, err := git.RevIsHash(ctx, *flRev); err != nil {
				log.Error(err, "can't tell if rev is a git hash, exiting", "rev", *flRev)
				os.Exit(1)
			} else if isHash {
				log.V(0).Info("rev appears to be a git hash, no further sync needed", "rev", *flRev)
				sleepForever()
			}
			initialSync = false
		}

		failCount = 0
		log.V(1).Info("next sync", "waitTime", flPeriod.String())
		cancel()
		time.Sleep(*flPeriod)
	}
}

func normalizePath(path string) (string, error) {
	delinked, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", err
	}
	abs, err := filepath.Abs(delinked)
	if err != nil {
		return "", err
	}
	return abs, nil
}

func updateSyncMetrics(key string, start time.Time) {
	syncDuration.WithLabelValues(key).Observe(time.Since(start).Seconds())
	syncCount.WithLabelValues(key).Inc()
}

// Do no work, but don't do something that triggers go's runtime into thinking
// it is deadlocked.
func sleepForever() {
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt, os.Kill)
	<-c
	os.Exit(0)
}

// Put the current UID/GID into /etc/passwd so SSH can look it up.  This
// assumes that we have the permissions to write to it.
func addUser() error {
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

// UpdateSymlink atomically swaps the symlink to point at the specified
// directory and cleans up the previous worktree.  If there was a previous
// worktree, this returns the path to it.
func (git *repoSync) UpdateSymlink(ctx context.Context, link, newDir string) (string, error) {
	// Get currently-linked repo directory (to be removed), unless it doesn't exist
	linkPath := filepath.Join(git.root, link)
	oldWorktreePath, err := filepath.EvalSymlinks(linkPath)
	if err != nil && !os.IsNotExist(err) {
		return "", fmt.Errorf("error accessing current worktree: %v", err)
	}

	// newDir is absolute, so we need to change it to a relative path.  This is
	// so it can be volume-mounted at another path and the symlink still works.
	newDirRelative, err := filepath.Rel(git.root, newDir)
	if err != nil {
		return "", fmt.Errorf("error converting to relative path: %v", err)
	}

	const tmplink = "tmp-link"
	log.V(1).Info("creating tmp symlink", "root", git.root, "dst", newDirRelative, "src", tmplink)
	if _, err := runCommand(ctx, git.root, "ln", "-snf", newDirRelative, tmplink); err != nil {
		return "", fmt.Errorf("error creating symlink: %v", err)
	}

	log.V(1).Info("renaming symlink", "root", git.root, "old_name", tmplink, "new_name", link)
	if _, err := runCommand(ctx, git.root, "mv", "-T", tmplink, link); err != nil {
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

// AddWorktreeAndSwap creates a new worktree and calls UpdateSymlink to swap the symlink to point to the new worktree
func (git *repoSync) AddWorktreeAndSwap(ctx context.Context, link, branch, rev string, depth int, hash string, submoduleMode string) error {
	log.V(0).Info("syncing git", "rev", rev, "hash", hash)

	args := []string{"fetch", "-f", "--tags"}
	if depth != 0 {
		args = append(args, "--depth", strconv.Itoa(depth))
	}
	args = append(args, "origin", branch)

	// Update from the remote.
	if _, err := runCommand(ctx, git.root, git.cmd, args...); err != nil {
		return err
	}

	// GC clone
	if _, err := runCommand(ctx, git.root, git.cmd, "gc", "--prune=all"); err != nil {
		return err
	}

	// Make a worktree for this exact git hash.
	worktreePath := filepath.Join(git.root, "rev-"+hash)
	_, err := runCommand(ctx, git.root, git.cmd, "worktree", "add", worktreePath, "origin/"+branch)
	log.V(0).Info("adding worktree", "path", worktreePath, "branch", fmt.Sprintf("origin/%s", branch))
	if err != nil {
		return err
	}

	// The .git file in the worktree directory holds a reference to
	// /git/.git/worktrees/<worktree-dir-name>. Replace it with a reference
	// using relative paths, so that other containers can use a different volume
	// mount name.
	worktreePathRelative, err := filepath.Rel(git.root, worktreePath)
	if err != nil {
		return err
	}
	gitDirRef := []byte(filepath.Join("gitdir: ../.git/worktrees", worktreePathRelative) + "\n")
	if err = ioutil.WriteFile(filepath.Join(worktreePath, ".git"), gitDirRef, 0644); err != nil {
		return err
	}

	// Reset the worktree's working copy to the specific rev.
	_, err = runCommand(ctx, worktreePath, git.cmd, "reset", "--hard", hash)
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
		_, err = runCommand(ctx, worktreePath, git.cmd, submodulesArgs...)
		if err != nil {
			return err
		}
	}

	// Change the file permissions, if requested.
	if *flChmod != 0 {
		mode := fmt.Sprintf("%#o", *flChmod)
		log.V(0).Info("changing file permissions", "mode", mode)
		_, err = runCommand(ctx, "", "chmod", "-R", mode, worktreePath)
		if err != nil {
			return err
		}
	}

	// Execute the command, if requested.
	if *flSyncHookCommand != "" {
		log.V(0).Info("executing command for git sync hooks", "command", *flSyncHookCommand)
		_, err = runCommand(ctx, worktreePath, *flSyncHookCommand)
		if err != nil {
			return err
		}
	}

	// Reset the root's rev (so we can prune and so we can rely on it later).
	_, err = runCommand(ctx, git.root, git.cmd, "reset", "--hard", hash)
	if err != nil {
		return err
	}
	log.V(0).Info("reset root to hash", "path", git.root, "hash", hash)

	// Flip the symlink.
	oldWorktree, err := git.UpdateSymlink(ctx, link, worktreePath)
	if err != nil {
		return err
	}
	setRepoReady()
	if oldWorktree != "" {
		// Clean up previous worktree
		log.V(1).Info("removing old worktree", "path", oldWorktree)
		if err := os.RemoveAll(oldWorktree); err != nil {
			return fmt.Errorf("error removing directory: %v", err)
		}
		if _, err := runCommand(ctx, git.root, git.cmd, "worktree", "prune"); err != nil {
			return err
		}
	}

	return nil
}

// CloneRepo does an initial clone of the git repo.
func (git *repoSync) CloneRepo(ctx context.Context, repo, branch, rev string, depth int) error {
	args := []string{"clone", "--no-checkout", "-b", branch}
	if depth != 0 {
		args = append(args, "--depth", strconv.Itoa(depth))
	}
	args = append(args, repo, git.root)
	log.V(0).Info("cloning repo", "origin", repo, "path", git.root)

	_, err := runCommand(ctx, "", git.cmd, args...)
	if err != nil {
		if strings.Contains(err.Error(), "already exists and is not an empty directory") {
			// Maybe a previous run crashed?  Git won't use this dir.
			log.V(0).Info("git root exists and is not empty (previous crash?), cleaning up", "path", git.root)
			err := os.RemoveAll(git.root)
			if err != nil {
				return err
			}
			_, err = runCommand(ctx, "", git.cmd, args...)
			if err != nil {
				return err
			}
		} else {
			return err
		}
	}

	return nil
}

// LocalHashForRev returns the locally known hash for a given rev.
func (git *repoSync) LocalHashForRev(ctx context.Context, rev string) (string, error) {
	output, err := runCommand(ctx, git.root, git.cmd, "rev-parse", rev)
	if err != nil {
		return "", err
	}
	return strings.Trim(string(output), "\n"), nil
}

// RemoteHashForRef returns the upstream hash for a given ref.
func (git *repoSync) RemoteHashForRef(ctx context.Context, ref string) (string, error) {
	output, err := runCommand(ctx, git.root, git.cmd, "ls-remote", "-q", "origin", ref)
	if err != nil {
		return "", err
	}
	parts := strings.Split(string(output), "\t")
	return parts[0], nil
}

func (git *repoSync) RevIsHash(ctx context.Context, rev string) (bool, error) {
	// If git doesn't identify rev as a commit, we're done.
	output, err := runCommand(ctx, git.root, git.cmd, "cat-file", "-t", rev)
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
	output, err = git.LocalHashForRev(ctx, rev)
	if err != nil {
		return false, err
	}
	return strings.HasPrefix(output, rev), nil
}

// SyncRepo syncs the branch of a given repository to the link at the given rev.
// returns (1) whether a change occured, (2) the new hash, and (3) an error if one happened
func (git *repoSync) SyncRepo(ctx context.Context, repo, branch, rev string, depth int, link string, authURL string, submoduleMode string) (bool, string, error) {
	if authURL != "" {
		// For ASKPASS Callback URL, the credentials behind is dynamic, it needs to be
		// re-fetched each time.
		if err := git.CallAskPassURL(ctx, authURL); err != nil {
			askpassCount.WithLabelValues(metricKeyError).Inc()
			return false, "", fmt.Errorf("failed to call GIT_ASKPASS_URL: %v", err)
		}
		askpassCount.WithLabelValues(metricKeySuccess).Inc()
	}

	target := filepath.Join(git.root, link)
	gitRepoPath := filepath.Join(target, ".git")
	var hash string
	_, err := os.Stat(gitRepoPath)
	switch {
	case os.IsNotExist(err):
		// First time. Just clone it and get the hash.
		err = git.CloneRepo(ctx, repo, branch, rev, depth)
		if err != nil {
			return false, "", err
		}
		hash, err = git.LocalHashForRev(ctx, rev)
		if err != nil {
			return false, "", err
		}
	case err != nil:
		return false, "", fmt.Errorf("error checking if repo exists %q: %v", gitRepoPath, err)
	default:
		// Not the first time. Figure out if the ref has changed.
		local, remote, err := git.GetRevs(ctx, branch, rev)
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

	return true, hash, git.AddWorktreeAndSwap(ctx, link, branch, rev, depth, hash, submoduleMode)
}

// GetRevs returns the local and upstream hashes for rev.
func (git *repoSync) GetRevs(ctx context.Context, branch, rev string) (string, string, error) {
	// Ask git what the exact hash is for rev.
	local, err := git.LocalHashForRev(ctx, rev)
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
	remote, err := git.RemoteHashForRef(ctx, ref)
	if err != nil {
		return "", "", err
	}

	return local, remote, nil
}

func cmdForLog(command string, args ...string) string {
	if strings.ContainsAny(command, " \t\n") {
		command = fmt.Sprintf("%q", command)
	}
	for i := range args {
		if strings.ContainsAny(args[i], " \t\n") {
			args[i] = fmt.Sprintf("%q", args[i])
		}
	}
	return command + " " + strings.Join(args, " ")
}

func runCommand(ctx context.Context, cwd, command string, args ...string) (string, error) {
	return runCommandWithStdin(ctx, cwd, "", command, args...)
}

func runCommandWithStdin(ctx context.Context, cwd, stdin, command string, args ...string) (string, error) {
	cmdStr := cmdForLog(command, args...)
	log.V(5).Info("running command", "cwd", cwd, "cmd", cmdStr)

	cmd := exec.CommandContext(ctx, command, args...)
	if cwd != "" {
		cmd.Dir = cwd
	}
	outbuf := bytes.NewBuffer(nil)
	errbuf := bytes.NewBuffer(nil)
	cmd.Stdout = outbuf
	cmd.Stderr = errbuf
	cmd.Stdin = bytes.NewBufferString(stdin)

	err := cmd.Run()
	stdout := outbuf.String()
	stderr := errbuf.String()
	if ctx.Err() == context.DeadlineExceeded {
		return "", fmt.Errorf("Run(%s): %w: { stdout: %q, stderr: %q }", cmdStr, ctx.Err(), stdout, stderr)
	}
	if err != nil {
		return "", fmt.Errorf("Run(%s): %w: { stdout: %q, stderr: %q }", cmdStr, err, stdout, stderr)
	}
	log.V(6).Info("command result", "stdout", stdout, "stderr", stderr)

	return stdout, nil
}

// SetupAuth configures the local git repo to use a username and password when
// accessing the repo at gitURL.
func (git *repoSync) SetupAuth(ctx context.Context, username, password, gitURL string) error {
	log.V(1).Info("setting up git credential store")

	_, err := runCommand(ctx, "", git.cmd, "config", "--global", "credential.helper", "store")
	if err != nil {
		return fmt.Errorf("can't configure git credential helper: %w", err)
	}

	creds := fmt.Sprintf("url=%v\nusername=%v\npassword=%v\n", gitURL, username, password)
	_, err = runCommandWithStdin(ctx, "", creds, git.cmd, "credential", "approve")
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
		err = os.Setenv("GIT_SSH_COMMAND", fmt.Sprintf("ssh -q -o UserKnownHostsFile=%s -i %s", pathToSSHKnownHosts, pathToSSHSecret))
	} else {
		err = os.Setenv("GIT_SSH_COMMAND", fmt.Sprintf("ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i %s", pathToSSHSecret))
	}

	// set env variable GIT_SSH_COMMAND to force git use customized ssh command
	if err != nil {
		return fmt.Errorf("can't set $GIT_SSH_COMMAND: %w", err)
	}

	return nil
}

func (git *repoSync) SetupCookieFile(ctx context.Context) error {
	log.V(1).Info("configuring git cookie file")

	var pathToCookieFile = "/etc/git-secret/cookie_file"

	_, err := os.Stat(pathToCookieFile)
	if err != nil {
		return fmt.Errorf("can't access git cookiefile: %w", err)
	}

	if _, err = runCommand(ctx, "",
		git.cmd, "config", "--global", "http.cookiefile", pathToCookieFile); err != nil {
		return fmt.Errorf("can't configure git cookiefile: %w", err)
	}

	return nil
}

// CallAskPassURL consults the specified URL looking for git credentials in the
// response.
//
// The expected ASKPASS callback output are below,
// see https://git-scm.com/docs/gitcredentials for more examples:
//   username=xxx@example.com
//   password=ya29.xxxyyyzzz
func (git *repoSync) CallAskPassURL(ctx context.Context, url string) error {
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
	if resp.StatusCode != 200 {
		return fmt.Errorf("auth URL returned status %d", resp.StatusCode)
	}
	authData, err := ioutil.ReadAll(resp.Body)
	resp.Body.Close()
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

	if err := git.SetupAuth(ctx, username, password, *flRepo); err != nil {
		return err
	}

	return nil
}

// This string is formatted for 80 columns.  Please keep it that way.
// DO NOT USE TABS.
var manual = `
GIT-SYNC

NAME
    git-sync - sync a remote git repository

SYNOPSIS
    git-sync --repo=<repo> [OPTION]...

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
    repo synchronization. The call is made after the symlink is updated.

OPTIONS

    Many options can be specified as either a commandline flag or an environment
    variable.

    --add-user, $GIT_SYNC_ADD_USER
            Add a record to /etc/passwd for the current UID/GID.  This is needed
            to use SSH (see --ssh) with an arbitrary UID.  This assumes that
            /etc/passwd is writable by the current UID.

    --askpass-url <string>, $GIT_ASKPASS_URL
            A URL to query for git credentials. The query must return success
            (200) and produce a series of key=value lines, including
            "username=<value>" and "password=<value>".

    --branch <string>, $GIT_SYNC_BRANCH
            The git branch to check out. (default: master)

    --change-permissions <int>, $GIT_SYNC_PERMISSIONS
            Optionally change permissions on the checked-out files to the
            specified mode.

    --cookie-file, $GIT_COOKIE_FILE
            Use a git cookiefile (/etc/git-secret/cookie_file) for
            authentication.

    --depth <int>, $GIT_SYNC_DEPTH
            Create a shallow clone with history truncated to the specified
            number of commits.

    --link <string>, $GIT_SYNC_LINK
            The name of the final symlink (under --root) which will point to the
            current git worktree. This must be a filename, not a path, and may
            not start with a period. (default: the leaf dir of --repo)

    --git <string>, $GIT_SYNC_GIT
            The git command to run (subject to PATH search, mostly for testing).
            (default: git)

    -h, --help
            Print help text and exit.

    --http-bind <string>, $GIT_SYNC_HTTP_BIND
            The bind address (including port) for git-sync's HTTP endpoint.
            (default: none)

    --http-metrics, $GIT_SYNC_HTTP_METRICS
            Enable metrics on git-sync's HTTP endpoint (see --http-bind).
            (default: true)

    --http-pprof, $GIT_SYNC_HTTP_PPROF
            Enable the pprof debug endpoints on git-sync's HTTP endpoint (see
            --http-bind). (default: false)

    --man
            Print this manual and exit.

    --max-sync-failures <int>, $GIT_SYNC_MAX_SYNC_FAILURES
            The number of consecutive failures allowed before aborting (the
            first sync must succeed), Setting this to -1 will retry forever
            after the initial sync. (default: 0)

    --one-time, $GIT_SYNC_ONE_TIME
            Exit after the first sync.

    --password <string>, $GIT_SYNC_PASSWORD
            The password or personal access token (see github docs) to use for
            git authentication (see --username).  NOTE: for security reasons,
            users should prefer the environment variable for specifying the
            password.

    --period <duration>, $GIT_SYNC_PERIOD
            How long to wait between sync attempts.  This must be at least
            10ms.  This flag obsoletes --wait, but if --wait is specifed, it
            will take precedence. (default: 10s)

    --repo <string>, $GIT_SYNC_REPO
            The git repository to sync.

    --rev <string>, $GIT_SYNC_REV
            The git revision (tag or hash) to check out. (default: HEAD)

    --root <string>, $GIT_SYNC_ROOT
            The root directory for git-sync operations, under which --link will
            be created. This flag is required.

    --ssh, $GIT_SYNC_SSH
            Use SSH for git authentication and operations.

    --ssh-key-file <string>, $GIT_SSH_KEY_FILE
            The SSH key to use when using --ssh. (default: /etc/git-secret/ssh)

    --ssh-known-hosts, $GIT_KNOWN_HOSTS
            Enable SSH known_hosts verification when using --ssh.
            (default: true)

    --ssh-known-hosts-file <string>, $GIT_SSH_KNOWN_HOSTS_FILE
            The known_hosts file to use when --ssh-known-hosts is specified.
            (default: /etc/git-secret/known_hosts)

    --submodules <string>, $GIT_SYNC_SUBMODULES
            The git submodule behavior: one of 'recursive', 'shallow', or 'off'.
            (default: recursive)

    --sync-hook-command <string>, $GIT_SYNC_HOOK_COMMAND
            An optional command to be executed after syncing a new hash of the
            remote repository.  This command does not take any arguments and
            executes with the synced repo as its working directory.  The
            execution is subject to the overall --sync-timeout flag and will
            extend the effective period between sync attempts.

    --sync-timeout <duration>, $GIT_SYNC_SYNC_TIMEOUT
            The total time allowed for one complete sync.  This must be at least
            10ms.  This flag obsoletes --timeout, but if --timeout is specified,
            it will take precedence. (default: 120s)

    --username <string>, $GIT_SYNC_USERNAME
            The username to use for git authentication (see --password).

    -v, --verbose <int>
            Set the log verbosity level.  Logs at this level and lower will be
            printed. (default: 0)

    --version
            Print the version and exit.

    --webhook-backoff <duration>, $GIT_SYNC_WEBHOOK_BACKOFF
            The time to wait before retrying a failed --webhook-url).
            (default: 3s)

    --webhook-method <string>, $GIT_SYNC_WEBHOOK_METHOD
            The HTTP method for the --webhook-url (default: POST)

    --webhook-success-status <int>, $GIT_SYNC_WEBHOOK_SUCCESS_STATUS
            The HTTP status code indicating a successful --webhook-url.  Setting
            this to -1 disables success checks to make webhooks fire-and-forget.
            (default: 200)

    --webhook-timeout <duration>, $GIT_SYNC_WEBHOOK_TIMEOUT
            The timeout for the --webhook-url. (default: 1s)

    --webhook-url <string>, $GIT_SYNC_WEBHOOK_URL
            A URL for optional webhook notifications when syncs complete.

EXAMPLE USAGE

    git-sync \
        --repo=https://github.com/kubernetes/git-sync \
        --branch=master \
        --rev=HEAD \
        --period=10s \
        --root=/mnt/git

AUTHENTICATION

    Git-sync offers several authentication options to choose from.  If none of
    the following are specified, git-sync will try to access the repo in the
    "natural" manner.  For example, "https://repo" will try to use plain HTTPS
    and "git@example.com:repo" will try to use SSH.

    username/password
            The --username (GIT_SYNC_USERNAME) and --password
            (GIT_SYNC_PASSWORD) flags will be used.  To prevent password
            leaks, the GIT_SYNC_PASSWORD environment variable is almost always
            preferred to the flag.

            A variant of this is --askpass-url (GIT_ASKPASS_URL), which
            consults a URL (e.g. http://metadata) to get credentials on each
            sync.

    SSH
            When --ssh (GIT_SYNC_SSH) is specified, the --ssh-key-file
            (GIT_SSH_KEY_FILE) will be used.  Users are strongly advised to
            also use --ssh-known-hosts (GIT_KNOWN_HOSTS) and
            --ssh-known-hosts-file (GIT_SSH_KNOWN_HOSTS_FILE) when using SSH.

    cookies
            When --cookie-file (GIT_COOKIE_FILE) is specified, the associated
            cookies can contain authentication information.

WEBHOOKS

    Webhooks are executed asynchronously from the main git-sync process. If a
    --webhook-url is configured, whenever a new hash is synced a call is sent
    using the method defined in --webhook-method. Git-sync will retry this
    webhook call until it succeeds (based on --webhook-success-status).  If
    unsuccessful, git-sync will wait --webhook-backoff (default 3s) before
    re-attempting the webhook call.
`

func printManPage() {
	fmt.Print(manual)
}
