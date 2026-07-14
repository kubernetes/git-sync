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
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// Env vars injected by the azure-workload-identity mutating admission webhook.
const (
	envAzureClientID           = "AZURE_CLIENT_ID"
	envAzureTenantID           = "AZURE_TENANT_ID"
	envAzureFederatedTokenFile = "AZURE_FEDERATED_TOKEN_FILE"
	envAzureAuthorityHost      = "AZURE_AUTHORITY_HOST"
)

// JWT-bearer client-assertion type, per RFC 7521 / RFC 7523.
const azureClientAssertionType = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

// azureTokenResponse models the subset of the AAD v2.0 token endpoint response
// we care about. Other fields (ext_expires_in, etc.) are intentionally ignored.
type azureTokenResponse struct {
	AccessToken string `json:"access_token"`
	ExpiresIn   int    `json:"expires_in"`
	TokenType   string `json:"token_type"`
}

// azureTokenError models the AAD v2.0 token endpoint error response.
type azureTokenError struct {
	Error            string `json:"error"`
	ErrorDescription string `json:"error_description"`
	ErrorCodes       []int  `json:"error_codes"`
	CorrelationID    string `json:"correlation_id"`
}

// azureTokenEndpoint builds the AAD v2.0 token endpoint URL from the values
// injected by the azure-workload-identity webhook. authorityHost is
// expected to be a URL like "https://login.microsoftonline.com/" but is
// normalized to tolerate a missing trailing slash.
func azureTokenEndpoint(authorityHost, tenantID string) (string, error) {
	if authorityHost == "" {
		return "", fmt.Errorf("$%s is empty", envAzureAuthorityHost)
	}
	if tenantID == "" {
		return "", fmt.Errorf("$%s is empty", envAzureTenantID)
	}
	u, err := url.Parse(strings.TrimRight(authorityHost, "/") + "/")
	if err != nil {
		return "", fmt.Errorf("invalid $%s %q: %w", envAzureAuthorityHost, authorityHost, err)
	}
	return u.String() + tenantID + "/oauth2/v2.0/token", nil
}

// RefreshAzureWIToken exchanges the projected ServiceAccount token at
// tokenFile for an Azure AD access token (scoped, by default, to the Azure
// DevOps resource) and stores it as a git credential against git.repo. It is
// safe to call repeatedly; the AAD endpoint mints a fresh access token each
// call. The caller resolves clientID/tenantID/tokenFile/authorityHost/scope
// from flags (or their AZURE_* env fallbacks) and decides when to call this
// (see the azureWITokenExpiry skew check in main.go's refreshCreds closure).
func (git *repoSync) RefreshAzureWIToken(ctx context.Context, clientID, tenantID, tokenFile, authorityHost, scope string) error {
	git.log.V(3).Info("refreshing Azure Workload Identity token")

	saTokenBytes, err := os.ReadFile(tokenFile)
	if err != nil {
		return fmt.Errorf("can't read federated token file %q: %w", tokenFile, err)
	}
	saToken := strings.TrimSpace(string(saTokenBytes))
	if saToken == "" {
		return fmt.Errorf("federated token file %q is empty", tokenFile)
	}

	endpoint, err := azureTokenEndpoint(authorityHost, tenantID)
	if err != nil {
		return err
	}

	tokenResp, err := exchangeAzureFederatedToken(ctx, endpoint, clientID, scope, saToken)
	if err != nil {
		return err
	}

	git.azureWITokenExpiry = time.Now().Add(time.Duration(tokenResp.ExpiresIn) * time.Second)

	// Azure DevOps accepts an AAD access token as the password of an HTTP basic
	// auth credential with any non-empty username. We use "-" to match the
	// convention already used by the GitHub App auth path in this codebase.
	if err := git.StoreCredentials(ctx, git.repo, "-", tokenResp.AccessToken); err != nil {
		return fmt.Errorf("can't store Azure WI access token as git credential: %w", err)
	}

	return nil
}

// exchangeAzureFederatedToken performs the OAuth2 client-credentials grant
// against the AAD v2.0 token endpoint, using the projected ServiceAccount
// token as the JWT-bearer client assertion. It returns the parsed token
// response or an error. The returned ExpiresIn is normalized to a positive
// value (defaulting to 300s if AAD returned 0 or a negative value).
//
// This is split out from RefreshAzureWIToken so it can be unit-tested against
// an httptest server without needing a real git environment.
func exchangeAzureFederatedToken(ctx context.Context, endpoint, clientID, scope, federatedToken string) (*azureTokenResponse, error) {
	form := url.Values{
		"client_id":             {clientID},
		"scope":                 {scope},
		"client_assertion_type": {azureClientAssertionType},
		"client_assertion":      {federatedToken},
		"grant_type":            {"client_credentials"},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, fmt.Errorf("can't build AAD token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("AAD token request failed: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("can't read AAD token response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		var aadErr azureTokenError
		if jerr := json.Unmarshal(body, &aadErr); jerr == nil && aadErr.Error != "" {
			return nil, fmt.Errorf("AAD token endpoint returned %d: %s: %s (correlation_id=%s, error_codes=%v)",
				resp.StatusCode, aadErr.Error, aadErr.ErrorDescription, aadErr.CorrelationID, aadErr.ErrorCodes)
		}
		return nil, fmt.Errorf("AAD token endpoint returned %d, body: %q", resp.StatusCode, string(body))
	}

	var tokenResp azureTokenResponse
	if err := json.Unmarshal(body, &tokenResp); err != nil {
		return nil, fmt.Errorf("can't parse AAD token response: %w", err)
	}
	if tokenResp.AccessToken == "" {
		return nil, fmt.Errorf("AAD token response contained no access_token")
	}
	if tokenResp.ExpiresIn <= 0 {
		// AAD always returns expires_in; if it didn't, assume a conservative 5 min
		// so we re-mint soon rather than holding a token forever.
		tokenResp.ExpiresIn = 300
	}
	return &tokenResp, nil
}
