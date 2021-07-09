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
	"context"
	"fmt"
	"net/http"
	"time"
)

// WebHook structure
type Webhook struct {
	// URL for the http/s request
	URL string
	// Method for the http/s request
	Method string
	// Code to look for when determining if the request was successful.
	//   If this is not specified, request is sent and forgotten about.
	Success int
	// Timeout for the http/s request
	Timeout time.Duration
}

func (w *Webhook) Name() string {
	return "webhook"
}

func (w *Webhook) Do(hash string) error {
	req, err := http.NewRequest(w.Method, w.URL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Gitsync-Hash", hash)

	ctx, cancel := context.WithTimeout(context.Background(), w.Timeout)
	defer cancel()
	req = req.WithContext(ctx)

	log.V(0).Info("sending webhook", "hash", hash, "url", w.URL, "method", w.Method, "timeout", w.Timeout)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()

	// If the webhook has a success statusCode, check against it
	if w.Success != -1 && resp.StatusCode != w.Success {
		return fmt.Errorf("received response code %d expected %d", resp.StatusCode, w.Success)
	}

	return nil
}
