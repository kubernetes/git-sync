package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// Trigger channel for webhook requests. If anything is received into this channel
//   it triggers the webhook goroutine to send new requests.
var WebhookCallTriggerChannel = make(chan struct{})

// Webhook collection
var WebhookArray = []Webhook{}

// WebHook structure
type Webhook struct {
	// URL for the http/s request
	URL string `json:"url"`
	// Method for the http/s request
	Method string `json:"method"`
	// Code to look for when determining if the request was successful.
	//   If this is not specified, request is sent and forgotten about.
	Success *int `json:"success"`
	// Timeout for the http/s request
	Timeout time.Duration `json:"timeout"`
}

func (w *Webhook) UnmarshalJSON(data []byte) error {
	type testAlias Webhook
	test := &testAlias{
		Timeout: time.Second * 5,
	}

	_ = json.Unmarshal(data, test)

	*w = Webhook(*test)
	return nil
}

func (w *Webhook) Do() error {
	req, err := http.NewRequest(w.Method, w.URL, nil)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), w.Timeout)
	defer cancel()
	req = req.WithContext(ctx)

	//
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()

	// If the webhook has a success statusCode, check against it
	if w.Success != nil && resp.StatusCode != *w.Success {
		return fmt.Errorf("received response code %d expected %d", resp.StatusCode, *w.Success)
	}

	return nil
}

// Wait for trigger events from the channel, and send webhooks when triggered
func ServeWebhooks() {
	for {
		// Wait for trigger
		<-WebhookCallTriggerChannel

		// Calling webhook - one after another
		for _, v := range WebhookArray {
			log.V(0).Infof("calling webhook %v\n", v.URL)
			if err := v.Do(); err != nil {
				log.Errorf("error calling webhook %v: %v", v.URL, err)
			} else {
				log.V(0).Infof("calling webhook %v was: OK\n", v.URL)
			}
		}
	}

}
