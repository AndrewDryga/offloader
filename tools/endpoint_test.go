package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// mockGateway returns a test server that mimics the gateway's API-port behavior:
// good key + endpoint -> a well-formed response; anything else -> 401/404.
func mockGateway() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("Authorization") != "Bearer good-key" {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":{"family":"unauthorized"}}`))
			return
		}
		if r.URL.Path != "/v1/endpoints/customer_usage_summary" {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"family":"not_found"}}`))
			return
		}
		_, _ = w.Write([]byte(`{"data":[{"account_id":"a"}],"meta":{"snapshot_id":"s1","freshness":{"watermark":"2026-06-01T00:00:00Z"}}}`))
	}))
}

func TestEndpointTestPassesOnGoodResponse(t *testing.T) {
	srv := mockGateway()
	defer srv.Close()
	code := run([]string{"endpoint", "test", "--url", srv.URL, "--key", "good-key", "--endpoint", "customer_usage_summary", "--params", "from=x&to=y"}, discard{}, discard{})
	if code != 0 {
		t.Fatalf("endpoint test exit = %d, want 0", code)
	}
}

func TestEndpointTestFailsOnUnexpectedStatus(t *testing.T) {
	srv := mockGateway()
	defer srv.Close()
	// no key -> 401, but we expect 200 by default -> failure
	code := run([]string{"endpoint", "test", "--url", srv.URL, "--endpoint", "customer_usage_summary"}, discard{}, discard{})
	if code != 1 {
		t.Fatalf("endpoint test (bad status) exit = %d, want 1", code)
	}
}

func TestEndpointTestVerifiesDenialStatus(t *testing.T) {
	srv := mockGateway()
	defer srv.Close()
	// expecting the 401 explicitly should pass
	code := run([]string{"endpoint", "test", "--url", srv.URL, "--endpoint", "customer_usage_summary", "--expect-status", "401"}, discard{}, discard{})
	if code != 0 {
		t.Fatalf("endpoint test (expected 401) exit = %d, want 0", code)
	}
}

func TestDocsPrintsUrls(t *testing.T) {
	code := run([]string{"docs", "--admin-url", "http://example:4001/"}, discard{}, discard{})
	if code != 0 {
		t.Fatalf("docs exit = %d, want 0", code)
	}
}
