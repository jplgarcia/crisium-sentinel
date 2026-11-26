"""Local plain-HTTP front for an https:// JSON-RPC provider.

crisium's RPC client (prt-rpc.lua) speaks only http://. The entrypoint starts this proxy on
127.0.0.1 when RPC_URL is https:// and points crisium at it. Each request is forwarded as is to
the provider over TLS, with the certificate and host name verified (Python's default context).
The provider URL often carries an API key, so it is never logged.

Usage: python3 rpc-proxy.py PORT   (the upstream URL comes from the RPC_URL environment variable)
"""

import http.client
import http.server
import os
import sys
import threading
import urllib.parse

UPSTREAM = os.environ["RPC_URL"]
PORT = int(sys.argv[1])
_url = urllib.parse.urlsplit(UPSTREAM)
if _url.scheme != "https" or not _url.hostname:
    sys.exit("rpc-proxy: RPC_URL must be an https:// URL")
HOST = _url.hostname
UPSTREAM_PORT = _url.port or 443
PATH = (_url.path or "/") + (f"?{_url.query}" if _url.query else "")
_local = threading.local()


def _connection():
    conn = getattr(_local, "conn", None)
    if conn is None:
        conn = http.client.HTTPSConnection(HOST, UPSTREAM_PORT, timeout=60)
        _local.conn = conn
    return conn


def forward(body):
    """POST body upstream on this thread's kept-alive connection; one retry on a dropped connection."""
    for attempt in (1, 2):
        conn = _connection()
        try:
            conn.request("POST", PATH, body=body, headers={
                "Content-Type": "application/json",
                "User-Agent": "crisium-sentinel",
            })
            response = conn.getresponse()
            return response.status, response.read()
        except (http.client.HTTPException, OSError):
            conn.close()
            _local.conn = None
            if attempt == 2:
                raise
    raise AssertionError("unreachable")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        try:
            status, data = forward(body)
        except Exception as exc:  # reported to crisium as an HTTP failure, never with the URL
            status, data = 502, f"rpc-proxy: provider unreachable ({type(exc).__name__})".encode()
            print(data.decode(), file=sys.stderr, flush=True)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"rpc-proxy: forwarding 127.0.0.1:{PORT} to {HOST} over TLS", file=sys.stderr, flush=True)
    server.serve_forever()
