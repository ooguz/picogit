#!/usr/bin/env python3
"""Small smart-HTTP git server for tests: runs `git http-backend` as a CGI.

  git_http_server.py --root DIR [--port N] [--port-file F] [--tls CERT KEY]
                     [--auth USER:PASS] [--no-chunked] [--verbose]

Paths:
  /<repo>/...            served by git http-backend (push enabled)
  /__file/<name>         a file from <root>/files, sent with Content-Length
  /__echo                echoes the request body (chunked or close-delimited)
  /redirect/<path>       301 redirect to /<path>
  /redirect307/<path>    307 redirect to /<path>

Responses are sent with chunked transfer encoding (HTTP/1.1) unless
--no-chunked is given, in which case the body is delimited by closing the
connection, so both client code paths can be tested.
"""
import argparse
import base64
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARGS = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "picogit-test/1"

    def log_message(self, fmt, *args):
        if ARGS.verbose:
            sys.stderr.write("[server] " + (fmt % args) + "\n")

    def do_GET(self):
        self.handle_any()

    def do_POST(self):
        self.handle_any()

    def send_simple(self, code, msg, extra=()):
        body = (msg + "\n").encode()
        self.send_response(code)
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self, out):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            while True:
                line = self.rfile.readline().strip()
                size = int(line.split(b";")[0], 16)
                if size == 0:
                    while self.rfile.readline().strip():
                        pass
                    break
                out.write(self.rfile.read(size))
                self.rfile.readline()
        else:
            remaining = int(self.headers.get("Content-Length", "0"))
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    break
                out.write(chunk)
                remaining -= len(chunk)
        out.flush()
        return out.tell()

    def handle_any(self):
        path, _, query = self.path.partition("?")
        for prefix, code in (("/redirect/", 301), ("/redirect307/", 307)):
            if path.startswith(prefix):
                loc = "/" + path[len(prefix):] + ("?" + query if query else "")
                self.send_simple(code, "moved", [("Location", loc)])
                return

        user = "anonymous"
        if ARGS.auth:
            want = "Basic " + base64.b64encode(ARGS.auth.encode()).decode()
            if self.headers.get("Authorization") != want:
                with tempfile.TemporaryFile() as body:
                    self.read_body(body)
                self.send_simple(401, "authentication required",
                                 [("WWW-Authenticate", 'Basic realm="picogit-test"')])
                return
            user = ARGS.auth.split(":", 1)[0]

        if path.startswith("/__file/"):
            name = os.path.basename(path[len("/__file/"):])
            fp = os.path.join(ARGS.root, "files", name)
            if not os.path.isfile(fp):
                self.send_simple(404, "not found")
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(os.path.getsize(fp)))
            self.end_headers()
            with open(fp, "rb") as f:
                shutil.copyfileobj(f, self.wfile)
            return


        if path == "/__echo":
            with tempfile.TemporaryFile() as body:
                self.read_body(body)
                body.seek(0)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_stream(body)
            return

        with tempfile.TemporaryFile() as body:
            length = self.read_body(body)
            body.seek(0)
            env = {
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "GIT_PROJECT_ROOT": ARGS.root,
                "GIT_HTTP_EXPORT_ALL": "1",
                "REQUEST_METHOD": self.command,
                "PATH_INFO": path,
                "QUERY_STRING": query,
                "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                "CONTENT_LENGTH": str(length),
                "REMOTE_USER": user,
                "REMOTE_ADDR": self.client_address[0],
                "GIT_CONFIG_NOSYSTEM": "1",
                "HOME": ARGS.root,
            }
            if self.headers.get("Git-Protocol") and not ARGS.protocol_v0:
                env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
            if self.headers.get("Content-Encoding"):
                env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
            proc = subprocess.Popen(["git", "http-backend"], stdin=body,
                                    stdout=subprocess.PIPE, env=env)
            status, headers = 200, []
            while True:
                line = proc.stdout.readline()
                if not line or line in (b"\r\n", b"\n"):
                    break
                k, _, v = line.decode().rstrip("\r\n").partition(":")
                if k.lower() == "status":
                    status = int(v.split()[0])
                else:
                    headers.append((k, v.strip()))
            self.send_response(status)
            for k, v in headers:
                self.send_header(k, v)
            self.send_stream(proc.stdout)
            proc.wait()

    def send_stream(self, src):
        """Finish the headers and send src as a chunked or close-delimited body."""
        if ARGS.no_chunked:
            self.send_header("Connection", "close")
            self.close_connection = True
            self.end_headers()
            shutil.copyfileobj(src, self.wfile)
            return
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        while True:
            chunk = src.read1(65536) if hasattr(src, "read1") else src.read(65536)
            if not chunk:
                break
            self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
        self.wfile.write(b"0\r\n\r\n")


def main():
    global ARGS
    p = argparse.ArgumentParser()
    p.add_argument("--root", required=True)
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--port-file")
    p.add_argument("--tls", nargs=2, metavar=("CERT", "KEY"))
    p.add_argument("--auth")
    p.add_argument("--no-chunked", action="store_true")
    p.add_argument("--protocol-v0", action="store_true",
                   help="ignore Git-Protocol (behave like a v0-only server)")
    p.add_argument("--verbose", action="store_true")
    ARGS = p.parse_args()
    ARGS.root = os.path.abspath(ARGS.root)

    srv = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    srv.daemon_threads = True
    if ARGS.tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(ARGS.tls[0], ARGS.tls[1])
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    port = srv.server_address[1]
    if ARGS.port_file:
        tmp = ARGS.port_file + ".tmp"
        with open(tmp, "w") as f:
            f.write(str(port))
        os.rename(tmp, ARGS.port_file)
    print("listening on port %d" % port, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
