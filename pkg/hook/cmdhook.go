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
	"path/filepath"
	"time"

	"k8s.io/git-sync/pkg/cmd"
	"k8s.io/git-sync/pkg/logging"
)

// Cmdhook structure, implements Hook
type Cmdhook struct {
	// Runner
	cmdrunner *cmd.CommandRunner
	// Command to run
	command string
	// Command args
	args []string
	// Git root path
	gitRoot string
	// Timeout for the command
	timeout time.Duration
	// Logger
	logger *logging.Logger
}

// NewLogger returns a new Cmdhook
func NewCmdhook(cmdrunner *cmd.CommandRunner, command, gitroot string, args []string, timeout time.Duration, l *logging.Logger) *Cmdhook {
	return &Cmdhook{
		cmdrunner: cmdrunner,
		command:   command,
		gitRoot:   gitroot,
		args:      args,
		timeout:   timeout,
		logger:    l,
	}
}

// Name describes hook, implements Hook.Name
func (w *Cmdhook) Name() string {
	return "cmdhook"
}

// Do runs cmdhook.command, implements Hook.Do
func (c *Cmdhook) Do(ctx context.Context, hash string) error {
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	worktreePath := filepath.Join(c.gitRoot, hash)

	c.logger.V(0).Info("running cmdhook", "command", c.command, "timeout", c.timeout)
	_, err := c.cmdrunner.Run(ctx, worktreePath, c.command, c.args...)
	return err
}
