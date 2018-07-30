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
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"os/exec"
	"os/signal"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/thockin/glogr"
	"github.com/thockin/logr"
)

var flRepo = flag.String("repo", envString("GIT_SYNC_REPO", ""),
	"the git repository to clone")
var flBranch = flag.String("branch", envString("GIT_SYNC_BRANCH", "master"),
	"the git branch to check out")
var flRev = flag.String("rev", envString("GIT_SYNC_REV", "HEAD"),
	"the git revision (tag or hash) to check out")
var flDepth = flag.Int("depth", envInt("GIT_SYNC_DEPTH", 0),
	"use a shallow clone with a history truncated to the specified number of commits")

var flRoot = flag.String("root", envString("GIT_SYNC_ROOT", "/git"),
	"the root directory for git operations")
var flDest = flag.String("dest", envString("GIT_SYNC_DEST", ""),
	"the name at which to publish the checked-out files under --root (defaults to leaf dir of --repo)")
var flWait = flag.Float64("wait", envFloat("GIT_SYNC_WAIT", 0),
	"the number of seconds between syncs")
var flOneTime = flag.Bool("one-time", envBool("GIT_SYNC_ONE_TIME", false),
	"exit after the initial checkout")
var flMaxSyncFailures = flag.Int("max-sync-failures", envInt("GIT_SYNC_MAX_SYNC_FAILURES", 0),
	"the number of consecutive failures allowed before aborting (the first pull must succeed)")
var flChmod = flag.Int("change-permissions", envInt("GIT_SYNC_PERMISSIONS", 0),
	"the file permissions to apply to the checked-out files")

var flUsername = flag.String("username", envString("GIT_SYNC_USERNAME", ""),
	"the username to use")
var flPassword = flag.String("password", envString("GIT_SYNC_PASSWORD", ""),
	"the password to use")

var flSSH = flag.Bool("ssh", envBool("GIT_SYNC_SSH", false),
	"use SSH for git operations")
var flSSHKnownHosts = flag.Bool("ssh-known-hosts", envBool("GIT_KNOWN_HOSTS", true),
	"enable SSH known_hosts verification")

var log = newLoggerOrDie()

func newLoggerOrDie() logr.Logger {
	g, err := glogr.New()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failind to initialize logging: %v\n", err)
		os.Exit(1)
	}
	return g
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
			log.Errorf("invalid value for %q: using default: %v", key, def)
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
			log.Errorf("invalid value for %q: using default: %v", key, def)
			return def
		}
		return val
	}
	return def
}

func main() {
	setFlagDefaults()

	flag.Parse()
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
	if _, err := exec.LookPath("git"); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: git executable not found: %v\n", err)
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

	// From here on, output goes through logging.
	log.V(0).Infof("starting up: %q", os.Args)

	initialSync := true
	failCount := 0
	for {
		if err := syncRepo(*flRepo, *flBranch, *flRev, *flDepth, *flRoot, *flDest); err != nil {
			if initialSync || failCount >= *flMaxSyncFailures {
				log.Errorf("error syncing repo: %v", err)
				os.Exit(1)
			}

			failCount++
			log.Errorf("unexpected error syncing repo: %v", err)
			log.V(0).Infof("waiting %v before retrying", waitTime(*flWait))
			time.Sleep(waitTime(*flWait))
			continue
		}
		if initialSync {
			if *flOneTime {
				os.Exit(0)
			}
			if isHash, err := revIsHash(*flRev, *flRoot); err != nil {
				log.Errorf("can't tell if rev %s is a git hash, exiting", *flRev)
				os.Exit(1)
			} else if isHash {
				log.V(0).Infof("rev %s appears to be a git hash, no further sync needed", *flRev)
				sleepForever()
			}
			initialSync = false
		}

		failCount = 0
		log.V(1).Infof("next sync in %v", waitTime(*flWait))
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
func updateSymlink(gitRoot, link, newDir string) error {
	// Get currently-linked repo directory (to be removed), unless it doesn't exist
	currentDir, err := filepath.EvalSymlinks(path.Join(gitRoot, link))
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("error accessing symlink: %v", err)
	}

	// newDir is /git/rev-..., we need to change it to relative path.
	// Volume in other container may not be mounted at /git, so the symlink can't point to /git.
	newDirRelative, err := filepath.Rel(gitRoot, newDir)
	if err != nil {
		return fmt.Errorf("error converting to relative path: %v", err)
	}

	if _, err := runCommand(gitRoot, "ln", "-snf", newDirRelative, "tmp-link"); err != nil {
		return fmt.Errorf("error creating symlink: %v", err)
	}
	log.V(1).Infof("created symlink %s -> %s", "tmp-link", newDirRelative)

	if _, err := runCommand(gitRoot, "mv", "-T", "tmp-link", link); err != nil {
		return fmt.Errorf("error replacing symlink: %v", err)
	}
	log.V(1).Infof("renamed symlink %s to %s", "tmp-link", link)

	// Clean up previous worktree
	if len(currentDir) > 0 {
		if err = os.RemoveAll(currentDir); err != nil {
			return fmt.Errorf("error removing directory: %v", err)
		}

		log.V(1).Infof("removed %s", currentDir)

		_, err := runCommand(gitRoot, "git", "worktree", "prune")
		if err != nil {
			return err
		}

		log.V(1).Infof("pruned old worktrees")
	}

	return nil
}

// addWorktreeAndSwap creates a new worktree and calls updateSymlink to swap the symlink to point to the new worktree
func addWorktreeAndSwap(gitRoot, dest, branch, rev, hash string) error {
	log.V(0).Infof("syncing to %s (%s)", rev, hash)

	// Make a worktree for this exact git hash.
	worktreePath := path.Join(gitRoot, "rev-"+hash)
	if *flOneTime {
		_, err := runCommand(gitRoot, "git", "worktree", "add", worktreePath, hash)
		if err != nil {
			return err
		}
		log.V(0).Infof("added worktree %s for origin/%s", worktreePath, branch)
	} else {
		// Update from the remote.
		if _, err := runCommand(gitRoot, "git", "fetch", "--tags", "origin", branch); err != nil {
			return err
		}

		_, err := runCommand(gitRoot, "git", "worktree", "add", worktreePath, "origin/"+branch)
		if err != nil {
			return err
		}
		log.V(0).Infof("added worktree %s for origin/%s", worktreePath, branch)

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
		_, err = runCommand(worktreePath, "git", "reset", "--hard", hash)
		if err != nil {
			return err
		}
		log.V(0).Infof("reset worktree %s to %s", worktreePath, hash)
	}

	if *flChmod != 0 {
		// set file permissions
		_, err := runCommand("", "chmod", "-R", strconv.Itoa(*flChmod), worktreePath)
		if err != nil {
			return err
		}
	}

	return updateSymlink(gitRoot, dest, worktreePath)
}

func cloneRepo(repo, branch, rev string, depth int, gitRoot string) error {
	args := []string{"clone", "--no-checkout", "-b", branch}
	if depth != 0 {
		args = append(args, "--depth", strconv.Itoa(depth))
	}
	args = append(args, repo, gitRoot)
	_, err := runCommand("", "git", args...)
	if err != nil {
		return err
	}
	log.V(0).Infof("cloned %s", repo)

	return nil
}

func hashForRev(rev, gitRoot string) (string, error) {
	output, err := runCommand(gitRoot, "git", "rev-list", "-n1", rev)
	if err != nil {
		return "", err
	}
	return strings.Trim(string(output), "\n"), nil
}

func revIsHash(rev, gitRoot string) (bool, error) {
	// If a rev is a tag name or HEAD, rev-list will produce the git hash.  If
	// it is already a git hash, the output will be the same hash.  Of course, a
	// user could specify "abc" and match "abcdef12345678", so we just do a
	// prefix match.
	output, err := hashForRev(rev, gitRoot)
	if err != nil {
		return false, err
	}
	return strings.HasPrefix(output, rev), nil
}

// syncRepo syncs the branch of a given repository to the destination at the given rev.
func syncRepo(repo, branch, rev string, depth int, gitRoot, dest string) error {
	target := path.Join(gitRoot, dest)
	gitRepoPath := path.Join(target, ".git")
	hash := rev
	_, err := os.Stat(gitRepoPath)
	switch {
	case os.IsNotExist(err):
		err = cloneRepo(repo, branch, rev, depth, gitRoot)
		if err != nil {
			return err
		}
		hash, err = hashForRev(rev, gitRoot)
		if err != nil {
			return err
		}
	case err != nil:
		return fmt.Errorf("error checking if repo exists %q: %v", gitRepoPath, err)
	default:
		local, remote, err := getRevs(target, branch, rev)
		if err != nil {
			return err
		}
		log.V(2).Infof("local hash:  %s", local)
		log.V(2).Infof("remote hash: %s", remote)
		if local != remote {
			log.V(0).Infof("update required")
			hash = remote
		} else {
			log.V(1).Infof("no update required")
			return nil
		}
	}

	return addWorktreeAndSwap(gitRoot, dest, branch, rev, hash)
}

// getRevs returns the local and upstream hashes for rev.
func getRevs(localDir, branch, rev string) (string, string, error) {
	// Ask git what the exact hash is for rev.
	local, err := hashForRev(rev, localDir)
	if err != nil {
		return "", "", err
	}

	// Build a ref string, depending on whether the user asked to track HEAD or a tag.
	ref := ""
	if rev == "HEAD" {
		ref = "refs/heads/" + branch
	} else {
		ref = "refs/tags/" + rev + "^{}"
	}

	// Figure out what hash the remote resolves ref to.
	remote, err := remoteHashForRef(ref, localDir)
	if err != nil {
		return "", "", err
	}

	return local, remote, nil
}

func remoteHashForRef(ref, gitRoot string) (string, error) {
	output, err := runCommand(gitRoot, "git", "ls-remote", "-q", "origin", ref)
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

func runCommand(cwd, command string, args ...string) (string, error) {
	log.V(5).Infof("run(%q): %s", cwd, cmdForLog(command, args...))

	cmd := exec.Command(command, args...)
	if cwd != "" {
		cmd.Dir = cwd
	}
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("error running command: %v: %q", err, string(output))
	}

	return string(output), nil
}

func setupGitAuth(username, password, gitURL string) error {
	log.V(1).Infof("setting up the git credential cache")
	cmd := exec.Command("git", "config", "--global", "credential.helper", "cache")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("error setting up git credentials %v: %s", err, string(output))
	}

	cmd = exec.Command("git", "credential", "approve")
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
	log.V(1).Infof("setting up git SSH credentials")

	var pathToSSHSecret = "/etc/git-secret/ssh"
	var pathToSSHKnownHosts = "/etc/git-secret/known_hosts"

	fileInfo, err := os.Stat(pathToSSHSecret)
	if err != nil {
		return fmt.Errorf("error: could not find SSH key Secret: %v", err)
	}

	if fileInfo.Mode() != 0400 {
		return fmt.Errorf("Permissions %s for SSH key are too open. It is recommended to mount secret volume with `defaultMode: 256` (decimal number for octal 0400).", fileInfo.Mode())
	}

	if setupKnownHosts {
		_, err := os.Stat(pathToSSHKnownHosts)
		if err != nil {
			return fmt.Errorf("error: could not find SSH known_hosts file: %v", err)
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
