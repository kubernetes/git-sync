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
	"encoding/json"
	stdflag "flag" // renamed so we don't accidentally use it
	"fmt"
	"io"
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
	"github.com/go-logr/logr"
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
var flErrorFile = pflag.String("error-file", envString("GIT_SYNC_ERROR_FILE", ""),
	"the name of a file into which errors will be written under --root (defaults to \"\", disabling error reporting)")
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
var flSparseCheckoutFile = pflag.String("sparse-checkout-file", envString("GIT_SYNC_SPARSE_CHECKOUT_FILE", ""),
	"the path to a sparse-checkout file")

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
var flGitConfig = pflag.String("git-config", envString("GIT_SYNC_GIT_CONFIG", ""),
	"additional git config options in 'key1:val1,key2:val2' format")

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

var log *customLogger

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

type submodulesMode string

const (
	submodulesRecursive submodulesMode = "recursive"
	submodulesShallow   submodulesMode = "shallow"
	submodulesOff       submodulesMode = "off"
)

type customLogger struct {
	logr.Logger
	root      string
	errorFile string
}

func (l customLogger) Error(err error, msg string, kvList ...interface{}) {
	l.Logger.Error(err, msg, kvList...)
	if l.errorFile == "" {
		return
	}
	payload := struct {
		Msg  string
		Err  string
		Args map[string]interface{}
	}{
		Msg:  msg,
		Err:  err.Error(),
		Args: map[string]interface{}{},
	}
	if len(kvList)%2 != 0 {
		kvList = append(kvList, "<no-value>")
	}
	for i := 0; i < len(kvList); i += 2 {
		k, ok := kvList[i].(string)
		if !ok {
			k = fmt.Sprintf("%v", kvList[i])
		}
		payload.Args[k] = kvList[i+1]
	}
	jb, err := json.Marshal(payload)
	if err != nil {
		l.Logger.Error(err, "can't encode error payload")
		content := fmt.Sprintf("%v", err)
		l.writeContent([]byte(content))
	} else {
		l.writeContent(jb)
	}
}

// exportError exports the error to the error file if --export-error is enabled.
func (l *customLogger) exportError(content string) {
	if l.errorFile == "" {
		return
	}
	l.writeContent([]byte(content))
}

// writeContent writes the error content to the error file.
func (l *customLogger) writeContent(content []byte) {
	if _, err := os.Stat(l.root); os.IsNotExist(err) {
		fileMode := os.FileMode(0755)
		if err := os.Mkdir(l.root, fileMode); err != nil {
			l.Logger.Error(err, "can't create the root directory", "root", l.root)
			return
		}
	}
	tmpFile, err := ioutil.TempFile(l.root, "tmp-err-")
	if err != nil {
		l.Logger.Error(err, "can't create temporary error-file", "directory", l.root, "prefix", "tmp-err-")
		return
	}
	defer func() {
		if err := tmpFile.Close(); err != nil {
			l.Logger.Error(err, "can't close temporary error-file", "filename", tmpFile.Name())
		}
	}()

	if _, err = tmpFile.Write(content); err != nil {
		l.Logger.Error(err, "can't write to temporary error-file", "filename", tmpFile.Name())
		return
	}

	errorFile := filepath.Join(l.root, l.errorFile)
	if err := os.Rename(tmpFile.Name(), errorFile); err != nil {
		l.Logger.Error(err, "can't rename to error-file", "temp-file", tmpFile.Name(), "error-file", errorFile)
		return
	}
	if err := os.Chmod(errorFile, 0644); err != nil {
		l.Logger.Error(err, "can't change permissions on the error-file", "error-file", errorFile)
	}
}

// deleteErrorFile deletes the error file.
func (l *customLogger) deleteErrorFile() {
	if l.errorFile == "" {
		return
	}
	errorFile := filepath.Join(l.root, l.errorFile)
	if err := os.Remove(errorFile); err != nil {
		if os.IsNotExist(err) {
			return
		}
		l.Logger.Error(err, "can't delete the error-file", "filename", errorFile)
	}
}

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

func setGlogFlags() {
	// Force logging to stderr.
	stderrFlag := stdflag.Lookup("logtostderr")
	if stderrFlag == nil {
		handleError(false, "ERROR: can't find glog flag 'logtostderr'")
	}
	stderrFlag.Value.Set("true")

	// Set verbosity from flag.
	vFlag := stdflag.Lookup("v")
	if vFlag == nil {
		fmt.Fprintf(os.Stderr, "ERROR: can't find glog flag 'v'\n")
		os.Exit(1)
	}
	vFlag.Value.Set(strconv.Itoa(*flVerbose))
}

// repoSync represents the remote repo and the local sync of it.
type repoSync struct {
	cmd         string         // the git command to run
	root        string         // absolute path to the root directory
	repo        string         // remote repo to sync
	branch      string         // remote branch to sync
	rev         string         // the rev or SHA to sync
	depth       int            // for shallow sync
	submodules  submodulesMode // how to handle submodules
	chmod       int            // mode to change repo to, or 0
	link        string         // the name of the symlink to publish under `root`
	authURL     string         // a URL to re-fetch credentials, or ""
	sparseFile  string         // path to a sparse-checkout file
	syncHookCmd string         // command to run after each sync
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
	// Parse and verify flags.  Errors here are fatal.
	//

	pflag.Parse()
	stdflag.CommandLine.Parse(nil) // Otherwise glog complains
	setGlogFlags()

	log = &customLogger{glogr.New(), *flRoot, *flErrorFile}

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
		handleError(true, "ERROR: --repo must be specified")
	}

	if *flDepth < 0 { // 0 means "no limit"
		handleError(true, "ERROR: --depth must be greater than or equal to 0")
	}

	switch submodulesMode(*flSubmodules) {
	case submodulesRecursive, submodulesShallow, submodulesOff:
	default:
		handleError(true, "ERROR: --submodules must be one of %q, %q, or %q", submodulesRecursive, submodulesShallow, submodulesOff)
	}

	if *flRoot == "" {
		handleError(true, "ERROR: --root must be specified")
	}

	if *flDest != "" {
		*flLink = *flDest
	}
	if *flLink == "" {
		parts := strings.Split(strings.Trim(*flRepo, "/"), "/")
		*flLink = parts[len(parts)-1]
	}
	if strings.Contains(*flLink, "/") {
		handleError(true, "ERROR: --link must not contain '/'")
	}
	if strings.HasPrefix(*flLink, ".") {
		handleError(true, "ERROR: --link must not start with '.'")
	}

	if *flWait != 0 {
		*flPeriod = time.Duration(int(*flWait*1000)) * time.Millisecond
	}
	if *flPeriod < 10*time.Millisecond {
		handleError(true, "ERROR: --period must be at least 10ms")
	}

	if *flTimeout != 0 {
		*flSyncTimeout = time.Duration(*flTimeout) * time.Second
	}
	if *flSyncTimeout < 10*time.Millisecond {
		handleError(true, "ERROR: --sync-timeout must be at least 10ms")
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

	if *flSSH {
		if *flUsername != "" {
			handleError(false, "ERROR: only one of --ssh and --username may be specified")
		}
		if *flPassword != "" {
			handleError(false, "ERROR: only one of --ssh and --password may be specified")
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

	// From here on, output goes through logging.
	log.V(0).Info("starting up",
		"pid", os.Getpid(),
		"uid", os.Getuid(),
		"gid", os.Getgid(),
		"home", os.Getenv("HOME"),
		"args", os.Args)

	if _, err := exec.LookPath(*flGitCmd); err != nil {
		log.Error(err, "ERROR: git executable not found", "git", *flGitCmd)
		os.Exit(1)
	}

	// Make sure the root exists.  0755 ensures that this is usable as a volume
	// when the consumer isn't running as the same UID.  We do this very early
	// so that we can normalize the path even when there are symlinks in play.
	if err := os.MkdirAll(*flRoot, 0755); err != nil {
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
		cmd:         *flGitCmd,
		root:        absRoot,
		repo:        *flRepo,
		branch:      *flBranch,
		rev:         *flRev,
		depth:       *flDepth,
		submodules:  submodulesMode(*flSubmodules),
		chmod:       *flChmod,
		link:        *flLink,
		authURL:     *flAskPassURL,
		sparseFile:  *flSparseCheckoutFile,
		syncHookCmd: *flSyncHookCommand,
	}

	// This context is used only for git credentials initialization. There are no long-running operations like
	// `git clone`, so hopefully 30 seconds will be enough.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)

	if *flUsername != "" && *flPassword != "" {
		if err := git.SetupAuth(ctx, *flUsername, *flPassword); err != nil {
			log.Error(err, "ERROR: can't set up git auth")
			os.Exit(1)
		}
	}

	if *flSSH {
		if err := setupGitSSH(*flSSHKnownHosts, *flSSHKeyFile, *flSSHKnownHostsFile); err != nil {
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

	// This needs to be after all other git-related config flags.
	if *flGitConfig != "" {
		if err := git.setupExtraGitConfigs(ctx, *flGitConfig); err != nil {
			log.Error(err, "ERROR: can't set additional git configs")
			os.Exit(1)
		}
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
		if initialSync {
			err := git.InitRepo(ctx)
			if err != nil {
				log.Error(err, "can't init root", absRoot)
				os.Exit(1)
			}
		}

		if changed, hash, err := git.SyncRepo(ctx); err != nil {
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
				log.deleteErrorFile()
				os.Exit(0)
			}
			if isHash, err := git.RevIsHash(ctx); err != nil {
				log.Error(err, "can't tell if rev is a git hash, exiting", "rev", git.rev)
				os.Exit(1)
			} else if isHash {
				log.V(0).Info("rev appears to be a git hash, no further sync needed", "rev", git.rev)
				log.deleteErrorFile()
				sleepForever()
			}
			initialSync = false
		}

		failCount = 0
		log.deleteErrorFile()
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

// initRepo looks at the git root and initializes it if needed.  This assumes
// the root dir already exists.
func (git *repoSync) InitRepo(ctx context.Context) error {
	// Check out the git root, and see if it is already usable.
	if _, err := os.Stat(git.root); err != nil {
		return err
	}

	// Make sure the directory we found is actually usable.
	if git.SanityCheck(ctx) {
		log.V(0).Info("root directory is valid", "path", git.root)
		return nil
	}

	// Maybe a previous run crashed?  Git won't use this dir.
	log.V(0).Info("root directory exists but failed checks, cleaning up", "path", git.root)

	// We remove the contents rather than the dir itself, because a common
	// use-case is to have a volume mounted at git.root, which makes removing
	// it impossible.
	if err := removeDirContents(git.root); err != nil {
		return fmt.Errorf("can't remove unusable git root: %w", err)
	}

	return nil
}

// sanityCheck tries to make sure that the dir is a valid git repository.
func (git *repoSync) SanityCheck(ctx context.Context) bool {
	log.V(0).Info("sanity-checking git repo", "repo", git.root)

	// If it is empty, we are done.
	if empty, err := dirIsEmpty(git.root); err != nil {
		log.Error(err, "can't list repo directory", "repo", git.root)
		return false
	} else if empty {
		log.V(0).Info("git repo is empty", "repo", git.root)
		return true
	}

	// Check that this is actually the root of the repo.
	if root, err := runCommand(ctx, git.root, git.cmd, "rev-parse", "--show-toplevel"); err != nil {
		log.Error(err, "can't get repo toplevel", "repo", git.root)
		return false
	} else {
		root = strings.TrimSpace(root)
		if root != git.root {
			log.V(0).Info("git repo is under another repo", "repo", git.root, "parent", root)
			return false
		}
	}

	// Consistency-check the repo.
	if _, err := runCommand(ctx, git.root, git.cmd, "fsck", "--no-progress", "--connectivity-only"); err != nil {
		log.Error(err, "repo sanity check failed", "repo", git.root)
		return false
	}

	return true
}

func dirIsEmpty(dir string) (bool, error) {
	dirents, err := ioutil.ReadDir(dir)
	if err != nil {
		return false, err
	}
	return len(dirents) == 0, nil
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

// handleError prints the error to the standard error, prints the usage if the `printUsage` flag is true,
// exports the error to the error file and exits the process with the exit code.
func handleError(printUsage bool, format string, a ...interface{}) {
	s := fmt.Sprintf(format, a...)
	fmt.Fprintln(os.Stderr, s)
	if printUsage {
		pflag.Usage()
	}
	log.exportError(s)
	os.Exit(1)
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
func (git *repoSync) UpdateSymlink(ctx context.Context, newDir string) (string, error) {
	// Get currently-linked repo directory (to be removed), unless it doesn't exist
	linkPath := filepath.Join(git.root, git.link)
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

	log.V(1).Info("renaming symlink", "root", git.root, "oldName", tmplink, "newName", git.link)
	if _, err := runCommand(ctx, git.root, "mv", "-T", tmplink, git.link); err != nil {
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
func (git *repoSync) AddWorktreeAndSwap(ctx context.Context, hash string) error {
	log.V(0).Info("syncing git", "rev", git.rev, "hash", hash)

	args := []string{"fetch", "-f", "--tags"}
	if git.depth != 0 {
		args = append(args, "--depth", strconv.Itoa(git.depth))
	}
	args = append(args, "origin", git.branch)

	// Update from the remote.
	if _, err := runCommand(ctx, git.root, git.cmd, args...); err != nil {
		return err
	}

	// GC clone
	if _, err := runCommand(ctx, git.root, git.cmd, "gc", "--prune=all"); err != nil {
		return err
	}

	// Make a worktree for this exact git hash.
	worktreePath := filepath.Join(git.root, hash)
	_, err := runCommand(ctx, git.root, git.cmd, "worktree", "add", worktreePath, "origin/"+git.branch, "--no-checkout")
	log.V(0).Info("adding worktree", "path", worktreePath, "branch", fmt.Sprintf("origin/%s", git.branch))
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

	// If sparse checkout is requested, configure git for it.
	if git.sparseFile != "" {
		// This is required due to the undocumented behavior outlined here:
		// https://public-inbox.org/git/CAPig+cSP0UiEBXSCi7Ua099eOdpMk8R=JtAjPuUavRF4z0R0Vg@mail.gmail.com/t/
		log.V(0).Info("configuring worktree sparse checkout")
		checkoutFile := git.sparseFile

		gitInfoPath := filepath.Join(git.root, fmt.Sprintf(".git/worktrees/%s/info", hash))
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
		_, err = runCommand(ctx, worktreePath, git.cmd, args...)
		if err != nil {
			return err
		}
	}

	// Reset the worktree's working copy to the specific rev.
	_, err = runCommand(ctx, worktreePath, git.cmd, "reset", "--hard", hash, "--")
	if err != nil {
		return err
	}
	log.V(0).Info("reset worktree to hash", "path", worktreePath, "hash", hash)

	// Update submodules
	// NOTE: this works for repo with or without submodules.
	if git.submodules != submodulesOff {
		log.V(0).Info("updating submodules")
		submodulesArgs := []string{"submodule", "update", "--init"}
		if git.submodules == submodulesRecursive {
			submodulesArgs = append(submodulesArgs, "--recursive")
		}
		if git.depth != 0 {
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

	// Reset the root's rev (so we can prune and so we can rely on it later).
	_, err = runCommand(ctx, git.root, git.cmd, "reset", "--hard", hash, "--")
	if err != nil {
		return err
	}
	log.V(0).Info("reset root to hash", "path", git.root, "hash", hash)

	// Flip the symlink.
	oldWorktree, err := git.UpdateSymlink(ctx, worktreePath)
	if err != nil {
		return err
	}
	setRepoReady()

	// From here on we have to save errors until the end.

	// Execute the hook command, if requested.
	var execErr error
	if git.syncHookCmd != "" {
		log.V(0).Info("executing command for git sync hooks", "command", git.syncHookCmd)
		// TODO: move this to be async like webhook?
		if _, err := runCommand(ctx, worktreePath, git.syncHookCmd); err != nil {
			// Save it until after cleanup runs.
			execErr = err
		}
	}

	// Clean up previous worktrees.
	var cleanupErr error
	if oldWorktree != "" {
		log.V(1).Info("removing old worktree", "path", oldWorktree)
		if err := os.RemoveAll(oldWorktree); err != nil {
			cleanupErr = fmt.Errorf("error removing directory: %v", err)
		} else if _, err := runCommand(ctx, git.root, git.cmd, "worktree", "prune"); err != nil {
			cleanupErr = err
		}
	}

	if cleanupErr != nil {
		return cleanupErr
	}
	if execErr != nil {
		return execErr
	}
	return nil
}

// CloneRepo does an initial clone of the git repo.
func (git *repoSync) CloneRepo(ctx context.Context) error {
	args := []string{"clone", "--no-checkout", "-b", git.branch}
	if git.depth != 0 {
		args = append(args, "--depth", strconv.Itoa(git.depth))
	}
	args = append(args, git.repo, git.root)
	log.V(0).Info("cloning repo", "origin", git.repo, "path", git.root)

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

	// If sparse checkout is requested, configure git for it.
	if git.sparseFile != "" {
		log.V(0).Info("configuring sparse checkout")
		checkoutFile := git.sparseFile

		// TODO: capture this as a function (mostly duplicated above)
		gitRepoPath := filepath.Join(git.root, ".git")
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
		_, err = runCommand(ctx, git.root, git.cmd, args...)
		if err != nil {
			return err
		}
	}

	return nil
}

// LocalHashForRev returns the locally known hash for a given rev.
func (git *repoSync) LocalHashForRev(ctx context.Context) (string, error) {
	output, err := runCommand(ctx, git.root, git.cmd, "rev-parse", git.rev)
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

func (git *repoSync) RevIsHash(ctx context.Context) (bool, error) {
	// If git doesn't identify rev as a commit, we're done.
	output, err := runCommand(ctx, git.root, git.cmd, "cat-file", "-t", git.rev)
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
	output, err = git.LocalHashForRev(ctx)
	if err != nil {
		return false, err
	}
	return strings.HasPrefix(output, git.rev), nil
}

// SyncRepo syncs the branch of a given repository to the link at the given rev.
// returns (1) whether a change occured, (2) the new hash, and (3) an error if one happened
func (git *repoSync) SyncRepo(ctx context.Context) (bool, string, error) {
	if git.authURL != "" {
		// For ASKPASS Callback URL, the credentials behind is dynamic, it needs to be
		// re-fetched each time.
		if err := git.CallAskPassURL(ctx); err != nil {
			askpassCount.WithLabelValues(metricKeyError).Inc()
			return false, "", fmt.Errorf("failed to call GIT_ASKPASS_URL: %v", err)
		}
		askpassCount.WithLabelValues(metricKeySuccess).Inc()
	}

	target := filepath.Join(git.root, git.link)
	gitRepoPath := filepath.Join(target, ".git")
	var hash string
	_, err := os.Stat(gitRepoPath)
	switch {
	case os.IsNotExist(err):
		// First time. Just clone it and get the hash.
		err = git.CloneRepo(ctx)
		if err != nil {
			return false, "", err
		}
		hash, err = git.LocalHashForRev(ctx)
		if err != nil {
			return false, "", err
		}
	case err != nil:
		return false, "", fmt.Errorf("error checking if repo exists %q: %v", gitRepoPath, err)
	default:
		// Not the first time. Figure out if the ref has changed.
		local, remote, err := git.GetRevs(ctx)
		if err != nil {
			return false, "", err
		}
		if local == remote {
			log.V(1).Info("no update required", "rev", git.rev, "local", local, "remote", remote)
			return false, "", nil
		}
		log.V(0).Info("update required", "rev", git.rev, "local", local, "remote", remote)
		hash = remote
	}

	return true, hash, git.AddWorktreeAndSwap(ctx, hash)
}

// GetRevs returns the local and upstream hashes for rev.
func (git *repoSync) GetRevs(ctx context.Context) (string, string, error) {
	// Ask git what the exact hash is for rev.
	local, err := git.LocalHashForRev(ctx)
	if err != nil {
		return "", "", err
	}

	// Build a ref string, depending on whether the user asked to track HEAD or a tag.
	ref := ""
	if git.rev == "HEAD" {
		ref = "refs/heads/" + git.branch
	} else {
		ref = "refs/tags/" + git.rev
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
	// Don't modify the passed-in args.
	argsCopy := make([]string, len(args))
	copy(argsCopy, args)
	for i := range args {
		if strings.ContainsAny(args[i], " \t\n") {
			argsCopy[i] = fmt.Sprintf("%q", args[i])
		}
	}
	return command + " " + strings.Join(argsCopy, " ")
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
// accessing the repo.
func (git *repoSync) SetupAuth(ctx context.Context, username, password string) error {
	log.V(1).Info("setting up git credential store")

	_, err := runCommand(ctx, "", git.cmd, "config", "--global", "credential.helper", "store")
	if err != nil {
		return fmt.Errorf("can't configure git credential helper: %w", err)
	}

	creds := fmt.Sprintf("url=%v\nusername=%v\npassword=%v\n", git.repo, username, password)
	_, err = runCommandWithStdin(ctx, "", creds, git.cmd, "credential", "approve")
	if err != nil {
		return fmt.Errorf("can't configure git credentials: %w", err)
	}

	return nil
}

func setupGitSSH(setupKnownHosts bool, pathToSSHSecret, pathToSSHKnownHosts string) error {
	log.V(1).Info("setting up git SSH credentials")

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

	if _, err = runCommand(ctx, "", git.cmd, "config", "--global", "http.cookiefile", pathToCookieFile); err != nil {
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
//   password=xxxyyyzzz
func (git *repoSync) CallAskPassURL(ctx context.Context) error {
	log.V(1).Info("calling GIT_ASKPASS URL to get credentials")

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

	if err := git.SetupAuth(ctx, username, password); err != nil {
		return err
	}

	return nil
}

func (git *repoSync) setupExtraGitConfigs(ctx context.Context, configsFlag string) error {
	log.V(1).Info("setting additional git configs")

	configs, err := parseGitConfigs(configsFlag)
	if err != nil {
		return fmt.Errorf("can't parse --git-config flag: %v", err)
	}
	for _, kv := range configs {
		if _, err := runCommand(ctx, "", git.cmd, "config", "--global", kv.key, kv.val); err != nil {
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

    --error-file, $GIT_SYNC_ERROR_FILE
            The name of a file (under --root) into which errors will be
            written. This must be a filename, not a path, and may not start
            with a period. (default: "", which means error reporting will be
            disabled)

    --git <string>, $GIT_SYNC_GIT
            The git command to run (subject to PATH search, mostly for testing).
            (default: git)

    --git-config <string>, $GIT_SYNC_GIT_CONFIG
            Additional git config options in 'key1:val1,key2:val2' format.  The
            key parts are passed to 'git config' and must be valid syntax for
            that command.  The val parts can be either quoted or unquoted
            values.  For all values the following escape sequences are
            supported: '\n' => [newline], '\t' => [tab], '\"' => '"', '\,' =>
            ',', '\\' => '\'.  Within unquoted values, commas MUST be escaped.
            Within quoted values, commas MAY be escaped, but are not required
            to be.  Any other escape sequence is an error. (default: "")

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

    --link <string>, $GIT_SYNC_LINK
            The name of the final symlink (under --root) which will point to the
            current git worktree. This must be a filename, not a path, and may
            not start with a period. The destination of this link (i.e.
            readlink()) is the currently checked out SHA. (default: the leaf
            dir of --repo)

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
            10ms.  This flag obsoletes --wait, but if --wait is specified, it
            will take precedence. (default: 10s)

    --repo <string>, $GIT_SYNC_REPO
            The git repository to sync.

    --rev <string>, $GIT_SYNC_REV
            The git revision (tag or hash) to check out. (default: HEAD)

    --root <string>, $GIT_SYNC_ROOT
            The root directory for git-sync operations, under which --link will
            be created. This flag is required.

    --sparse-checkout-file, $GIT_SYNC_SPARSE_CHECKOUT_FILE
            The path to a git sparse-checkout file (see git documentation for
            details) which controls which files and directories will be checked
            out.

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
