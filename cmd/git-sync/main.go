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
	"k8s.io/git-sync/pkg/pid1"
	"k8s.io/git-sync/pkg/version"
)

var flVer = flag.Bool("version", false, "print the version and exit")

var flRepo = flag.String("repo", envString("GIT_SYNC_REPO", ""),
	"the git repository to clone")
var flBranch = flag.String("branch", envString("GIT_SYNC_BRANCH", ""),
	"OBSOLETE: use --rev instead")
var flRev = flag.String("rev", envString("GIT_SYNC_REV", "master"),
	"the git ref (branch or tag) or full SHA (specified as 'sha:<value>') to track")
var flDepth = flag.Int("depth", envInt("GIT_SYNC_DEPTH", 0),
	"use a shallow clone with a history truncated to the specified number of commits")
var flSubmodules = flag.String("submodules", envString("GIT_SYNC_SUBMODULES", "recursive"),
	"git submodule behavior: one of 'recursive', 'shallow', or 'off'")

var flRoot = flag.String("root", envString("GIT_SYNC_ROOT", ""),
	"the root directory for git-sync operations, under which --leaf will be created")
var flDest = flag.String("dest", envString("GIT_SYNC_DEST", ""),
	"OBSOLETE: use --leaf instead")
var flLeaf = flag.String("leaf", envString("GIT_SYNC_LEAF", ""),
	"the name of (a symlink to) a directory in which to check-out files under --root (defaults to the leaf dir of --repo)")
var flWait = flag.String("wait", envString("GIT_SYNC_WAIT", ""),
	"OBSOLETE: use --period instead")
var flPeriod = flag.Duration("period", envDuration("GIT_SYNC_PERIOD", time.Second),
	"how often to run syncs (e.g. 10s, 1m30s), must be >= 10ms")
var flTimeout = flag.String("timeout", envString("GIT_SYNC_TIMEOUT", ""),
	"OBSOLETE: use --sync-timeout instead")
var flSyncTimeout = flag.Duration("sync-timeout", envDuration("GIT_SYNC_SYNC_TIMEOUT", 120*time.Second),
	"the total time allowed for one complete sync (e.g. 10s, 1m30s), must be >= 1s")
var flOneTime = flag.Bool("one-time", envBool("GIT_SYNC_ONE_TIME", false),
	"exit after the first sync (overrides --period)")
var flMaxSyncFailures = flag.Int("max-sync-failures", envInt("GIT_SYNC_MAX_SYNC_FAILURES", 0),
	"the number of consecutive failures allowed before aborting (the first sync must succeed, -1 will retry forever after the initial sync)")
var flChmod = flag.Int("change-permissions", envInt("GIT_SYNC_PERMISSIONS", 0),
	"the file permissions to apply to the checked-out files (0 will not change permissions at all)")

var flWebhookURL = flag.String("webhook-url", envString("GIT_SYNC_WEBHOOK_URL", ""),
	"the URL for a webook notification when syncs complete (default is no webook)")
var flWebhookMethod = flag.String("webhook-method", envString("GIT_SYNC_WEBHOOK_METHOD", "POST"),
	"the HTTP method for the webook")
var flWebhookStatusSuccess = flag.Int("webhook-success-status", envInt("GIT_SYNC_WEBHOOK_SUCCESS_STATUS", 200),
	"the HTTP status code indicating a successful webhook (-1 disables success checks to make webhooks fire-and-forget)")
var flWebhookTimeout = flag.Duration("webhook-timeout", envDuration("GIT_SYNC_WEBHOOK_TIMEOUT", time.Second),
	"the timeout for the webhook")
var flWebhookBackoff = flag.Duration("webhook-backoff", envDuration("GIT_SYNC_WEBHOOK_BACKOFF", time.Second*3),
	"the time to wait before retrying a failed webhook")

var flUsername = flag.String("username", envString("GIT_SYNC_USERNAME", ""),
	"the username to use for git auth")
var flPassword = flag.String("password", envString("GIT_SYNC_PASSWORD", ""),
	"the password to use for git auth (users should prefer env vars for passwords)")

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

var flHTTPBind = flag.String("http-bind", envString("GIT_SYNC_HTTP_BIND", ""),
	"the bind address (including port) for git-sync's HTTP endpoint")
var flHTTPMetrics = flag.Bool("http-metrics", envBool("GIT_SYNC_HTTP_METRICS", true),
	"enable metrics on git-sync's HTTP endpoint")
var flHTTPprof = flag.Bool("http-pprof", envBool("GIT_SYNC_HTTP_PPROF", false),
	"enable the pprof debug endpoints on git-sync's HTTP endpoint")

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
		Help: "How many git syncs completed, partitioned by success",
	}, []string{"status"})

	askpassCount = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "git_sync_askpass_calls",
		Help: "How many git syncs completed, partitioned by success",
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

func setFlagDefaults() {
	// Force logging to stderr (from glog).
	stderrFlag := flag.Lookup("logtostderr")
	if stderrFlag == nil {
		fmt.Fprintf(os.Stderr, "ERROR: can't find flag 'logtostderr'\n")
		os.Exit(1)
	}
	stderrFlag.Value.Set("true")
}

// syncrepo represents the remote repo and the local sync of it.
type syncRepo struct {
	cmd        string // the git command to run
	rootDir    string // absolute path
	repo       string // remote repo
	rev        string // the rev or SHA to sync
	revIsSHA   bool   // true if rev is an exact SHA
	depth      int    // for shallow sync
	submodules string // how to handle submodules
	chmod      int    // mode to change repo to, or 0
	linkName   string // the name of the symlink to publish in rootDir
	authURL    string // a URL to re-fetch credentials, or ""
	syncCount  int64  // how many times have we successfully synced
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

	setFlagDefaults()
	flag.Parse()

	if *flVer {
		fmt.Println(version.VERSION)
		os.Exit(0)
	}

	if *flRepo == "" {
		fmt.Fprintf(os.Stderr, "ERROR: --repo must be specified\n")
		flag.Usage()
		os.Exit(1)
	}

	if *flBranch != "" {
		fmt.Fprintf(os.Stderr, "ERROR: --branch is OBSOLETE, see --rev instead\n")
		flag.Usage()
		os.Exit(1)
	}

	if *flRev == "" {
		fmt.Fprintf(os.Stderr, "ERROR: --rev must be specified\n")
		flag.Usage()
		os.Exit(1)
	}

	symbolIsSHA := false
	symbol := *flRev
	if strings.HasPrefix(*flRev, "sha:") {
		symbolIsSHA = true
		symbol = (*flRev)[4:]
	}

	if *flDepth < 0 { // 0 means "no limit"
		fmt.Fprintf(os.Stderr, "ERROR: --depth must be greater than or equal to 0\n")
		flag.Usage()
		os.Exit(1)
	}

	switch *flSubmodules {
	case submodulesRecursive, submodulesShallow, submodulesOff:
	default:
		fmt.Fprintf(os.Stderr, "ERROR: --submodules must be one of %q, %q, or %q", submodulesRecursive, submodulesShallow, submodulesOff)
		flag.Usage()
		os.Exit(1)
	}

	if *flRoot == "" {
		fmt.Fprintf(os.Stderr, "ERROR: --root must be provided\n")
		flag.Usage()
		os.Exit(1)
	}

	if *flDest != "" {
		fmt.Fprintf(os.Stderr, "ERROR: --dest is OBSOLETE, see --leaf instead\n")
		flag.Usage()
		os.Exit(1)
	}
	if *flLeaf == "" {
		parts := strings.Split(strings.Trim(*flRepo, "/"), "/")
		*flLeaf = parts[len(parts)-1]
	}
	if strings.Contains(*flLeaf, "/") {
		fmt.Fprintf(os.Stderr, "ERROR: --leaf must be a leaf name, not a path\n")
		flag.Usage()
		os.Exit(1)
	}
	if strings.HasPrefix(*flLeaf, ".") {
		fmt.Fprintf(os.Stderr, "ERROR: --leaf must not start with '.'\n")
		flag.Usage()
		os.Exit(1)
	}

	if *flWait != "" {
		fmt.Fprintf(os.Stderr, "ERROR: --wait is OBSOLETE, see --period instead\n")
		flag.Usage()
		os.Exit(1)
	}

	if *flOneTime == false && *flPeriod < 10*time.Millisecond {
		fmt.Fprintf(os.Stderr, "ERROR: --period must be at least 10ms\n")
		flag.Usage()
		os.Exit(1)
	}

	if *flTimeout != "" {
		fmt.Fprintf(os.Stderr, "ERROR: --timeout is OBSOLETE, see --sync-timeout instead\n")
		flag.Usage()
		os.Exit(1)
	}
	if *flSyncTimeout < time.Second {
		fmt.Fprintf(os.Stderr, "ERROR: --sync-timeout must be at least 1s\n")
		flag.Usage()
		os.Exit(1)
	}

	if *flWebhookURL != "" {
		if *flWebhookStatusSuccess <= 0 {
			fmt.Fprintf(os.Stderr, "ERROR: --webhook-success-status must be greater than 0\n")
			flag.Usage()
			os.Exit(1)
		}
		if *flWebhookTimeout < time.Second {
			fmt.Fprintf(os.Stderr, "ERROR: --webhook-timeout must be at least 1s\n")
			flag.Usage()
			os.Exit(1)
		}
		if *flWebhookBackoff < time.Second {
			fmt.Fprintf(os.Stderr, "ERROR: --webhook-backoff must be at least 1s\n")
			flag.Usage()
			os.Exit(1)
		}
	}

	if _, err := exec.LookPath(*flGitCmd); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: git executable %q not found: %v\n", *flGitCmd, err)
		os.Exit(1)
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
			flag.Usage()
			os.Exit(1)
		}
		if *flSSHKnownHosts {
			if *flSSHKnownHostsFile == "" {
				fmt.Fprintf(os.Stderr, "ERROR: --ssh-known-hosts-file must be specified when --ssh-known-hosts is specified\n")
				flag.Usage()
				os.Exit(1)
			}
		}
	}

	if *flAddUser {
		if err := addUser(); err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: can't write to /etc/passwd: %v\n", err)
			os.Exit(1)
		}
	}

	// This context is used only for git credentials initialization. There are no long-running operations like
	// `git clone`, so initTimeout set to 30 seconds should be enough.
	ctx, cancel := context.WithTimeout(context.Background(), initTimeout)

	if *flUsername != "" && *flPassword != "" {
		if err := setupGitAuth(ctx, *flUsername, *flPassword, *flRepo); err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: can't create .netrc file: %v\n", err)
			os.Exit(1)
		}
	}

	if *flSSH {
		if err := setupGitSSH(*flSSHKnownHosts); err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: can't configure SSH: %v\n", err)
			os.Exit(1)
		}
	}

	if *flCookieFile {
		if err := setupGitCookieFile(ctx); err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: can't set git cookie file: %v\n", err)
			os.Exit(1)
		}
	}

	// The scope of the initialization context ends here, so we call cancel to release resources associated with it.
	cancel()

	if *flHTTPBind != "" {
		ln, err := net.Listen("tcp", *flHTTPBind)
		if err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: unable to bind HTTP endpoint: %v\n", err)
			os.Exit(1)
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

	absRoot, err := filepath.Abs(*flRoot)
	if err != nil {
		log.Error(err, "can't normalize path", "path", *flRoot)
		os.Exit(1)
	}

	// FIXME: test-case for case where local repo exists but doesn't have rev
	// FIXME: adapt to all the other v4 changes
	// FIXME: peel off smaller PRs
	// FIXME: merge e2e files
	// FIXME: update README and docs

	git := &syncRepo{
		cmd:        *flGitCmd,
		rootDir:    absRoot,
		repo:       *flRepo,
		rev:        symbol,
		revIsSHA:   symbolIsSHA,
		depth:      *flDepth,
		submodules: *flSubmodules,
		chmod:      *flChmod,
		linkName:   *flLeaf,
		authURL:    *flAskPassURL,
	}

	failCount := 0
	curSHA := "(unknown)"
	for initialSync := true; true; initialSync = false {
		if !initialSync {
			if *flMaxSyncFailures >= 0 && failCount > *flMaxSyncFailures {
				// Exit after too many retries, maybe the error is not recoverable.
				log.Error(err, "too many failures, aborting", "failCount", failCount)
				os.Exit(1)
			}
			log.V(1).Info("next sync", "wait_time", flPeriod.String())
			time.Sleep(*flPeriod)
		}

		ctx, cancel := context.WithTimeout(context.Background(), *flSyncTimeout)

		if initialSync {
			// Make sure the git root is a valid repo.
			sha, err := git.InitRepo(ctx)
			if err != nil {
				log.Error(err, "can't init local git repo", "repo", absRoot)
				os.Exit(1)
			}
			if sha != "" {
				curSHA = sha
			}
		}

		newSHA, err := git.Sync(ctx, curSHA)
		if err != nil {
			log.Error(err, "failed to sync", "rev", *flRev)
			failCount++
			cancel()
			continue
		}

		curSHA = newSHA
		failCount = 0
		cancel()

		if webhook != nil {
			webhook.Send(newSHA)
		}

		if initialSync && *flOneTime {
			log.V(2).Info("synced once, exiting")
			os.Exit(0)
		}

		if symbolIsSHA {
			// If the symbol is known to be a SHA, we can sync once and be done.  It
			// won't be changing.
			log.V(0).Info("synced to exact SHA, no further sync needed", "sha", symbol)
			sleepForever()
		}
	}
}

const shaNone = "(none)"

// initRepo looks at the git root initializes it if needed.  Returns the
// current SHA if possible, or else shaNone.
func (git *syncRepo) InitRepo(ctx context.Context) (string, error) {
	// Check out the git root, and see if it is already usable.
	_, err := os.Stat(git.rootDir)
	switch {
	case os.IsNotExist(err):
		// Probably the first time through.
		log.V(0).Info("git root does not exist, initializing", "root", git.rootDir)
		if err := os.MkdirAll(git.rootDir, 0755); err != nil {
			return "", err
		}
	case err != nil:
		return "", err
	default:
		// Make sure the directory we found is actually usable.
		log.V(0).Info("git root exists", "root", git.rootDir)
		if git.SanityCheck(ctx, "") {
			log.V(0).Info("git root is a valid git repo", "root", git.rootDir)
			// Get the current SHA, if possible.  We can ignore errors here,
			// since the repo might not have a HEAD yet.
			sha, _ := runCommand(ctx, git.rootDir, git.cmd, "rev-parse", "HEAD")
			return strings.TrimSpace(sha), nil
		}
		// Maybe a previous run crashed?  Git won't use this dir.
		log.V(0).Info("git root exists but failed checks, cleaning up and reinitializing", "root", git.rootDir)
		// We remove the contents rather than the dir itself, because a
		// common use-case is to have a volume mounted at git.rootDir.
		if err := removeDirContents(git.rootDir); err != nil {
			return "", fmt.Errorf("can't remove unusable git root: %w", err)
		}
	}
	if _, err := runCommand(ctx, git.rootDir, git.cmd, "init"); err != nil {
		return "", err
	}
	return shaNone, nil
}

// sanityCheck tries to make sure that the dir is a valid git repository.
func (git *syncRepo) SanityCheck(ctx context.Context, sha string) bool {
	// Optionally check a worktree subdir.
	dir := git.rootDir
	if sha != "" {
		dir = git.worktreePath(sha)
	}

	log.V(0).Info("sanity-checking git repo", "repo", dir)

	// Check that this is actually the root of the repo.
	if root, err := runCommand(ctx, dir, git.cmd, "rev-parse", "--show-toplevel"); err != nil {
		log.Error(err, "can't get repo toplevel", "repo", dir)
		return false
	} else {
		root = strings.TrimSpace(root)
		if root != dir {
			log.V(0).Info("git repo is under another repo", "repo", dir, "parent", root)
			return false
		}
	}

	// Consistency-check the repo.
	if _, err := runCommand(ctx, dir, git.cmd, "fsck", "--no-progress", "--connectivity-only"); err != nil {
		log.Error(err, "repo sanity check failed", "repo", dir)
		return false
	}

	return true
}

func removeDirContents(dir string) error {
	dirents, err := ioutil.ReadDir(dir)
	if err != nil {
		return err
	}

	for _, fi := range dirents {
		p := filepath.Join(dir, fi.Name())
		log.V(2).Info("removing path recursively", "path", p, "isDir", fi.IsDir())
		if err := os.RemoveAll(p); err != nil {
			return err
		}
	}

	return nil
}

func (git *syncRepo) Sync(ctx context.Context, curSHA string) (string, error) {
	start := time.Now()

	if git.authURL != "" {
		// For ASKPASS Callback URL, the credentials behind is dynamic, it needs to be
		// re-fetched each time.
		if err := callGitAskPassURL(ctx, git.authURL); err != nil {
			askpassCount.WithLabelValues(metricKeyError).Inc()
			return "", fmt.Errorf("GIT_ASKPASS: %w", err)
		}
	}
	askpassCount.WithLabelValues(metricKeySuccess).Inc()

	newSHA := git.rev
	if !git.revIsSHA {
		sha, err := git.remoteSHA(ctx)
		if err != nil {
			updateSyncMetrics(metricKeyError, start)
			return "", err
		}
		log.V(0).Info("remote SHA for ref", "ref", git.rev, "sha", sha)
		newSHA = sha
	}
	// Even if we are current, we force a sync one time to set things like
	// depth, which could have changed between runs.
	if newSHA == curSHA && git.syncCount > 0 {
		log.V(1).Info("no update required", "rev", git.rev, "sha", newSHA)
		updateSyncMetrics(metricKeyNoOp, start)
		return newSHA, nil
	}

	log.V(1).Info("update required", "rev", git.rev, "sha", newSHA, "currently", curSHA)
	if err := git.syncSHA(ctx, newSHA); err != nil {
		updateSyncMetrics(metricKeyError, start)
		return "", fmt.Errorf("syncSHA(%s): %w", newSHA, err)
	}
	git.syncCount++
	updateSyncMetrics(metricKeySuccess, start)
	return newSHA, nil
}

func updateSyncMetrics(key string, start time.Time) {
	syncDuration.WithLabelValues(key).Observe(time.Since(start).Seconds())
	syncCount.WithLabelValues(key).Inc()
}

// remoteSHA returns the upstream hash for a given rev, dereferenced
// to the commit hash.
func (git *syncRepo) remoteSHA(ctx context.Context) (string, error) {
	// Fetch both the naked and dereferenced rev, take the last one (git returns
	// the dereferenced last, if present).
	output, err := runCommand(ctx, "", git.cmd, "ls-remote", "-q", "--heads", "--tags", git.repo, git.rev, git.rev+"^{}")
	if err != nil {
		return "", err
	}
	lines := strings.Split(string(output), "\n") // guaranteed to have at least 1 element
	line := lastNonEmpty(lines)
	parts := strings.Fields(line)
	if len(parts) == 0 {
		return "", fmt.Errorf("empty remote hash for %s", git.rev)
	}
	return parts[0], nil
}

func lastNonEmpty(lines []string) string {
	last := ""
	for _, line := range lines {
		if line != "" {
			last = line
		}
	}
	return last
}

// syncSHA pulls a particular SHA from a remote repo, and publishes it through
// the specified symlink.  If depth is 0, the whole remote will be fetched.
func (git *syncRepo) syncSHA(ctx context.Context, sha string) error {
	worktreePath := git.worktreePath(sha)

	// Check if the worktree for this SHA exists and can be used.
	_, err := os.Stat(worktreePath)
	switch {
	case os.IsNotExist(err):
		// A worktree for this SHA doesn't exist.
		log.V(0).Info("worktree does not exist, will create it", "worktree", worktreePath)
	case err != nil:
		return err
	default:
		// A worktree for this SHA exists, let's make sure it is correct.
		log.V(0).Info("worktree exists, verifying", "worktree", worktreePath)
		linkPath := git.linkPath()
		linked, err := samePath(linkPath, worktreePath)
		if err != nil {
			log.Error(err, "can't verify worktree, will recreate it")
		} else if !linked {
			log.V(0).Info("link does not point to correct worktree, will recreate it")
		} else if !git.SanityCheck(ctx, sha) {
			log.V(0).Info("worktree failed checks, will recreate it")
		} else {
			// FIXME: we could 'rev-parse HEAD' or other things to verify.
			log.V(0).Info("SHA is already synced, ensuring depth", "sha", sha)
			// This will set/unset the repo's 'shallow' property based on
			// depth, even if we already have the SHA.
			if err := git.fetchSHA(ctx, sha); err != nil {
				return err
			}
			return nil
		}

		// Something is not right, just start over.
		if err := os.RemoveAll(worktreePath); err != nil {
			return fmt.Errorf("can't remove invalid worktree %q: %w", worktreePath, err)
		}
	}

	// By the time we get here we know the worktree doesn't exist.
	if err := git.fetchSHA(ctx, sha); err != nil {
		return err
	}
	if err := git.publishWorktree(ctx, sha); err != nil {
		return fmt.Errorf("publishWorktree: %w", err)
	}

	return nil
}

func (git *syncRepo) worktreePath(sha string) string {
	return filepath.Join(git.rootDir, "worktrees", sha)
}

func (git *syncRepo) linkPath() string {
	return filepath.Join(git.rootDir, git.linkName)
}

func samePath(lhs, rhs string) (bool, error) {
	lhsAbs, err := normalizePath(lhs)
	if err != nil {
		return false, fmt.Errorf("normalizePath(%s): %w", lhs, err)
	}
	rhsAbs, err := normalizePath(rhs)
	if err != nil {
		return false, fmt.Errorf("normalizePath(%s): %w", rhs, err)
	}
	return (lhsAbs == rhsAbs), nil
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

// fetchSHA retrieves the specified SHA from the parent repo into the git root.
func (git *syncRepo) fetchSHA(ctx context.Context, sha string) error {
	log.V(0).Info("fetching SHA from repo", "sha", sha, "repo", git.repo)

	// If we already have the SHA, this makes fetch a no-op.  If we don't,
	// ignore the error.
	runCommand(ctx, git.rootDir, git.cmd, "reset", "--soft", sha, "--")

	// Fetch the SHA and do some cleanup, setting or un-setting the repo's
	// shallow flag as appropriate.
	args := []string{"fetch", git.repo, sha, "--force", "--prune"}
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
	if _, err := runCommand(ctx, git.rootDir, git.cmd, args...); err != nil {
		return err
	}
	// Make sure that subsequent `git rev-parse HEAD` calls work.
	// ignore the error.
	if _, err := runCommand(ctx, git.rootDir, git.cmd, "reset", "--soft", sha, "--"); err != nil {
		return err
	}

	return nil
}

func (git *syncRepo) isShallow(ctx context.Context) (bool, error) {
	boolStr, err := runCommand(ctx, git.rootDir, git.cmd, "rev-parse", "--is-shallow-repository")
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

// publishWorktree creates a new worktree, swaps the symlink to point
// to the new worktree, cleans up old worktrees, and cleans up the repo.
func (git *syncRepo) publishWorktree(ctx context.Context, sha string) error {
	// Make a worktree for this exact git sha.
	worktreePath := git.worktreePath(sha)
	log.V(0).Info("adding worktree", "path", worktreePath)
	_, err := runCommand(ctx, git.rootDir, git.cmd, "worktree", "add", "-q", "-f", worktreePath, sha)
	if err != nil {
		return err
	}

	// The .git file in the worktree directory holds an absolute path reference
	// to the git root (e.g. /git/.git/worktrees/<worktree-dir-name>. Replace it
	// with a relative path, so that other containers can use a different volume
	// mount path.
	repoRelativeToWorktree, err := filepath.Rel(worktreePath, git.rootDir)
	if err != nil {
		return err
	}
	gitDirRef := []byte(fmt.Sprintf("gitdir: %s\n", filepath.Join(repoRelativeToWorktree, ".git", "worktrees", sha)))
	if err = ioutil.WriteFile(filepath.Join(worktreePath, ".git"), gitDirRef, 0644); err != nil {
		return err
	}

	// Update submodules
	if git.submodules != submodulesOff {
		// NOTE: this works for repos with or without submodules.
		log.V(0).Info("updating submodules")
		submodulesArgs := []string{"submodule", "update", "--init"}
		if git.submodules == submodulesRecursive {
			submodulesArgs = append(submodulesArgs, "--recursive")
		}
		if git.depth > 0 {
			submodulesArgs = append(submodulesArgs, "--depth", strconv.Itoa(git.depth))
		}
		_, err = runCommand(ctx, worktreePath, git.cmd, submodulesArgs...)
		if err != nil {
			return err
		}
	}

	// Change the file permissions, if requested.
	if git.chmod != 0 {
		mode := fmt.Sprintf("%#o", git.chmod)
		log.V(0).Info("changing file permissions", "mode", mode)
		_, err = runCommand(ctx, "", "chmod", "-R", mode, worktreePath)
		if err != nil {
			return err
		}
	}

	// Flip the symlink.
	if _, err := git.updateSymlink(ctx, worktreePath); err != nil {
		return err
	}
	setRepoReady()

	// Clean up old worktree dirs.
	log.V(1).Info("removing old worktree dirs")
	if dirents, err := ioutil.ReadDir(git.worktreePath("")); err != nil {
		return err
	} else {
		for _, fi := range dirents {
			switch fi.Name() {
			case sha:
				// Ignore.
			default:
				p := filepath.Join(git.worktreePath(""), fi.Name())
				log.V(2).Info("removing path recursively", "path", p, "isDir", fi.IsDir())
				if err := os.RemoveAll(p); err != nil {
					return fmt.Errorf("can't remove old worktree: %w", err)
				}
			}
		}
	}

	// Clean up the repo and purge stuff we don't need.
	//FIXME: what do we need to clean up after a fetch changes from unshallw to shallow?
	log.V(1).Info("cleaning up repo")
	if _, err := runCommand(ctx, git.rootDir, git.cmd, "worktree", "prune"); err != nil {
		return err
	}
	if _, err := runCommand(ctx, git.rootDir, git.cmd, "reflog", "expire", "--expire-unreachable=all", "--all"); err != nil {
		return err
	}
	if _, err := runCommand(ctx, git.rootDir, git.cmd, "gc", "--prune=all"); err != nil {
		return err
	}

	return nil
}

// updateSymlink atomically swaps the symlink to point at the specified
// directory and cleans up the previous worktree.  If there was a previous
// worktree, this returns the path to it.
func (git *syncRepo) updateSymlink(ctx context.Context, newDir string) (string, error) {
	// Get currently-linked repo directory (to be removed), unless it doesn't exist
	linkPath := git.linkPath()
	oldWorktreePath, err := filepath.EvalSymlinks(linkPath)
	if err != nil && !os.IsNotExist(err) {
		return "", fmt.Errorf("can't access current worktree %s: %w", linkPath, err)
	}

	// newDir is absolute, so we need to change it to a relative path.  This is
	// so it can be volume-mounted at another path and the symlink still works.
	newDirRelative, err := filepath.Rel(git.rootDir, newDir)
	if err != nil {
		return "", fmt.Errorf("can't make relative path %s -> %s: %w", git.rootDir, newDir, err)
	}

	const tmplink = "tmp-link"
	log.V(1).Info("creating tmp symlink", "root", git.rootDir, "dst", newDirRelative, "src", tmplink)
	if _, err := runCommand(ctx, git.rootDir, "ln", "-snf", newDirRelative, tmplink); err != nil {
		return "", fmt.Errorf("can't create tmp symlink %q: %w", tmplink, err)
	}

	log.V(1).Info("renaming symlink", "root", git.rootDir, "old_name", tmplink, "new_name", git.linkName)
	if _, err := runCommand(ctx, git.rootDir, "mv", "-T", tmplink, git.linkName); err != nil {
		return "", fmt.Errorf("can't replace symlink %q: %w", git.linkName, err)
	}

	return oldWorktreePath, nil
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

func setupGitAuth(ctx context.Context, username, password, gitURL string) error {
	log.V(1).Info("setting up git credential store")

	_, err := runCommand(ctx, "", *flGitCmd, "config", "--global", "credential.helper", "store")
	if err != nil {
		return fmt.Errorf("can't configure git credential helper: %w", err)
	}

	creds := fmt.Sprintf("url=%v\nusername=%v\npassword=%v\n", gitURL, username, password)
	_, err = runCommandWithStdin(ctx, "", creds, *flGitCmd, "credential", "approve")
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

func setupGitCookieFile(ctx context.Context) error {
	log.V(1).Info("configuring git cookie file")

	var pathToCookieFile = "/etc/git-secret/cookie_file"

	_, err := os.Stat(pathToCookieFile)
	if err != nil {
		return fmt.Errorf("can't access git cookiefile: %w", err)
	}

	if _, err = runCommand(ctx, "",
		*flGitCmd, "config", "--global", "http.cookiefile", pathToCookieFile); err != nil {
		return fmt.Errorf("can't configure git cookiefile: %w", err)
	}

	return nil
}

// The expected ASKPASS callback output are below,
// see https://git-scm.com/docs/gitcredentials for more examples:
// username=xxx@example.com
// password=ya29.xxxyyyzzz
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

	if err := setupGitAuth(ctx, username, password, *flRepo); err != nil {
		return err
	}

	return nil
}
