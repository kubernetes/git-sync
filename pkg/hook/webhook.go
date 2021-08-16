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

package hook

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"k8s.io/git-sync/pkg/logging"
)

// WebHook structure, implements Hook
type Webhook struct {
	// Url for the http/s request
	url string
	// Method for the http/s request
	method string
	// Code to look for when determining if the request was successful.
	// If this is not specified, request is sent and forgotten about.
	success int
	// Timeout for the http/s request
	timeout time.Duration
	// Logger
	logger *logging.Logger
}

// NewWebhook returns a new WebHook
func NewWebhook(url, method string, success int, timeout time.Duration, l *logging.Logger) *Webhook {
	return &Webhook{
		url:     url,
		method:  method,
		success: success,
		timeout: timeout,
		logger:  l,
	}
}

// Name describes hook, implements Hook.Name
func (w *Webhook) Name() string {
	return "webhook"
}

// Do calls webhook.url, implements Hook.Do
func (w *Webhook) Do(ctx context.Context, hash string) error {
	req, err := http.NewRequest(w.method, w.url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Gitsync-Hash", hash)

	ctx, cancel := context.WithTimeout(ctx, w.timeout)
	defer cancel()
	req = req.WithContext(ctx)

	w.logger.V(0).Info("sending webhook", "hash", hash, "url", w.url, "method", w.method, "timeout", w.timeout)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()

	// If the webhook has a success statusCode, check against it
	if w.success != -1 && resp.StatusCode != w.success {
		return fmt.Errorf("received response code %d expected %d", resp.StatusCode, w.success)
	}

	return nil
}
