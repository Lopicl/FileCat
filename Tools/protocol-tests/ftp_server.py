"""Small FTP test servers for FileCat, using only the standard library. Both serve ROOT as
user "test", password "secret", on 127.0.0.1:

  2991  explicit FTPS: AUTH TLS is required, and so is PROT P for transfers
  2992  the same, but data connections must reuse the control connection's TLS session, as
        vsftpd (require_ssl_reuse) and FileZilla Server insist by default
  2122  plain FTP without MLSD/MLST, so clients fall back to LIST

Usage: ftp_server.py ROOT CERT KEY
"""
import os
import posixpath
import socket
import ssl
import sys
import threading
import time

ROOT, CERT, KEY = sys.argv[1:4]
CONTEXT = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
CONTEXT.load_cert_chain(CERT, KEY)


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


class Session(threading.Thread):
    def __init__(self, connection, secure, mlsd, require_reuse=False):
        super().__init__(daemon=True)
        self.control = connection
        self.secure = secure
        self.mlsd = mlsd
        self.require_reuse = require_reuse
        self.buffer = b""
        self.tls = False
        self.protected = False
        self.user = None
        self.signed_in = False
        self.cwd = "/"
        self.passive = None
        self.rest = 0
        self.rename_from = None

    # Control connection

    def reply(self, text):
        self.control.sendall((text + "\r\n").encode())

    def read_line(self):
        while b"\n" not in self.buffer:
            data = self.control.recv(4096)
            if not data:
                return None
            self.buffer += data
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line.rstrip(b"\r").decode("utf-8", "replace")

    def run(self):
        try:
            self.reply("220 FileCat test FTP server")
            while True:
                line = self.read_line()
                if line is None:
                    return
                command, _, argument = line.partition(" ")
                command = command.upper()
                handler = getattr(self, "do_" + command, None)
                if handler is None:
                    self.reply("502 Not implemented")
                elif self.secure and not self.tls and command not in ("AUTH", "FEAT", "QUIT"):
                    self.reply("530 Use AUTH TLS first")
                elif not self.signed_in and command not in ("AUTH", "USER", "PASS", "FEAT", "QUIT", "PBSZ", "PROT"):
                    self.reply("530 Please sign in")
                elif handler(argument) is False:
                    return
        except (OSError, ssl.SSLError) as error:
            log("session ended: %s" % error)
        finally:
            self.control.close()

    # Paths

    def virtual(self, path):
        if not path:
            return self.cwd
        return posixpath.normpath(posixpath.join(self.cwd, path)).replace("//", "/")

    def real(self, path):
        return os.path.join(ROOT, self.virtual(path).lstrip("/"))

    # Data connections

    def open_passive(self):
        if self.passive:
            self.passive.close()
        self.passive = socket.socket()
        self.passive.bind(("127.0.0.1", 0))
        self.passive.listen(1)
        return self.passive.getsockname()[1]

    def accept_data(self):
        self.passive.settimeout(10)
        data, _ = self.passive.accept()
        self.passive.close()
        self.passive = None
        if self.protected:
            data = CONTEXT.wrap_socket(data, server_side=True)
            log("data connection, TLS session reused: %s" % data.session_reused)
            if self.require_reuse and not data.session_reused:
                data.close()
                raise ConnectionError("not reused")
        return data

    def transfer(self, send=None, receive=None):
        if not self.passive:
            self.reply("425 Use EPSV or PASV first")
            return
        if self.secure and not self.protected:
            self.reply("521 Use PROT P first")
            return
        self.reply("150 Opening data connection")
        try:
            data = self.accept_data()
        except ConnectionError:
            self.reply("522 SSL connection failed: session reuse required")
            return
        except OSError:
            self.reply("425 Can't open data connection")
            return
        try:
            if send is not None:
                for chunk in send:
                    data.sendall(chunk)
            else:
                while True:
                    chunk = data.recv(65536)
                    if not chunk:
                        break
                    receive(chunk)
        except (OSError, ssl.SSLError):
            data.close()
            self.reply("426 Transfer aborted")
            return
        data.close()
        self.reply("226 Transfer complete")

    # Commands

    def do_AUTH(self, argument):
        if not self.secure or argument.upper() not in ("TLS", "SSL"):
            self.reply("504 Not supported")
            return
        self.reply("234 Starting TLS")
        self.control = CONTEXT.wrap_socket(self.control, server_side=True)
        self.tls = True

    def do_USER(self, argument):
        self.user = argument
        self.reply("331 Password please")

    def do_PASS(self, argument):
        if self.user == "test" and argument == "secret":
            self.signed_in = True
            self.reply("230 Signed in")
        else:
            self.reply("530 Wrong user name or password")

    def do_PBSZ(self, argument):
        self.reply("200 PBSZ=0")

    def do_PROT(self, argument):
        self.protected = argument.upper() == "P"
        self.reply("200 Protection set")

    def do_FEAT(self, argument):
        features = ["UTF8", "EPSV", "PASV", "REST STREAM", "SIZE"]
        if self.secure:
            features += ["AUTH TLS", "PBSZ", "PROT"]
        if self.mlsd:
            features.append("MLST type*;size*;modify*;")
        self.control.sendall(("211-Features:\r\n" + "".join(" %s\r\n" % f for f in features) + "211 End\r\n").encode())

    def do_OPTS(self, argument):
        self.reply("200 OK")

    def do_TYPE(self, argument):
        self.reply("200 Binary")

    def do_NOOP(self, argument):
        self.reply("200 OK")

    def do_SYST(self, argument):
        self.reply("215 UNIX Type: L8")

    def do_QUIT(self, argument):
        self.reply("221 Bye")
        return False

    def do_PWD(self, argument):
        self.reply('257 "%s" is the current folder' % self.cwd.replace('"', '""'))

    def do_CWD(self, argument):
        if os.path.isdir(self.real(argument)):
            self.cwd = self.virtual(argument)
            self.reply("250 OK")
        else:
            self.reply("550 Failed to change directory.")

    def do_EPSV(self, argument):
        self.reply("229 Entering Extended Passive Mode (|||%d|)" % self.open_passive())

    def do_PASV(self, argument):
        port = self.open_passive()
        self.reply("227 Entering Passive Mode (127,0,0,1,%d,%d)" % (port // 256, port % 256))

    def facts(self, path, name):
        info = os.stat(path)
        modified = time.strftime("%Y%m%d%H%M%S", time.gmtime(info.st_mtime))
        kind = "dir" if os.path.isdir(path) else "file"
        return "type=%s;size=%d;modify=%s; %s" % (kind, info.st_size, modified, name)

    def do_MLSD(self, argument):
        if not self.mlsd:
            self.reply("502 Not implemented")
            return
        folder = self.real(argument)
        if not os.path.isdir(folder):
            self.reply("550 No such folder")
            return
        lines = [self.facts(os.path.join(folder, n), n) for n in sorted(os.listdir(folder))]
        self.transfer(send=[("\r\n".join(lines) + "\r\n").encode() if lines else b""])

    def do_MLST(self, argument):
        path = self.real(argument)
        if not self.mlsd or not os.path.exists(path):
            self.reply("550 No such file")
            return
        self.control.sendall(("250-Listing\r\n %s\r\n250 End\r\n" % self.facts(path, self.virtual(argument))).encode())

    def do_LIST(self, argument):
        if argument.startswith("-"):
            argument = ""
        folder = self.real(argument)
        lines = []
        for name in sorted(os.listdir(folder)):
            info = os.stat(os.path.join(folder, name))
            kind = "d" if os.path.isdir(os.path.join(folder, name)) else "-"
            date = time.strftime("%b %d %H:%M", time.localtime(info.st_mtime))
            lines.append("%srw-r--r--   1 test     staff    %8d %s %s" % (kind, info.st_size, date, name))
        self.transfer(send=[("\r\n".join(lines) + "\r\n").encode() if lines else b""])

    def do_SIZE(self, argument):
        path = self.real(argument)
        if os.path.isfile(path):
            self.reply("213 %d" % os.path.getsize(path))
        else:
            self.reply("550 No such file")

    def do_REST(self, argument):
        self.rest = int(argument)
        self.reply("350 Restarting at %d" % self.rest)

    def do_RETR(self, argument):
        path = self.real(argument)
        offset, self.rest = self.rest, 0
        if not os.path.isfile(path):
            self.reply("550 No such file")
            return

        def chunks():
            with open(path, "rb") as file:
                file.seek(offset)
                while True:
                    chunk = file.read(65536)
                    if not chunk:
                        return
                    yield chunk

        self.transfer(send=chunks())

    def do_STOR(self, argument):
        with open(self.real(argument), "wb") as file:
            self.transfer(receive=file.write)

    def do_MKD(self, argument):
        path = self.real(argument)
        if os.path.exists(path):
            self.reply("550 File exists")
            return
        os.mkdir(path)
        self.reply('257 "%s" created' % self.virtual(argument))

    def do_RMD(self, argument):
        try:
            os.rmdir(self.real(argument))
            self.reply("250 Removed")
        except OSError as error:
            self.reply("550 %s" % error.strerror)

    def do_DELE(self, argument):
        try:
            os.remove(self.real(argument))
            self.reply("250 Deleted")
        except OSError as error:
            self.reply("550 %s" % error.strerror)

    def do_RNFR(self, argument):
        if not os.path.exists(self.real(argument)):
            self.reply("550 No such file")
            return
        self.rename_from = self.real(argument)
        self.reply("350 Ready")

    def do_RNTO(self, argument):
        if not self.rename_from:
            self.reply("503 RNFR first")
            return
        os.rename(self.rename_from, self.real(argument))
        self.rename_from = None
        self.reply("250 Renamed")


def serve(port, secure, mlsd, require_reuse=False):
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(16)
    log("listening on %d (TLS: %s, MLSD: %s)" % (port, secure, mlsd))
    while True:
        connection, _ = listener.accept()
        Session(connection, secure, mlsd, require_reuse).start()


threading.Thread(target=serve, args=(2991, True, True), daemon=True).start()
threading.Thread(target=serve, args=(2992, True, True, True), daemon=True).start()
serve(2122, False, False)
