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

package main // import "k8s.io/git-sync"

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"math/rand"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var flRepo = flag.String("repo", envString("GIT_SYNC_REPO", ""), "git repo url")
var flBranch = flag.String("branch", envString("GIT_SYNC_BRANCH", "master"), "git branch")
var flRev = flag.String("rev", envString("GIT_SYNC_REV", "HEAD"), "git rev")
var flDepth = flag.Int("depth", envInt("GIT_SYNC_DEPTH", 0),
	"shallow clone with a history truncated to the specified number of commits")

var flRoot = flag.String("root", envString("GIT_SYNC_ROOT", "/git"),
	"root directory for git operations")
var flDest = flag.String("dest", envString("GIT_SYNC_DEST", ""),
	"path at which to publish the checked-out files (a subdirectory under --root)")
var flWait = flag.Int("wait", envInt("GIT_SYNC_WAIT", 0),
	"number of seconds between syncs")
var flOneTime = flag.Bool("one-time", envBool("GIT_SYNC_ONE_TIME", false),
	"exit after the initial checkout")
var flMaxSyncFailures = flag.Int("max-sync-failures", envInt("GIT_SYNC_MAX_SYNC_FAILURES", 0),
	"number of consecutive failures allowed before aborting (the first pull must succeed)")
var flChmod = flag.Int("change-permissions", envInt("GIT_SYNC_PERMISSIONS", 0),
	"change the permissions of the checked-out files to this")

var flUsername = flag.String("username", envString("GIT_SYNC_USERNAME", ""), "username")
var flPassword = flag.String("password", envString("GIT_SYNC_PASSWORD", ""), "password")

var flSSH = flag.Bool("ssh", envBool("GIT_SYNC_SSH", false), "use SSH protocol")

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
			log.Printf("invalid value for %q: using default: %q", key, def)
			return def
		}
		return val
	}
	return def
}

const usage = "usage: GIT_SYNC_REPO= GIT_SYNC_DEST= [GIT_SYNC_BRANCH= GIT_SYNC_WAIT= GIT_SYNC_DEPTH= GIT_SYNC_USERNAME= GIT_SYNC_PASSWORD= GIT_SYNC_SSH= GIT_SYNC_ONE_TIME= GIT_SYNC_MAX_SYNC_FAILURES=] git-sync -repo GIT_REPO_URL -dest PATH [-branch -wait -username -password -ssh -depth -one-time -max-sync-failures]"

func main() {
	flag.Parse()
	if *flRepo == "" || *flDest == "" {
		flag.Usage()
		os.Exit(1)
	}
	if _, err := exec.LookPath("git"); err != nil {
		log.Printf("required git executable not found: %v", err)
		os.Exit(1)
	}

	if *flUsername != "" && *flPassword != "" {
		if err := setupGitAuth(*flUsername, *flPassword, *flRepo); err != nil {
			log.Printf("error creating .netrc file: %v", err)
			os.Exit(1)
		}
	}

	if *flSSH {
		if err := setupGitSSH(); err != nil {
			log.Printf("error configuring SSH: %v", err)
			os.Exit(1)
		}
	}

	initialSync := true
	failCount := 0
	for {
		if err := syncRepo(*flRepo, *flBranch, *flRev, *flDepth, *flRoot, *flDest); err != nil {
			if initialSync || failCount >= *flMaxSyncFailures {
				log.Printf("error syncing repo: %v", err)
				os.Exit(1)
			}

			failCount++
			log.Printf("unexpected error syncing repo: %v", err)
			log.Printf("waiting %d seconds before retryng", *flWait)
			time.Sleep(time.Duration(*flWait) * time.Second)
			continue
		}

		initialSync = false
		failCount = 0

		if *flOneTime {
			os.Exit(0)
		}

		log.Printf("waiting %d seconds", *flWait)
		time.Sleep(time.Duration(*flWait) * time.Second)
	}
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

	log.Printf("create symlink %v->%v", "tmp-link", newDirRelative)

	if _, err := runCommand(gitRoot, "mv", "-T", "tmp-link", link); err != nil {
		return fmt.Errorf("error replacing symlink: %v", err)
	}

	log.Printf("rename symlink %v to %v", "tmp-link", link)

	// Clean up previous worktree
	if len(currentDir) > 0 {
		if err = os.RemoveAll(currentDir); err != nil {
			return fmt.Errorf("error removing directory: %v", err)
		}

		log.Printf("remove %v", currentDir)

		output, err := runCommand(gitRoot, "git", "worktree", "prune")
		if err != nil {
			return err
		}

		log.Printf("worktree prune %v", output)
	}

	return nil
}

// addWorktreeAndSwap creates a new worktree and calls updateSymlink to swap the symlink to point to the new worktree
func addWorktreeAndSwap(gitRoot, dest, branch, rev string) error {
	// fetch branch
	_, err := runCommand(gitRoot, "git", "fetch", "origin", branch)
	if err != nil {
		return err
	}
	log.Printf("fetched origin/%s", branch)

	// add worktree in subdir
	rand.Seed(time.Now().UnixNano())
	worktreePath := path.Join(gitRoot, "rev-"+strconv.Itoa(rand.Int()))
	_, err = runCommand(gitRoot, "git", "worktree", "add", worktreePath, "origin/"+branch)
	if err != nil {
		return err
	}
	log.Printf("added worktree %s for origin/%s", worktreePath, branch)

	// .git file in worktree directory holds a reference to /git/.git/worktrees/<worktree-dir-name>
	// Replace it with a reference using relative paths, so that other containers can use a different volume mount name
	worktreePathRelative, err := filepath.Rel(gitRoot, worktreePath)
	if err != nil {
		return err
	}
	gitDirRef := []byte(path.Join("gitdir: ../.git/worktrees", worktreePathRelative) + "\n")
	if err = ioutil.WriteFile(path.Join(worktreePath, ".git"), gitDirRef, 0644); err != nil {
		return err
	}

	// reset working copy
	_, err = runCommand(worktreePath, "git", "reset", "--hard", rev)
	if err != nil {
		return err
	}
	log.Printf("reset worktree %s to %s", worktreePath, rev)

	if *flChmod != 0 {
		// set file permissions
		_, err = runCommand("", "chmod", "-R", strconv.Itoa(*flChmod), worktreePath)
		if err != nil {
			return err
		}
	}

	return updateSymlink(gitRoot, dest, worktreePath)
}

func cloneRepo(repo, branch, rev string, depth int, gitRoot string) error {
	args := []string{"clone", "--no-checkout", "-b", branch}
	if depth != 0 {
		args = append(args, "-depth", strconv.Itoa(depth))
	}
	args = append(args, repo, gitRoot)
	_, err := runCommand("", "git", args...)
	if err != nil {
		return err
	}
	log.Printf("cloned %s", repo)

	return nil
}

// syncRepo syncs the branch of a given repository to the destination at the given rev.
func syncRepo(repo, branch, rev string, depth int, gitRoot, dest string) error {
	target := path.Join(gitRoot, dest)
	gitRepoPath := path.Join(target, ".git")
	_, err := os.Stat(gitRepoPath)
	switch {
	case os.IsNotExist(err):
		err = cloneRepo(repo, branch, rev, depth, gitRoot)
		if err != nil {
			return err
		}
	case err != nil:
		return fmt.Errorf("error checking if repo exist %q: %v", gitRepoPath, err)
	default:
		needUpdate, err := gitRemoteChanged(target, branch)
		if err != nil {
			return err
		}
		if !needUpdate {
			log.Printf("no change")
			return nil
		}
	}

	return addWorktreeAndSwap(gitRoot, dest, branch, rev)
}

// gitRemoteChanged returns true if the remote HEAD is different from the local HEAD, false otherwise
func gitRemoteChanged(localDir, branch string) (bool, error) {
	_, err := runCommand(localDir, "git", "remote", "update")
	if err != nil {
		return false, err
	}
	localHead, err := runCommand(localDir, "git", "rev-parse", "HEAD")
	if err != nil {
		return false, err
	}
	remoteHead, err := runCommand(localDir, "git", "rev-parse", fmt.Sprintf("origin/%v", branch))
	if err != nil {
		return false, err
	}
	return (localHead != remoteHead), nil
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
	log.Printf("run(%q): %s", cwd, cmdForLog(command, args...))

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
	log.Println("setting up the git credential cache")
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

func setupGitSSH() error {
	log.Println("setting up git SSH credentials")

	if _, err := os.Stat("/etc/git-secret/ssh"); err != nil {
		return fmt.Errorf("error: could not find SSH key Secret: %v", err)
	}

	// Kubernetes mounts Secret as 0444 by default, which is not restrictive enough to use as an SSH key.
	// TODO: Remove this command once Kubernetes allows for specifying permissions for a Secret Volume.
	// See https://github.com/kubernetes/kubernetes/pull/28936.
	if err := os.Chmod("/etc/git-secret/ssh", 0400); err != nil {

		// If the Secret Volume is mounted as readOnly, the read-only filesystem nature prevents the necessary chmod.
		return fmt.Errorf("error running chmod on Secret (make sure Secret Volume is NOT mounted with readOnly=true): %v", err)
	}

	return nil
}
