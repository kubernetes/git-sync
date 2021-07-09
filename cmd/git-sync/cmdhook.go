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

package main

import (
	"context"
	"path/filepath"
	"time"
)

// Cmdhook structure
type Cmdhook struct {
	// Command to run
	Command string
	// Git root path
	GitRoot string
	// Timeout for the command
	Timeout time.Duration
}

func (w *Cmdhook) Name() string {
	return "cmdhook"
}

func (c *Cmdhook) Do(hash string) error {
	ctx, cancel := context.WithTimeout(context.Background(), c.Timeout)
	defer cancel()

	worktreePath := filepath.Join(c.GitRoot, hash)

	_, err := runCommand(ctx, worktreePath, c.Command)
	return err
}
