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

// git-sync is a command that pull a git repository to a local directory.

package main // import "k8s.io/git-sync/cmd/git-sync"

import (
	"bytes"
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
	"path"
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
var flBranch = flag.String("branch", envString("GIT_SYNC_BRANCH", "master"),
	"the git branch to check out")
var flRev = flag.String("rev", envString("GIT_SYNC_REV", "HEAD"),
	"the git revision (tag or hash) to check out")
var flDepth = flag.Int("depth", envInt("GIT_SYNC_DEPTH", 0),
	"use a shallow clone with a history truncated to the specified number of commits")

var flRoot = flag.String("root", envString("GIT_SYNC_ROOT", envString("HOME", "")+"/git"),
	"the root directory for git-sync operations, under which --dest will be created")
var flDest = flag.String("dest", envString("GIT_SYNC_DEST", ""),
	"the name of (a symlink to) a directory in which to check-out files under --root (defaults to the leaf dir of --repo)")
var flWait = flag.Float64("wait", envFloat("GIT_SYNC_WAIT", 0),
	"the number of seconds between syncs")
var flSyncTimeout = flag.Int("timeout", envInt("GIT_SYNC_TIMEOUT", 120),
	"the max number of seconds allowed for a complete sync")
var flOneTime = flag.Bool("one-time", envBool("GIT_SYNC_ONE_TIME", false),
	"exit after the first sync")
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
)

// initTimeout is a timeout for initialization, like git credentials setup.
const initTimeout = time.Second * 30

func init() {
	prometheus.MustRegister(syncDuration)
	prometheus.MustRegister(syncCount)
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
		fmt.Fprintf(os.Stderr, "ERROR: --repo must be provided\n")
		flag.Usage()
		os.Exit(1)
	}

	if *flDest == "" {
		parts := strings.Split(strings.Trim(*flRepo, "/"), "/")
		*flDest = parts[len(parts)-1]
	}

	if strings.Contains(*flDest, "/") {
		fmt.Fprintf(os.Stderr, "ERROR: --dest must be a bare name\n")
		flag.Usage()
		os.Exit(1)
	}

	if _, err := exec.LookPath(*flGitCmd); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: git executable %q not found: %v\n", *flGitCmd, err)
		os.Exit(1)
	}

	if (*flUsername != "" || *flPassword != "" || *flCookieFile || *flAskPassURL != "") && *flSSH {
		fmt.Fprintf(os.Stderr, "ERROR: --ssh is set but --username, --password, --askpass-url, or --cookie-file were provided\n")
		os.Exit(1)
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

	if *flAskPassURL != "" {
		if err := setupGitAskPassURL(ctx); err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: failed to call ASKPASS callback URL: %v\n", err)
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
	log.V(0).Info("starting up", "args", os.Args)

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
		ctx, cancel := context.WithTimeout(context.Background(), time.Second*time.Duration(*flSyncTimeout))
		if changed, hash, err := syncRepo(ctx, *flRepo, *flBranch, *flRev, *flDepth, *flRoot, *flDest, *flAskPassURL); err != nil {
			syncDuration.WithLabelValues("error").Observe(time.Since(start).Seconds())
			syncCount.WithLabelValues("error").Inc()
			if *flMaxSyncFailures != -1 && failCount >= *flMaxSyncFailures {
				// Exit after too many retries, maybe the error is not recoverable.
				log.Error(err, "failed to sync repo, aborting")
				os.Exit(1)
			}

			failCount++
			log.Error(err, "unexpected error syncing repo, will retry")
			log.V(0).Info("waiting before retrying", "waitTime", waitTime(*flWait))
			cancel()
			time.Sleep(waitTime(*flWait))
			continue
		} else if changed && webhook != nil {
			webhook.Send(hash)
		}
		syncDuration.WithLabelValues("success").Observe(time.Since(start).Seconds())
		syncCount.WithLabelValues("success").Inc()

		if initialSync {
			if *flOneTime {
				os.Exit(0)
			}
			if isHash, err := revIsHash(ctx, *flRev, *flRoot); err != nil {
				log.Error(err, "can't tell if rev is a git hash, exiting", "rev", *flRev)
				os.Exit(1)
			} else if isHash {
				log.V(0).Info("rev appears to be a git hash, no further sync needed", "rev", *flRev)
				sleepForever()
			}
			initialSync = false
		}

		failCount = 0
		log.V(1).Info("next sync", "wait_time", waitTime(*flWait))
		cancel()
		time.Sleep(waitTime(*flWait))
	}
}

func waitTime(seconds float64) time.Duration {
	return time.Duration(int(seconds*1000)) * time.Millisecond
}

func setFlagDefaults() {
	// Force logging to stderr.
	stderrFlag := flag.Lookup("logtostderr")
	if stderrFlag == nil {
		fmt.Fprintf(os.Stderr, "can't find flag 'logtostderr'\n")
		os.Exit(1)
	}
	stderrFlag.Value.Set("true")
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
			return fmt.Errorf("can't get current working directory: %v", err)
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
	// Get currently-linked repo directory (to be removed), unless it doesn't exist
	linkPath := path.Join(gitRoot, link)
	oldWorktreePath, err := filepath.EvalSymlinks(linkPath)
	if err != nil && !os.IsNotExist(err) {
		return "", fmt.Errorf("error accessing current worktree: %v", err)
	}

	// newDir is absolute, so we need to change it to a relative path.  This is
	// so it can be volume-mounted at another path and the symlink still works.
	newDirRelative, err := filepath.Rel(gitRoot, newDir)
	if err != nil {
		return "", fmt.Errorf("error converting to relative path: %v", err)
	}

	const tmplink = "tmp-link"
	log.V(1).Info("creating tmp symlink", "root", gitRoot, "dst", newDirRelative, "src", tmplink)
	if _, err := runCommand(ctx, gitRoot, "ln", "-snf", newDirRelative, tmplink); err != nil {
		return "", fmt.Errorf("error creating symlink: %v", err)
	}

	log.V(1).Info("renaming symlink", "root", gitRoot, "old_name", tmplink, "new_name", link)
	if _, err := runCommand(ctx, gitRoot, "mv", "-T", tmplink, link); err != nil {
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

// addWorktreeAndSwap creates a new worktree and calls updateSymlink to swap the symlink to point to the new worktree
func addWorktreeAndSwap(ctx context.Context, gitRoot, dest, branch, rev string, depth int, hash string) error {
	log.V(0).Info("syncing git", "rev", rev, "hash", hash)

	args := []string{"fetch", "-f", "--tags"}
	if depth != 0 {
		args = append(args, "--depth", strconv.Itoa(depth))
	}
	args = append(args, "origin", branch)

	// Update from the remote.
	if _, err := runCommand(ctx, gitRoot, *flGitCmd, args...); err != nil {
		return err
	}

	// GC clone
	if _, err := runCommand(ctx, gitRoot, *flGitCmd, "gc", "--prune=all"); err != nil {
		return err
	}

	// Make a worktree for this exact git hash.
	worktreePath := path.Join(gitRoot, "rev-"+hash)
	_, err := runCommand(ctx, gitRoot, *flGitCmd, "worktree", "add", worktreePath, "origin/"+branch)
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
	gitDirRef := []byte(path.Join("gitdir: ../.git/worktrees", worktreePathRelative) + "\n")
	if err = ioutil.WriteFile(path.Join(worktreePath, ".git"), gitDirRef, 0644); err != nil {
		return err
	}

	// Reset the worktree's working copy to the specific rev.
	_, err = runCommand(ctx, worktreePath, *flGitCmd, "reset", "--hard", hash)
	if err != nil {
		return err
	}
	log.V(0).Info("reset worktree to hash", "path", worktreePath, "hash", hash)

	// Update submodules
	// NOTE: this works for repo with or without submodules.
	log.V(0).Info("updating submodules")
	submodulesArgs := []string{"submodule", "update", "--init", "--recursive"}
	if depth != 0 {
		submodulesArgs = append(submodulesArgs, "--depth", strconv.Itoa(depth))
	}
	_, err = runCommand(ctx, worktreePath, *flGitCmd, submodulesArgs...)
	if err != nil {
		return err
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

	// Flip the symlink.
	oldWorktree, err := updateSymlink(ctx, gitRoot, dest, worktreePath)
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
		if _, err := runCommand(ctx, gitRoot, *flGitCmd, "worktree", "prune"); err != nil {
			return err
		}
	}

	return nil
}

func cloneRepo(ctx context.Context, repo, branch, rev string, depth int, gitRoot string) error {
	args := []string{"clone", "--no-checkout", "-b", branch}
	if depth != 0 {
		args = append(args, "--depth", strconv.Itoa(depth))
	}
	args = append(args, repo, gitRoot)
	log.V(0).Info("cloning repo", "origin", repo, "path", gitRoot)

	_, err := runCommand(ctx, "", *flGitCmd, args...)
	if err != nil {
		if strings.Contains(err.Error(), "already exists and is not an empty directory") {
			// Maybe a previous run crashed?  Git won't use this dir.
			log.V(0).Info("git root exists and is not empty (previous crash?), cleaning up", "path", gitRoot)
			err := os.RemoveAll(gitRoot)
			if err != nil {
				return err
			}
			_, err = runCommand(ctx, "", *flGitCmd, args...)
			if err != nil {
				return err
			}
		} else {
			return err
		}
	}

	return nil
}

// localHashForRev returns the locally known hash for a given rev.
func localHashForRev(ctx context.Context, rev, gitRoot string) (string, error) {
	output, err := runCommand(ctx, gitRoot, *flGitCmd, "rev-parse", rev)
	if err != nil {
		return "", err
	}
	return strings.Trim(string(output), "\n"), nil
}

// remoteHashForRef returns the upstream hash for a given ref.
func remoteHashForRef(ctx context.Context, ref, gitRoot string) (string, error) {
	output, err := runCommand(ctx, gitRoot, *flGitCmd, "ls-remote", "-q", "origin", ref)
	if err != nil {
		return "", err
	}
	parts := strings.Split(string(output), "\t")
	return parts[0], nil
}

func revIsHash(ctx context.Context, rev, gitRoot string) (bool, error) {
	// If git doesn't identify rev as a commit, we're done.
	output, err := runCommand(ctx, gitRoot, *flGitCmd, "cat-file", "-t", rev)
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
func syncRepo(ctx context.Context, repo, branch, rev string, depth int, gitRoot, dest string, authUrl string) (bool, string, error) {
	if authUrl != "" {
		// For ASKPASS Callback URL, the credentials behind is dynamic, it needs to be
		// re-fetched each time.
		if err := setupGitAskPassURL(ctx); err != nil {
			return false, "", fmt.Errorf("failed to call GIT_ASKPASS_URL: %v", err)
		}
	}

	target := path.Join(gitRoot, dest)
	gitRepoPath := path.Join(target, ".git")
	var hash string
	_, err := os.Stat(gitRepoPath)
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
		return false, "", fmt.Errorf("error checking if repo exists %q: %v", gitRepoPath, err)
	default:
		// Not the first time. Figure out if the ref has changed.
		local, remote, err := getRevs(ctx, target, branch, rev)
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

	return true, hash, addWorktreeAndSwap(ctx, gitRoot, dest, branch, rev, depth, hash)
}

// getRevs returns the local and upstream hashes for rev.
func getRevs(ctx context.Context, localDir, branch, rev string) (string, string, error) {
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
	remote, err := remoteHashForRef(ctx, ref, localDir)
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
	log.V(5).Info("running command", "cwd", cwd, "cmd", cmdForLog(command, args...))

	cmd := exec.CommandContext(ctx, command, args...)
	if cwd != "" {
		cmd.Dir = cwd
	}
	output, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return "", fmt.Errorf("command timed out: %v: %q", err, string(output))

	}
	if err != nil {
		return "", fmt.Errorf("error running command: %v: %q", err, string(output))
	}

	return string(output), nil
}

func runCommandWithStdin(ctx context.Context, cwd, stdin, command string, args ...string) (string, error) {
	log.V(5).Info("running command", "cwd", cwd, "cmd", cmdForLog(command, args...))

	cmd := exec.CommandContext(ctx, command, args...)
	if cwd != "" {
		cmd.Dir = cwd
	}

	in, err := cmd.StdinPipe()
	if err != nil {
		return "", err
	}
	if _, err := io.Copy(in, bytes.NewBufferString(stdin)); err != nil {
		return "", err
	}
	if err := in.Close(); err != nil {
		return "", err
	}

	output, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return "", fmt.Errorf("command timed out: %v: %q", err, string(output))
	}
	if err != nil {
		return "", fmt.Errorf("error running command: %v: %q", err, string(output))
	}

	return string(output), nil
}

func setupGitAuth(ctx context.Context, username, password, gitURL string) error {
	log.V(1).Info("setting up git credential store")

	_, err := runCommand(ctx, "", *flGitCmd, "config", "--global", "credential.helper", "store")
	if err != nil {
		return fmt.Errorf("error setting up git credentials: %v", err)
	}

	creds := fmt.Sprintf("url=%v\nusername=%v\npassword=%v\n", gitURL, username, password)
	_, err = runCommandWithStdin(ctx, "", creds, *flGitCmd, "credential", "approve")
	if err != nil {
		return fmt.Errorf("error setting up git credentials: %v", err)
	}

	return nil
}

func setupGitSSH(setupKnownHosts bool) error {
	log.V(1).Info("setting up git SSH credentials")

	var pathToSSHSecret = *flSSHKeyFile
	var pathToSSHKnownHosts = *flSSHKnownHostsFile

	_, err := os.Stat(pathToSSHSecret)
	if err != nil {
		return fmt.Errorf("error: could not access SSH key Secret: %v", err)
	}

	if setupKnownHosts {
		_, err = os.Stat(pathToSSHKnownHosts)
		if err != nil {
			return fmt.Errorf("error: could not access SSH known_hosts file: %v", err)
		}

		err = os.Setenv("GIT_SSH_COMMAND", fmt.Sprintf("ssh -q -o UserKnownHostsFile=%s -i %s", pathToSSHKnownHosts, pathToSSHSecret))
	} else {
		err = os.Setenv("GIT_SSH_COMMAND", fmt.Sprintf("ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i %s", pathToSSHSecret))
	}

	//set env variable GIT_SSH_COMMAND to force git use customized ssh command
	if err != nil {
		return fmt.Errorf("Failed to set the GIT_SSH_COMMAND env var: %v", err)
	}

	return nil
}

func setupGitCookieFile(ctx context.Context) error {
	log.V(1).Info("configuring git cookie file")

	var pathToCookieFile = "/etc/git-secret/cookie_file"

	_, err := os.Stat(pathToCookieFile)
	if err != nil {
		return fmt.Errorf("error: could not access git cookie file: %v", err)
	}

	if _, err = runCommand(ctx, "",
		*flGitCmd, "config", "--global", "http.cookiefile", pathToCookieFile); err != nil {
		return fmt.Errorf("error configuring git cookie file: %v", err)
	}

	return nil
}

// The expected ASKPASS callback output are below,
// see https://git-scm.com/docs/gitcredentials for more examples:
// username=xxx@example.com
// password=ya29.xxxyyyzzz
func setupGitAskPassURL(ctx context.Context) error {
	log.V(1).Info("configuring GIT_ASKPASS_URL")

	var netClient = &http.Client{
		Timeout: time.Second * 1,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	httpReq, err := http.NewRequestWithContext(ctx, "GET", *flAskPassURL, nil)
	if err != nil {
		return fmt.Errorf("error create auth request: %v", err)
	}
	resp, err := netClient.Do(httpReq)
	if err != nil {
		return fmt.Errorf("error access auth url: %v", err)
	}
	if resp.StatusCode != 200 {
		return fmt.Errorf("access auth url: %v", err)
	}
	authData, err := ioutil.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return fmt.Errorf("error read auth response: %v", err)
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
		return fmt.Errorf("error setup git auth: %v", err)
	}

	return nil
}
