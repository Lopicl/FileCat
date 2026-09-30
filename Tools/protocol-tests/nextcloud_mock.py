"""A tiny stand-in for Nextcloud: Login Flow v2 plus WebDAV forwarded to rclone."""
import http.server, json, urllib.request, urllib.error, socketserver

STATE = {"approved": False}
UPSTREAM = "http://127.0.0.1:8084"

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def reply(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else None

    def handle_any(self):
        if self.path == "/index.php/login/v2" and self.command == "POST":
            STATE["approved"] = False
            return self.reply(200, json.dumps({
                "poll": {"token": "tok", "endpoint": "http://127.0.0.1:8082/index.php/login/v2/poll"},
                "login": "http://127.0.0.1:8082/login/flow"}).encode())
        if self.path == "/login/flow":
            STATE["approved"] = True
            return self.reply(200, b"<h1>Account connected</h1>", "text/html")
        if self.path == "/index.php/login/v2/poll":
            data = self.body() or b""
            if STATE["approved"] and b"token=tok" in data:
                return self.reply(200, json.dumps({"server": "http://127.0.0.1:8082", "loginName": "test", "appPassword": "secret"}).encode())
            return self.reply(404, b"[]")
        if self.path.startswith("/remote.php/dav/files/test"):
            request = urllib.request.Request(UPSTREAM + self.path, data=self.body(), method=self.command)
            for key in ["Authorization", "Depth", "Range", "Overwrite", "Content-Type"]:
                if self.headers.get(key): request.add_header(key, self.headers[key])
            if self.headers.get("Destination"):
                request.add_header("Destination", self.headers["Destination"].replace("127.0.0.1:8082", "127.0.0.1:8084"))
            try:
                response = urllib.request.urlopen(request)
                status, headers, content = response.status, response.headers, response.read()
            except urllib.error.HTTPError as error:
                status, headers, content = error.code, error.headers, error.read()
            content = content.replace(b"127.0.0.1:8084", b"127.0.0.1:8082")
            self.send_response(status)
            for key in ["Content-Type", "WWW-Authenticate", "Content-Range", "Last-Modified"]:
                if headers.get(key): self.send_header(key, headers[key])
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return
        self.reply(404, b"not found", "text/plain")

    do_GET = do_POST = do_PUT = do_DELETE = do_PROPFIND = do_MKCOL = do_MOVE = do_COPY = handle_any

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

Server(("127.0.0.1", 8082), Handler).serve_forever()
