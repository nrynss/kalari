#!/usr/bin/env python3
"""Load the served pages in a headless browser and list every request they make.

    python3 web/fixture/browser_check.py

This is a development tool, not part of web/check.sh. The gate must not need a
browser. The script starts the fixture server on loopback, starts headless
Chrome with its DevTools pipe, and drives one page tab over the pipe. It reads
the requests the page itself makes with the DevTools Network domain. The
browser's own background traffic never reaches that domain, so no host is
subtracted from the result.

Any request whose host is not the page's own loopback origin fails. A popup is
a second page target, so any page target outside that origin fails too. A top
level navigation and a meta refresh change the page's own URL, so they fail as
well.

Every served page that runs a module is loaded: the three shells, the
walkthrough session, a benchmark session and the illustrative run page. The
rendered snapshots cannot be loaded here, because the fixture server does not
serve them. The static scan and the snapshot checks in web/check.py cover every
other state.
"""

from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHROME_CANDIDATES = (
    "google-chrome-stable",
    "google-chrome",
    "chromium",
    "chromium-browser",
    "chrome",
)
PAGES = (
    ("/", "For judges: start here."),
    ("/session.html?id=payouts-upgrade", "Upgrading the payout ledger"),
    ("/run.html?id=pilot-c3-payouts-r5", "Pilot run: Merchant payout ledger"),
    ("/run.html?id=payouts-attempt-1", "This run shows the shape of the evidence"),
    ("/session.html?id=pilot-c3-payouts", "Benchmark measures"),
)
FLAGS = (
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--disable-extensions",
    "--disable-popup-blocking",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-client-side-phishing-detection",
    "--disable-domain-reliability",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-sync",
    "--metrics-recording-only",
    "--no-pings",
    "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
    "--remote-debugging-pipe",
)
LOOPBACK = ("127.0.0.1", "localhost", "::1")


class Failure(Exception):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def find_browser() -> str:
    for name in CHROME_CANDIDATES:
        path = shutil.which(name)
        if path:
            return path
    raise Failure("no headless browser was found")


class Chrome:
    """One headless Chrome process, driven over the DevTools pipe on fd 3 and 4."""

    def __init__(self, browser: str, profile: Path) -> None:
        from_browser, to_browser = os.pipe()
        from_child, to_child = os.pipe()
        saved: dict[int, int | None] = {}
        for fd in (3, 4):
            try:
                saved[fd] = os.dup(fd)
            except OSError:
                saved[fd] = None
        os.dup2(from_browser, 3)
        os.dup2(to_child, 4)
        try:
            self.proc = subprocess.Popen(
                [browser, *FLAGS, f"--user-data-dir={profile}", "about:blank"],
                pass_fds=(3, 4),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        finally:
            os.close(from_browser)
            os.close(to_child)
            for fd, copy in saved.items():
                if copy is None:
                    os.close(fd)
                else:
                    os.dup2(copy, fd)
                    os.close(copy)
        self.read = from_child
        self.write = to_browser
        self.buffer = b""
        self.ident = 0
        self.events: list[dict] = []

    def send(self, method: str, params: dict | None = None, session: str | None = None) -> int:
        self.ident += 1
        message = {"id": self.ident, "method": method, "params": params or {}}
        if session:
            message["sessionId"] = session
        os.write(self.write, json.dumps(message).encode("utf-8") + b"\0")
        return self.ident

    def _pump(self, timeout: float) -> bool:
        ready, _, _ = select.select([self.read], [], [], timeout)
        if not ready:
            return False
        chunk = os.read(self.read, 1 << 20)
        if not chunk:
            return False
        self.buffer += chunk
        return True

    def _messages(self) -> list[dict]:
        messages: list[dict] = []
        while b"\0" in self.buffer:
            line, self.buffer = self.buffer.split(b"\0", 1)
            messages.append(json.loads(line))
        return messages

    def call(self, method: str, params: dict | None = None, session: str | None = None, timeout: float = 20.0):
        ident = self.send(method, params, session)
        deadline = time.time() + timeout
        while time.time() < deadline:
            for message in self._messages():
                if message.get("id") == ident:
                    check("error" not in message, f"{method} failed: {message.get('error')}")
                    return message.get("result", {})
                self.events.append(message)
            self._pump(0.25)
        raise Failure(f"the browser did not answer {method}")

    def drain(self, seconds: float) -> None:
        deadline = time.time() + seconds
        while time.time() < deadline:
            if self._pump(0.25):
                self.events.extend(self._messages())

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        os.close(self.read)
        os.close(self.write)


def start_server() -> tuple[subprocess.Popen[str], str]:
    process = subprocess.Popen(
        [sys.executable, str(HERE / "server.py"), "--port", "0"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    assert process.stdout is not None
    ready, _, _ = select.select([process.stdout], [], [], 10)
    line = process.stdout.readline().strip() if ready else ""
    if line.startswith("http://"):
        return process, line.rstrip("/")
    process.terminate()
    raise Failure("the fixture server did not print a loopback address")


def origin(url: str) -> tuple[str, str, int | None]:
    parts = urllib.parse.urlsplit(url)
    port = parts.port or (443 if parts.scheme == "https" else 80)
    return (parts.scheme, parts.hostname or "", port)


def attach(chrome: Chrome) -> str:
    targets = chrome.call("Target.getTargets")["targetInfos"]
    page = next((target for target in targets if target["type"] == "page"), None)
    check(page is not None, "the browser has no page target")
    return chrome.call("Target.attachToTarget", {"targetId": page["targetId"], "flatten": True})["sessionId"]


def load(chrome: Chrome, session: str, base: str, path: str, expected: str) -> tuple[list[str], list[str]]:
    chrome.events.clear()
    chrome.call("Page.navigate", {"url": base + path}, session=session, timeout=30)
    chrome.drain(3.0)
    requests = [
        event["params"]["request"]["url"]
        for event in chrome.events
        if event.get("method") == "Network.requestWillBeSent"
    ]
    targets = chrome.call("Target.getTargets")["targetInfos"]
    page_urls = [target.get("url", "") for target in targets if target["type"] == "page"]
    document = chrome.call(
        "Runtime.evaluate",
        {"expression": "document.URL + '\\n' + (document.body ? document.body.innerText : '')", "returnByValue": True},
        session=session,
    )
    value = document.get("result", {}).get("value", "")
    check(expected in value, f"the page {path} did not render {expected!r}")
    return requests, page_urls


def external_urls(urls: list[str], own: tuple[str, str, int | None]) -> list[str]:
    outside: list[str] = []
    for url in urls:
        parts = urllib.parse.urlsplit(url)
        if parts.scheme not in ("http", "https"):
            continue
        if origin(url) != own:
            outside.append(url)
    return sorted(set(outside))


def main() -> int:
    browser = find_browser()
    process, base = start_server()
    own = origin(base + "/")
    check(own[1] in LOOPBACK, f"the fixture server is not on loopback: {base}")
    work = Path("/tmp/opencode")
    profile = work / f"kalari-browser-{os.getpid()}"
    shutil.rmtree(profile, ignore_errors=True)
    chrome = Chrome(browser, profile)
    print(f"browser check on {base} with {Path(browser).name}")
    try:
        session = attach(chrome)
        chrome.call("Network.enable", session=session)
        chrome.call("Page.enable", session=session)
        chrome.call("Target.setDiscoverTargets", {"discover": True})
        for path, expected in PAGES:
            requests, page_urls = load(chrome, session, base, path, expected)
            outside = external_urls(requests + page_urls, own)
            check(not outside, f"the page {path} left its origin: {', '.join(outside[:4])}")
            same = [url for url in requests if origin(url) == own]
            print(f"  {path}: {len(same)} same-origin request(s), no other host, and the page rendered")
    finally:
        chrome.close()
        shutil.rmtree(profile, ignore_errors=True)
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    print("browser check passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Failure as error:
        print(f"browser check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
