#!/usr/bin/env python3
"""SwitchGate - Network gateway proxy for Nintendo Switch (macOS, Linux, Windows)."""

import argparse
import http.client
import http.server
import ipaddress
import logging
import os
import select
import signal
import socket
import socketserver
import sys
import threading
import urllib.parse

DEFAULT_PORT = 8888
BUFFER_SIZE = 65536
TUNNEL_TIMEOUT = 1.0
LOG_FILE = "proxy.log"

ALLOWED_NETWORKS = [
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("127.0.0.0/8"),
]

RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
BLUE = "\033[0;34m"
NC = "\033[0m"


def supports_color():
    if not hasattr(sys.stdout, "isatty") or not sys.stdout.isatty():
        return False
    if sys.platform == "win32":
        try:
            import ctypes
            kernel32 = ctypes.windll.kernel32
            kernel32.SetConsoleMode(kernel32.GetStdHandle(-11), 7)
            return True
        except Exception:
            return False
    return True


def setup_logging(log_file):
    logger = logging.getLogger("switchgate")
    logger.setLevel(logging.INFO)

    formatter = logging.Formatter(
        "[%(asctime)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
    )

    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setLevel(logging.INFO)
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)

    file_handler = logging.FileHandler(log_file, mode="w", encoding="utf-8")
    file_handler.setLevel(logging.INFO)
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    return logger


def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return None


def show_banner():
    print(f"{BLUE}SwitchGate - Network Gateway for Nintendo Switch{NC}")
    print("==============================================")


def show_switch_config(ip, port, log_file):
    print()
    if not ip:
        print(f"{RED}WARNING: Could not detect local IP address.{NC}")
        print(f"{YELLOW}Make sure you are connected to a network.{NC}")
        print()
        ip = "<not detected>"

    print(f"{GREEN}NINTENDO SWITCH CONFIGURATION:{NC}")
    print("==========================================")
    print(f"{BLUE}Proxy IP:{NC} {ip}")
    print(f"{BLUE}Port:{NC} {port}")
    print()
    print(f"{YELLOW}HOW TO CONFIGURE ON SWITCH:{NC}")
    print("1. Go to Settings > Internet")
    print("2. Select your Wi-Fi network")
    print("3. Choose 'Change settings'")
    print("4. In 'Proxy server' choose 'Yes'")
    print(f"5. Enter IP: {ip}")
    print(f"6. Enter Port: {port}")
    print("7. Save and test connection")
    print()
    print(f"{GREEN}Proxy Status:{NC}")
    print(f"- Log file: {log_file}")
    print()
    print(f"{YELLOW}Press Ctrl+C to stop the proxy{NC}")
    print()


class ThreadedProxyServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, server_address, RequestHandlerClass, logger):
        self.proxy_logger = logger
        super().__init__(server_address, RequestHandlerClass)

    def verify_request(self, request, client_address):
        client_ip = client_address[0]
        try:
            ip = ipaddress.ip_address(client_ip)
            allowed = any(ip in network for network in ALLOWED_NETWORKS)
        except ValueError:
            allowed = False

        if not allowed:
            self.proxy_logger.warning("Rejected connection from %s", client_ip)
        return allowed


class ProxyRequestHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        self.server.proxy_logger.info(
            "%s %s", self.client_address[0], format % args
        )

    def log_error(self, format, *args):
        self.server.proxy_logger.error(
            "%s %s", self.client_address[0], format % args
        )

    def do_GET(self):
        self._forward_request()

    def do_POST(self):
        self._forward_request()

    def do_PUT(self):
        self._forward_request()

    def do_DELETE(self):
        self._forward_request()

    def do_HEAD(self):
        self._forward_request()

    def do_PATCH(self):
        self._forward_request()

    def do_OPTIONS(self):
        self._forward_request()

    def _forward_request(self):
        url = urllib.parse.urlparse(self.path)
        host = url.hostname
        port = url.port or 80
        path = url.path or "/"
        if url.query:
            path = f"{path}?{url.query}"

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else None

        hop_by_hop = {
            "proxy-connection", "proxy-authorization",
            "connection", "keep-alive", "te", "trailers",
            "transfer-encoding", "upgrade",
        }
        headers = {}
        for key, value in self.headers.items():
            if key.lower() not in hop_by_hop:
                headers[key] = value

        try:
            conn = http.client.HTTPConnection(host, port, timeout=30)
            conn.request(self.command, path, body=body, headers=headers)
            response = conn.getresponse()

            self.send_response_only(response.status, response.reason)
            for key, value in response.getheaders():
                if key.lower() != "transfer-encoding":
                    self.send_header(key, value)
            self.end_headers()

            while True:
                chunk = response.read(BUFFER_SIZE)
                if not chunk:
                    break
                self.wfile.write(chunk)

            conn.close()
        except Exception as e:
            self.server.proxy_logger.error(
                "%s Error forwarding to %s: %s",
                self.client_address[0], self.path, e,
            )
            try:
                self.send_error(502, f"Bad Gateway: {e}")
            except Exception:
                pass

    def do_CONNECT(self):
        try:
            host, port_str = self.path.split(":")
            port = int(port_str)
        except ValueError:
            host = self.path
            port = 443

        try:
            remote_sock = socket.create_connection((host, port), timeout=10)
        except Exception as e:
            self.send_error(502, f"Cannot connect to {self.path}: {e}")
            return

        self.send_response_only(200, "Connection Established")
        self.end_headers()

        client_sock = self.connection
        self._tunnel(client_sock, remote_sock)
        remote_sock.close()

    def _tunnel(self, client_sock, remote_sock):
        sockets = [client_sock, remote_sock]
        try:
            while True:
                readable, _, errors = select.select(
                    sockets, [], sockets, TUNNEL_TIMEOUT
                )
                if errors:
                    break
                for sock in readable:
                    other = remote_sock if sock is client_sock else client_sock
                    try:
                        data = sock.recv(BUFFER_SIZE)
                        if not data:
                            return
                        other.sendall(data)
                    except (ConnectionError, OSError):
                        return
        except Exception:
            pass


def main():
    global RED, GREEN, YELLOW, BLUE, NC

    parser = argparse.ArgumentParser(
        description="SwitchGate - Network gateway proxy for Nintendo Switch"
    )
    parser.add_argument(
        "--port", "-p",
        type=int,
        default=DEFAULT_PORT,
        help=f"Proxy port (default: {DEFAULT_PORT})",
    )
    args = parser.parse_args()

    if not supports_color():
        RED = GREEN = YELLOW = BLUE = NC = ""

    log_file = os.path.join(os.getcwd(), LOG_FILE)
    logger = setup_logging(log_file)

    show_banner()

    try:
        server = ThreadedProxyServer(
            ("0.0.0.0", args.port), ProxyRequestHandler, logger
        )
    except OSError as e:
        print(f"{RED}ERROR: Could not start proxy on port {args.port}: {e}{NC}")
        print(f"{YELLOW}The port may be in use. Try a different port with --port{NC}")
        sys.exit(1)

    local_ip = get_local_ip()
    logger.info("Proxy started on port %d", args.port)
    show_switch_config(local_ip, args.port, log_file)

    def shutdown_handler(signum, frame):
        print()
        print(f"{YELLOW}Stopping proxy...{NC}")
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, shutdown_handler)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, shutdown_handler)

    print(f"{BLUE}Monitoring connections (Ctrl+C to exit):{NC}")
    print("==================================================")

    server.serve_forever()
    server.server_close()
    print(f"{GREEN}Proxy stopped.{NC}")


if __name__ == "__main__":
    main()
