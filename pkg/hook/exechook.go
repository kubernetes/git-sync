/*
Copyright 2021 The Kubernetes Authors All rights reserved.

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

package hook

import (
	"context"
	"fmt"
	"os"
	"time"

	"k8s.io/git-sync/pkg/cmd"
)

// Exechook structure, implements Hook
type Exechook struct {
	// Runner
	cmdrunner cmd.Runner
	// Command to run
	command string
	// Command args
	args []string
	// How to get a worktree path
	getWorktree func(hash string) string
	// Timeout for the command
	timeout time.Duration
	// Logger
	log logintf
}

// NewExechook returns a new Exechook
func NewExechook(cmdrunner cmd.Runner, command string, getWorktree func(string) string, args []string, timeout time.Duration, log logintf) *Exechook {
	return &Exechook{
		cmdrunner:   cmdrunner,
		command:     command,
		getWorktree: getWorktree,
		args:        args,
		timeout:     timeout,
		log:         log,
	}
}

// Name describes hook, implements Hook.Name
func (h *Exechook) Name() string {
	return "exechook"
}

// Do runs exechook.command, implements Hook.Do
func (h *Exechook) Do(ctx context.Context, hash string) error {
	ctx, cancel := context.WithTimeout(ctx, h.timeout)
	defer cancel()

	worktreePath := h.getWorktree(hash)

	env := os.Environ()
	env = append(env, envKV("GITSYNC_HASH", hash))

	h.log.V(0).Info("running exechook", "hash", hash, "command", h.command, "timeout", h.timeout)
	stdout, stderr, err := h.cmdrunner.Run(ctx, worktreePath, env, h.command, h.args...)
	if err == nil {
		h.log.V(1).Info("exechook succeeded", "hash", hash, "stdout", stdout, "stderr", stderr)
	}
	return err
}

func envKV(k, v string) string {
	return fmt.Sprintf("%s=%s", k, v)
}
