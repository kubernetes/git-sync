package main

import (
	"fmt"
	"net/http"
	"time"
)

// Create an http client that has our timeout by default
var netClient = &http.Client{
	Timeout: time.Duration(time.Second * time.Duration(*flWebhookTimeout)),
}

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
}

// WebhookCall Do webhook call
func WebHookCall(url string, method string, statusCode *int) error {
	req, err := http.NewRequest(method, url, nil)
	if err != nil {
		return err
	}

	//
	resp, err := netClient.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()

	// If the webhook has a success statusCode, check against it
	if statusCode != nil && resp.StatusCode != *statusCode {
		return fmt.Errorf("received response code %q expected %q", resp.StatusCode, statusCode)
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
			if err := WebHookCall(v.URL, v.Method, v.Success); err != nil {
				log.Errorf("error calling webhook %v: %v", v.URL, err)
			} else {
				log.V(0).Infof("calling webhook %v was: OK\n", v.URL)
			}
		}
	}

}
