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

package cmd

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"

	"k8s.io/git-sync/pkg/logging"
)

// Runner structure
type Runner struct {
	// Logger
	logger *logging.Logger
}

// NewRunner returns a new CommandRunner
func NewRunner(logger *logging.Logger) *Runner {
	return &Runner{logger: logger}
}

// Run runs given command
func (c *Runner) Run(ctx context.Context, cwd string, env []string, command string, args ...string) (string, error) {
	return c.RunWithStdin(ctx, cwd, env, "", command, args...)
}

// RunWithStdin runs given command with stardart input
func (c *Runner) RunWithStdin(ctx context.Context, cwd string, env []string, stdin, command string, args ...string) (string, error) {
	cmdStr := cmdForLog(command, args...)
	c.logger.V(5).Info("running command", "cwd", cwd, "cmd", cmdStr)

	cmd := exec.CommandContext(ctx, command, args...)
	if cwd != "" {
		cmd.Dir = cwd
	}
	if len(env) != 0 {
		cmd.Env = env
	}
	outbuf := bytes.NewBuffer(nil)
	errbuf := bytes.NewBuffer(nil)
	cmd.Stdout = outbuf
	cmd.Stderr = errbuf
	cmd.Stdin = bytes.NewBufferString(stdin)

	err := cmd.Run()
	stdout := strings.TrimSpace(outbuf.String())
	stderr := strings.TrimSpace(errbuf.String())
	if ctx.Err() == context.DeadlineExceeded {
		return "", fmt.Errorf("Run(%s): %w: { stdout: %q, stderr: %q }", cmdStr, ctx.Err(), stdout, stderr)
	}
	if err != nil {
		return "", fmt.Errorf("Run(%s): %w: { stdout: %q, stderr: %q }", cmdStr, err, stdout, stderr)
	}
	c.logger.V(6).Info("command result", "stdout", stdout, "stderr", stderr)

	return stdout, nil
}

func cmdForLog(command string, args ...string) string {
	if strings.ContainsAny(command, " \t\n") {
		command = fmt.Sprintf("%q", command)
	}
	argsCopy := make([]string, len(args))
	copy(argsCopy, args)
	for i := range args {
		if strings.ContainsAny(args[i], " \t\n") {
			argsCopy[i] = fmt.Sprintf("%q", args[i])
		}
	}
	return command + " " + strings.Join(argsCopy, " ")
}
