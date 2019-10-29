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

	// Holds the data as it crosses from producer to consumer.
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

func (d *webhookData) events() chan struct{} {
	return d.ch
}

func (d *webhookData) get() string {
	d.mutex.Lock()
	defer d.mutex.Unlock()
	return d.hash
}

func (d *webhookData) set(newHash string) {
	d.mutex.Lock()
	defer d.mutex.Unlock()
	d.hash = newHash
}

func (d *webhookData) send(newHash string) {
	d.set(newHash)

	// Non-blocking write.  If the channel is full, the consumer will see the
	// newest value.  If the channel was not full, the consumer will get another
	// event.
	select {
	case d.ch <- struct{}{}:
	default:
	}
}

func (w *Webhook) Send(hash string) {
	w.Data.send(hash)
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

// Wait for trigger events from the channel, and send webhooks when triggered
func (w *Webhook) run() {
	var lastHash string

	// Wait for trigger from webhookData.Send
	for range w.Data.events() {
		// Retry in case of error
		for {
			// Always get the latest value, in case we fail-and-retry and the
			// value changed in the meantime.  This means that we might not send
			// every single hash.
			hash := w.Data.get()
			if hash == lastHash {
				break
			}

			if err := w.Do(hash); err != nil {
				log.Error(err, "webhook failed", "url", w.URL, "method", w.Method, "timeout", w.Timeout)
				time.Sleep(w.Backoff)
			} else {
				lastHash = hash
				break
			}
		}
	}
}
