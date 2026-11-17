/*
Copyright 2026 The Kubernetes Authors All rights reserved.

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
	"context"
	"strings"
	"testing"

	"github.com/go-logr/logr"
	"github.com/go-logr/logr/funcr"
)

func TestRunRedactedLogsLogArgs(t *testing.T) {
	var logged []string
	r := NewRunner(funcr.New(func(_, args string) {
		logged = append(logged, args)
	}, funcr.Options{Verbosity: 5}))
	_, _, err := r.RunRedacted(context.Background(), "", nil, "sh",
		[]string{"-c", "exit 1", "TOKEN"},
		[]string{"-c", "exit 1", "REDACTED"})
	if err == nil {
		t.Fatal("expected an error")
	}
	if len(logged) != 1 {
		t.Fatalf("expected one log line, got %d: %v", len(logged), logged)
	}
	if strings.Contains(logged[0], "TOKEN") {
		t.Errorf("log line leaks the executed args: %s", logged[0])
	}
	if !strings.Contains(logged[0], "REDACTED") {
		t.Errorf("log line should mention the log args: %s", logged[0])
	}
}

func TestRunRedactedExecutesArgs(t *testing.T) {
	r := NewRunner(logr.Discard())
	stdout, _, err := r.RunRedacted(context.Background(), "", nil, "sh",
		[]string{"-c", "printf actual"},
		[]string{"-c", "printf redacted"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if stdout != "actual" {
		t.Errorf("expected the executed args to be used, got stdout %q", stdout)
	}
}

func TestRunRedactedReportsLogArgs(t *testing.T) {
	r := NewRunner(logr.Discard())
	_, _, err := r.RunRedacted(context.Background(), "", nil, "sh",
		[]string{"-c", "exit 1", "TOKEN"},
		[]string{"-c", "exit 1", "REDACTED"})
	if err == nil {
		t.Fatal("expected an error")
	}
	if strings.Contains(err.Error(), "TOKEN") {
		t.Errorf("error leaks the executed args: %v", err)
	}
	if !strings.Contains(err.Error(), "REDACTED") {
		t.Errorf("error should mention the log args: %v", err)
	}
}
