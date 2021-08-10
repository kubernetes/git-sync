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
	"testing"
	"time"

	"k8s.io/git-sync/pkg/cmd"
	"k8s.io/git-sync/pkg/logging"
)

func TestNotZeroReturnCmdhookDo(t *testing.T) {
	t.Run("test not zero return code", func(t *testing.T) {
		l := logging.NewLogger("", "")
		ch := NewCmdhook(
			cmd.NewCommandRunner(l),
			"false",
			"/tmp",
			[]string{},
			time.Second,
			l,
		)
		err := ch.Do(context.Background(), "")
		if err == nil {
			t.Fatalf("expected error but got none")
		}
	})
}

func TestZeroReturnCmdhookDo(t *testing.T) {
	t.Run("test zero return code", func(t *testing.T) {
		l := logging.NewLogger("", "")
		ch := NewCmdhook(
			cmd.NewCommandRunner(l),
			"true",
			"/tmp",
			[]string{},
			time.Second,
			l,
		)
		err := ch.Do(context.Background(), "")
		if err != nil {
			t.Fatalf("expected nil but got err")
		}
	})
}

func TestTimeoutCmdhookDo(t *testing.T) {
	t.Run("test timeout", func(t *testing.T) {
		l := logging.NewLogger("", "")
		ch := NewCmdhook(
			cmd.NewCommandRunner(l),
			"/bin/sh",
			"/tmp",
			[]string{"-c", "sleep 2"},
			time.Second,
			l,
		)
		err := ch.Do(context.Background(), "")
		if err == nil {
			t.Fatalf("expected err but got nil")
		}
	})
}
