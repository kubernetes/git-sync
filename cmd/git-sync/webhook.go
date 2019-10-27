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

	Data *webhookData
}

type webhookData struct {
	ch chan struct{}

	newHash string
	curHash string
}

func NewWebhookData() *webhookData {
	return &webhookData{
		ch: make(chan struct{}, 1),
	}
}

func (d *webhookData) UpdateAndTrigger(newHash string) {
	d.newHash = newHash

	select {
	case d.ch <- struct{}{}:
	default:
	}
}

func (d *webhookData) updateState() bool {
	newHash := d.newHash
	if newHash != d.curHash {
		d.curHash = newHash
		return true
	}
	return false
}

func (d *webhookData) Hash() string {
	d.updateState()
	return d.curHash
}

func (d *webhookData) Wait() bool {
	// wait for message from UpdateAndTrigger
	<-d.ch

	changed := d.updateState()

	return changed
}

func (d *webhookData) WaitForChange() {
	for {
		changed := d.Wait()

		if changed {
			return
		}
	}
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
	for {
		// Wait for trigger and changed hash value
		w.Data.WaitForChange()

		for {
			hash := w.Data.Hash()
			if err := w.Do(hash); err != nil {
				log.Error(err, "error calling webhook", "url", w.URL)
				time.Sleep(w.Backoff)
			} else {
				log.V(0).Info("success calling webhook", "url", w.URL)
				break
			}
		}
	}
}
