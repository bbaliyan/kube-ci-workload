#!/usr/bin/env python3
"""A tiny authenticated git server for tests. It stands in for GitHub and GitLab.

usage: git-http-server.py <repo-root> <token-file> <log-file> <port-file>

Every request needs HTTP Basic credentials whose password is the token in
<token-file>. Without them the server answers 401, so git asks the askpass
helper. The server logs one line per request: the method, the path and the
result. It never logs a header. It writes its port to <port-file> when ready.
"""
import base64
import http.server
import os
import subprocess
import sys

root, token_file, log_file, port_file = sys.argv[1:5]
token = open(token_file).read().strip()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def note(self, result):
        with open(log_file, "a") as log:
            log.write(f"{self.command} {self.path} {result}\n")

    def authorized(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return None
        user, _, password = base64.b64decode(header[6:]).decode().partition(":")
        return user if password == token else None

    def handle_any(self):
        user = self.authorized()
        if user is None:
            self.note("401")
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="git"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        path, _, query = self.path.partition("?")
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        env = dict(
            os.environ,
            GIT_PROJECT_ROOT=root,
            GIT_HTTP_EXPORT_ALL="1",
            PATH_INFO=path,
            QUERY_STRING=query,
            REQUEST_METHOD=self.command,
            CONTENT_TYPE=self.headers.get("Content-Type", ""),
            CONTENT_LENGTH=str(length),
            REMOTE_USER=user,
            REMOTE_ADDR="127.0.0.1",
        )
        for source, target in (("Content-Encoding", "HTTP_CONTENT_ENCODING"), ("Git-Protocol", "HTTP_GIT_PROTOCOL")):
            if self.headers.get(source):
                env[target] = self.headers[source]
        out = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True).stdout
        head, _, payload = out.partition(b"\r\n\r\n")
        status = "200 OK"
        headers = []
        for line in head.decode().split("\r\n"):
            key, _, value = line.partition(": ")
            if key == "Status":
                status = value
            elif key:
                headers.append((key, value))
        self.note(status.split()[0])
        self.send_response(int(status.split()[0]))
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = handle_any


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
