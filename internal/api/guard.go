package api

import (
	"net"
	"net/http"
	"strings"
)

// guard wraps the handler tree with two browser-facing protections. The API
// has no authentication (it trusts the LAN), so without these any web page
// a LAN user happens to visit could drive it:
//
//   - Cross-site request forgery: a page on evil.example POSTing to
//     http://airlock.local/api/devices/sda/format. http.CrossOriginProtection
//     rejects non-safe (POST/DELETE/…) requests whose Sec-Fetch-Site or
//     Origin header marks them as cross-origin. Requests without either
//     header (curl, the macOS companion) pass.
//
//   - DNS rebinding: evil.example re-resolving to the Pi's LAN address so
//     the browser treats airlock as same-origin and can read file listings
//     and dumps. We refuse requests whose Host header isn't a name the
//     appliance could legitimately be reached by.
func (s *Server) guard(next http.Handler) http.Handler {
	cop := http.NewCrossOriginProtection()
	cop.SetDenyHandler(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "cross-origin request refused"})
	}))
	inner := cop.Handler(next)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.hostAllowed(r.Host) {
			writeJSON(w, http.StatusMisdirectedRequest, map[string]string{"error": "unrecognised Host header"})
			return
		}
		inner.ServeHTTP(w, r)
	})
}

// localSuffixes are DNS suffixes that only resolve inside a LAN (mDNS,
// common router-assigned domains, RFC 8375 home.arpa).
var localSuffixes = []string{
	".local", ".lan", ".home", ".home.arpa", ".internal", ".localdomain", ".fritz.box",
}

// hostAllowed reports whether the Host header names this appliance: an IP
// literal, a single-label name (NetBIOS-style "airlock"), a LAN-only
// suffix, or an entry from AIRLOCK_ALLOWED_HOSTS.
func (s *Server) hostAllowed(hostport string) bool {
	host := hostport
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		host = h
	}
	host = strings.ToLower(strings.TrimSuffix(strings.Trim(host, "[]"), "."))
	if host == "" {
		return true // HTTP/1.0 without Host; nothing a browser would send
	}
	if net.ParseIP(host) != nil || !strings.Contains(host, ".") {
		return true
	}
	for _, suf := range localSuffixes {
		if strings.HasSuffix(host, suf) {
			return true
		}
	}
	for _, h := range s.allowedHosts {
		if host == h {
			return true
		}
	}
	return false
}

// SetAllowedHosts adds extra Host names (e.g. a custom DNS record pointing
// at the Pi) to the DNS-rebinding allow-list.
func (s *Server) SetAllowedHosts(hosts []string) {
	s.allowedHosts = s.allowedHosts[:0]
	for _, h := range hosts {
		if h = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(h), ".")); h != "" {
			s.allowedHosts = append(s.allowedHosts, h)
		}
	}
}
