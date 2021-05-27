/*
Copyright 2019 The Kubernetes Authors All rights reserved.

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
	"time"
)

const (
	hash1 = "1111111111111111111111111111111111111111"
	hash2 = "2222222222222222222222222222222222222222"
)

func TestWebhookData(t *testing.T) {
	t.Run("webhook consumes first hash value", func(t *testing.T) {
		whd := NewWebhookData()

		whd.send(hash1)

		<-whd.events()

		hash := whd.get()
		if hash1 != hash {
			t.Fatalf("expected hash %s but got %s", hash1, hash)
		}
	})

	t.Run("last update wins when channel buffer is full", func(t *testing.T) {
		whd := NewWebhookData()

		for i := 0; i < 10; i++ {
			h := fmt.Sprintf("111111111111111111111111111111111111111%d", i)
			whd.send(h)
		}
		whd.send(hash2)

		<-whd.events()

		hash := whd.get()
		if hash2 != hash {
			t.Fatalf("expected hash %s but got %s", hash2, hash)
		}
	})

	t.Run("same hash value", func(t *testing.T) {
		whd := NewWebhookData()
		events := whd.events()

		whd.send(hash1)
		<-events

		hash := whd.get()
		if hash1 != hash {
			t.Fatalf("expected hash %s but got %s", hash1, hash)
		}

		whd.send(hash1)
		<-events

		hash = whd.get()
		if hash1 != hash {
			t.Fatalf("expected hash %s but got %s", hash1, hash)
		}
	})
}

func TestDo(t *testing.T) {
	t.Run("test invalid urls are handled", func(t *testing.T) {
		wh := Webhook{
			URL:     ":http://localhost:601426/hooks/webhook",
			Method:  "POST",
			Success: 200,
			Timeout: time.Second,
			Backoff: time.Second * 3,
			Data:    NewWebhookData(),
		}
		err := wh.Do("hash")
		if err == nil {
			t.Fatalf("expected error for invalid url but got none")
		}
	})
}
