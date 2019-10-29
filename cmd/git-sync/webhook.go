package main

import (
	"context"
	"fmt"
	"net/http"
	"sync"
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

	Data *webhookData
}

type webhookData struct {
	ch    chan struct{}
	mutex sync.Mutex
	hash  string
}

func NewWebhookData() *webhookData {
	return &webhookData{
		ch: make(chan struct{}, 1),
	}
}

func (d *webhookData) Events() chan struct{} {
	return d.ch
}

func (d *webhookData) update(newHash string) {
	d.mutex.Lock()
	defer d.mutex.Unlock()
	d.hash = newHash
}

func (d *webhookData) UpdateAndTrigger(newHash string) {
	d.update(newHash)

	select {
	case d.ch <- struct{}{}:
	default:
	}
}

func (d *webhookData) Hash() string {
	d.mutex.Lock()
	defer d.mutex.Unlock()
	return d.hash
}

func (w *Webhook) Do(hash string) error {
	req, err := http.NewRequest(w.Method, w.URL, nil)
	req.Header.Set("Gitsync-Hash", hash)
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
func (w *Webhook) run() {
	var lastHash string

	// Wait for trigger from webhookData.UpdateAndTrigger
	for range w.Data.Events() {

		for {
			hash := w.Data.Hash()
			if hash == lastHash {
				break
			}

			if err := w.Do(hash); err != nil {
				log.Error(err, "error calling webhook", "url", w.URL)
				time.Sleep(w.Backoff)
			} else {
				log.V(0).Info("success calling webhook", "url", w.URL)
				lastHash = hash
				break
			}
		}
	}
}
