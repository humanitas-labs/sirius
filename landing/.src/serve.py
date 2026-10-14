"""Dev server for the landing page with caching off, so a plain reload always picks up new assets.
Run from landing/: python3 .src/serve.py [port]"""
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

class NoCache(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, max-age=0")
        super().end_headers()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8731
ThreadingHTTPServer(("127.0.0.1", port), NoCache).serve_forever()
