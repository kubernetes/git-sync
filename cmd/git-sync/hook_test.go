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
	"fmt"
	"testing"
)

const (
	hash1 = "1111111111111111111111111111111111111111"
	hash2 = "2222222222222222222222222222222222222222"
)

func TestHookData(t *testing.T) {
	t.Run("hook consumes first hash value", func(t *testing.T) {
		hd := NewHookData()

		hd.send(hash1)

		<-hd.events()

		hash := hd.get()
		if hash1 != hash {
			t.Fatalf("expected hash %s but got %s", hash1, hash)
		}
	})

	t.Run("last update wins when channel buffer is full", func(t *testing.T) {
		hd := NewHookData()

		for i := 0; i < 10; i++ {
			h := fmt.Sprintf("111111111111111111111111111111111111111%d", i)
			hd.send(h)
		}
		hd.send(hash2)

		<-hd.events()

		hash := hd.get()
		if hash2 != hash {
			t.Fatalf("expected hash %s but got %s", hash2, hash)
		}
	})

	t.Run("same hash value", func(t *testing.T) {
		hd := NewHookData()
		events := hd.events()

		hd.send(hash1)
		<-events

		hash := hd.get()
		if hash1 != hash {
			t.Fatalf("expected hash %s but got %s", hash1, hash)
		}

		hd.send(hash1)
		<-events

		hash = hd.get()
		if hash1 != hash {
			t.Fatalf("expected hash %s but got %s", hash1, hash)
		}
	})
}
