package main

import (
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// httpGet fetches a URL with an optional bearer token and a short timeout. Used by
// doctor / snapshot / support-bundle to talk to a running gateway's admin port.
func httpGet(url, token string) (int, string, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return 0, "", err
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(body), nil
}

func adminURL(base, path string) string {
	return strings.TrimRight(base, "/") + path
}

// fetchDiagnostics returns the gateway's /diagnostics body (caller redacts it).
func fetchDiagnostics(base, token string) (string, error) {
	code, body, err := httpGet(adminURL(base, "/diagnostics"), token)
	if err != nil {
		return "", err
	}
	if code != http.StatusOK {
		return "", fmt.Errorf("admin /diagnostics returned %d", code)
	}
	return body, nil
}
