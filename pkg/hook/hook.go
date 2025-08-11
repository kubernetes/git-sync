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

// Package hook provides a way to run hooks in a controlled way.
package hook

import (
	"context"
	"fmt"
	"runtime"
	"sync"
	"time"

	"github.com/go-logr/logr"
	"github.com/prometheus/client_golang/prometheus"
)

var (
	hookRunCount = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "git_sync_hook_run_count_total",
		Help: "How many hook runs completed, partitioned by name and state (success, error)",
	}, []string{"name", "status"})
)

func init() {
	prometheus.MustRegister(hookRunCount)
}

// Hook describes a single hook of some sort, which can be run by HookRunner.
type Hook interface {
	// Describes hook
	Name() string
	// Function that called by HookRunner
	Do(ctx context.Context, hash string) error
}

type hookData struct {
	ch    chan struct{}
	mutex sync.Mutex
	hash  string
}

// NewHookData returns a new HookData.
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

// NewHookRunner returns a new HookRunner.
func NewHookRunner(hook Hook, backoff time.Duration, data *hookData, log logintf, oneTime bool, async bool) *HookRunner {
	hr := &HookRunner{hook: hook, backoff: backoff, data: data, log: log, oneTime: oneTime, async: async}
	if oneTime || !async {
		hr.result = make(chan bool, 1)
	}
	return hr
}

// HookRunner struct.
type HookRunner struct {
	// Hook to run and check
	hook Hook
	// Backoff for failed hooks
	backoff time.Duration
	// Holds the data as it crosses from producer to consumer.
	data *hookData
	// Logger
	log logintf
	// Used to send a status result when running in one-time or non-async mode.
	// Should be initialised to a buffered channel of size 1.
	result chan bool
	// Bool for whether this is a one-time hook or not.
	oneTime bool
	// Bool for whether this is an async hook or not.
	async bool
}

// Just the logr methods we need in this package.
type logintf interface {
	Info(msg string, keysAndValues ...interface{})
	Error(err error, msg string, keysAndValues ...interface{})
	V(level int) logr.Logger
}

// Send sends hash to hookdata.
func (r *HookRunner) Send(hash string) error {
	r.data.send(hash)
	if !r.async {
		r.log.V(1).Info("waiting for completion", "hash", hash, "name", r.hook.Name())
		err := r.WaitForCompletion()
		r.log.V(1).Info("hook completed", "hash", hash, "err", err, "name", r.hook.Name())
		if err != nil {
			return err
		}
	}
	return nil
}

// Run waits for trigger events from the channel, and run hook when triggered.
func (r *HookRunner) Run(ctx context.Context) {
	var lastHash string

	// Wait for trigger from hookData.Send
	for range r.data.events() {
		// Retry in case of error
		for {
			// Always get the latest value, in case we fail-and-retry and the
			// value changed in the meantime.  This means that we might not send
			// every single hash.
			hash := r.data.get()
			if hash == lastHash {
				break
			}

			if err := r.hook.Do(ctx, hash); err != nil {
				r.log.Error(err, "hook failed", "hash", hash, "retry", r.backoff)
				updateHookRunCountMetric(r.hook.Name(), "error")
				// don't want to sleep unnecessarily terminating anyways
				r.sendResult(false)
				time.Sleep(r.backoff)
			} else {
				updateHookRunCountMetric(r.hook.Name(), "success")
				lastHash = hash
				r.sendResult(true)
				break
			}
		}
	}
}

func (r *HookRunner) sendResult(completedSuccessfully bool) {
	// if onetime is true, we send the result then exit
	if r.oneTime {
		r.result <- completedSuccessfully
		close(r.result)
		runtime.Goexit()
	} else if !r.async {
		// if onetime is false, and we've set non-async we send but don't exit.
		r.result <- completedSuccessfully
	}
	// if neither oneTime nor !async, we do nothing here.
}

// WaitForCompletion waits for HookRunner to send completion message to
// calling thread and returns either true if HookRunner executed successfully
// and some error otherwise.
// Assumes that either r.oneTime or !r.async, otherwise returns an error.
func (r *HookRunner) WaitForCompletion() error {
	// Make sure function should be called
	if r.result == nil {
		return fmt.Errorf("HookRunner.WaitForCompletion called on async runner")
	}

	// If oneTimeResult is not nil, we wait for its result.
	if r.result != nil {
		hookRunnerFinishedSuccessfully := <-r.result
		r.log.V(1).Info("hook completed", "success", hookRunnerFinishedSuccessfully,
			"oneTime", r.oneTime, "async", r.async, "name", r.hook.Name())
		if !hookRunnerFinishedSuccessfully {
			return fmt.Errorf("hook completed with error")
		}
	}

	return nil
}

func updateHookRunCountMetric(name, status string) {
	hookRunCount.WithLabelValues(name, status).Inc()
}
