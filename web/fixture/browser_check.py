#!/usr/bin/env python3
"""Load the served pages in a headless browser and list every request host.

    python3 web/fixture/browser_check.py

This is a development tool, not part of web/check.sh. The gate must not need a
browser. The script starts the fixture server on loopback, loads the three
published pages in headless Chrome, and reads every request URL from Chrome's
network log. Chrome makes its own background requests, so the script records a
baseline on about:blank and subtracts those hosts. Any remaining host that is
not loopback is a request the page made, and the script fails.

The pages carry `default-src 'self'` and the fixture server sends the same
policy as a header. The browser test is the runtime evidence for that static
rule.
"""

from __future__ import annotations

import json
import secrets
import select
import shutil
import subprocess
import sys
import tempfile
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
)
FLAGS = (
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--disable-background-networking",
    "--disable-component-update",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-sync",
    "--metrics-recording-only",
    "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
    "--virtual-time-budget=4000",
)


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


def load(browser: str, url: str, work: Path) -> tuple[str, set[str]]:
    name = secrets.token_hex(4)
    profile = work / f"profile-{name}"
    netlog = work / f"netlog-{name}.json"
    result = subprocess.run(
        [
            browser,
            *FLAGS,
            f"--user-data-dir={profile}",
            f"--log-net-log={netlog}",
            "--net-log-capture-mode=IncludeSensitive",
            "--dump-dom",
            url,
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    check(netlog.is_file(), f"the browser wrote no network log for {url}")
    return result.stdout, urls_in_netlog(netlog)


def urls_in_netlog(path: Path) -> set[str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    urls: set[str] = set()

    def walk(value) -> None:
        if isinstance(value, dict):
            for key, item in value.items():
                if key == "url" and isinstance(item, str) and item.startswith("http"):
                    urls.add(item)
                else:
                    walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    walk(data)
    return urls


def hosts(urls: set[str]) -> set[str]:
    result: set[str] = set()
    for url in urls:
        host = urllib.parse.urlsplit(url).hostname
        if host:
            result.add(host)
    return result


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
        return process, line
    process.terminate()
    raise Failure("the fixture server did not print a loopback address")


def main() -> int:
    browser = find_browser()
    process, base = start_server()
    print(f"browser check on {base} with {Path(browser).name}")
    temp_root = Path("/tmp/opencode")
    work = Path(
        tempfile.mkdtemp(
            prefix="kalari-browser-",
            dir=str(temp_root) if temp_root.is_dir() else None,
        )
    )
    try:
        background: set[str] = set()
        for _ in range(2):
            _dom, baseline_urls = load(browser, "about:blank", work)
            background |= hosts(baseline_urls)
        print(f"  the browser made {len(background)} background host(s): {', '.join(sorted(background)) or 'none'}")
        for path, expected in PAGES:
            dom, urls = load(browser, base.rstrip("/") + path, work)
            external = hosts(urls) - background - {"127.0.0.1", "localhost", "::1"}
            check(not external, f"the page {path} requested {', '.join(sorted(external))}")
            check(expected in dom, f"the page {path} did not render {expected!r}")
            same_origin = [url for url in urls if urllib.parse.urlsplit(url).hostname in ("127.0.0.1", "localhost")]
            print(f"  {path}: {len(same_origin)} same-origin request(s), no other host, and the page rendered")
    finally:
        shutil.rmtree(work, ignore_errors=True)
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
