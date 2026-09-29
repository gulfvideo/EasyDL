#!/usr/bin/env python3
"""A tiny HTTP file server that honours Range requests, for the resume test.

Python's own http.server ignores Range, and so does samplelib.com — it answers a
ranged request with 200 and the whole file, which makes resume impossible and made
the resume test unable to tell "resumed" from "restarted". Serving locally makes the
test hermetic and, more importantly, lets it *measure* what happened: every request
is appended to the log file as

    range=<start or ->  sent=<bytes>

so the test can assert that the second attempt asked for a byte offset and
transferred only the remainder, rather than guessing from yt-dlp's wording.

    rangeserver.py <directory> <logfile>      prints "PORT=<n>", then serves
"""
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIRECTORY, LOGFILE = sys.argv[1], sys.argv[2]
_lock = threading.Lock()


def note(line):
    with _lock, open(LOGFILE, "a") as fh:
        fh.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):  # keep stderr quiet
        pass

    def _resolve(self):
        name = os.path.basename(self.path.split("?", 1)[0])
        path = os.path.join(DIRECTORY, name)
        return path if os.path.isfile(path) else None

    def do_HEAD(self):
        self._serve(body=False)

    def do_GET(self):
        self._serve(body=True)

    def _serve(self, body):
        path = self._resolve()
        if not path:
            self.send_error(404)
            return

        total = os.path.getsize(path)
        start, end = 0, total - 1
        status = 200

        header = self.headers.get("Range")
        match = re.match(r"bytes=(\d+)-(\d*)", header or "")
        if match:
            start = int(match.group(1))
            if match.group(2):
                end = int(match.group(2))
            if start >= total:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{total}")
                self.end_headers()
                note(f"range={start} sent=0 status=416")
                return
            status = 206

        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
        self.end_headers()

        written = 0
        if body:
            try:
                with open(path, "rb") as fh:
                    fh.seek(start)
                    remaining = length
                    while remaining > 0:
                        chunk = fh.read(min(65536, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        written += len(chunk)
                        remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass  # the client sniffed the header and hung up

        if self.command == "GET":
            note(f"range={start if match else '-'} sent={written} status={status}")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(f"PORT={server.server_address[1]}", flush=True)
server.serve_forever()
