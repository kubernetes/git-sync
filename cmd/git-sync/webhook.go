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
	// Backoff for failed webhook calls
	Backoff time.Duration
}

type webhookRepoInfo struct {
	Hash   string
	Branch string
}

func (w *Webhook) Do(info webhookRepoInfo) error {
	req, err := http.NewRequest(w.Method, w.URL, nil)
	req.Header.Set("Git-Sync-Branch", info.Branch)
	req.Header.Set("Git-Sync-Hash", info.Hash)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), w.Timeout)
	defer cancel()
	req = req.WithContext(ctx)

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

// Wait for trigger events from the channel, and send webhooks when triggered
func (w *Webhook) run(ch chan webhookRepoInfo) {
	for {
		// Wait for trigger
		info := <-ch

		for {
			if err := w.Do(info); err != nil {
				log.Error(err, "error calling webhook", "url", w.URL)
				time.Sleep(w.Backoff)
			} else {
				log.V(0).Info("success calling webhook", "url", w.URL)
				break
			}
		}
	}
}
