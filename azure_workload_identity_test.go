/*
Copyright 2026 The Kubernetes Authors All rights reserved.

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
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestAzureTokenEndpoint(t *testing.T) {
	cases := []struct {
		name          string
		authorityHost string
		tenantID      string
		want          string
		wantErr       bool
	}{
		{
			name:          "trailing slash on authority",
			authorityHost: "https://login.microsoftonline.com/",
			tenantID:      "deadbeef-1111-2222-3333-444455556666",
			want:          "https://login.microsoftonline.com/deadbeef-1111-2222-3333-444455556666/oauth2/v2.0/token",
		},
		{
			name:          "no trailing slash on authority",
			authorityHost: "https://login.microsoftonline.com",
			tenantID:      "deadbeef-1111-2222-3333-444455556666",
			want:          "https://login.microsoftonline.com/deadbeef-1111-2222-3333-444455556666/oauth2/v2.0/token",
		},
		{
			name:          "sovereign cloud authority",
			authorityHost: "https://login.microsoftonline.us/",
			tenantID:      "tenant",
			want:          "https://login.microsoftonline.us/tenant/oauth2/v2.0/token",
		},
		{
			name:          "empty authority",
			authorityHost: "",
			tenantID:      "tenant",
			wantErr:       true,
		},
		{
			name:          "empty tenant",
			authorityHost: "https://login.microsoftonline.com/",
			tenantID:      "",
			wantErr:       true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := azureTokenEndpoint(tc.authorityHost, tc.tenantID)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}
}

// TestExchangeAzureFederatedToken_RequestShape verifies that the OAuth2
// request we send to AAD is well-formed: correct method, content-type,
// and all five required form fields with the expected values.
func TestExchangeAzureFederatedToken_RequestShape(t *testing.T) {
	const (
		wantClientID = "11111111-2222-3333-4444-555555555555"
		wantScope    = "499b84ac-1321-427f-aa17-267ca6975798/.default"
		wantSAToken  = "eyJhbGciOi.fake.federated"
		fakeAccess   = "eyJ0eXAiOi.fake.access"
	)

	var (
		gotMethod      string
		gotContentType string
		gotAccept      string
		gotForm        url.Values
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotContentType = r.Header.Get("Content-Type")
		gotAccept = r.Header.Get("Accept")
		if err := r.ParseForm(); err != nil {
			t.Errorf("ParseForm: %v", err)
		}
		gotForm = r.PostForm

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(azureTokenResponse{
			AccessToken: fakeAccess,
			ExpiresIn:   3599,
			TokenType:   "Bearer",
		})
	}))
	defer srv.Close()

	tr, err := exchangeAzureFederatedToken(context.Background(), srv.URL, wantClientID, wantScope, wantSAToken)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tr.AccessToken != fakeAccess {
		t.Errorf("access_token: got %q want %q", tr.AccessToken, fakeAccess)
	}
	if tr.ExpiresIn != 3599 {
		t.Errorf("expires_in: got %d want 3599", tr.ExpiresIn)
	}

	if gotMethod != http.MethodPost {
		t.Errorf("method: got %q want POST", gotMethod)
	}
	if gotContentType != "application/x-www-form-urlencoded" {
		t.Errorf("Content-Type: got %q", gotContentType)
	}
	if gotAccept != "application/json" {
		t.Errorf("Accept: got %q", gotAccept)
	}

	checks := map[string]string{
		"client_id":             wantClientID,
		"scope":                 wantScope,
		"client_assertion_type": azureClientAssertionType,
		"client_assertion":      wantSAToken,
		"grant_type":            "client_credentials",
	}
	for k, want := range checks {
		got := gotForm.Get(k)
		if got != want {
			t.Errorf("form[%q]: got %q want %q", k, got, want)
		}
	}
}

// TestExchangeAzureFederatedToken_AADError verifies that AAD-style JSON
// error responses are surfaced with their AADSTS code and correlation ID,
// not just a generic "status N" message.
func TestExchangeAzureFederatedToken_AADError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(azureTokenError{
			Error:            "invalid_client",
			ErrorDescription: "AADSTS70021: No matching federated identity record found",
			ErrorCodes:       []int{70021},
			CorrelationID:    "abc-123",
		})
	}))
	defer srv.Close()

	_, err := exchangeAzureFederatedToken(context.Background(), srv.URL, "cid", "scope", "token")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	for _, want := range []string{"invalid_client", "AADSTS70021", "abc-123"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q missing %q", err.Error(), want)
		}
	}
}

// TestExchangeAzureFederatedToken_NonJSONError exercises the fallback path
// when AAD (or a proxy in front of it) returns a non-JSON error body.
func TestExchangeAzureFederatedToken_NonJSONError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = io.WriteString(w, "upstream is having a bad day")
	}))
	defer srv.Close()

	_, err := exchangeAzureFederatedToken(context.Background(), srv.URL, "cid", "scope", "token")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "502") {
		t.Errorf("error %q missing status code", err.Error())
	}
	if !strings.Contains(err.Error(), "upstream is having a bad day") {
		t.Errorf("error %q missing raw body", err.Error())
	}
}

// TestExchangeAzureFederatedToken_EmptyAccessToken catches a malformed but
// 200-OK response — we should reject it rather than store an empty token.
func TestExchangeAzureFederatedToken_EmptyAccessToken(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"expires_in":3599}`)
	}))
	defer srv.Close()

	_, err := exchangeAzureFederatedToken(context.Background(), srv.URL, "cid", "scope", "token")
	if err == nil {
		t.Fatal("expected error for empty access_token, got nil")
	}
}

// TestExchangeAzureFederatedToken_ZeroExpiresInDefaults verifies the
// defensive defaulting when AAD (or a fake) omits or zeroes expires_in.
func TestExchangeAzureFederatedToken_ZeroExpiresInDefaults(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"access_token":"abc","expires_in":0}`)
	}))
	defer srv.Close()

	tr, err := exchangeAzureFederatedToken(context.Background(), srv.URL, "cid", "scope", "token")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tr.ExpiresIn != 300 {
		t.Errorf("expected ExpiresIn defaulted to 300, got %d", tr.ExpiresIn)
	}
}
