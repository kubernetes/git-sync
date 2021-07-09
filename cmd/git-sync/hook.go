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
	"sync"
	"time"
)

type Hook interface {
	// Describes hook
	Name() string
	// Function that called by HookRunner
	Do(hash string) error
}

type hookData struct {
	ch    chan struct{}
	mutex sync.Mutex
	hash  string
}

func NewHookData() *hookData {
	return &hookData{
		ch: make(chan struct{}, 1),
	}
}

func (d *hookData) events() chan struct{} {
	return d.ch
}

func (d *hookData) get() string {
	d.mutex.Lock()
	defer d.mutex.Unlock()
	return d.hash
}

func (d *hookData) set(newHash string) {
	d.mutex.Lock()
	defer d.mutex.Unlock()
	d.hash = newHash
}

func (d *hookData) send(newHash string) {
	d.set(newHash)

	// Non-blocking write.  If the channel is full, the consumer will see the
	// newest value.  If the channel was not full, the consumer will get another
	// event.
	select {
	case d.ch <- struct{}{}:
	default:
	}
}

type HookRunner struct {
	// Hook to run and check
	Hook Hook
	// Backoff for failed hooks
	Backoff time.Duration
	// Holds the data as it crosses from producer to consumer.
	Data *hookData
}

func (r *HookRunner) Send(hash string) {
	r.Data.send(hash)
}

// Wait for trigger events from the channel, and run hook when triggered
func (r *HookRunner) run() {
	var lastHash string

	// Wait for trigger from hookData.Send
	for range r.Data.events() {
		// Retry in case of error
		for {
			// Always get the latest value, in case we fail-and-retry and the
			// value changed in the meantime.  This means that we might not send
			// every single hash.
			hash := r.Data.get()
			if hash == lastHash {
				break
			}

			if err := r.Hook.Do(hash); err != nil {
				log.Error(err, "hook failed")
				updateHookRunCountMetric(r.Hook.Name(), metricKeyError)
				time.Sleep(r.Backoff)
			} else {
				updateHookRunCountMetric(r.Hook.Name(), metricKeySuccess)
				lastHash = hash
				break
			}
		}
	}
}

func updateHookRunCountMetric(name, status string) {
	hookRunCount.WithLabelValues(name, status).Inc()
}
