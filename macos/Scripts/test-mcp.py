#!/usr/bin/env python3
"""Exercise a built NMCP executable over its real stdio MCP transport.

Uses only Python's standard library and local loopback fixtures. It never reads
or writes NETworkManager user data: each subprocess gets a temporary application
support directory. Build first, then pass --server /path/to/NMCP. Optionally pass
--launcher /path/to/run-mcp.sh to check the normal client entry point too;
NMCP_CONFIGURATION is inherited so it can select the prebuilt configuration.
"""

import argparse
import collections
import json
import os
from pathlib import Path
import queue
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time


MAX_LINE_BYTES = 1024 * 1024
OFFLINE_TOOLS = {"network_interfaces", "subnet_info", "port_lookup", "mac_vendor_lookup"}
NETWORK_TOOLS = {"ping", "dns_lookup", "tcp_probe"}
RESOURCE_URIS = {"networkmanager://server-info", "networkmanager://usage"}


class CheckFailure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise CheckFailure(message)


def isolated_environment(directory, overrides=None):
    environment = os.environ.copy()
    environment.update(overrides or {})
    environment["NETWORKMANAGER_SUPPORT_DIRECTORY"] = str(Path(directory) / "support")
    return environment


def check_no_persisted_json(directory, expected=None):
    expected = expected or {}
    files = {str(path.relative_to(directory)): path.read_bytes() for path in Path(directory).rglob("*")
             if path.is_file() and path.suffix.lower() == ".json"}
    changed_paths = set(files) ^ set(expected)
    check(not changed_paths, "MCP server added or removed application JSON files: " + ", ".join(sorted(changed_paths)))
    for path, original_bytes in expected.items():
        check(files[path] == original_bytes, "MCP server modified existing application JSON: " + path)


class Deadline:
    def __init__(self, seconds):
        self.end = time.monotonic() + seconds

    def remaining(self, maximum=4):
        remaining = min(maximum, self.end - time.monotonic())
        if remaining <= 0:
            raise CheckFailure("MCP integration suite exceeded its 30-second deadline")
        return remaining


class MCPProcess:
    """A small independent MCP wire client with bounded reads and cleanup."""

    def __init__(self, server, deadline, *arguments, settings_bytes=None, environment_overrides=None):
        self.deadline = deadline
        self.storage = tempfile.TemporaryDirectory(prefix="nmcp-integration-")
        self.expected_json = {}
        try:
            if settings_bytes is not None:
                support = Path(self.storage.name) / "support"
                support.mkdir()
                (support / "settings.json").write_bytes(settings_bytes)
                self.expected_json["support/settings.json"] = settings_bytes
            self.process = subprocess.Popen(
                [str(server), *arguments], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, start_new_session=True,
                env=isolated_environment(self.storage.name, environment_overrides),
            )
        except Exception:
            self.storage.cleanup()
            raise
        self.messages = queue.Queue()
        self.stderr = collections.deque(maxlen=64)
        self.pending = {}
        self.next_id = 0
        self.readers = [
            threading.Thread(target=self._read_stdout, daemon=True),
            threading.Thread(target=self._read_stderr, daemon=True),
        ]
        for reader in self.readers:
            reader.start()

    def _read_stdout(self):
        try:
            while True:
                line = self.process.stdout.readline(MAX_LINE_BYTES + 1)
                if not line:
                    self.messages.put(("eof", None))
                    return
                if len(line) > MAX_LINE_BYTES or not line.endswith(b"\n"):
                    raise CheckFailure("stdout contains an oversized or unterminated MCP message")
                message = json.loads(line.decode("utf-8"))
                check(isinstance(message, dict) and message.get("jsonrpc") == "2.0",
                      "stdout must contain only JSON-RPC 2.0 objects")
                self.messages.put(("message", message))
        except Exception as error:
            self.messages.put(("failure", str(error)))

    def _read_stderr(self):
        while True:
            line = self.process.stderr.readline(4096)
            if not line:
                return
            self.stderr.append(line.decode("utf-8", errors="replace"))

    def __enter__(self):
        return self

    def __exit__(self, error_type, error, traceback):
        self.cleanup()
        if error is not None and self.stderr:
            print("Server stderr:\n" + "".join(self.stderr), file=sys.stderr)

    def cleanup(self):
        try:
            if self.process.stdin and not self.process.stdin.closed:
                self.process.stdin.close()
            if self.process.poll() is None:
                try:
                    self.process.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGTERM)
                    try:
                        self.process.wait(timeout=0.5)
                    except subprocess.TimeoutExpired:
                        os.killpg(self.process.pid, signal.SIGKILL)
                        self.process.wait(timeout=1)
            for reader in self.readers:
                reader.join(timeout=0.2)
            self.process.stdout.close()
            self.process.stderr.close()
            check_no_persisted_json(self.storage.name, self.expected_json)
        finally:
            self.storage.cleanup()

    def send_raw(self, message):
        self.process.stdin.write(message + b"\n")
        self.process.stdin.flush()

    def send(self, message):
        self.send_raw(json.dumps(message, separators=(",", ":")).encode("utf-8"))

    def begin(self, method, params=None, request_id=None):
        self.next_id += 1
        identifier = self.next_id if request_id is None else request_id
        message = {"jsonrpc": "2.0", "id": identifier, "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)
        return identifier

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)

    def receive(self, timeout=4):
        try:
            kind, value = self.messages.get(timeout=self.deadline.remaining(timeout))
        except queue.Empty:
            raise CheckFailure("Timed out waiting for an MCP response")
        if kind == "eof":
            raise CheckFailure("MCP process closed stdout before replying")
        if kind == "failure":
            raise CheckFailure("Invalid protocol stdout: " + value)
        return value

    def response(self, identifier, timeout=4):
        end = time.monotonic() + self.deadline.remaining(timeout)
        while identifier not in self.pending:
            message = self.receive(max(0.001, end - time.monotonic()))
            if "id" not in message:
                continue
            check("result" in message or "error" in message, "Unexpected server request")
            self.pending[message["id"]] = message
        message = self.pending.pop(identifier)
        check(("result" in message) != ("error" in message), "Response must contain result or error")
        return message

    def response_snapshot(self, identifiers):
        """Describe replies already available when an integration check fails."""
        transport = "open"
        while True:
            try:
                kind, value = self.messages.get_nowait()
            except queue.Empty:
                break
            if kind == "message" and "id" in value:
                self.pending[value["id"]] = value
            elif kind != "message":
                transport = kind + (": " + str(value) if value is not None else "")
        responses = {}
        for identifier in identifiers:
            message = self.pending.get(identifier)
            if message is None:
                responses[str(identifier)] = "pending"
            elif "error" in message:
                responses[str(identifier)] = {"rpcError": message["error"]}
            else:
                payload = message.get("result", {}).get("structuredContent", {})
                responses[str(identifier)] = {"status": payload.get("status"), "error": payload.get("error")}
        return json.dumps({"transport": transport, "processExitCode": self.process.poll(), "responses": responses},
                          separators=(",", ":"))

    def request(self, method, params=None, timeout=4):
        return self.response(self.begin(method, params), timeout)

    def result(self, method, params=None, timeout=4):
        response = self.request(method, params, timeout)
        check("error" not in response, "Unexpected MCP error: " + json.dumps(response))
        return response["result"]

    def initialize(self, version="2025-11-25"):
        result = self.result("initialize", {
            "protocolVersion": version, "capabilities": {},
            "clientInfo": {"name": "NETworkManager-integration-check", "version": "1.0.0"},
        })
        check(result.get("serverInfo", {}).get("name"), "Handshake omitted server name")
        check(result.get("serverInfo", {}).get("version"), "Handshake omitted server version")
        check("tools" in result.get("capabilities", {}), "Missing tools capability")
        check("resources" in result.get("capabilities", {}), "Missing resources capability")
        self.notify("notifications/initialized")
        return result

    def call(self, name, arguments, timeout=4):
        return self.result("tools/call", {"name": name, "arguments": arguments}, timeout)

    def eof(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=self.deadline.remaining(2))
        except subprocess.TimeoutExpired:
            raise CheckFailure("MCP server did not exit within two seconds of stdin EOF")
        check(self.process.returncode == 0, "MCP EOF shutdown did not exit successfully")
        for reader in self.readers:
            reader.join(timeout=0.2)
        while not self.messages.empty():
            kind, value = self.messages.get_nowait()
            check(kind != "failure", "Invalid protocol output during EOF shutdown: " + str(value))


def tool_data(result, error=False):
    check(result.get("isError", False) == error, "Unexpected tool error state: " + json.dumps(result))
    content = result.get("content", [])
    check(content and content[0].get("type") == "text", "Tool result must include text content")
    data = json.loads(content[0]["text"])
    check(isinstance(data, dict), "Tool payload must be a JSON object")
    check(result.get("structuredContent") == data, "Text and structuredContent disagree")
    check(isinstance(data.get("status"), str), "Tool payload omitted its execution status")
    check((data["status"] != "succeeded") == error, "Tool status disagrees with isError")
    check(isinstance(data.get("tool"), str) and data["tool"], "Tool payload omitted its tool name")
    check(isinstance(data.get("observedAt"), str) and data["observedAt"], "Tool payload omitted its observation time")
    if "error" in data:
        detail = data["error"]
        check(isinstance(detail, dict), "Tool error detail must be an object")
        for key in ("code", "message"):
            check(isinstance(detail.get(key), str) and detail[key], "Tool error omitted " + key)
    return data


class DNSFixture:
    """Loopback UDP responder; never forwards queries to another server."""

    def __init__(self, answer=True):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.settimeout(0.1)
        self.port = self.socket.getsockname()[1]
        self.answer = answer
        self.received = threading.Event()
        self.queries = queue.Queue()
        self.closed = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while not self.closed.is_set():
            try:
                query, peer = self.socket.recvfrom(4096)
                self.received.set()
                self.queries.put(query)
                if not self.answer or len(query) < 17:
                    continue
                offset = 12
                while offset < len(query) and query[offset]:
                    offset += query[offset] + 1
                offset += 5
                if offset > len(query):
                    continue
                header = query[:2] + struct.pack("!5H", 0x8180, 1, 1, 0, 0)
                answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + socket.inet_aton("127.0.0.1")
                self.socket.sendto(header + query[12:offset] + answer, peer)
            except socket.timeout:
                continue
            except OSError:
                return

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.closed.set()
        self.socket.close()
        self.thread.join(timeout=0.3)

    def wait_for_queries(self, count, deadline):
        end = time.monotonic() + deadline.remaining(2)
        for received in range(count):
            try:
                self.queries.get(timeout=max(0.001, end - time.monotonic()))
            except queue.Empty:
                raise CheckFailure("Concurrent DNS requests did not reach the loopback fixture: "
                                   "received %d of %d UDP queries within two seconds" % (received, count))


def check_offline(server, deadline):
    with MCPProcess(server, deadline) as client:
        check(client.initialize()["protocolVersion"] == "2025-11-25", "Wrong negotiated protocol version")
        listing = client.result("tools/list")
        tools = listing["tools"]
        check({tool["name"] for tool in tools} == OFFLINE_TOOLS, "Default tools expose network operations or omit offline tools")
        check(len(tools) == len(OFFLINE_TOOLS), "Duplicate tool names")
        for tool in tools:
            check(tool["inputSchema"].get("type") == "object", "Invalid tool input schema")
            check(tool["inputSchema"].get("additionalProperties") is False, "Tool schema permits unknown parameters")

        for cidr, expected in [
            ("192.168.1.27/24", {
                "cidr": "192.168.1.0/24", "prefix": 24, "network": "192.168.1.0",
                "mask": "255.255.255.0", "wildcard": "0.0.0.255", "broadcast": "192.168.1.255",
                "firstHost": "192.168.1.1", "lastHost": "192.168.1.254",
                "usableHostCount": 254, "totalAddressCount": 256,
            }),
            ("192.0.2.11/31", {
                "cidr": "192.0.2.10/31", "prefix": 31, "network": "192.0.2.10",
                "mask": "255.255.255.254", "wildcard": "0.0.0.1", "broadcast": "192.0.2.11",
                "firstHost": "192.0.2.10", "lastHost": "192.0.2.11",
                "usableHostCount": 2, "totalAddressCount": 2,
            }),
            ("192.0.2.11/32", {
                "cidr": "192.0.2.11/32", "prefix": 32, "network": "192.0.2.11",
                "mask": "255.255.255.255", "wildcard": "0.0.0.0", "broadcast": "192.0.2.11",
                "firstHost": "192.0.2.11", "lastHost": "192.0.2.11",
                "usableHostCount": 1, "totalAddressCount": 1,
            }),
        ]:
            subnet = tool_data(client.call("subnet_info", {"cidr": cidr}))
            for key, value in expected.items():
                check(subnet.get(key) == value, "Incorrect subnet " + key + " for " + cidr)
        interfaces = tool_data(client.call("network_interfaces", {"includeLoopback": True}))
        check("127.0.0.1" in json.dumps(interfaces), "Interface inventory omitted IPv4 loopback")
        port = tool_data(client.call("port_lookup", {"port": 443}))
        check("https" in json.dumps(port).lower(), "Bundled port database did not resolve HTTPS")
        vendor = tool_data(client.call("mac_vendor_lookup", {"mac": "E8:0A:B9:00:00:01"}))
        check("cisco" in json.dumps(vendor).lower(), "Bundled OUI database did not resolve known Cisco prefix")

        for name, arguments in [
            ("subnet_info", {}), ("subnet_info", {"cidr": "192.168.1.0/33"}),
            ("subnet_info", {"cidr": "192.168.1.0/24", "unexpected": True}),
            ("port_lookup", {"port": "443"}), ("port_lookup", {"port": 65536}),
            ("port_lookup", {"port": True}), ("mac_vendor_lookup", {"mac": "xyz"}),
            ("network_interfaces", {"includeLoopback": "true"}),
        ]:
            invalid = tool_data(client.call(name, arguments), error=True)
            check(invalid.get("error", {}).get("code") == "invalid_arguments", "Invalid input omitted its error code")
        disabled = client.request("tools/call", {"name": "tcp_probe", "arguments": {"host": "127.0.0.1", "port": 1}})
        check("error" in disabled or disabled.get("result", {}).get("isError") is True, "Network calls bypassed opt-in")

        resources = client.result("resources/list")["resources"]
        check({resource["uri"] for resource in resources} == RESOURCE_URIS, "Unexpected resource inventory")
        for uri in RESOURCE_URIS:
            contents = client.result("resources/read", {"uri": uri})["contents"]
            check(contents and contents[0]["uri"] == uri and contents[0].get("text"), "Resource read returned no matching text")
            if uri.endswith("server-info"):
                check(contents[0].get("mimeType") == "application/json", "Server info must have JSON MIME type")
                json.loads(contents[0]["text"])
            else:
                check(contents[0].get("mimeType") == "text/markdown", "Usage must have Markdown MIME type")

        for method, params in [
            ("does/not/exist", {}), ("resources/read", {"uri": "file:///etc/passwd"}),
            ("tools/call", {"name": "does_not_exist", "arguments": {}}),
        ]:
            response = client.request(method, params)
            check("error" in response and isinstance(response["error"].get("code"), int), "Unknown request was not a JSON-RPC error")
        client.send_raw(b"{invalid-json")
        malformed = client.receive()
        check(malformed.get("error", {}).get("code") == -32700, "Malformed JSON did not produce parse error")
        identifier = client.begin("ping", request_id="string-request-id")
        check(client.response(identifier).get("result") == {}, "Session did not recover after invalid requests")
        client.eof()
    print("PASS: default capabilities, offline tools, /24 /31 /32 subnets, strict inputs, resources, protocol errors, EOF")


def check_network(server, deadline):
    with MCPProcess(server, deadline, "--allow-network") as client:
        client.initialize()
        names = {tool["name"] for tool in client.result("tools/list")["tools"]}
        check(names == OFFLINE_TOOLS | NETWORK_TOOLS, "Network opt-in did not expose expected tools")
        ping = tool_data(client.call("ping", {"host": "127.0.0.1", "timeout": 0.5}))
        check(ping["status"] == "succeeded", "ICMP loopback probe failed")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(4)
            port = listener.getsockname()[1]
            result = tool_data(client.call("tcp_probe", {"host": "127.0.0.1", "port": port, "timeout": 0.5}))
            check(result["status"] == "succeeded", "TCP loopback probe failed")
        closed = tool_data(client.call("tcp_probe", {"host": "127.0.0.1", "port": port, "timeout": 0.5}), error=True)
        check(closed["status"] == "failed", "Closed TCP port was not reported as a failed probe")

        with DNSFixture() as fixture:
            result = tool_data(client.call("dns_lookup", {
                "host": "fixture.test", "recordType": "A", "server": "127.0.0.1",
                "serverPort": fixture.port, "timeout": 0.5,
            }))
            check(result["status"] == "succeeded" and "127.0.0.1" in json.dumps(result), "Loopback DNS fixture failed")
        with DNSFixture(answer=False) as fixture:
            started = time.monotonic()
            result = tool_data(client.call("dns_lookup", {
                "host": "timeout.test", "server": "127.0.0.1", "serverPort": fixture.port, "timeout": 0.1,
            }, timeout=2), error=True)
            check(result["status"] == "timedOut", "Unanswered DNS query was not reported as timed out")
            check(time.monotonic() - started < 1.5, "DNS timeout was not bounded")
        for name, arguments in [
            ("ping", {"host": "-c100"}), ("ping", {"host": "127.0.0.1\nlocalhost"}),
            ("ping", {"host": "127.0.0.1;touch /tmp/nmcp-injection"}),
            ("tcp_probe", {"host": "127.0.0.1", "port": 0}),
            ("tcp_probe", {"host": "127.0.0.1", "port": 22, "timeout": 6}),
            ("dns_lookup", {"host": "fixture.test", "recordType": "INVALID"}),
        ]:
            invalid = tool_data(client.call(name, arguments), error=True)
            check(invalid.get("error", {}).get("code") == "invalid_arguments", "Invalid input omitted its error code")

        with DNSFixture(answer=False) as fixture:
            identifier = client.begin("tools/call", {"name": "dns_lookup", "arguments": {
                "host": "cancel.test", "server": "127.0.0.1", "serverPort": fixture.port, "timeout": 5,
            }})
            check(fixture.received.wait(deadline.remaining(2)), "Cancellation fixture never received DNS query")
            client.notify("notifications/cancelled", {"requestId": identifier, "reason": "integration test"})
            cancelled = client.response(identifier, timeout=2)
            if "error" not in cancelled:
                result = tool_data(cancelled["result"], error=True)
                check(result["status"] == "cancelled", "Cancellation did not propagate to diagnostic task")
            tool_data(client.call("subnet_info", {"cidr": "10.0.0.1/32"}, timeout=1))

        # Saturate the documented diagnostic limit using pending local DNS
        # queries, then verify cancellation releases every occupied slot.
        with DNSFixture(answer=False) as fixture:
            identifiers = [client.begin("tools/call", {"name": "dns_lookup", "arguments": {
                "host": "busy-%d.test" % number, "server": "127.0.0.1",
                "serverPort": fixture.port, "timeout": 5,
            }}) for number in range(4)]
            try:
                fixture.wait_for_queries(4, deadline)
            except CheckFailure as error:
                raise CheckFailure(str(error) + "; MCP state: " + client.response_snapshot(identifiers)) from error
            busy = tool_data(client.call("tcp_probe", {"host": "127.0.0.1", "port": 1, "timeout": 0.1}, timeout=1), error=True)
            check(busy.get("error", {}).get("code") == "busy", "Fifth concurrent diagnostic was not rejected as busy")
            for identifier in identifiers:
                client.notify("notifications/cancelled", {"requestId": identifier, "reason": "release integration fixture"})
            for identifier in identifiers:
                client.response(identifier, timeout=2)
        with DNSFixture() as fixture:
            resumed = tool_data(client.call("dns_lookup", {
                "host": "resumed.test", "server": "127.0.0.1", "serverPort": fixture.port, "timeout": 0.5,
            }))
            check(resumed["status"] == "succeeded", "Cancellation did not release diagnostic capacity")
        client.eof()
    with MCPProcess(server, deadline, "--allow-network") as client, DNSFixture(answer=False) as fixture:
        client.initialize()
        client.begin("tools/call", {"name": "dns_lookup", "arguments": {
            "host": "eof.test", "server": "127.0.0.1", "serverPort": fixture.port, "timeout": 5,
        }})
        check(fixture.received.wait(deadline.remaining(2)), "EOF fixture never received its pending DNS query")
        client.eof()
    print("PASS: opt-in, local ICMP/TCP/DNS, strict inputs, timeout, cancellation, concurrency bound, pending DNS EOF")


def check_corrupt_preferences(server, deadline):
    # The first diagnostic initializes localization and reads application
    # preferences. Invalid JSON must neither deadlock that initialization nor
    # cause a read-only MCP process to rewrite the caller's existing settings.
    original = b'{"language": invalid-json\x00\r\n'
    with MCPProcess(server, deadline, "--allow-network", settings_bytes=original) as client:
        client.initialize()
        result = tool_data(client.call("ping", {"host": "127.0.0.1", "timeout": 0.5}))
        check(result["status"] == "succeeded", "Corrupt preferences prevented the first localized diagnostic")
        client.eof()
    print("PASS: corrupt settings initialization, localized diagnostic, original settings bytes preserved, no added JSON")


def run_cli(server, argument, deadline, timeout=2, environment_overrides=None):
    with tempfile.TemporaryDirectory(prefix="nmcp-cli-integration-") as directory:
        result = subprocess.run([str(server), argument], capture_output=True,
                                timeout=deadline.remaining(timeout),
                                env=isolated_environment(directory, environment_overrides))
        check_no_persisted_json(directory)
        return result


def check_versions_and_cli(server, deadline):
    for requested, expected in [("2024-11-05", "2024-11-05"), ("2099-01-01", "2025-11-25")]:
        with MCPProcess(server, deadline) as client:
            result = client.initialize(requested)
            check(result["protocolVersion"] == expected, "Unsupported protocol negotiation behavior")
            client.result("ping")
            client.eof()
    with MCPProcess(server, deadline) as client:
        client.eof()
    for argument in ["--help", "--version"]:
        result = run_cli(server, argument, deadline)
        check(result.returncode == 0 and result.stdout.strip(), argument + " did not return useful output")
    result = run_cli(server, "--unknown-flag", deadline)
    check(result.returncode != 0, "Unknown command-line options were silently accepted")
    print("PASS: old version, fallback, empty stdin, help, version, invalid CLI options")


def check_launcher(launcher, deadline):
    # Start with a queued initialize request, as a real MCP client does. The
    # warm launcher must preserve stdin and its four-second handshake budget,
    # keep stdout valid JSON-RPC, and avoid SwiftPM entirely: even asking Swift
    # for its binary path can wait on another build's package lock.
    with tempfile.TemporaryDirectory(prefix="nmcp-launcher-path-") as directory:
        swift = Path(directory) / "swift"
        swift.write_text('#!/bin/sh\n: > "$0.called"\nprintf "%s\\n" "Unexpected SwiftPM invocation during warm MCP launch" >&2\nexit 91\n')
        swift.chmod(0o755)
        environment = {"PATH": directory + os.pathsep + os.environ.get("PATH", os.defpath)}
        with MCPProcess(launcher, deadline, environment_overrides=environment) as client:
            check(client.initialize()["protocolVersion"] == "2025-11-25", "Launcher handshake negotiated an unexpected version")
            tools = client.result("tools/list")["tools"]
            check(len(tools) == len(OFFLINE_TOOLS) and {tool["name"] for tool in tools} == OFFLINE_TOOLS,
                  "Launcher changed the default offline tool inventory")
            subnet = tool_data(client.call("subnet_info", {"cidr": "192.0.2.11/31"}))
            check(subnet["cidr"] == "192.0.2.10/31" and subnet["usableHostCount"] == 2,
                  "Tool call through launcher returned an incorrect subnet")
            client.eof()
        for argument in ["--help", "--version"]:
            result = run_cli(launcher, argument, deadline, timeout=4, environment_overrides=environment)
            check(result.returncode == 0 and result.stdout.strip(), "Launcher " + argument + " did not return useful output")
        check(not swift.with_name("swift.called").exists(), "Warm launcher invoked SwiftPM")
    print("PASS: warm launcher without SwiftPM, handshake within 4 seconds, offline inventory, subnet, protocol stdout, EOF, CLI")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True, type=Path, help="Path to the prebuilt NMCP executable")
    parser.add_argument("--launcher", type=Path, help="Optional run-mcp.sh entry point; its selected configuration must already be built")
    arguments = parser.parse_args()
    server = arguments.server.expanduser().resolve()
    if not server.is_file() or not os.access(server, os.X_OK):
        parser.error("--server must point to a built executable")
    launcher = arguments.launcher.expanduser().resolve() if arguments.launcher else None
    if launcher and (not launcher.is_file() or not os.access(launcher, os.X_OK)):
        parser.error("--launcher must point to an executable launcher script")
    deadline = Deadline(30)
    try:
        check_offline(server, deadline)
        check_network(server, deadline)
        check_corrupt_preferences(server, deadline)
        check_versions_and_cli(server, deadline)
        if launcher:
            check_launcher(launcher, deadline)
    except (CheckFailure, OSError, subprocess.TimeoutExpired, ValueError, KeyError) as error:
        print("MCP integration FAILED: " + str(error), file=sys.stderr)
        return 1
    print("MCP integration: all checks passed (loopback only; temporary support directories; no persisted JSON)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
