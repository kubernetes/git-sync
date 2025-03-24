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

// Package cmd provides an API to run commands and log them in a consistent
// way.
package cmd

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/go-logr/logr"
)

// Runner is an API to run commands and log them in a consistent way.
type Runner struct {
	log logintf
}

// Just the logr methods we need in this package.
type logintf interface {
	Info(msg string, keysAndValues ...interface{})
	Error(err error, msg string, keysAndValues ...interface{})
	V(level int) logr.Logger
	WithCallDepth(depth int) logr.Logger
}

// NewRunner returns a new CommandRunner.
func NewRunner(log logintf) Runner {
	return Runner{log: log}
}

// Run runs the given command, returning the stdout, stderr, and any error.
func (r Runner) Run(ctx context.Context, cwd string, env []string, command string, args ...string) (string, string, error) {
	// call depth = 2 to erase the runWithStdin frame and this one
	return runWithStdin(ctx, r.log.WithCallDepth(2), cwd, env, "", command, args...)
}

// RunWithStdin runs the given command with standard input, returning the stdout,
// stderr, and any error.
func (r Runner) RunWithStdin(ctx context.Context, cwd string, env []string, stdin, command string, args ...string) (string, string, error) {
	// call depth = 2 to erase the runWithStdin frame and this one
	return runWithStdin(ctx, r.log.WithCallDepth(2), cwd, env, stdin, command, args...)
}

func runWithStdin(ctx context.Context, log logintf, cwd string, env []string, stdin, command string, args ...string) (string, string, error) {
	cmdStr := cmdForLog(command, args...)
	log.V(5).Info("running command", "cwd", cwd, "cmd", cmdStr)

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

	start := time.Now()
	err := cmd.Run()
	wallTime := time.Since(start)
	stdout := strings.TrimSpace(outbuf.String())
	stderr := strings.TrimSpace(errbuf.String())
	if ctx.Err() == context.DeadlineExceeded {
		return stdout, stderr, fmt.Errorf("Run(%s): %w: { stdout: %q, stderr: %q }", cmdStr, ctx.Err(), stdout, stderr)
	}
	if err != nil {
		return stdout, stderr, fmt.Errorf("Run(%s): %w: { stdout: %q, stderr: %q }", cmdStr, err, stdout, stderr)
	}
	log.V(6).Info("command result", "stdout", stdout, "stderr", stderr, "time", wallTime)

	return stdout, stderr, nil
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

func (r Runner) WithCallDepth(depth int) Runner {
	return Runner{
		log: r.log.WithCallDepth(depth),
	}
}
