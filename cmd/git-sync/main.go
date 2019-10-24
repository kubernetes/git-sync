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
	"errors"
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
	"time"

	"github.com/go-logr/glogr"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/rivo/uniseg"
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
	"the root directory for git operations")
var flDest = flag.String("dest", envString("GIT_SYNC_DEST", ""),
	"the name at which to publish the checked-out files under --root (defaults to leaf dir of --repo)")
var flWait = flag.Float64("wait", envFloat("GIT_SYNC_WAIT", 0),
	"the number of seconds between syncs")
var flSyncTimeout = flag.Int("timeout", envInt("GIT_SYNC_TIMEOUT", 120),
	"the max number of seconds for a complete sync")
var flOneTime = flag.Bool("one-time", envBool("GIT_SYNC_ONE_TIME", false),
	"exit after the initial checkout")
var flSpecific = flag.Bool("specific", envBool("GIT_SYNC_SPECIFIC", false),
	"checkout at a specific time daily")
var flSpecificTime = flag.String("specific-time", envString("GIT_SYNC_SPECIFIC_TIME", "0000"),
	"specify in military time when to checkout")
var flMaxSyncFailures = flag.Int("max-sync-failures", envInt("GIT_SYNC_MAX_SYNC_FAILURES", 0),
	"the number of consecutive failures allowed before aborting (the first pull must succeed, -1 disables aborting for any number of failures after the initial sync)")
var flChmod = flag.Int("change-permissions", envInt("GIT_SYNC_PERMISSIONS", 0),
	"the file permissions to apply to the checked-out files")

var flWebhookURL = flag.String("webhook-url", envString("GIT_SYNC_WEBHOOK_URL", ""),
	"the URL for the webook to send to. Default is \"\" which disables the webook.")
var flWebhookMethod = flag.String("webhook-method", envString("GIT_SYNC_WEBHOOK_METHOD", "POST"),
	"the method for the webook to send with")
var flWebhookStatusSuccess = flag.Int("webhook-success-status", envInt("GIT_SYNC_WEBHOOK_SUCCESS_STATUS", 200),
	"the status code which indicates a successful webhook call. A value of -1 disables success checks to make webhooks fire-and-forget")
var flWebhookTimeout = flag.Duration("webhook-timeout", envDuration("GIT_SYNC_WEBHOOK_TIMEOUT", time.Second),
	"the timeout used when communicating with the webhook target")
var flWebhookBackoff = flag.Duration("webhook-backoff", envDuration("GIT_SYNC_WEBHOOK_BACKOFF", time.Second*3),
	"if a webhook call fails (dependant on webhook-success-status) this defines how much time to wait before retrying the call")

var flUsername = flag.String("username", envString("GIT_SYNC_USERNAME", ""),
	"the username to use")
var flPassword = flag.String("password", envString("GIT_SYNC_PASSWORD", ""),
	"the password to use")

var flSSH = flag.Bool("ssh", envBool("GIT_SYNC_SSH", false),
	"use SSH for git operations")
var flSSHKeyFile = flag.String("ssh-key-file", envString("GIT_SSH_KEY_FILE", "/etc/git-secret/ssh"),
	"the ssh key to use")
var flSSHKnownHosts = flag.Bool("ssh-known-hosts", envBool("GIT_KNOWN_HOSTS", true),
	"enable SSH known_hosts verification")
var flSSHKnownHostsFile = flag.String("ssh-known-hosts-file", envString("GIT_SSH_KNOWN_HOSTS_FILE", "/etc/git-secret/known_hosts"),
	"the known hosts file to use")

var flCookieFile = flag.Bool("cookie-file", envBool("GIT_COOKIE_FILE", false),
	"use git cookiefile")

var flGitCmd = flag.String("git", envString("GIT_SYNC_GIT", "git"),
	"the git command to run (subject to PATH search)")

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

func sanitizeSpecificTime(t string) (h int, m int) {
	if uniseg.GraphemeClusterCount(t) != 4 {
		err := errors.New("error=")
		log.Error(err, "--specific-time value not in military format, e.g. 1500 or 0130")
		os.Exit(1)
	}

	tsplit := strings.Split(t, "")
	h, _ = strconv.Atoi(strings.Join(tsplit[0:2], ""))
	m, _ = strconv.Atoi(strings.Join(tsplit[2:], ""))

	return h, m
}

func initSpecific(h int, m int) {
	hold := true
	t := time.Now()
	n := time.Date(t.Year(), t.Month(), t.Day(), h, m, 0, 0, t.Location())
	d := n.Sub(t)
	if d < 0 {
		n = n.Add(24 * time.Hour)
		d = n.Sub(t)
	}
	for hold {
		time.Sleep(d)
		d = 24 * time.Hour
		hold = false
	}
}

func main() {
	setFlagDefaults()

	flag.Parse()

	if *flVer {
		fmt.Println(version.VERSION)
		os.Exit(0)
	}

	if *flRepo == "" {
		fmt.Fprintf(os.Stderr, "ERROR: --repo or $GIT_SYNC_REPO must be provided\n")
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

	if (*flUsername != "" || *flPassword != "" || *flCookieFile) && *flSSH {
		fmt.Fprintf(os.Stderr, "ERROR: GIT_SYNC_SSH set but HTTP parameters provided. These cannot be used together.")
		os.Exit(1)
	}

	if *flUsername != "" && *flPassword != "" {
		if err := setupGitAuth(*flUsername, *flPassword, *flRepo); err != nil {
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
		if err := setupGitCookieFile(); err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: can't set git cookie file: %v\n", err)
			os.Exit(1)
		}
	}

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
			mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {})
			http.Serve(ln, mux)
		}()
	}

	// From here on, output goes through logging.
	log.V(0).Info("starting up", "args", os.Args)

	// Startup webhooks goroutine
	webhookTriggerChan := make(chan struct{}, 1)
	if *flWebhookURL != "" && *flSpecific == true {
		err := errors.New("error=")
		log.Error(err, "--specific does not support webhooks")
		os.Exit(1)
	} else if *flWebhookURL != "" {
		webhook := Webhook{
			URL:     *flWebhookURL,
			Method:  *flWebhookMethod,
			Success: *flWebhookStatusSuccess,
			Timeout: *flWebhookTimeout,
			Backoff: *flWebhookBackoff,
		}
		go webhook.run(webhookTriggerChan)
	}

	initialSync := true
	failCount := 0
	for {
		start := time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), time.Second*time.Duration(*flSyncTimeout))
		if *flSpecific {
			h, m := sanitizeSpecificTime(*flSpecificTime)
			initSpecific(h, m)
		}
		if changed, err := syncRepo(ctx, *flRepo, *flBranch, *flRev, *flDepth, *flRoot, *flDest); err != nil {
			syncDuration.WithLabelValues("error").Observe(time.Now().Sub(start).Seconds())
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
		} else if changed {
			// Trigger webhooks to be called. We do a non-blocking write to the channel as we
			// don't want to backup the syncing locally because we can't complete a webhook call.
			// Since the channel has a buffer of 1 we ensure that it is called for a change, but
			// this allows us to de-dupe calls if they happen before the webhook call completes.
			select {
			case webhookTriggerChan <- struct{}{}:
			default:
			}
		}
		syncDuration.WithLabelValues("success").Observe(time.Now().Sub(start).Seconds())
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

// updateSymlink atomically swaps the symlink to point at the specified directory and cleans up the previous worktree.
func updateSymlink(ctx context.Context, gitRoot, link, newDir string) error {
	// Get currently-linked repo directory (to be removed), unless it doesn't exist
	fullpath := path.Join(gitRoot, link)
	currentDir, err := filepath.EvalSymlinks(fullpath)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("error accessing symlink: %v", err)
	}

	// newDir is /git/rev-..., we need to change it to relative path.
	// Volume in other container may not be mounted at /git, so the symlink can't point to /git.
	newDirRelative, err := filepath.Rel(gitRoot, newDir)
	if err != nil {
		return fmt.Errorf("error converting to relative path: %v", err)
	}

	const tmplink = "tmp-link"
	if _, err := runCommand(ctx, gitRoot, "ln", "-snf", newDirRelative, tmplink); err != nil {
		return fmt.Errorf("error creating symlink: %v", err)
	}
	log.V(1).Info("created tmp symlink", "root", gitRoot, "dst", newDirRelative, "src", tmplink)

	if _, err := runCommand(ctx, gitRoot, "mv", "-T", tmplink, link); err != nil {
		return fmt.Errorf("error replacing symlink: %v", err)
	}
	log.V(1).Info("renamed symlink", "root", gitRoot, "old_name", tmplink, "new_name", link)

	// Clean up previous worktree
	if len(currentDir) > 0 {
		if err = os.RemoveAll(currentDir); err != nil {
			return fmt.Errorf("error removing directory: %v", err)
		}

		log.V(1).Info("removed previous worktree", "path", currentDir)

		_, err := runCommand(ctx, gitRoot, *flGitCmd, "worktree", "prune")
		if err != nil {
			return err
		}

		log.V(1).Info("pruned old worktrees")
	}

	return nil
}

// addWorktreeAndSwap creates a new worktree and calls updateSymlink to swap the symlink to point to the new worktree
func addWorktreeAndSwap(ctx context.Context, gitRoot, dest, branch, rev string, depth int, hash string) error {
	log.V(0).Info("syncing git", "rev", rev, "hash", hash)

	args := []string{"fetch", "--tags"}
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
	if err != nil {
		return err
	}
	log.V(0).Info("added worktree", "path", worktreePath, "branch", fmt.Sprintf("origin/%s", branch))

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
	// NOTICE: it works for repos with or without submodules
	// TODO: add --depth flag support
	// possible bug in git: git fetches full submodule history even with --depth flag is provided
	// (tested with git version 2.23.0 on Mac)
	_, err = runCommand(ctx, worktreePath, *flGitCmd, "submodule", "update", "--init", "--recursive")
	if err != nil {
		return err
	}
	log.V(0).Info("updated submodules")

	if *flChmod != 0 {
		// set file permissions
		_, err = runCommand(ctx, "", "chmod", "-R", strconv.Itoa(*flChmod), worktreePath)
		if err != nil {
			return err
		}
	}

	return updateSymlink(ctx, gitRoot, dest, worktreePath)
}

func cloneRepo(ctx context.Context, repo, branch, rev string, depth int, gitRoot string) error {
	args := []string{"clone", "--no-checkout", "-b", branch}
	if depth != 0 {
		args = append(args, "--depth", strconv.Itoa(depth))
	}
	args = append(args, repo, gitRoot)
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
	log.V(0).Info("cloned repo", "origin", repo)

	return nil
}

func hashForRev(ctx context.Context, rev, gitRoot string) (string, error) {
	output, err := runCommand(ctx, gitRoot, *flGitCmd, "rev-parse", rev)
	if err != nil {
		return "", err
	}
	return strings.Trim(string(output), "\n"), nil
}

func revIsHash(ctx context.Context, rev, gitRoot string) (bool, error) {
	// If rev is a tag name or HEAD, rev-parse will produce the git hash.  If
	// rev is already a git hash, the output will be the same hash.  Of course, a
	// user could specify "abc" and match "abcdef12345678", so we just do a
	// prefix match.
	output, err := hashForRev(ctx, rev, gitRoot)
	if err != nil {
		return false, err
	}
	return strings.HasPrefix(output, rev), nil
}

// syncRepo syncs the branch of a given repository to the destination at the given rev.
// returns (1) whether a change occured and (2) an error if one happened
func syncRepo(ctx context.Context, repo, branch, rev string, depth int, gitRoot, dest string) (bool, error) {
	target := path.Join(gitRoot, dest)
	gitRepoPath := path.Join(target, ".git")
	hash := rev
	_, err := os.Stat(gitRepoPath)
	switch {
	case os.IsNotExist(err):
		err = cloneRepo(ctx, repo, branch, rev, depth, gitRoot)
		if err != nil {
			return false, err
		}
		hash, err = hashForRev(ctx, rev, gitRoot)
		if err != nil {
			return false, err
		}
	case err != nil:
		return false, fmt.Errorf("error checking if repo exists %q: %v", gitRepoPath, err)
	default:
		local, remote, err := getRevs(ctx, target, branch, rev)
		if err != nil {
			return false, err
		}
		log.V(2).Info("git state", "local", local, "remote", remote)
		if local == remote {
			log.V(1).Info("no update required")
			return false, nil
		}
		log.V(0).Info("update required")
		hash = remote
	}

	return true, addWorktreeAndSwap(ctx, gitRoot, dest, branch, rev, depth, hash)
}

// getRevs returns the local and upstream hashes for rev.
func getRevs(ctx context.Context, localDir, branch, rev string) (string, string, error) {
	// Ask git what the exact hash is for rev.
	local, err := hashForRev(ctx, rev, localDir)
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

func remoteHashForRef(ctx context.Context, ref, gitRoot string) (string, error) {
	output, err := runCommand(ctx, gitRoot, *flGitCmd, "ls-remote", "-q", "origin", ref)
	if err != nil {
		return "", err
	}
	parts := strings.Split(string(output), "\t")
	return parts[0], nil
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

func setupGitAuth(username, password, gitURL string) error {
	log.V(1).Info("setting up git credential cache")
	cmd := exec.Command(*flGitCmd, "config", "--global", "credential.helper", "cache")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("error setting up git credentials %v: %s", err, string(output))
	}

	cmd = exec.Command(*flGitCmd, "credential", "approve")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	creds := fmt.Sprintf("url=%v\nusername=%v\npassword=%v\n", gitURL, username, password)
	io.Copy(stdin, bytes.NewBufferString(creds))
	stdin.Close()
	output, err = cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("error setting up git credentials %v: %s", err, string(output))
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
		_, err := os.Stat(pathToSSHKnownHosts)
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

func setupGitCookieFile() error {
	log.V(1).Info("configuring git cookie file")

	var pathToCookieFile = "/etc/git-secret/cookie_file"

	_, err := os.Stat(pathToCookieFile)
	if err != nil {
		return fmt.Errorf("error: could not access git cookie file: %v", err)
	}

	cmd := exec.Command(*flGitCmd, "config", "--global", "http.cookiefile", pathToCookieFile)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("error configuring git cookie file %v: %s", err, string(output))
	}

	return nil
}
