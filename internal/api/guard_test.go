package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func guardedOK(s *Server) http.Handler {
	return s.guard(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
}

func TestGuard_CrossOrigin(t *testing.T) {
	h := guardedOK(&Server{})
	cases := []struct {
		name    string
		method  string
		headers map[string]string
		want    int
	}{
		{"curl / companion (no browser headers)", "POST", nil, http.StatusNoContent},
		{"same-origin fetch", "POST", map[string]string{"Sec-Fetch-Site": "same-origin", "Origin": "http://airlock.local"}, http.StatusNoContent},
		{"cross-site form post", "POST", map[string]string{"Sec-Fetch-Site": "cross-site", "Origin": "https://evil.example"}, http.StatusForbidden},
		{"cross-site, Origin only (older browser)", "DELETE", map[string]string{"Origin": "https://evil.example"}, http.StatusForbidden},
		{"cross-site GET is allowed (safe method)", "GET", map[string]string{"Sec-Fetch-Site": "cross-site"}, http.StatusNoContent},
	}
	for _, tc := range cases {
		req := httptest.NewRequest(tc.method, "http://airlock.local/api/eject-all", nil)
		for k, v := range tc.headers {
			req.Header.Set(k, v)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != tc.want {
			t.Errorf("%s: got %d, want %d", tc.name, rec.Code, tc.want)
		}
	}
}

func TestHostAllowed(t *testing.T) {
	s := &Server{}
	s.SetAllowedHosts([]string{" Files.Example.NET. ", ""})
	allowed := []string{
		"airlock", "airlock:80", "airlock.local", "airlock.local.", "AIRLOCK.LOCAL:80",
		"192.168.1.20", "192.168.1.20:80", "[fe80::1]:80", "airlock.home.arpa",
		"airlock.fritz.box", "files.example.net", "",
	}
	for _, h := range allowed {
		if !s.hostAllowed(h) {
			t.Errorf("hostAllowed(%q) = false, want true", h)
		}
	}
	for _, h := range []string{"evil.example", "airlock.local.evil.example", "rebind.attacker.net:80"} {
		if s.hostAllowed(h) {
			t.Errorf("hostAllowed(%q) = true, want false", h)
		}
	}
}
