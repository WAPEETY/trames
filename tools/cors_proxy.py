#!/usr/bin/env python3
"""Tiny CORS proxy for running the web build locally.

Roma Mobilità's GTFS-realtime files are served without CORS headers, so a
browser app can't fetch them directly. This forwards GET requests for an
allow-listed set of URLs and adds `Access-Control-Allow-Origin: *`.

    python3 tools/cors_proxy.py            # listens on 127.0.0.1:8787
    flutter run -d web-server --dart-define=CORS_PROXY=http://localhost:8787/?url=

Development only. In production put the feed behind your own backend.
"""
import http.server
import sys
import urllib.parse
import urllib.request

ALLOWED_PREFIXES = (
    "https://romamobilita.it/wp-content/uploads/shared/",
    "https://romamobilita.it/sites/default/files/",
)


class Handler(http.server.BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        query = urllib.parse.urlparse(self.path).query
        url = urllib.parse.parse_qs(query).get("url", [""])[0]
        if not url.startswith(ALLOWED_PREFIXES):
            self.send_response(403)
            self._cors()
            self.end_headers()
            self.wfile.write(b"url not allowed")
            return
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "trames/0.1"})
            with urllib.request.urlopen(req, timeout=20) as r:
                body = r.read()
                ctype = r.headers.get("Content-Type", "application/octet-stream")
        except Exception as e:  # upstream error -> 502
            self.send_response(502)
            self._cors()
            self.end_headers()
            self.wfile.write(str(e).encode())
            return
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("proxy: " + fmt % args + "\n")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    print(f"CORS proxy on http://127.0.0.1:{port}/?url=<allowed url>")
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
