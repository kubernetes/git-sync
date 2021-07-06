package main

import (
	"context"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type SubmodulesRemoteTracking struct {
	Cmd                      string        // the git command to run
	RootDir                  string        // absolute path
	Depth                    int           // for shallow sync
	Submodules               string        // how to handle submodules
	SubmodulesRemoteTracking string        // submodule's name list that enabled for remote-tracking sync
	Period                   time.Duration // how often to run submodules remote-tracking sync

	// Holds the state data as it crosses from producer to consumer.
	State *submodulesRemoteTrackingState
}

type submodulesRemoteTrackingState struct {
	ch                   chan struct{}
	mutex                sync.Mutex
	enabled              bool
	projectSHA           string
	submodulesNames      []string
	submodulesUpdateArgs []string
}

const (
	projectSubmodulesRecursive = "recursive"
)

func NewSubmodulesRemoteTrackingState() *submodulesRemoteTrackingState {
	return &submodulesRemoteTrackingState{
		ch:                   make(chan struct{}, 1),
		submodulesNames:      []string{},
		submodulesUpdateArgs: []string{},
	}
}

func (s *SubmodulesRemoteTracking) init() {
	state := s.State

	state.mutex.Lock()
	defer state.mutex.Unlock()

	splitFn := func(c rune) bool {
		return c == ','
	}

	state.submodulesNames = strings.FieldsFunc(s.SubmodulesRemoteTracking, splitFn)
	state.enabled = len(state.submodulesNames) > 0

	if s.Submodules == projectSubmodulesRecursive {
		state.submodulesUpdateArgs = append(state.submodulesUpdateArgs, "--recursive")
	}
	if s.Depth > 0 {
		state.submodulesUpdateArgs = append(state.submodulesUpdateArgs, "--depth", strconv.Itoa(s.Depth))
	}
}

func (s *SubmodulesRemoteTracking) sync(ctx context.Context, projectSHA string) error {
	worktreePath := s.projectWorktreePath(projectSHA)
	submodulePaths, err := s.getPaths(ctx, projectSHA)
	if err != nil {
		return err
	}

	for _, submodulePath := range submodulePaths {
		uptodate, err := s.isUpToDate(ctx, projectSHA, submodulePath)
		if err != nil {
			return err
		}

		submoduleName, err := s.nameFromPath(ctx, projectSHA, submodulePath)
		if err != nil {
			return err
		}

		if uptodate {
			log.V(1).Info("submodule is up to date", "submoduleName", submoduleName, "submodulePath", submodulePath)
			continue
		}

		log.V(0).Info("updating submodule with remote tracking", "submoduleName", submoduleName, "submodulePath", submodulePath)
		submoduleRemoteUpdateArgs := append([]string{"submodule", "update", "--remote"}, s.State.submodulesUpdateArgs...)
		submoduleRemoteUpdateArgs = append(submoduleRemoteUpdateArgs, submodulePath)

		if _, err = runCommand(ctx, worktreePath, s.Cmd, submoduleRemoteUpdateArgs...); err != nil {
			return err
		}

		updatedLocalHash, err := s.localHash(ctx, projectSHA, submodulePath)
		if err != nil {
			return err
		}

		log.V(0).Info("submodule with remote tracking is updated", "submoduleName", submoduleName, "submodulePath", submodulePath, "hash", updatedLocalHash)
	}

	return nil
}

func (s *SubmodulesRemoteTracking) getPaths(ctx context.Context, projectSHA string) ([]string, error) {
	worktreePath := s.projectWorktreePath(projectSHA)
	output, err := runCommand(ctx, worktreePath, s.Cmd, "submodule", "--quiet", "foreach", "pwd")
	if err != nil {
		return []string{}, err
	}

	splitFn := func(c rune) bool {
		return c == '\n'
	}

	trimWorktreePath := strings.ReplaceAll(output, worktreePath+"/", "")
	submodulePaths := strings.FieldsFunc(trimWorktreePath, splitFn)

	list := []string{}
	for _, submodulePath := range submodulePaths {
		for _, submoduleRemoteTrackingName := range s.State.submodulesNames {
			submoduleName, err := s.nameFromPath(ctx, projectSHA, submodulePath)
			if err != nil {
				return []string{}, err
			}

			if submoduleRemoteTrackingName == submoduleName {
				list = append(list, submodulePath)
			}
		}
	}

	return list, nil
}

func (s *SubmodulesRemoteTracking) nameFromPath(ctx context.Context, projectSHA, submodulePath string) (string, error) {
	worktreePath := s.projectWorktreePath(projectSHA)
	submoduleNameArgs := []string{"config", "--file", ".gitmodules", "--get-regexp", ".path$"}
	output, err := runCommand(ctx, worktreePath, s.Cmd, submoduleNameArgs...)
	if err != nil {
		return "", err
	}

	splitFn := func(c rune) bool {
		return c == '\n'
	}

	configPaths := strings.FieldsFunc(string(output), splitFn)
	for _, configPath := range configPaths {
		log.V(5).Info("looking up submodule name", "configPath", configPath, "submodulePath", submodulePath)
		parts := strings.Split(configPath, " ")
		if len(parts) == 2 && parts[1] == submodulePath {
			re := regexp.MustCompile(`submodule\.(?P<name>.*)\.path`)
			res := re.FindStringSubmatch(parts[0])

			for i, key := range re.SubexpNames() {
				if key == "name" {
					log.V(5).Info("found submodule", "submoduleName", res[i])
					return res[i], nil
				}
			}
		}
	}

	return "", nil
}

func (s *SubmodulesRemoteTracking) isUpToDate(ctx context.Context, projectSHA, submodulePath string) (bool, error) {
	localHash, err := s.localHash(ctx, projectSHA, submodulePath)
	if err != nil {
		return false, err
	}

	submoduleName, err := s.nameFromPath(ctx, projectSHA, submodulePath)
	if err != nil {
		return false, nil
	}

	branchRef, err := s.branchRef(ctx, projectSHA, submoduleName)
	if err != nil {
		return false, err
	}

	remoteHash, err := s.remoteHashForRef(ctx, projectSHA, submodulePath, branchRef)
	if err != nil {
		return false, err
	}

	log.V(5).Info("submodule", "submoduleName", submoduleName, "localHash", localHash, "remoteHash", remoteHash, "ref", branchRef)
	if localHash == remoteHash {
		return true, nil
	}

	return false, nil
}

func (s *SubmodulesRemoteTracking) localHash(ctx context.Context, projectSHA, submodulePath string) (string, error) {
	submoduleWorktreePath := s.worktreePath(projectSHA, submodulePath)
	output, err := runCommand(ctx, submoduleWorktreePath, s.Cmd, "rev-parse", "HEAD")
	if err != nil {
		return "", err
	}

	localHash := strings.Trim(string(output), "\n")
	return localHash, nil
}

func (s *SubmodulesRemoteTracking) remoteHashForRef(ctx context.Context, projectSHA, submodulePath, ref string) (string, error) {
	submoduleWorktreePath := s.worktreePath(projectSHA, submodulePath)
	output, err := runCommand(ctx, submoduleWorktreePath, s.Cmd, "ls-remote", "--quiet", "origin", ref)
	if err != nil {
		return "", err
	}

	parts := strings.Split(string(output), "\t")
	remoteHash := parts[0]

	return remoteHash, nil
}

func (s *SubmodulesRemoteTracking) branchRef(ctx context.Context, projectSHA, submoduleName string) (string, error) {
	worktreePath := s.projectWorktreePath(projectSHA)
	confGitModulesArgs := []string{"config", "--file", ".gitmodules", "--default", "", "--get"}
	confGitModulesArgs = append(confGitModulesArgs, "submodule."+submoduleName+".branch")
	output, err := runCommand(ctx, worktreePath, s.Cmd, confGitModulesArgs...)
	if err != nil {
		return "", err
	}

	branch := strings.Trim(string(output), "\n")
	if branch != "" {
		return "refs/heads/" + branch, nil
	}

	return "HEAD", nil
}

func (s *SubmodulesRemoteTracking) run() {
	s.init()

	state := s.State
	curSHA := ""

	for state.enabled {
		ctx, cancel := context.WithTimeout(context.Background(), initTimeout)

		select {
		case <-state.events():
			curSHA = state.getProjectSHA()
			log.V(5).Info("submodules remote-tracking sync, update", "projectSHA", curSHA)
		case <-time.After(s.Period):
			log.V(5).Info("submodules remote-tracking sync, polling for updates", "projectSHA", curSHA)
		}

		if curSHA != "" {
			s.sync(ctx, curSHA)
		}

		cancel()
	}

	log.V(1).Info("submodules remote-tracking sync is disabled, no submodules enabled")
}

func (s *SubmodulesRemoteTracking) worktreePath(sha, submodulePath string) string {
	return filepath.Join(s.projectWorktreePath(sha), submodulePath)
}

func (s *SubmodulesRemoteTracking) projectWorktreePath(sha string) string {
	return filepath.Join(s.RootDir, "rev-"+sha)
}

func (s *SubmodulesRemoteTracking) UpdateState(projectSHA string) {
	s.State.setProjectSHA(projectSHA)

	select {
	case s.State.ch <- struct{}{}:
	default:
	}
}

func (state *submodulesRemoteTrackingState) setProjectSHA(sha string) {
	state.mutex.Lock()
	defer state.mutex.Unlock()
	state.projectSHA = sha
}

func (state *submodulesRemoteTrackingState) getProjectSHA() string {
	state.mutex.Lock()
	defer state.mutex.Unlock()
	return state.projectSHA
}

func (state *submodulesRemoteTrackingState) events() chan struct{} {
	return state.ch
}
