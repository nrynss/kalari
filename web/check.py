#!/usr/bin/env python3
"""Verify the Chaaya pages, the fixture store and the served static files.

The app is plain ES modules. This check is Python standard library only. It
starts the fixture server on loopback, reads the served pages, parses the
committed rendered snapshots from disk, and verifies that every served file
has a sha256. The snapshots are produced by the same view code the browser
runs. The fixture server never serves a snapshot.

    ./web/check.sh
"""

from __future__ import annotations

import hashlib
import html as html_module
import json
import re
import select
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path

from fixture.validate import (
    envelope_errors,
    looks_like_benchmark,
    validate_benchmark_record,
    validate_benchmark_records,
)

REPO = Path(__file__).resolve().parent.parent
WEB = REPO / "web"
SITE = WEB / "site"
FIXTURE = WEB / "fixture"
RENDERED = FIXTURE / "rendered"
MANIFEST = RENDERED / "manifest.json"
INPUTS = RENDERED / "inputs.json"
EVIDENCE = FIXTURE / "evidence.jsonl"

PAGES = (
    "judges",
    "judges-empty",
    "judges-no-store",
    "judges-extra-run",
    "judges-frozen-after",
    "judges-frozen-pair",
    "judges-frozen-split",
    "session",
    "session-showcase",
    "session-frozen",
    "session-redaction",
    "run",
    "run-showcase",
    "run-frozen",
    "run-illustrative",
    "run-containment",
    "run-containment-earlier",
    "run-endpoint",
    "run-redaction",
    "run-reference",
)
JUDGES_PAGES = tuple(name for name in PAGES if name.startswith("judges"))
SESSION_PAGES = ("session", "session-showcase", "session-frozen", "session-redaction")
RUN_PAGES = ("run", "run-showcase", "run-frozen", "run-illustrative", "run-containment", "run-containment-earlier", "run-endpoint", "run-redaction", "run-reference")
SHELLS = ("index.html", "session.html", "run.html")

ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
NUMBER_RE = re.compile(r"(?<![A-Za-z0-9])[0-9][0-9,.]*(?![A-Za-z0-9])")
PERCENT_RE = re.compile(r"[0-9]+(?:[.,][0-9]+)?\s*%")
PROBABILITY_TEXT_RE = re.compile(r"^[0-9]+(?:\.[0-9])?%$")
DECIMAL_RE = re.compile(r"(?<![\w$.])[0-9]*\.[0-9]+(?![\w%])")
IPV4_RE = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
HTTP_RE = re.compile(r"https?://", re.IGNORECASE)
SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
QUOTED_PROTOCOL_RELATIVE_RE = re.compile(r"""["'`](?:https?:)?//""", re.IGNORECASE)
PROTOCOL_RELATIVE_TEXT_RE = re.compile(r"(?<![:/])//[A-Za-z0-9]")
SVG_NAMESPACE = "http://www.w3.org/2000/svg"
URL_ATTRIBUTES = {
    "href",
    "src",
    "srcset",
    "action",
    "formaction",
    "poster",
    "data",
    "cite",
    "background",
    "longdesc",
    "usemap",
    "profile",
    "manifest",
}
SECRET_RES = [
    re.compile(r"(?i)api[_-]?key"),
    re.compile(r"(?i)bearer\s"),
    re.compile(r"BEGIN [A-Z ]*PRIVATE KEY"),
    re.compile(r"ssh-(?:rsa|ed25519)"),
    re.compile(r"(?i)vultr[_-]?inference[_-]?api[_-]?key"),
]
# The single external prefix the judges page may link. Every evidence figure
# links its raw file on GitHub, pinned to EVIDENCE_REF. Top-level navigation
# stays on the page origin, so default-src 'self' does not change.
GITHUB_PREFIX = "https://github.com/nrynss/kalari/"
GITHUB_LINK_RE = re.compile(r"https://github\.com/nrynss/kalari/[^\s<>\"']+")


def github_allowed(token: str) -> bool:
    return token == GITHUB_PREFIX.rstrip("/") or token.startswith(GITHUB_PREFIX)
EVIDENCE_REF_RE = re.compile(r'export const EVIDENCE_REF = "([0-9a-f]{40})"')
MODEL_TAGS = {
    "OpenCode 2.2.5",
    "DeepSeek V4.1 Flash",
    "GLM 5.3 Flash",
    "Qwen3.8 27B",
    "Muse Glimmer 30B",
    "MiMo V2.6 Flash",
}
SHOWCASE_MODELS = ["GLM 5.3 Flash", "Qwen3.8 27B", "Muse Glimmer 30B", "MiMo V2.6 Flash", "DeepSeek V4.1 Flash"]
CSP_REQUIRED = ("default-src 'self'", "connect-src 'self'")
HEADINGS = {"h1", "h2", "h3", "h4", "h5", "h6"}
# A served module must not open, assign or navigate a browsing context. None of
# these has a use in this app, and the CSP does not block navigation.
JAVASCRIPT_SINKS = (
    (re.compile(r"\b(?:window|self|top|parent)\s*\.\s*open\s*\("), "script opens a new browsing context"),
    (
        re.compile(r"\b(?:window\s*\.\s*)?(?:document\s*\.\s*)?location(?:\s*\.\s*href)?\s*=(?!=)"),
        "script assigns to location",
    ),
    (
        re.compile(r"\blocation\s*\.\s*(?:assign|replace|reload)\s*\("),
        "script navigates with location",
    ),
    (re.compile(r"(?<![\w.])eval\s*\("), "script evaluates a string as code"),
    (re.compile(r"\b(?:window|self|top|parent)\s*\.\s*eval\s*\("), "script evaluates a string as code"),
    (re.compile(r"\bdocument\s*\.\s*(?:write|writeln)\s*\("), "script writes into the document"),
    (re.compile(r"\bnew\s+Function\s*\("), "script builds a function from a string"),
)
# Each display path that shows a store string carries one URL in the redaction
# snapshots. The count proves the check covers every path. The paths are stdout,
# stderr, command, check detail, check id, lesson, lesson check, grader log,
# grade note, source, session note, session summary, change title, change
# endpoint, call site, radius note, workspace and decision question.
REDACTION_PAGES = {"run-redaction": 13, "session-redaction": 18, "run-endpoint": 1}



class Failure(Exception):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def say(message: str) -> None:
    print(f"  {message}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def walk_files(directory: Path) -> list[Path]:
    if not directory.is_dir():
        return []
    return sorted(path for path in directory.rglob("*") if path.is_file())


def read_page(name: str) -> str:
    path = RENDERED / f"{name}.html"
    check(path.is_file(), f"the rendered snapshot {name} is missing. run `node web/fixture/render.mjs`")
    return path.read_text(encoding="utf-8")


class Server:
    def __init__(self, *args: str) -> None:
        self.args = args
        self.proc: subprocess.Popen[str] | None = None
        self.base = ""

    def __enter__(self) -> "Server":
        self.proc = subprocess.Popen(
            [sys.executable, str(FIXTURE / "server.py"), "--port", "0", *self.args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        assert self.proc.stdout is not None
        ready, _, _ = select.select([self.proc.stdout], [], [], 5.0)
        line = self.proc.stdout.readline().strip() if ready else ""
        if not line.startswith("http://"):
            self.__exit__(None, None, None)
            raise Failure("the fixture server did not print a loopback address")
        self.base = line
        check(self.base.startswith("http://127.0.0.1:"), f"fixture server is not loopback: {self.base}")
        say(f"fixture server on {self.base}")
        return self

    def __exit__(self, *_exc) -> None:
        if self.proc is None:
            return
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        self.proc = None


def request(base: str, path: str, method: str = "GET", data: bytes | None = None):
    url = base.rstrip("/") + path
    req = urllib.request.Request(url, method=method, data=data)
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, response.read(), response.headers.get_content_type(), dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, error.read(), error.headers.get_content_type(), dict(error.headers)


def get_text(base: str, path: str) -> str:
    status, body, content_type, _headers = request(base, path)
    check(status == 200, f"GET {path} answered {status}, expected 200")
    check(
        "text" in (content_type or "") or "javascript" in (content_type or ""),
        f"GET {path} has an unexpected content type: {content_type}",
    )
    return body.decode("utf-8")


def get_json(base: str, path: str):
    status, body, content_type, _headers = request(base, path)
    check(status == 200, f"GET {path} answered {status}, expected 200")
    check("json" in (content_type or ""), f"GET {path} is not JSON: {content_type}")
    try:
        return json.loads(body)
    except json.JSONDecodeError as error:
        raise Failure(f"GET {path} did not return valid JSON: {error}") from error


def id_path(base: str, kind: str, value: str) -> str:
    return f"/api/{kind}/{urllib.parse.quote(value, safe='')}"


def run_id_from_href(href: str) -> str | None:
    parts = urllib.parse.urlsplit(href or "")
    if not parts.path.endswith("run.html"):
        return None
    values = urllib.parse.parse_qs(parts.query).get("id")
    if not values or not values[0]:
        return None
    return values[0]


def session_id_from_href(href: str) -> str | None:
    parts = urllib.parse.urlsplit(href or "")
    if not parts.path.endswith("session.html"):
        return None
    values = urllib.parse.parse_qs(parts.query).get("id")
    if not values or not values[0]:
        return None
    return values[0]


class ExternalHTMLParser(HTMLParser):
    """Find external URLs in attributes or text after entity decoding."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.problems: list[str] = []
        self.stack: list[str] = []

    def _check_url(self, name: str, value: str) -> None:
        value = html_module.unescape(value).strip()
        if not value or value.startswith("#"):
            return
        if value.startswith(GITHUB_PREFIX):
            return
        if value.startswith("//"):
            self.problems.append(f"{name} is protocol relative: {value}")
            return
        if HTTP_RE.search(value):
            self.problems.append(f"{name} is external: {value}")
            return
        match = SCHEME_RE.match(value)
        if match and not match.group(0).lower().startswith("data:"):
            self.problems.append(f"{name} has an external scheme: {value}")

    def _check_srcset(self, name: str, value: str) -> None:
        for part in value.split(","):
            candidate = part.strip().split(" ")[0]
            self._check_url(name, candidate)

    def _check_style(self, value: str) -> None:
        for match in re.finditer(r"url\(\s*(['\"]?)(.*?)\1\s*\)", value, re.IGNORECASE | re.DOTALL):
            self._check_url("style url", match.group(2))
        if HTTP_RE.search(value):
            self.problems.append(f"style is external: {value}")

    def handle_starttag(self, tag: str, attrs) -> None:
        for name, value in attrs:
            if value is None:
                continue
            if name == "xmlns" or name.startswith("xmlns:"):
                if html_module.unescape(value).strip() == SVG_NAMESPACE:
                    continue
                self._check_url(name, value)
                continue
            if tag == "meta" and name == "http-equiv" and html_module.unescape(value).strip().lower() == "refresh":
                self.problems.append("meta refresh can navigate the page away from its origin")
                continue
            if name in URL_ATTRIBUTES:
                if name == "srcset":
                    self._check_srcset(name, value)
                else:
                    self._check_url(name, value)
            elif name == "style":
                self._check_style(value)
            elif name.startswith("on"):
                self.problems.extend(scan_javascript(value))
                if HTTP_RE.search(value):
                    self.problems.append(f"{name} is external: {value}")
        self.stack.append(tag)

    def handle_endtag(self, tag: str) -> None:
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index] == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        if "script" in self.stack:
            self.problems.extend(scan_javascript(data))
            return
        if "style" in self.stack:
            self.problems.extend(scan_css(data))
            return
        for match in HTTP_RE.finditer(data):
            tail = data[match.start():]
            token = re.split(r'[\s<>"\'()]+', tail, maxsplit=1)[0]
            if github_allowed(token):
                continue
            self.problems.append(f"text is external: {data.strip()[:120]}")
            break
        if PROTOCOL_RELATIVE_TEXT_RE.search(data):
            self.problems.append(f"text is protocol relative: {data.strip()[:120]}")


def scan_html(text: str) -> list[str]:
    parser = ExternalHTMLParser()
    parser.feed(text)
    return parser.problems


def scan_svg(text: str) -> list[str]:
    problems: list[str] = []
    for match in re.finditer(r'\b(xmlns|href|src|xlink:href)\s*=\s*"([^"]*)"', text, re.IGNORECASE):
        name = match.group(1)
        value = html_module.unescape(match.group(2)).strip()
        if name == "xmlns" and value == SVG_NAMESPACE:
            continue
        if value.startswith("#"):
            continue
        if value.startswith(GITHUB_PREFIX):
            continue
        if value.startswith("//") or HTTP_RE.search(value):
            problems.append(f"{name} is external: {value}")
    for match in HTTP_RE.finditer(text):
        tail = text[match.start() : match.start() + len(SVG_NAMESPACE)]
        if tail != SVG_NAMESPACE:
            token = re.split(r'[\s<>"\'()]+', text[match.start():], maxsplit=1)[0]
            if github_allowed(token):
                continue
            problems.append("raw external URL in SVG")
    return problems


def scan_css(text: str) -> list[str]:
    problems: list[str] = []
    for match in re.finditer(r"url\(\s*(['\"]?)(.*?)\1\s*\)", text, re.IGNORECASE | re.DOTALL):
        value = match.group(2).strip()
        if value.startswith("#"):
            continue
        if value.startswith(GITHUB_PREFIX):
            continue
        if value.startswith("//") or HTTP_RE.search(value):
            problems.append(f"css url is external: {value}")
    for match in HTTP_RE.finditer(text):
        token = re.split(r'[\s<>"\'()]+', text[match.start():], maxsplit=1)[0]
        if github_allowed(token):
            continue
        problems.append(f"raw external URL in CSS near: {text[max(0, match.start() - 20) : match.start() + 80]}")
    return problems


def first_argument(text: str, start: int) -> str:
    """Read the first argument of a call, up to its top-level comma or close."""
    depth = 1
    index = start
    quote = None
    while index < len(text):
        char = text[index]
        if quote:
            if char == "\\":
                index += 2
                continue
            if char == quote:
                quote = None
        elif char in "\"'`":
            quote = char
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                return text[start:index]
        elif char == "," and depth == 1:
            return text[start:index]
        index += 1
    return text[start:index]


def relative_literal(value: str) -> bool:
    if not value or value.startswith("//"):
        return False
    if HTTP_RE.search(value) or SCHEME_RE.match(value):
        return False
    return True


def call_argument_is_local(argument: str) -> bool:
    value = argument.strip()
    if re.fullmatch(r"localPath\(.*\)", value, re.DOTALL):
        return True
    if value[:1] in ("'", '"'):
        end = value.rfind(value[0])
        if end <= 0:
            return False
        return relative_literal(value[1:end])
    if value[:1] == "`":
        inner = value[1:]
        prefix = inner.split("${", 1)[0] if "${" in inner else inner
        return relative_literal(prefix)
    return False


def scan_javascript(text: str) -> list[str]:
    problems: list[str] = []
    for match in HTTP_RE.finditer(text):
        token = re.split(r'[\s<>"\'()`]+', text[match.start():], maxsplit=1)[0]
        if github_allowed(token):
            continue
        problems.append(f"external URL in script near: {text[max(0, match.start() - 20) : match.start() + 80]}")
    for match in QUOTED_PROTOCOL_RELATIVE_RE.finditer(text):
        token = text[match.start() + 1 :].split('"', 1)[0].split("'", 1)[0].split("`", 1)[0]
        if github_allowed(token):
            continue
        problems.append(f"quoted protocol-relative URL in script near: {text[match.start() : match.start() + 80]}")
    if "String.fromCharCode" in text:
        problems.append("script assembles a string with String.fromCharCode")
    if "XMLHttpRequest" in text:
        problems.append("script can send a request outside the app's relative paths")
    for pattern, message in JAVASCRIPT_SINKS:
        match = pattern.search(text)
        if match:
            problems.append(f"{message} near: {text[match.start() : match.start() + 80]}")
    for match in re.finditer(r"\bfetch\s*\(\s*", text):
        argument = first_argument(text, match.end())
        if not call_argument_is_local(argument):
            problems.append(f"fetch argument is not a relative literal or a localPath guard: {argument.strip()[:80]}")
    for match in re.finditer(r"\bimport\s*\(\s*", text):
        argument = first_argument(text, match.end())
        if not call_argument_is_local(argument):
            problems.append(f"import argument is not a relative literal: {argument.strip()[:80]}")
    for match in re.finditer(r"\bnew\s+(?:WebSocket|EventSource|Worker)\s*\(\s*", text):
        argument = first_argument(text, match.end())
        if not call_argument_is_local(argument):
            problems.append(f"a network constructor takes a non-relative argument: {argument.strip()[:80]}")
    return problems


def scan_file(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return []
    suffix = path.suffix.lower()
    if suffix in (".html", ".htm"):
        return scan_html(text)
    if suffix == ".svg":
        return scan_svg(text)
    if suffix == ".css":
        return scan_css(text)
    if suffix in (".mjs", ".js"):
        return scan_javascript(text)
    return [f"external URL: {text.strip()[:120]}"] if HTTP_RE.search(text) else []


def assert_no_external_urls() -> None:
    files = walk_files(SITE) + walk_files(RENDERED)
    # inputs.json holds the synthetic records that prove redaction. It carries
    # URLs on purpose, and it is never served or rendered.
    files = [path for path in files if path != INPUTS]
    for path in files:
        for problem in scan_file(path):
            raise Failure(f"{problem} in served file {path.relative_to(REPO)}")
    say(f"no external URL and no runtime request outside the relative paths in {len(files)} files and snapshots")


def evidence_ref() -> str:
    text = (SITE / "app/views.mjs").read_text(encoding="utf-8")
    match = EVIDENCE_REF_RE.search(text)
    check(match is not None, "views.mjs has no pinned EVIDENCE_REF hash")
    ref = match.group(1)
    result = subprocess.run(
        ["git", "cat-file", "-e", ref],
        cwd=REPO,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    check(result.returncode == 0, f"EVIDENCE_REF {ref} is not a commit in this repository")
    return ref


def github_links() -> list[tuple[str, str]]:
    """Every GitHub link in the served files and snapshots, with its file."""
    found: list[tuple[str, str]] = []
    files = walk_files(SITE) + walk_files(RENDERED)
    files = [path for path in files if path != INPUTS]
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for match in GITHUB_LINK_RE.finditer(text):
            url = match.group(0).rstrip("\"'`)>.,;")
            found.append((path.relative_to(REPO).as_posix(), url))
    return found


def assert_github_pins() -> None:
    """Only the pinned GitHub prefix may appear, and every path exists at it."""
    ref = evidence_ref()
    links = github_links()
    check(links, "the page cites no GitHub evidence link")
    for name, url in links:
        match = re.fullmatch(
            r"https://github\.com/nrynss/kalari/(blob|tree)/([0-9a-f]{40})/(\S+)",
            url,
        )
        check(
            match is not None,
            f"the link {url} in {name} is not a pinned blob or tree path",
        )
        assert match is not None
        pinned = match.group(2)
        target = match.group(3).split("#", 1)[0]
        check(pinned == ref, f"the link {url} in {name} does not pin EVIDENCE_REF")
        check(target, f"the link {url} in {name} names no path")
        result = subprocess.run(
            ["git", "cat-file", "-e", f"{ref}:{target}"],
            cwd=REPO,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        check(result.returncode == 0, f"the link {url} in {name} names a path missing at EVIDENCE_REF: {target}")
    say(f"{len(links)} GitHub evidence links, all pinned to {ref[:12]} with paths that exist there")


def assert_private_data_is_absent() -> None:
    text = EVIDENCE.read_text(encoding="utf-8")
    check(not IPV4_RE.findall(text), "the fixture evidence store contains an IP address")
    check(not EMAIL_RE.findall(text), "the fixture evidence store contains an email address")
    for pattern in SECRET_RES:
        check(not pattern.search(text), f"the fixture evidence store matches a secret pattern: {pattern.pattern}")
    check("http://" not in text and "https://" not in text, "the fixture evidence store contains a URL")
    say("the fixture evidence store has no IP address, email, key pattern or URL")
    live = REPO / "tests" / "live"
    extra = [live / "containment-transcript.txt"] + walk_files(live / "containment-evidence")
    for path in extra:
        if not path.is_file():
            continue
        body = path.read_text(encoding="utf-8")
        name = path.relative_to(REPO)
        check(not IPV4_RE.findall(body), f"{name} contains an IP address")
        check(not EMAIL_RE.findall(body), f"{name} contains an email address")
        check("http://" not in body and "https://" not in body, f"{name} contains a URL")
        for pattern in SECRET_RES:
            check(not pattern.search(body), f"{name} matches a secret pattern: {pattern.pattern}")
    say(f"{len([p for p in extra if p.is_file()])} committed containment files have no IP address, email, key pattern or URL")


def assert_rendered_pages_private() -> None:
    for name in PAGES:
        text = read_page(name)
        check(not IPV4_RE.findall(text), f"the rendered page {name} contains an IP address")
        check(not EMAIL_RE.findall(text), f"the rendered page {name} contains an email address")
        for pattern in SECRET_RES:
            check(
                not pattern.search(text),
                f"the rendered page {name} matches a secret pattern: {pattern.pattern}",
            )
    say(f"the {len(PAGES)} rendered pages have no IP address, email or key pattern")


def css_without_comments(text: str) -> str:
    return re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)


def media_print_blocks(css: str) -> list[str]:
    blocks: list[str] = []
    for match in re.finditer(r"@media[^{]*\bprint\b[^{]*\{", css):
        start = match.end()
        depth = 1
        index = start
        while index < len(css) and depth:
            if css[index] == "{":
                depth += 1
            elif css[index] == "}":
                depth -= 1
            index += 1
        blocks.append(css[start : index - 1])
    return blocks


def assert_banner_print_rules(css: str) -> None:
    blocks = media_print_blocks(css_without_comments(css))
    check(blocks, "the stylesheet has no print block")
    scoped = 0
    for block in blocks:
        for rule in re.finditer(r"([^{}]+)\{([^{}]*)\}", block):
            selector = rule.group(1).strip()
            if ".fixture-banner" in selector:
                check(
                    'html[data-fixture="true"]' in selector,
                    f"a print rule for the fixture banner is not scoped to fixture mode: {selector}",
                )
                scoped += 1
    check(scoped > 0, "the print block has no rule for the fixture banner")


def assert_published_has_no_banner() -> None:
    for name in SHELLS:
        text = (SITE / name).read_text(encoding="utf-8")
        check("fixture-banner" not in text, f"{name} carries the fixture banner in the published file")
        check('data-fixture="true"' not in text, f"{name} carries fixture mode in the published file")
    for name in PAGES:
        text = read_page(name)
        check("fixture-banner" not in text, f"the rendered page {name} carries the fixture banner")
        check('data-fixture="true"' not in text, f"the rendered page {name} carries fixture mode")
    css = (SITE / "app.css").read_text(encoding="utf-8")
    assert_banner_print_rules(css)
    say("the published shells and the rendered pages carry no fixture banner, and every banner print rule is scoped")


def csp_meta(text: str) -> str | None:
    match = re.search(
        r'<meta[^>]*http-equiv="Content-Security-Policy"[^>]*content="([^"]+)"',
        text,
        re.IGNORECASE | re.DOTALL,
    )
    return match.group(1) if match else None


def assert_footer_landmark() -> None:
    for name in SHELLS:
        text = (SITE / name).read_text(encoding="utf-8")
        footer = text.find("<footer")
        main_end = text.find("</main>")
        check(footer != -1, f"{name} has no footer")
        check('role="contentinfo"' in text[footer:], f"{name} has no contentinfo landmark")
        check(main_end != -1 and footer > main_end, f"{name} puts the footer inside main")
    say("every published shell has a page-level contentinfo footer outside main")


def assert_csp_shells() -> None:
    for name in SHELLS:
        text = (SITE / name).read_text(encoding="utf-8")
        content = csp_meta(text)
        check(content is not None, f"{name} has no Content-Security-Policy meta tag")
        for directive in CSP_REQUIRED:
            check(directive in content, f"{name} has no {directive} in its Content-Security-Policy")
        meta_at = text.find("Content-Security-Policy")
        script_at = text.find("<script")
        check(meta_at < script_at, f"{name} loads a script before its Content-Security-Policy")
    say("every published shell carries a strict Content-Security-Policy before its scripts")


def assert_csp_headers(base: str) -> None:
    ok = ("/", "/app.css", "/favicon.svg", "/api/benchmark")
    errors = ("/no-such-page", "/api/sessions/")
    for path in ok + errors:
        status, _body, _content_type, headers = request(base, path)
        expected = 200 if path in ok else (400 if path.endswith("/") else 404)
        check(status == expected, f"GET {path} answered {status}, expected {expected}")
        value = headers.get("Content-Security-Policy", "")
        for directive in CSP_REQUIRED:
            check(directive in value, f"GET {path} has no {directive} in its Content-Security-Policy")
    status, _body, _content_type, headers = request(base, "/api/runs", method="POST", data=b"x" * 4097)
    check(status == 413, f"a 4097-byte body answered {status}, expected 413")
    value = headers.get("Content-Security-Policy", "")
    for directive in CSP_REQUIRED:
        check(directive in value, f"the 413 response has no {directive} in its Content-Security-Policy")
    say("the fixture server sends the same Content-Security-Policy on 200, 400, 404 and 413 responses")


def assert_manifest() -> None:
    check(MANIFEST.is_file(), "web/fixture/rendered/manifest.json is missing")
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    check(manifest.get("schema") == "kalari.web.rendered.v1", "unexpected rendered manifest schema")
    check(manifest.get("root") == "web/site", "the manifest root is not web/site")
    pages = manifest.get("pages", {})
    check(set(pages) == set(PAGES), f"the manifest pages are not {', '.join(PAGES)}")
    for name, entry in pages.items():
        check(isinstance(entry, dict), f"rendered page {name} has no hash entry")
        path = REPO / entry["path"]
        check(path.is_file(), f"rendered page {name} is missing: {entry['path']}")
        check(
            sha256(path) == entry["sha256"],
            f"rendered page {name} changed since the snapshot was made. run `node web/fixture/render.mjs`",
        )
    site_files = walk_files(SITE)
    expected = {path.relative_to(SITE).as_posix(): path for path in site_files}
    hashes = manifest.get("sha256", {})
    check(set(hashes) == set(expected), "the manifest does not hash every served file exactly")
    for relative, path in expected.items():
        check(
            sha256(path) == hashes[relative],
            f"{relative} changed since the rendered snapshots were made. run `node web/fixture/render.mjs`",
        )
    evidence = manifest.get("evidence", {})
    check(isinstance(evidence, dict), "the manifest has no evidence hash")
    check(
        sha256(REPO / evidence["path"]) == evidence["sha256"],
        "web/fixture/evidence.jsonl changed since the rendered snapshots were made.",
    )
    inputs = manifest.get("inputs", {})
    check(isinstance(inputs, dict), "the manifest has no snapshot input hash")
    check(
        sha256(REPO / inputs["path"]) == inputs["sha256"],
        "web/fixture/rendered/inputs.json changed since the manifest was made.",
    )
    say(
        f"{len(pages)} rendered page hashes, {len(site_files)} served file hashes, "
        "and the fixture evidence and input hashes verified"
    )


def assert_live_entry_points(base: str) -> None:
    judges = get_text(base, "/")
    session = get_text(base, "/session.html?id=payouts-upgrade")
    run = get_text(base, "/run.html?id=pilot-c3-payouts-r5")
    check('src="app/judges.mjs"' in judges, "the judges page does not load app/judges.mjs")
    check('src="app/session.mjs"' in session, "the session page does not load app/session.mjs")
    check('src="app/run.mjs"' in run, "the run page does not load app/run.mjs")
    check("fixture-banner" in judges, "the live shell has no fixture banner")
    check("fixture-banner" in session and "fixture-banner" in run, "a live shell has no fixture banner")
    check('data-fixture="true"' in judges, "the fixture server did not mark the page as fixture mode")
    api = get_text(base, "/app/api.mjs")
    for route in ("api/benchmark", "api/runs", "api/sessions/", "api/lessons"):
        check(route in api, f"the app API module does not fetch {route}")
    check("localPath" in api, "the app API module has no relative-path guard")
    check("URLSearchParams" in get_text(base, "/app/session.mjs"), "the session entry does not read the id query")
    check("URLSearchParams" in get_text(base, "/app/run.mjs"), "the run entry does not read the id query")
    views = get_text(base, "/app/views.mjs")
    check("not yet published" in views, "the live view has no not-yet-published state")
    check("data-opinion-label" in views, "the live view has no Clef opinion label")
    say("the live shells and entry modules are present")


def assert_fixture_isolation(base: str) -> None:
    for path in (
        "/fixture/evidence.jsonl",
        "/fixture/server.py",
        "/fixture/rendered/judges.html",
        "/rendered/judges.html",
        "/rendered/session.html",
        "/rendered/manifest.json",
        "/check.py",
        "/check.sh",
    ):
        status, _, _, _ = request(base, path)
        check(status == 404, f"the fixture server served {path}: {status}")
    status, _, content_type, _ = request(base, "/app.css")
    check(status == 200, f"the fixture server did not serve the published stylesheet: {status}")
    check("text/css" in (content_type or ""), "the published stylesheet has the wrong content type")
    say("the fixture server serves web/site/ only, and every fixture path and snapshot path answers 404")


def assert_ids(values: list, where: str) -> None:
    for value in values:
        check(isinstance(value, str) and ID_RE.match(value), f"{where} returned an id the API rejects: {value!r}")


def assert_route_records(base: str, records: list, where: str) -> None:
    for record in records:
        for message in envelope_errors(record):
            raise Failure(f"{where} returned a bad record: {message}")
    check(records, f"{where} returned no records")


def assert_api_contract(base: str) -> None:
    sessions = get_json(base, "/api/sessions")
    runs = get_json(base, "/api/runs")
    lessons = get_json(base, "/api/lessons")
    benchmark = get_json(base, "/api/benchmark")
    check(isinstance(sessions, list), "/api/sessions is not an array")
    check(isinstance(runs, list), "/api/runs is not an array")
    check(isinstance(lessons, list), "/api/lessons is not an array")
    check(isinstance(benchmark, list), "/api/benchmark is not an array")
    check(sessions and runs and lessons and benchmark, "the fixture store is unexpectedly empty")
    assert_ids(sessions, "/api/sessions")
    assert_ids(runs, "/api/runs")
    assert_route_records(base, lessons, "/api/lessons")
    assert_route_records(base, benchmark, "/api/benchmark")
    errors = validate_benchmark_records(benchmark, set(runs))
    check(not errors, "benchmark record contract: " + "; ".join(errors[:6]))

    for session_id in sessions:
        records = get_json(base, id_path(base, "sessions", session_id))
        assert_route_records(base, records, f"/api/sessions/{session_id}")
    for run_id in runs:
        records = get_json(base, id_path(base, "runs", run_id))
        assert_route_records(base, records, f"/api/runs/{run_id}")

    session_records = get_json(base, "/api/sessions/payouts-upgrade")
    check(
        any(record.get("kind") == "session" for record in session_records),
        "the walkthrough session has no metadata record",
    )
    run_records = get_json(base, "/api/runs/pilot-c3-payouts-r5")
    check(any(record.get("kind") == "benchmark" for record in run_records), "the capped run has no benchmark record")

    status, _, _, _ = request(base, "/api/runs/does-not-exist")
    check(status == 404, f"a missing run answered {status}, expected 404")
    status, _, _, _ = request(base, "/api/sessions/")
    check(status == 400, f"an empty session id answered {status}, expected 400")
    status, _, _, _ = request(base, "/api/runs/bad%2Fid")
    check(status == 400, f"an encoded slash in a run id answered {status}, expected 400")
    status, _, _, _ = request(base, "/api/sessions/bad%2Fid")
    check(status == 400, f"an encoded slash in a session id answered {status}, expected 400")
    status, _, _, _ = request(base, "/api/runs/%41")
    check(status == 400, f"an encoded character in a run id answered {status}, expected 400")
    status, _, _, _ = request(base, "/api/runs", method="POST")
    check(status == 404, f"POST /api/runs answered {status}, expected 404")
    status, _, _, _ = request(base, "/api/runs", method="POST", data=b"x" * 4096)
    check(status == 400, f"a 4096-byte body answered {status}, expected 400")
    status, _, _, _ = request(base, "/api/runs", method="POST", data=b"x" * 4097)
    check(status == 413, f"a 4097-byte body answered {status}, expected 413")
    say(
        f"{len(benchmark)} benchmark records, {len(sessions)} sessions, {len(runs)} runs. "
        "Every route record passes the envelope contract, and the fixture server matches "
        "the expected 400, 404 and 413 responses."
    )


class JudgesParser(HTMLParser):
    """Collect numbers, anchors and run links from a rendered page."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, dict[str, str]]] = []
        self.numbers: list[tuple[str, str, str | None]] = []
        self.anchors: list[dict[str, object]] = []
        self.anchor: dict[str, object] | None = None
        self.model_depth = 0
        self.model_texts: list[str] = []
        self.model_buffer: list[str] = []

    def _context(self) -> dict[str, object]:
        cell = next((attributes.get("data-label") for _, attributes in reversed(self.stack) if "data-label" in attributes), None)
        classes = [
            value
            for _, attributes in self.stack
            for value in (attributes.get("class") or "").split()
        ]
        return {
            "cell": cell,
            "median": "median-line" in classes,
            "containment": "containment-measure-value" in classes,
        }

    def _in_model(self) -> bool:
        return self.model_depth > 0

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = {key: value for key, value in attrs}
        if "model-tag" in (attributes.get("class") or "").split():
            self.model_depth += 1
            if self.model_depth == 1:
                self.model_buffer = []
        if tag == "a":
            self.anchor = {
                "attrs": attributes,
                "text": [],
                "href": attributes.get("href", ""),
                **self._context(),
            }
        self.stack.append((tag, attributes))

    def handle_startendtag(self, tag: str, attrs) -> None:
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self.anchor is not None:
            text = "".join(self.anchor["text"]).strip()
            self.anchor["text"] = text
            self.anchor["has_digit"] = any(char.isdigit() for char in text)
            self.anchors.append(self.anchor)
            self.anchor = None
        for index in range(len(self.stack) - 1, -1, -1):
            attributes = self.stack[index][1]
            if self.stack[index][0] == tag:
                if "model-tag" in (attributes.get("class") or "").split() and self.model_depth:
                    self.model_depth -= 1
                    if self.model_depth == 0:
                        self.model_texts.append("".join(self.model_buffer).strip())
                        self.model_buffer = []
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        if any(tag in ("script", "style", "noscript", "template") for tag, _ in self.stack):
            return
        if self._in_model():
            self.model_buffer.append(data)
        if self.anchor is not None:
            self.anchor["text"].append(data)
        for match in NUMBER_RE.finditer(data):
            anchor = next((attributes for tag, attributes in reversed(self.stack) if tag == "a"), None)
            if anchor is None:
                self.numbers.append((match.group(0), data.strip()[:120], None, self._in_model()))
            else:
                self.numbers.append(
                    (match.group(0), data.strip()[:120], run_id_from_href(anchor.get("href", "")), self._in_model())
                )


CELL_MEASURE_TITLES = {
    "Sandbox runs": "Sandbox runs",
    "Wall time": "Wall time",
    "Records lost": "Records lost",
    "Records duplicated": "Records duplicated",
    "Tokens in": "Input tokens",
    "Tokens out": "Output tokens",
    "Time stuck": "Time stuck",
    "Cost": "List-price cost",
    "Session cap": "Session cap",
    "Records": "Graded records",
    "Missing": "Missing records",
    "Extra": "Extra records",
    "Duplicates": "Duplicate records",
    "Mismatched": "Mismatched records",
}


SHOWCASE_TITLE = "Showcase run"


def assert_model_tags(name: str, html: str) -> None:
    """Model names carry digits, but they are names, not figures. Only known
    names may use the marker."""
    parser = JudgesParser()
    parser.feed(html)
    for text in parser.model_texts:
        check(text in MODEL_TAGS, f"on {name}, the model marker names an unknown model: {text!r}")
    if parser.model_texts:
        say(f"{name}: {len(parser.model_texts)} model names marked, all known")


def assert_numbers_link_to_runs(base: str, judges_html: str, run_ids: set[str], benchmark_run_ids: set[str]) -> None:
    parser = JudgesParser()
    parser.feed(judges_html)
    figures = [item for item in parser.numbers if len(item) < 4 or not item[3]]
    check(figures, "the judges page displays no numbers at all")
    for item in figures:
        number, context, run_id = item[0], item[1], item[2]
        check(run_id is not None, f"the number {number!r} is outside a run link (near {context!r})")
        check(run_id in run_ids, f"the number {number!r} links to run {run_id!r}, which is not in /api/runs")

    linked: set[str] = set()
    for anchor in parser.anchors:
        href = str(anchor["href"])
        run_id = run_id_from_href(href)
        data_id = anchor["attrs"].get("data-run-link")
        title = anchor["attrs"].get("title", "")
        if run_id is not None or data_id or "run-link" in (anchor["attrs"].get("class") or "").split():
            check(run_id is not None, f"a run link has no run id in its href: {href!r}")
            check(
                isinstance(run_id, str) and ID_RE.match(run_id),
                f"a run link has an id the API rejects: {run_id!r}",
            )
            check(
                data_id == run_id,
                f"a run link has data-run-link {data_id!r} but href id {run_id!r}",
            )
            check(run_id in run_ids, f"a run link points to {run_id!r}, which is not in /api/runs")
            linked.add(run_id)
        if anchor["has_digit"]:
            check(data_id is not None, f"an anchor shows a number but is not a run link: {anchor['text']!r}")
            check(
                data_id == run_id,
                f"an anchor shows a number but data-run-link {data_id!r} does not equal href id {run_id!r}",
            )
            check(
                title in TITLE_FIELDS or title in CONTAINMENT_TITLES or title in HERO_TITLES or title in REFERENCE_TITLES or title == SHOWCASE_TITLE or title == f"Open run {run_id}",
                f"an anchor shows a number with an unknown title: {title!r}",
            )

    for run_id in sorted(linked):
        status, _, _, _ = request(base, id_path(base, "runs", run_id))
        check(status == 200, f"the run link {run_id!r} answers {status} at {id_path(base, 'runs', run_id)}")

    missing_benchmark = benchmark_run_ids - linked
    check(
        not missing_benchmark,
        "the judges page does not link every benchmark run. Missing: " + ", ".join(sorted(missing_benchmark)),
    )
    missing_runs = run_ids - linked
    check(
        not missing_runs,
        "the judges page does not link every run. Missing: " + ", ".join(sorted(missing_runs)),
    )
    say(f"{len(parser.numbers)} displayed numbers, all inside working run links")
    say(f"{len(linked)} distinct runs linked and fetched. Every run in the store is present")


class TableParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[str] = []
        self.row_run: str | None = None
        self.cell: dict[str, object] | None = None
        self.anchor: dict[str, object] | None = None
        self.cells: list[dict[str, object]] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = {key: value for key, value in attrs}
        if tag == "tr":
            self.row_run = None
        if tag == "td":
            self.cell = {"label": attributes.get("data-label"), "run": None, "text": [], "anchors": []}
            self.anchor = None
        if tag == "a" and self.cell is not None:
            data_id = attributes.get("data-run-link")
            if data_id:
                self.cell["run"] = self.cell["run"] or data_id
                self.row_run = self.row_run or data_id
            self.anchor = {"attrs": attributes, "text": []}
            self.cell["anchors"].append(self.anchor)
        self.stack.append(tag)

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self.anchor is not None:
            self.anchor["text"] = "".join(self.anchor["text"]).strip()
            self.anchor = None
        if tag == "td" and self.cell is not None:
            text = "".join(self.cell["text"]).strip()
            self.cells.append(
                {
                    "label": self.cell["label"],
                    "run": self.cell["run"] or self.row_run,
                    "text": text,
                    "anchors": self.cell["anchors"],
                }
            )
            self.cell = None
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index] == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        if self.cell is not None:
            self.cell["text"].append(data)
        if self.anchor is not None:
            self.anchor["text"].append(data)


def js_number(value: float, minimum: int, maximum: int) -> str:
    text = f"{float(value):,.{maximum}f}"
    if maximum == 0:
        return text
    whole, _, fraction = text.partition(".")
    fraction = fraction.rstrip("0")
    if len(fraction) < minimum:
        fraction += "0" * (minimum - len(fraction))
    return f"{whole}.{fraction}" if fraction else whole


def format_seconds(value) -> str:
    return f"{js_number(value, 1, 3)} s"


def format_count(value) -> str:
    return js_number(value, 0, 0)


def format_money(value) -> str:
    return f"${js_number(value, 4, 4)}"


def format_tokens(value) -> str:
    return js_number(value, 0, 0)


def verdict_word(value) -> str:
    return {
        "PASS": "Passed",
        "FAIL": "Failed",
        "exited": "Completed",
        "killed_timeout": "Stopped by the time cap",
        "killed_output_cap": "Stopped by the output cap",
    }.get(value, str(value) if value else "Unknown")


def bool_word(value) -> str:
    if value is True:
        return "Yes"
    if value is False:
        return "No"
    return "Unknown"


CELL_FIELDS = {
    "Sandbox runs": ("payload", "sandbox_runs", format_count),
    "Wall time": ("payload", "wall_time_s", format_seconds),
    "Records lost": ("payload", "records_lost", format_count),
    "Records duplicated": ("payload", "records_duplicated", format_count),
    "Tokens in": ("payload", "tokens_input", format_tokens),
    "Tokens out": ("payload", "tokens_output", format_tokens),
    "Time stuck": ("payload", "time_stuck_s", format_seconds),
    "Cost": ("payload", "cost_usd", format_money),
    "Session cap": ("payload", "session_cap_s", format_seconds),
    "Records": ("grade", "records", format_count),
    "Missing": ("grade", "missing", format_count),
    "Extra": ("grade", "extra", format_count),
    "Duplicates": ("grade", "duplicates", format_count),
    "Mismatched": ("grade", "mismatched", format_count),
}

TITLE_FIELDS = {
    "Sandbox runs": ("payload", "sandbox_runs", format_count),
    "Wall time": ("payload", "wall_time_s", format_seconds),
    "Median wall time": ("payload", "wall_time_s", format_seconds),
    "Median sandbox runs": ("payload", "sandbox_runs", format_count),
    "Records lost": ("payload", "records_lost", format_count),
    "Worst run: records lost": ("payload", "records_lost", format_count),
    "Records duplicated": ("payload", "records_duplicated", format_count),
    "Worst run: records duplicated": ("payload", "records_duplicated", format_count),
    "Input tokens": ("payload", "tokens_input", format_tokens),
    "Output tokens": ("payload", "tokens_output", format_tokens),
    "Time stuck": ("payload", "time_stuck_s", format_seconds),
    "List-price cost": ("payload", "cost_usd", format_money),
    "Session cap": ("payload", "session_cap_s", format_seconds),
    "Graded records": ("grade", "records", format_count),
    "Missing records": ("grade", "missing", format_count),
    "Extra records": ("grade", "extra", format_count),
    "Duplicate records": ("grade", "duplicates", format_count),
    "Mismatched records": ("grade", "mismatched", format_count),
}


def expected_value(record: dict, source: str, key: str, formatter) -> str:
    payload = record.get("payload") or {}
    if source == "grade":
        value = (payload.get("grade") or {}).get(key)
    else:
        value = payload.get(key)
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return formatter(value)
    return "unknown"


def finite(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def payload_of(record: dict) -> dict:
    payload = record.get("payload")
    return payload if isinstance(payload, dict) else {}


def measured(record: dict, source: str, key: str):
    payload = payload_of(record)
    if source == "grade":
        grade = payload.get("grade")
        return grade.get(key) if isinstance(grade, dict) else None
    return payload.get(key)


def assert_measure_links(cell: dict, record: dict, run_ids: set[str]) -> None:
    """A measure cell links to its run exactly when the record holds the value."""
    label = cell["label"]
    title = CELL_MEASURE_TITLES[label]
    source, key, formatter = CELL_FIELDS[label]
    value = measured(record, source, key)
    anchors = [(anchor["attrs"].get("title"), anchor["attrs"].get("data-run-link"), anchor["text"]) for anchor in cell["anchors"]]
    if finite(value) and cell["run"] in run_ids:
        check(
            anchors == [(title, cell["run"], formatter(value))],
            f"the {label!r} cell for {cell['run']!r} has links {anchors}, expected one {title!r} link",
        )
    else:
        check(not anchors, f"the {label!r} cell for {cell['run']!r} links a value it does not have: {anchors}")


def assert_values_match_records(name: str, html: str, benchmark: list[dict], run_ids: set[str]) -> None:
    records = {
        record["run_id"]: record
        for record in benchmark
        if isinstance(record, dict) and isinstance(record.get("run_id"), str)
    }
    table_parser = TableParser()
    table_parser.feed(html)
    checked = 0
    for cell in table_parser.cells:
        label = cell["label"]
        run_id = cell["run"]
        text = cell["text"]
        if label == "Behaviour":
            check(re.search(r"\bB[1-5]\b", text) is not None, f"a behaviour cell has no behaviour code: {text!r}")
            check(not cell["anchors"], f"a behaviour cell links a value: {cell['anchors']}")
            continue
        if label == "Run":
            check(bool(run_id), "a run cell has no run link")
            check(text == run_id, f"a run cell shows {text!r} instead of {run_id!r}")
            anchors = [(anchor["attrs"].get("title"), anchor["attrs"].get("data-run-link"), anchor["text"]) for anchor in cell["anchors"]]
            if run_id in run_ids:
                check(
                    anchors == [(f"Open run {run_id}", run_id, run_id)],
                    f"the run cell for {run_id!r} has links {anchors}, expected one run link",
                )
            else:
                check(not anchors, f"the run cell for {run_id!r} links a run the index does not hold")
            continue
        if label is None:
            check(not re.search(r"\d", text), f"an unlabelled table cell shows a number: {text!r}")
            check(not cell["anchors"], f"an unlabelled table cell shows a link: {text!r}")
            continue
        if label not in ("Verdict", "Right first time", "Grade") and label not in CELL_FIELDS:
            check(not re.search(r"\d", text), f"the table cell {label!r} is not a known measure")
            continue
        if not run_id:
            check(not re.search(r"\d", text), f"the table cell {label!r} shows a number but has no run link")
            continue
        record = records.get(run_id)
        check(record is not None, f"a table cell links to {run_id!r}, which has no benchmark record")
        if label == "Verdict":
            expected = verdict_word(payload_of(record).get("verdict"))
            check(not cell["anchors"], f"a verdict cell links a value: {text!r}")
        elif label == "Right first time":
            expected = bool_word(payload_of(record).get("right_first_time"))
            check(not cell["anchors"], f"a right-first-time cell links a value: {text!r}")
        elif label == "Grade":
            expected = verdict_word((payload_of(record).get("grade") or {}).get("verdict"))
            check(not cell["anchors"], f"a grade cell links a value: {text!r}")
        else:
            source, key, formatter = CELL_FIELDS[label]
            expected = expected_value(record, source, key, formatter)
            assert_measure_links(cell, record, run_ids)
        check(
            text == expected,
            f"the table value for {label!r} on {run_id!r} is {text!r}, expected {expected!r}",
        )
        checked += 1

    parser = JudgesParser()
    parser.feed(html)
    measured_links = 0
    for anchor in parser.anchors:
        attrs = anchor["attrs"]
        run_id = attrs.get("data-run-link")
        if not run_id:
            continue
        title = attrs.get("title", "")
        text = anchor["text"]
        if title in TITLE_FIELDS:
            record = records.get(run_id)
            check(record is not None, f"a measure links to {run_id!r}, which has no benchmark record")
            source, key, formatter = TITLE_FIELDS[title]
            expected = expected_value(record, source, key, formatter)
            check(
                text == expected,
                f"the measure {title!r} on {run_id!r} is {text!r}, expected {expected!r}",
            )
            check(
                anchor["cell"] or anchor["median"] or anchor["containment"],
                f"the measure {title!r} on {run_id!r} is outside a measure cell, a median line or the containment panel",
            )
            if anchor["cell"]:
                check(
                    CELL_MEASURE_TITLES.get(str(anchor["cell"])) == title,
                    f"the cell {anchor['cell']!r} carries the measure title {title!r}",
                )
            measured_links += 1
        elif title == f"Open run {run_id}":
            check(
                text == run_id,
                f"the run link for {run_id!r} shows {text!r} instead of the run id",
            )
        elif title in CONTAINMENT_TITLES:
            pass  # assert_containment checks these against the containment record
        elif title in HERO_TITLES or title in REFERENCE_TITLES:
            pass  # assert_hero and assert_reference_panel check these against their records
        elif title == SHOWCASE_TITLE:
            pass  # assert_showcase checks these against the showcase records
        elif title:
            raise Failure(f"an anchor with data-run-link has an unknown title: {title!r}")
    say(f"{name}: {checked} table values match their records")
    return measured_links


def assert_anchor_containers(name: str, html: str) -> None:
    """Every anchor that shows a digit is a measure link or shows its run id."""
    parser = JudgesParser()
    parser.feed(html)
    for anchor in parser.anchors:
        if not anchor["has_digit"]:
            continue
        href = str(anchor["href"])
        text = str(anchor["text"])
        title = anchor["attrs"].get("title", "")
        run_id = run_id_from_href(href)
        session_id = session_id_from_href(href)
        if session_id is not None and text == session_id:
            continue
        if run_id is not None and title == f"Open run {run_id}" and text == run_id:
            continue
        if run_id is not None and title in CONTAINMENT_TITLES:
            check(
                anchor["attrs"].get("data-run-link") == run_id,
                f"on {name}, the containment figure {title!r} has no data-run-link for {run_id!r}",
            )
            continue
        if run_id is not None and (title in HERO_TITLES or title in REFERENCE_TITLES):
            check(
                anchor["attrs"].get("data-run-link") == run_id,
                f"on {name}, the figure {title!r} has no data-run-link for {run_id!r}",
            )
            continue
        if run_id is not None and title in TITLE_FIELDS:
            check(
                anchor["attrs"].get("data-run-link") == run_id,
                f"on {name}, the measure {title!r} has no data-run-link for {run_id!r}",
            )
            check(
                anchor["cell"] or anchor["median"] or anchor["containment"],
                f"on {name}, the measure {title!r} is outside a measure cell, a median line or the containment panel",
            )
            continue
        if run_id is not None and title == SHOWCASE_TITLE:
            check(
                anchor["attrs"].get("data-run-link") == run_id,
                f"on {name}, the showcase figure has no data-run-link for {run_id!r}",
            )
            continue
        raise Failure(f"on {name}, the anchor {text!r} shows a number but is not a measure or a run id")


CONTAINMENT_SESSION = "containment-runs"
CONTAINMENT_PREFIX = "Containment run: "
CONTAINMENT_TITLES = {
    CONTAINMENT_PREFIX + "configured time cap": (("config", "time_cap_ms"), lambda v: f"{format_count(v)} ms"),
    CONTAINMENT_PREFIX + "measured wall time": (("result", "wall_ms"), lambda v: f"{format_count(v)} ms"),
    CONTAINMENT_PREFIX + "pages fetched": (("result", "pages_fetched"), lambda v: f"{format_count(v)} pages"),
    CONTAINMENT_PREFIX + "configured output cap": (("config", "output_cap_bytes"), lambda v: f"{format_count(v)} bytes"),
    CONTAINMENT_PREFIX + "configured memory": (("config", "memory_mib"), lambda v: f"{format_count(v)} MiB"),
}


def containment_records_of(records: list[dict]) -> list[dict]:
    return [
        record
        for record in records or []
        if isinstance(record, dict)
        and record.get("kind") == "containment"
        and payload_of(record).get("schema") == "kalari.containment.v1"
    ]


def containment_record_of(records: list[dict]) -> dict | None:
    """The run the time cap stopped, else the first run."""
    found = containment_records_of(records)
    for record in found:
        if (payload_of(record).get("result") or {}).get("verdict") == "killed_timeout":
            return record
    return found[0] if found else None


def containment_expected(records: list[dict], run_ids: set[str]) -> list[tuple]:
    """The measure links the containment panel draws for these records: the
    main run's figures, then the earlier run's wall time."""
    main = containment_record_of(records)
    if main is None:
        return []
    expected = []
    for record in [main] + [r for r in containment_records_of(records) if r is not main]:
        if record.get("run_id") not in run_ids:
            continue
        for title, (path, formatter) in CONTAINMENT_TITLES.items():
            if record is not main and title != CONTAINMENT_PREFIX + "measured wall time":
                continue
            section, key = path
            value = (payload_of(record).get(section) or {}).get(key)
            if finite(value) and not (title.endswith("pages fetched") and value == 0):
                expected.append((title, record["run_id"], formatter(value)))
    return expected


def plain_text(fragment: str) -> str:
    return re.sub(r"\s+", " ", html_module.unescape(re.sub(r"<[^>]+>", " ", fragment))).strip()


def assert_containment(name: str, html: str, records: list[dict], run_ids: set[str]) -> None:
    """The judges containment panel matches its records, links each run and the
    session, and keeps its claims qualified."""
    record = containment_record_of(records)
    has_section = 'id="containment"' in html
    if record is None:
        check(not has_section, f"on {name}, a containment panel is drawn with no containment record")
        return
    check(has_section, f"on {name}, the containment records have no panel")
    start = html.index('<section id="containment"')
    section = html[start : html.index("</section>", start)]
    parser = JudgesParser()
    parser.feed(section)
    actual = [
        (anchor["attrs"].get("title"), anchor["attrs"].get("data-run-link"), anchor["text"])
        for anchor in parser.anchors
        if str(anchor["attrs"].get("title", "")).startswith(CONTAINMENT_PREFIX)
    ]
    expected = containment_expected(records, run_ids)
    check(sorted(actual) == sorted(expected), f"on {name}, the containment figures are {actual}, expected {expected}")
    for item in parser.numbers:
        number, context, run_id = item[0], item[1], item[2]
        if len(item) > 3 and item[3]:
            continue
        check(run_id is not None, f"on {name}, the containment panel shows {number!r} outside a run link ({context!r})")
    p = payload_of(record)
    run_id = record["run_id"]
    text = plain_text(section)
    # every run is reachable from the panel, and the session too
    main_links = [
        anchor
        for anchor in parser.anchors
        if anchor["attrs"].get("data-run-link") == run_id and anchor["text"] == "Read the run and its evidence"
    ]
    check(len(main_links) == 1 and main_links[0]["href"] == f"run.html?id={run_id}", f"on {name}, the panel does not link its main run page")
    for phrase in ("No model", "fixed consumer", "run_in_sandbox"):
        check(phrase in text, f"on {name}, the panel does not say the run used no model")
    for needle in (
        "tests/live/containment-transcript.txt",
        "tests/live/containment-evidence/run-1.jsonl",
        "tests/live/containment-evidence/run-2.jsonl",
        "bench/RESULTS.md",
    ):
        check(needle in section, f"on {name}, the panel does not link {needle}")
    for other in containment_records_of(records):
        if other is record:
            continue
        links = [
            anchor
            for anchor in parser.anchors
            if anchor["attrs"].get("data-run-link") == other["run_id"] and anchor["text"] == "Read the run that crashed on the rate limit"
        ]
        check(len(links) == 1 and links[0]["href"] == f"run.html?id={other['run_id']}", f"on {name}, the panel does not link the earlier run page")
        check("The run before it" in text and "exited with a non-zero status" in text, f"on {name}, the panel does not describe the earlier run")
    check(f'href="session.html?id={CONTAINMENT_SESSION}"' in section, f"on {name}, the panel does not link its session")
    # the failure
    result = p.get("result") or {}
    check(result.get("verdict") == "killed_timeout" and result.get("passed") is False, f"on {name}, the main run is not a killed_timeout with passed=false")
    check("killed_timeout" in text and "passed is false" in text, f"on {name}, the panel does not show killed_timeout and passed=false")
    check("Configured time cap" in text and "Measured wall time" in text, f"on {name}, the panel lacks the time cap or the wall time")
    check("polling" in text and "No fixed overshoot bound" in text, f"on {name}, the panel does not explain polling or disclaims an overshoot bound badly")
    check("configuration only" in text and "Neither fired" in text, f"on {name}, the panel does not keep the output and memory caps as configuration")
    # the boundary, with requested, effective and observed kept apart
    check("Requested:" in text and "Effective, read back from msb inspect" in text and "Observed:" in text, f"on {name}, the panel does not separate requested, effective and observed policy")
    observed = (p.get("network") or {}).get("observed") or {}
    check(observed.get("same_guest") is False and "second guest" in text, f"on {name}, the panel must say the probe ran in a second guest")
    denied, refused = observed.get("denied_attempts"), observed.get("denied_and_refused")
    if observed.get("breaches") == 0:
        check(
            f"({count_word(refused)} of {count_word(denied)})" in text,
            f"on {name}, the panel does not state {count_word(refused)} of {count_word(denied)} refused",
        )
    for attempt in observed.get("attempts") or []:
        word = "refused" if attempt.get("expected") == "refused" else "answered"
        if attempt.get("observed") != attempt.get("expected"):
            word = "answered" if attempt.get("expected") == "refused" else "did not answer"
        check(word in text, f"on {name}, the panel does not show the {attempt.get('label')} outcome")
    # the cleanup
    cleanup = p.get("cleanup") or {}
    check(cleanup.get("ok") is True and "present and unchanged" in text, f"on {name}, the panel does not show verified cleanup")
    check(
        f"This test created {count_word(len(cleanup.get('sandboxes_created') or []))} sandboxes" in text,
        f"on {name}, the panel does not state how many sandboxes were created",
    )
    # claims stay qualified, labels stay plain, and the old session-cap story is gone
    for match in re.finditer(r"zero blast radius", text, re.IGNORECASE):
        check(text[max(0, match.start() - 24) : match.start()].lower().endswith("not a claim of "), f"on {name}, an unqualified zero-blast-radius claim")
    check("not a claim of zero blast radius" in text, f"on {name}, the panel lacks the blast-radius qualification")
    check("not benchmark sessions" in text, f"on {name}, the panel is not labelled apart from the benchmark")
    for phrase in ("session cap", "The cap fired", "harness"):
        check(phrase not in text, f"on {name}, the panel keeps the old story: {phrase!r}")
    for word in ("demonstration", "deliberate", "demo "):
        check(word not in text.lower(), f"on {name}, the panel carries the label {word!r}")
    check("agent wrote" not in text.lower() and "agent-written" not in text.lower(), f"on {name}, the panel implies an agent wrote a consumer")


def validate_containment_records(records: list[dict]) -> list[str]:
    """The containment evidence contract: every record is honest about what it shows."""
    errors: list[str] = []
    found = containment_records_of(records)
    if not found:
        return ["no containment record"]
    if not any((payload_of(r).get("result") or {}).get("verdict") == "killed_timeout" for r in found):
        errors.append("no containment run was stopped by the time cap")
    seen: set[str] = set()
    for record in found:
        run_id = record.get("run_id")
        tag = f"run {run_id}: "
        p = payload_of(record)
        if run_id in seen:
            errors.append(tag + "two containment records share a run id")
        seen.add(run_id)
        if record.get("session_id") != CONTAINMENT_SESSION:
            errors.append(tag + "session id is not containment-runs")
        if not isinstance(run_id, str) or not ID_RE.match(run_id):
            errors.append(tag + "run id is not a valid id")
        if p.get("benchmark") is not False:
            errors.append(tag + "payload does not say it is not a benchmark")
        if re.search(r"(?i)demonstration|deliberate|\bdemo\b", json.dumps(p)):
            errors.append(tag + "payload carries a label this test does not use")
        config, result = p.get("config") or {}, p.get("result") or {}
        for key in ("time_cap_ms", "output_cap_bytes", "memory_mib"):
            if not (finite(config.get(key)) and config[key] > 0):
                errors.append(tag + f"config.{key} is not a positive number")
        if not (finite(result.get("wall_ms")) and result["wall_ms"] >= 0):
            errors.append(tag + "result.wall_ms is not a number")
        verdict = result.get("verdict")
        if verdict not in ("killed_timeout", "exited") or result.get("passed") is not False:
            errors.append(tag + "result is not killed_timeout or exited with passed=false")
        if verdict == "exited" and result.get("exit_code") in (None, 0):
            errors.append(tag + "an exited run that failed must have a non-zero exit code")
        if verdict == "killed_timeout" and not (finite(result.get("pages_fetched")) and result["pages_fetched"] > 0):
            errors.append(tag + "a killed run must record the pages it fetched")
        if result.get("stdout_truncated") is not False:
            errors.append(tag + "result.stdout_truncated must be false: the output cap is not claimed to fire")
        if result.get("run_id") != run_id:
            errors.append(tag + "result.run_id differs from the envelope run id")
        outcomes = p.get("outcomes") or {}
        for key in ("candidate", "baseline", "differential"):
            if not isinstance(outcomes.get(key), dict):
                errors.append(tag + f"outcomes.{key} is missing")
        if (outcomes.get("differential") or {}).get("passed") is not False:
            errors.append(tag + "the differential check must have failed")
        argv = (p.get("creation") or {}).get("argv")
        if not (isinstance(argv, list) and argv[:2] == ["msb", "create"] and "--no-net" in argv):
            errors.append(tag + "creation.argv is not an msb create with --no-net")
        network = p.get("network") or {}
        for key in ("requested", "effective", "observed"):
            if not isinstance(network.get(key), dict):
                errors.append(tag + f"network.{key} is missing")
        observed = network.get("observed") or {}
        if observed.get("same_guest") is not False:
            errors.append(tag + "network.observed.same_guest must be false")
        if observed.get("breaches") != 0:
            errors.append(tag + "network.observed.breaches is not zero")
        if not (observed.get("attempts") and observed.get("denied_attempts", 0) > 0):
            errors.append(tag + "no denied probe attempts recorded")
        if (p.get("cleanup") or {}).get("ok") is not True:
            errors.append(tag + "cleanup.ok is not true")
        if "zero blast radius" not in " ".join(p.get("limits") or []):
            errors.append(tag + "limits do not disclaim zero blast radius")
        # it traces to the production run and check records of the same run
        runs = [r for r in records if r.get("kind") == "run" and r.get("run_id") == run_id]
        if len(runs) != 1:
            errors.append(tag + "no single run record")
        else:
            rp = payload_of(runs[0])
            if (rp.get("request") or {}).get("caps", {}).get("timeout_ms") != config.get("time_cap_ms"):
                errors.append(tag + "run record time cap differs from the containment config")
            if (rp.get("verdict") or {}).get("wall_ms") != result.get("wall_ms"):
                errors.append(tag + "run record wall_ms differs from the containment result")
            if (rp.get("verdict") or {}).get("verdict") != verdict:
                errors.append(tag + "run record verdict differs from the containment result")
        if not [r for r in records if r.get("kind") == "check" and r.get("run_id") == run_id]:
            errors.append(tag + "no check records")
    return errors


def assert_containment_run_page(name: str, html: str, records: list[dict]) -> None:
    record = containment_record_of(records)
    check(record is not None, f"{name} has no containment record")
    p = payload_of(record)
    text = plain_text(html)
    for needle in (
        "Containment evidence",
        "Not a benchmark run",
        "Configured time cap",
        "Measured wall time (supervisor clock)",
        "How the sandbox was created",
        "Requested",
        "Effective",
        "Observed",
        "Cleanup",
        "What this does not show",
        " ".join((p.get("creation") or {}).get("argv") or []),
    ):
        check(needle in text, f"on {name}, the containment evidence lacks {needle!r}")
    for attempt in (p.get("network") or {}).get("observed", {}).get("attempts", []):
        check(attempt["label"] in text, f"on {name}, the probe attempt {attempt['label']!r} is missing")
    check(html.count("<table") <= 1, f"on {name}, the containment evidence added a table")
    for word in ("demonstration", "deliberate"):
        check(word not in text.lower(), f"on {name}, the run page carries the label {word!r}")


REFERENCE_SESSION = "reference-paging"
REFERENCE_RUN = "reference-paging-fix"

HERO_TITLES = {
    "Kalari mean cost",
    "Reference mean cost",
    "Kalari mean wall time",
    "Reference mean wall time",
    "Kalari total stuck",
    "Reference total stuck",
    "Cost ratio",
    "Wall time ratio",
    "Stuck note",
    "Kalari pass tally",
    "Reference pass tally",
    "Kalari sessions",
    "Reference sessions",
    "Hero cap-kill wall time",
    "Hero cap-kill cap",
}

REFERENCE_TITLES = {
    "Reference loss: exit code",
    "Reference loss: printed records",
    "Reference loss: graded records",
    "Reference loss: expected records",
    "Reference loss: missing records",
    "Reference fix: setup",
    "Reference fix: records",
    "Reference fix: expected records",
    "Reference fix: wall time",
    "Reference fix: input tokens",
    "Reference fix: output tokens",
    "Reference fix: cost",
}


def reference_record_of(records: list[dict]) -> dict | None:
    """The reference run record, if the store publishes it."""
    for record in records or []:
        if (
            isinstance(record, dict)
            and record.get("kind") == "reference"
            and payload_of(record).get("schema") == "kalari.reference.v1"
        ):
            return record
    return None


def hero_sets(benchmark: list[dict]) -> tuple[list[dict], list[dict]]:
    """The frozen benchmark rows per arm. Kalari is conditions 4 and 5,
    reference is conditions 1, 2, 3 and 6."""
    kalari, reference = [], []
    for record in benchmark or []:
        if not isinstance(record, dict) or record.get("kind") != "benchmark":
            continue
        p = payload_of(record)
        if p.get("provenance") != "frozen" or p.get("status") != "valid":
            continue
        if p.get("arm") == "kalari":
            kalari.append(record)
        elif p.get("arm") == "reference":
            reference.append(record)
    return kalari, reference


def hero_sums(records: list[dict]) -> dict | None:
    if not records:
        return None
    sums: dict[str, float] = {}
    for key in ("cost_usd", "wall_time_s", "time_stuck_s"):
        values = [payload_of(record).get(key) for record in records]
        if any(not finite(value) for value in values):
            return None
        sums[key] = sum(values)  # type: ignore[arg-type]
    return {
        "n": len(records),
        "stuck": sums["time_stuck_s"],
        "cost_mean": sums["cost_usd"] / len(records),
        "wall_mean": sums["wall_time_s"] / len(records),
    }


def hero_ratio_text(ratio: float, win: str, lose: str) -> str:
    if ratio >= 1:
        return f"{ratio:.1f}x {win}"
    return f"{1 / ratio:.1f}x {lose}"


def hero_stuck_badge(kal_total: float, ref_total: float) -> str:
    if kal_total == 0 and ref_total == 0:
        return "No stuck time on either side"
    if kal_total == 0:
        return "Every hung run was on the reference side"
    if ref_total == 0:
        return "Every hung run was on the Kalari side"
    if ref_total >= kal_total:
        return f"{ref_total / kal_total:.1f}x less stuck on the Kalari side"
    return f"{kal_total / ref_total:.1f}x more stuck on the Kalari side"


def hero_bar_widths(kal_value: float, ref_value: float) -> tuple[str, str]:
    if not (kal_value > 0) and not (ref_value > 0):
        return "0.0%", "0.0%"
    large = max(kal_value, ref_value)
    return f"{100 * kal_value / large:.1f}%", f"{100 * ref_value / large:.1f}%"


def hero_stuck_note(kalari: list[dict], reference: list[dict], kal_stuck: float) -> str:
    ref_stuck_runs = sum(1 for record in reference if payload_of(record).get("time_stuck_s", 0) > 0)
    if ref_stuck_runs == 0 and kal_stuck == 0:
        return "No session ended in a hung run."
    sessions = "session" if ref_stuck_runs == 1 else "sessions"
    kalari_part = (
        "No Kalari session ended in a hung run."
        if kal_stuck == 0
        else "Kalari sessions ended in hung runs too."
    )
    return f"{capitalise(count_word(ref_stuck_runs))} reference {sessions} recovered from a hung run. {kalari_part}"


def hero_expected(benchmark: list[dict], containment: list[dict]) -> list[tuple] | None:
    """Every hero figure as (title, run id, text), recomputed from the records.
    None when an arm is missing or a measure is unknown."""
    kalari, reference = hero_sets(benchmark)
    kal, ref = hero_sums(kalari), hero_sums(reference)
    if kal is None or ref is None:
        return None
    if kal["cost_mean"] <= 0 or ref["cost_mean"] <= 0 or kal["wall_mean"] <= 0 or ref["wall_mean"] <= 0:
        return None
    kal_cost = median_record(kalari, "cost_usd")
    ref_cost = median_record(reference, "cost_usd")
    kal_wall = median_record(kalari, "wall_time_s")
    ref_wall = median_record(reference, "wall_time_s")
    kal_stuck = max(kalari, key=lambda record: payload_of(record)["time_stuck_s"])
    ref_stuck = max(reference, key=lambda record: payload_of(record)["time_stuck_s"])
    figures = [
        ("Kalari mean cost", kal_cost["run_id"], format_money(kal["cost_mean"])),
        ("Reference mean cost", ref_cost["run_id"], format_money(ref["cost_mean"])),
        ("Kalari mean wall time", kal_wall["run_id"], format_seconds(kal["wall_mean"])),
        ("Reference mean wall time", ref_wall["run_id"], format_seconds(ref["wall_mean"])),
        ("Kalari total stuck", kal_stuck["run_id"], format_seconds(kal["stuck"])),
        ("Reference total stuck", ref_stuck["run_id"], format_seconds(ref["stuck"])),
        (
            "Cost ratio",
            kal_cost["run_id"],
            hero_ratio_text(ref["cost_mean"] / kal["cost_mean"], "cheaper", "costlier"),
        ),
        (
            "Wall time ratio",
            kal_wall["run_id"],
            hero_ratio_text(ref["wall_mean"] / kal["wall_mean"], "faster", "slower"),
        ),
        ("Stuck note", kal_stuck["run_id"], hero_stuck_badge(kal["stuck"], ref["stuck"])),
    ]
    # Each arm block shows its session count, so the count appears once per
    # row, linked to that row's representative run.
    for run in (kal_cost, kal_wall, kal_stuck):
        figures.append(("Kalari sessions", run["run_id"], f"{format_count(kal['n'])} sessions"))
    for run in (ref_cost, ref_wall, ref_stuck):
        figures.append(("Reference sessions", run["run_id"], f"{format_count(ref['n'])} sessions"))
    kal_pass = sum(1 for record in kalari if payload_of(record).get("verdict") == "PASS")
    ref_pass = sum(1 for record in reference if payload_of(record).get("verdict") == "PASS")
    if kal_pass == kal["n"] and ref_pass == ref["n"]:
        figures.append(("Kalari pass tally", kal_cost["run_id"], f"{format_count(kal['n'])}/{format_count(kal['n'])}"))
        figures.append(("Reference pass tally", ref_cost["run_id"], f"{format_count(ref['n'])}/{format_count(ref['n'])}"))
    else:
        figures.append(("Kalari pass tally", kal_cost["run_id"], f"{format_count(kal_pass)} of {format_count(kal['n'])}"))
        figures.append(("Reference pass tally", ref_cost["run_id"], f"{format_count(ref_pass)} of {format_count(ref['n'])}"))
    main = containment_record_of(containment or [])
    if main is not None:
        wall_ms = (payload_of(main).get("result") or {}).get("wall_ms")
        cap_ms = (payload_of(main).get("config") or {}).get("time_cap_ms")
        if finite(wall_ms) and finite(cap_ms):
            figures.append(("Hero cap-kill wall time", main["run_id"], f"{format_count(wall_ms)} ms"))
            figures.append(("Hero cap-kill cap", main["run_id"], f"{format_count(cap_ms)} ms"))
    return figures


def hero_bar_expected(benchmark: list[dict]) -> list[str] | None:
    kalari, reference = hero_sets(benchmark)
    kal, ref = hero_sums(kalari), hero_sums(reference)
    if kal is None or ref is None:
        return None
    if kal["cost_mean"] <= 0 or ref["cost_mean"] <= 0 or kal["wall_mean"] <= 0 or ref["wall_mean"] <= 0:
        return None
    widths: list[str] = []
    for key in ("cost_mean", "wall_mean"):
        kal_width, ref_width = hero_bar_widths(kal[key], ref[key])
        widths += [kal_width, ref_width]
    kal_width, ref_width = hero_bar_widths(kal["stuck"], ref["stuck"])
    widths += [kal_width, ref_width]
    return widths


def hero_section_of(html: str, section_id: str) -> str:
    start = html.index(f'<section id="{section_id}"')
    return html[start : html.index("</section>", start)]


def assert_hero(name: str, html: str, benchmark: list[dict], run_ids: set[str], containment: list[dict]) -> None:
    expected = hero_expected(benchmark, containment or [])
    has_section = 'id="changed"' in html
    if expected is None:
        check(not has_section, f"on {name}, a hero comparison is drawn with an incomplete arm")
        return
    check(has_section, f"on {name}, the frozen rows have both arms and no hero comparison")
    section = hero_section_of(html, "changed")
    parser = JudgesParser()
    parser.feed(section)
    actual = [
        (anchor["attrs"].get("title"), anchor["attrs"].get("data-run-link"), anchor["text"])
        for anchor in parser.anchors
        if str(anchor["attrs"].get("title", "")) in HERO_TITLES
    ]
    check(
        Counter(actual) == Counter(expected),
        f"on {name}, the hero figures are {actual}, expected {expected}",
    )
    kalari, reference = hero_sets(benchmark)
    kal_runs = {record["run_id"] for record in kalari}
    ref_runs = {record["run_id"] for record in reference}
    main = containment_record_of(containment or [])
    for title, run_id, _text in actual:
        check(run_id in run_ids, f"on {name}, the hero figure {title!r} links {run_id!r}, which is not in /api/runs")
        if title in ("Hero cap-kill wall time", "Hero cap-kill cap"):
            check(
                main is not None and run_id == main["run_id"],
                f"on {name}, the hero figure {title!r} does not link the cap-kill run",
            )
        elif str(title).startswith("Reference"):
            check(run_id in ref_runs, f"on {name}, the hero figure {title!r} links a run outside the reference arm")
        else:
            check(run_id in kal_runs, f"on {name}, the hero figure {title!r} links a run outside the Kalari arm")
    for item in parser.numbers:
        number, context, run_id = item[0], item[1], item[2]
        if len(item) > 3 and item[3]:
            continue
        check(run_id is not None, f"on {name}, the hero shows {number!r} outside a run link ({context!r})")
    widths = re.findall(r'style="width: ([0-9.]+%)"', section)
    check(
        widths == hero_bar_expected(benchmark),
        f"on {name}, the hero bars are {widths}, expected {hero_bar_expected(benchmark)}",
    )
    text = plain_text(section)
    kal, ref = hero_sums(kalari), hero_sums(reference)
    assert kal is not None and ref is not None
    for phrase in (
        "One fresh guest per run",
        "No network except one allow rule",
        "Caps on time, memory and output",
        "The agent chose its own sandbox",
        "reached the internet",
        "cannot switch off",
        hero_stuck_note(kalari, reference, kal["stuck"]),
        "Both arms:",
        "The only difference is Kalari.",
        "DeepSeek",
    ):
        check(phrase in text, f"on {name}, the hero lacks {phrase!r}")
    for needle in ("bench/RESULTS.md", "bench/FROZEN.md"):
        check(needle in section, f"on {name}, the hero does not link {needle}")
    if main is not None:
        check("killed_timeout" in text, f"on {name}, the hero cap-kill line lacks the verdict")
        check("See the cap-kill run" in text, f"on {name}, the hero cap-kill line lacks its run link")
    say(f"{name}: {len(actual)} hero figures recomputed from the benchmark records")


def dollars2(value) -> str:
    return f"${value:,.2f}"


def reference_expected(record: dict) -> list[tuple]:
    """Every problem-panel figure as (title, run id, text) from the record."""
    p = payload_of(record)
    before = p.get("before") or {}
    after = p.get("after") or {}
    run_id = record["run_id"]
    return [
        # The heading links the missing count too, so it appears twice.
        ("Reference loss: missing records", run_id, format_count(before.get("missing"))),
        ("Reference loss: exit code", run_id, format_count(before.get("exit_code"))),
        ("Reference loss: printed records", run_id, format_count(before.get("records"))),
        ("Reference loss: graded records", run_id, format_count(before.get("records"))),
        ("Reference loss: expected records", run_id, format_count(before.get("expected"))),
        ("Reference loss: missing records", run_id, format_count(before.get("missing"))),
        ("Reference fix: setup", run_id, after.get("setup") or "OpenCode with microsandbox-mcp and DeepSeek V4.1 Flash"),
        ("Reference fix: records", run_id, format_count(after.get("records"))),
        ("Reference fix: expected records", run_id, format_count(after.get("expected"))),
        ("Reference fix: wall time", run_id, format_seconds(after.get("wall_time_s"))),
        ("Reference fix: input tokens", run_id, format_tokens(after.get("tokens_input"))),
        ("Reference fix: output tokens", run_id, format_tokens(after.get("tokens_output"))),
        ("Reference fix: cost", run_id, dollars2(after.get("cost_usd"))),
    ]


def assert_reference_panel(name: str, html: str, reference: list[dict], run_ids: set[str]) -> None:
    record = reference_record_of(reference or [])
    has_section = 'id="problem"' in html
    if record is None:
        check(not has_section, f"on {name}, a problem panel is drawn with no reference record")
        return
    check(has_section, f"on {name}, the reference record has no problem panel")
    section = hero_section_of(html, "problem")
    parser = JudgesParser()
    parser.feed(section)
    actual = [
        (anchor["attrs"].get("title"), anchor["attrs"].get("data-run-link"), anchor["text"])
        for anchor in parser.anchors
        if str(anchor["attrs"].get("title", "")) in REFERENCE_TITLES
    ]
    expected = reference_expected(record)
    check(
        Counter(actual) == Counter(expected),
        f"on {name}, the problem figures are {actual}, expected {expected}",
    )
    for _title, run_id, _text in actual:
        check(run_id == REFERENCE_RUN, f"on {name}, a problem figure links {run_id!r}, expected {REFERENCE_RUN!r}")
        check(run_id in run_ids, f"on {name}, the problem figure links {run_id!r}, which is not in /api/runs")
    for item in parser.numbers:
        number, context, run_id = item[0], item[1], item[2]
        if len(item) > 3 and item[3]:
            continue
        check(run_id is not None, f"on {name}, the problem panel shows {number!r} outside a run link ({context!r})")
    text = plain_text(section)
    for phrase in (
        "The problem",
        "The silent loss",
        "The fix",
        "import_items.py",
        "This run is not a benchmark session",
        "never enters the tallies",
        "bench/reference-paging/README.md",
        "DeepSeek",
    ):
        check(phrase in text, f"on {name}, the problem panel lacks {phrase!r}")
    check(
        f'href="session.html?id={REFERENCE_SESSION}"' in section,
        f"on {name}, the problem panel does not link its session",
    )
    say(f"{name}: {len(actual)} problem figures match the reference record")


def assert_reference_excluded(name: str, benchmark: list[dict], reference: list[dict]) -> None:
    """The reference run never enters the benchmark tallies or the hero sums."""
    kinds = {record.get("kind") for record in benchmark or [] if isinstance(record, dict)}
    check("reference" not in kinds, f"on {name}, a reference record is in the benchmark route")
    bench_runs = {record.get("run_id") for record in benchmark or [] if isinstance(record, dict)}
    check(REFERENCE_RUN not in bench_runs, f"on {name}, the reference run is in the benchmark route")
    sessions = {record.get("session_id") for record in benchmark or [] if isinstance(record, dict)}
    check(REFERENCE_SESSION not in sessions, f"on {name}, the reference session is in the benchmark route")
    kalari, reference_arm = hero_sets(benchmark)
    hero_runs = {record["run_id"] for record in kalari + reference_arm}
    check(REFERENCE_RUN not in hero_runs, f"on {name}, the reference run enters a hero arm")
    say(f"{name}: the reference run is outside the benchmark sums")


def assert_reference_run_page(name: str, html: str, records: list[dict]) -> None:
    record = reference_record_of(records)
    check(record is not None, f"{name} has no reference record")
    p = payload_of(record)
    before = p.get("before") or {}
    after = p.get("after") or {}
    text = plain_text(html)
    for needle in (
        "Reference run",
        "Not a benchmark run",
        "The silent loss",
        "The fix",
        "What this run is not",
        "import_items.py",
        "imported 100 items",
        "bench/reference-paging/README.md",
        format_count(before.get("missing")),
        format_count(before.get("expected")),
        format_seconds(after.get("wall_time_s")),
        format_tokens(after.get("tokens_input")),
        format_tokens(after.get("tokens_output")),
        dollars2(after.get("cost_usd")),
    ):
        check(needle in text, f"on {name}, the reference evidence lacks {needle!r}")
    check(html.count("<table") <= 1, f"on {name}, the reference evidence added a table")
    check("benchmark session" in text.lower(), f"on {name}, the run page does not say what the run is not")


SHOWCASE_SESSION = "showcase-disbursements"
LEAD_SHOWCASE_RUN = "showcase-kalari-glm-r3"


def showcase_records_of(records: list[dict]) -> list[dict]:
    """The showcase records, in their own session apart from the benchmark."""
    return [
        record
        for record in records or []
        if isinstance(record, dict)
        and record.get("kind") == "showcase"
        and isinstance(record.get("payload"), dict)
        and record["payload"].get("schema") == "kalari.showcase.v1"
    ]


def showcase_text(record: dict) -> str:
    """The grid and card anchor text for one showcase run. Mirrors the view."""
    p = payload_of(record)
    label = p.get("label") or record.get("run_id", "")
    verdict = "Passed" if p.get("verdict") == "PASS" else "Failed" if p.get("verdict") == "FAIL" else "Unknown"
    extras: list[str] = []
    for key, word in (("records_lost", "lost"), ("records_duplicated", "duplicated"), ("records_changed", "changed")):
        value = p.get(key)
        if isinstance(value, int) and not isinstance(value, bool) and value > 0:
            extras.append(f"{format_count(value)} {word}")
    differential = p.get("differential")
    if p.get("fixed") is True and isinstance(differential, list) and differential:
        extras.append(f"fixed after {differential[0]}")
    elif p.get("flagged") is True and p.get("verdict") == "FAIL":
        extras.append("flagged")
    return f"{label}: {verdict}" + (f", {', '.join(extras)}" if extras else "")


def showcase_expected(records: list[dict], run_ids: set[str], sessions: list) -> list[tuple] | None:
    """Every showcase anchor as (title, run id, text). The lead run links its
    grid cell and the session card, so it appears twice."""
    found = [record for record in showcase_records_of(records) if record.get("run_id") in run_ids]
    if not found:
        return None
    expected = [(SHOWCASE_TITLE, record["run_id"], showcase_text(record)) for record in found]
    lead = next((record for record in found if record.get("run_id") == LEAD_SHOWCASE_RUN), None)
    if lead is not None and SHOWCASE_SESSION in (sessions or []):
        expected.append((SHOWCASE_TITLE, LEAD_SHOWCASE_RUN, showcase_text(lead)))
    return expected


def assert_showcase(name: str, html: str, records: list[dict], run_ids: set[str], sessions: list) -> None:
    """The models grid matches its records, names every model, and keeps the
    manufactured scenario apart from the benchmark."""
    expected = showcase_expected(records, run_ids, sessions)
    has_section = 'id="models"' in html
    if expected is None:
        check(not has_section, f"on {name}, a models grid is drawn with no showcase record")
        return
    check(has_section, f"on {name}, the showcase records have no models grid")
    start = html.index('<section id="models"')
    section = html[start : html.index("</section>", start)]
    parser = JudgesParser()
    parser.feed(html)
    actual = [
        (anchor["attrs"].get("title"), anchor["attrs"].get("data-run-link"), anchor["text"])
        for anchor in parser.anchors
        if str(anchor["attrs"].get("title", "")) == SHOWCASE_TITLE
    ]
    check(
        Counter(actual) == Counter(expected),
        f"on {name}, the showcase figures are {actual}, expected {expected}",
    )
    for _title, run_id, _text in actual:
        check(run_id in run_ids, f"on {name}, a showcase figure links {run_id!r}, which is not in /api/runs")
    text = plain_text(section)
    for phrase in (
        "Across models",
        "the corruption shipped silently",
        "flagged with the evidence",
        "manufactured",
        "not part of the frozen comparison",
    ):
        check(phrase in text, f"on {name}, the models grid lacks {phrase!r}")
    for model in SHOWCASE_MODELS:
        check(model.split()[0] in text, f"on {name}, the models grid names no {model!r} row")
    for arm in ("OpenCode alone", "OpenCode with Kalari"):
        check(arm in text, f"on {name}, the models grid lacks the {arm!r} column")
    for needle in ("bench/showcase/disbursements/README.md", "bench/showcase/disbursements/QUIRKS.md"):
        check(needle in section, f"on {name}, the models grid does not link {needle}")
    say(f"{name}: {len(actual)} showcase figures match their records")


def assert_showcase_excluded(name: str, benchmark: list[dict], records: list[dict]) -> None:
    """The showcase runs never enter the benchmark sums or the hero arms."""
    kinds = {record.get("kind") for record in benchmark or [] if isinstance(record, dict)}
    check("showcase" not in kinds, f"on {name}, a showcase record is in the benchmark route")
    bench_runs = {record.get("run_id") for record in benchmark or [] if isinstance(record, dict)}
    showcase_runs = {record.get("run_id") for record in showcase_records_of(records)}
    check(not (bench_runs & showcase_runs), f"on {name}, a showcase run enters the benchmark sums")
    kalari, reference = hero_sets(benchmark)
    hero_runs = {record["run_id"] for record in kalari + reference}
    check(not (hero_runs & showcase_runs), f"on {name}, a showcase run enters a hero arm")
    say(f"{name}: the showcase runs are outside the benchmark sums")


def assert_sessions(name: str, html: str, sessions: list, showcase: list[dict], run_ids: set[str]) -> None:
    """The session cards name the sessions in the store, and never a missing
    session line."""
    text = plain_text(html)
    check("not in the current evidence store" not in text, f"on {name}, a card claims a session the store does not have")
    ids = list(sessions or [])
    expected_cards = [session for session in (SHOWCASE_SESSION, CONTAINMENT_SESSION, "frozen-c4-payouts", "payouts-upgrade") if session in ids]
    if not expected_cards:
        check("Read a full session" not in text, f"on {name}, the sessions section is drawn with no session card")
        return
    check("Read a full session" in text, f"on {name}, the sessions section has no heading")
    for needle, session in (
        ("Showcase disbursements", SHOWCASE_SESSION),
        ("Containment runs", CONTAINMENT_SESSION),
        ("Frozen payouts, Kalari arm", "frozen-c4-payouts"),
        ("Upgrading the payout ledger", "payouts-upgrade"),
    ):
        if session in ids:
            check(needle in text, f"on {name}, the {session} card is missing")
            check(f'href="session.html?id={session}"' in html, f"on {name}, the {session} card does not link its session")
    if SHOWCASE_SESSION in ids:
        lead = next((record for record in showcase_records_of(showcase) if record.get("run_id") == LEAD_SHOWCASE_RUN), None)
        check(lead is not None, f"on {name}, the showcase session has no lead run")
    say(f"{name}: {len(expected_cards)} session cards match the store")


def assert_showcase_session(name: str, html: str, records: list[dict]) -> None:
    found = showcase_records_of(records)
    check(found, f"{name} has no showcase record")
    text = plain_text(html)
    for needle in (
        "Showcase runs",
        "manufactured",
        "Not part of the frozen comparison",
    ):
        check(needle in text, f"on {name}, the showcase session lacks {needle!r}")
    for record in found:
        p = payload_of(record)
        check((p.get("label") or "") in text, f"on {name}, the showcase session omits {record.get('run_id')!r}")
    check(html.count("<table") <= 1, f"on {name}, the showcase session added a table")


def assert_showcase_run_page(name: str, html: str, records: list[dict]) -> None:
    found = showcase_records_of(records)
    check(len(found) == 1, f"{name} does not hold one showcase record")
    p = payload_of(found[0])
    text = plain_text(html)
    for needle in (
        "Showcase run",
        "Not part of the frozen comparison",
        str(p.get("model") or ""),
        verdict_word(p.get("verdict")),
        format_count(p.get("records")),
        format_count(p.get("records_lost")),
        format_count(p.get("records_duplicated")),
        format_count(p.get("records_changed")),
        str(p.get("source") or ""),
        str(p.get("transcript") or ""),
    ):
        check(needle in text, f"on {name}, the showcase run page lacks {needle!r}")
    for needle in (
        "bench/showcase/disbursements/README.md",
        "bench/showcase/disbursements/QUIRKS.md",
    ):
        check(needle in html, f"on {name}, the showcase run page does not link {needle}")
    if p.get("arm") == "kalari":
        sequence = p.get("differential") or []
        check(sequence, f"on {name}, the Kalari run page shows no differential sequence")
        for item in sequence:
            check(item in text, f"on {name}, the Kalari run page omits the differential {item!r}")
    check(html.count("<table") <= 1, f"on {name}, the showcase evidence added a table")


def table_measure_links(html: str, benchmark: list[dict], run_ids: set[str]) -> int:
    """Count measure links the table cells carry for these records."""
    records = {
        record["run_id"]: record
        for record in benchmark
        if isinstance(record, dict) and isinstance(record.get("run_id"), str)
    }
    parser = TableParser()
    parser.feed(html)
    links = 0
    for cell in parser.cells:
        label = cell["label"]
        if label not in CELL_FIELDS:
            continue
        record = records.get(cell["run"])
        if record is None or cell["run"] not in run_ids:
            continue
        source, key, _formatter = CELL_FIELDS[label]
        if finite(measured(record, source, key)):
            links += 1
    return links


def loss_measure_links(benchmark: list[dict], run_ids: set[str]) -> int:
    """Count the worst-run links the frozen contrast draws from these records."""
    frozen = [
        record
        for record in benchmark
        if payload_of(record).get("provenance") == "frozen"
        and payload_of(record).get("status") not in ("invalid", "diagnostic")
    ]
    links = 0
    for upgrade in {payload_of(record).get("upgrade") for record in frozen}:
        before = [
            record
            for record in frozen
            if payload_of(record).get("condition") == 3 and payload_of(record).get("upgrade") == upgrade
        ]
        after = [
            record
            for record in frozen
            if payload_of(record).get("condition") == 5 and payload_of(record).get("upgrade") == upgrade
        ]
        if not before or not after:
            continue
        for records in (before, after):
            for key in ("records_lost", "records_duplicated"):
                values = [
                    record for record in records if finite(payload_of(record).get(key))
                ]
                if not values:
                    continue
                worst = max(values, key=lambda record: payload_of(record)[key])
                if payload_of(worst)[key] > 0 and worst.get("run_id") in run_ids:
                    links += 1
    return links


def measure_anchor_count(html: str) -> int:
    parser = JudgesParser()
    parser.feed(html)
    return sum(
        1
        for anchor in parser.anchors
        if anchor["attrs"].get("data-run-link") and anchor["attrs"].get("title") in TITLE_FIELDS
    )


def assert_measure_link_count(
    name: str,
    html: str,
    benchmark: list[dict],
    run_ids: set[str],
    kind: str,
) -> None:
    """Every measure link the records require is present, and no other one is."""
    table = table_measure_links(html, benchmark, run_ids)
    expected = table
    if kind == "judges":
        expected += 2 * expected_contrast_columns(benchmark)
        expected += loss_measure_links(benchmark, run_ids)
    actual = measure_anchor_count(html)
    check(
        actual == expected,
        f"the page {name} shows {actual} measure links, expected {expected} from its records "
        f"({table} in table cells)",
    )
    say(f"{name}: {actual} measure links match the {expected} the records require")


def assert_cell_counts(name: str, html: str, expected: dict) -> None:
    parser = TableParser()
    parser.feed(html)
    actual = Counter(cell["label"] for cell in parser.cells)
    check(
        actual == Counter(expected),
        f"the page {name} has table cells {dict(actual)}, expected {dict(expected)}",
    )


def judges_cell_counts(benchmark: list[dict]) -> Counter:
    """The table cells the judges view draws for a set of benchmark records."""
    counts: Counter = Counter()
    others = [record for record in benchmark if payload_of(record).get("status") != "diagnostic"]
    diagnostics = [record for record in benchmark if payload_of(record).get("status") == "diagnostic"]
    groups: dict[tuple, list[dict]] = {}
    for record in others:
        payload = payload_of(record)
        groups.setdefault((payload.get("condition"), payload.get("upgrade")), []).append(record)
    for records in groups.values():
        graded = any(isinstance(payload_of(record).get("grade"), dict) for record in records)
        for record in records:
            counts["Run"] += 3 if graded else 2
            for label in (
                "Verdict",
                "Right first time",
                "Sandbox runs",
                "Wall time",
                "Records lost",
                "Records duplicated",
                "Tokens in",
                "Tokens out",
                "Time stuck",
                "Cost",
                "Session cap",
            ):
                counts[label] += 1
            if graded:
                counts["Grade"] += 1
                if isinstance(payload_of(record).get("grade"), dict):
                    for label in ("Records", "Missing", "Extra", "Duplicates", "Mismatched"):
                        counts[label] += 1
                else:
                    counts[None] += 1
    for _record in diagnostics:
        counts["Behaviour"] += 1
        for label in (
            "Run",
            "Verdict",
            "Right first time",
            "Sandbox runs",
            "Wall time",
            "Records lost",
            "Records duplicated",
        ):
            counts[label] += 1
    return counts


def session_cell_counts(records: list[dict]) -> Counter:
    counts: Counter = Counter({"Kind": len(records), "Run": len(records), "Change kinds": len(records)})
    counts.update(judges_cell_counts([record for record in records if record.get("kind") == "benchmark"]))
    return counts


class ContrastParser(HTMLParser):
    """Read each contrast column and every median line inside it."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, dict[str, str]]] = []
        self.column: dict[str, object] | None = None
        self.column_level = 0
        self.title: list[str] = []
        self.in_title = False
        self.median: dict[str, object] | None = None
        self.median_anchor: dict[str, object] | None = None
        self.capture: str | None = None
        self.medians: list[dict[str, object]] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = {key: value for key, value in attrs}
        classes = (attributes.get("class") or "").split()
        self.stack.append((tag, attributes))
        if tag == "div" and "contrast-column" in classes:
            self.column = {
                "condition": attributes.get("data-condition", ""),
                "upgrade": attributes.get("data-upgrade", ""),
                "provenance": attributes.get("data-provenance", ""),
                "title": "",
                "runs": [],
            }
            self.column_level = len(self.stack)
            self.title = []
        elif self.column is not None and tag == "h4":
            self.in_title = True
        elif self.column is not None and tag == "p" and "median-line" in classes:
            self.median = {"label": "", "value": "", "anchors": []}
        elif self.median is not None and tag == "a":
            self.median_anchor = {
                "attrs": attributes,
                "text": [],
                "in_value": self.capture == "value",
            }
            self.median["anchors"].append(self.median_anchor)
            if attributes.get("data-run-link"):
                self.column["runs"].append(attributes["data-run-link"])
        elif self.column is not None and tag == "a" and attributes.get("data-run-link"):
            self.column["runs"].append(attributes["data-run-link"])
        elif self.median is not None and tag == "span":
            if "median-label" in classes:
                self.capture = "label"
            elif "median-value" in classes:
                self.capture = "value"

    def handle_endtag(self, tag: str) -> None:
        if tag == "h4" and self.in_title:
            self.in_title = False
            if self.column is not None:
                self.column["title"] = "".join(self.title).strip()
        if tag == "a":
            self.median_anchor = None
        if tag == "span":
            self.capture = None
        if tag == "p" and self.median is not None:
            if self.column is not None:
                self.medians.append(
                    {
                        "condition": self.column["condition"],
                        "upgrade": self.column["upgrade"],
                        "provenance": self.column["provenance"],
                        "title": self.column["title"],
                        "runs": list(self.column["runs"]),
                        "label": self.median["label"].strip(),
                        "value": self.median["value"].strip(),
                        "anchors": self.median["anchors"],
                    }
                )
            self.median = None
        if tag == "div" and self.column is not None and len(self.stack) == self.column_level:
            self.column = None
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        if self.in_title and self.column is not None:
            self.title.append(data)
        if self.capture is not None and self.median is not None:
            self.median[self.capture] = str(self.median[self.capture]) + data
        if self.median_anchor is not None:
            self.median_anchor["text"].append(data)


def expected_contrast_columns(benchmark: list[dict]) -> int:
    """Count the contrast columns the judges view draws for these records."""
    pilot = [
        record
        for record in benchmark
        if payload_of(record).get("provenance") != "frozen" and payload_of(record).get("status") == "valid"
    ]
    frozen = [
        record
        for record in benchmark
        if payload_of(record).get("provenance") == "frozen" and payload_of(record).get("status") == "valid"
    ]

    def has(records, condition, upgrade):
        return any(
            payload_of(record).get("condition") == condition and payload_of(record).get("upgrade") == upgrade
            for record in records
        )

    columns = 0
    if has(pilot, 3, "settlements") and has(pilot, 2, "settlements"):
        columns += 2
    for upgrade in {payload_of(record).get("upgrade") for record in frozen}:
        if has(frozen, 5, upgrade) and has(frozen, 3, upgrade):
            columns += 2
    return columns


def assert_medians(name: str, html: str, benchmark: list[dict]) -> None:
    parser = ContrastParser()
    parser.feed(html)
    columns = expected_contrast_columns(benchmark)
    check(
        len(parser.medians) == 2 * columns,
        f"the page {name} shows {len(parser.medians)} median lines, expected {2 * columns} for {columns} columns",
    )
    checked = 0
    for median in parser.medians:
        label = median["label"]
        check(label in ("Median wall time", "Median sandbox runs"), f"an unknown median line: {label!r}")
        condition = int(median["condition"])
        upgrade = median["upgrade"]
        provenance = median["provenance"]
        group = [
            record
            for record in benchmark
            if record.get("kind") == "benchmark"
            and isinstance(record.get("payload"), dict)
            and record["payload"].get("condition") == condition
            and record["payload"].get("upgrade") == upgrade
            and record["payload"].get("status") == "valid"
            and (
                record["payload"].get("provenance") == "frozen"
                if provenance == "frozen"
                else record["payload"].get("provenance") != "frozen"
            )
        ]
        check(group, f"the {provenance} column for condition {condition} has no records")
        check(
            set(str(record["run_id"]) for record in group) == set(str(item) for item in median["runs"]),
            f"the {provenance} column for condition {condition} {upgrade} does not list the records of its group",
        )
        key = "wall_time_s" if label == "Median wall time" else "sandbox_runs"
        formatter = format_seconds if key == "wall_time_s" else format_count
        values = sorted(
            record["payload"][key]
            for record in group
            if isinstance(record["payload"].get(key), (int, float))
            and not isinstance(record["payload"].get(key), bool)
        )
        check(values, f"the {provenance} column for condition {condition} has no {key} value")
        middle = median_record(group, key)
        expected = formatter(values[(len(values) - 1) // 2])
        check(
            median["value"] == expected,
            f"the median {label!r} in the {provenance} column for condition {condition} is "
            f"{median['value']!r}, expected {expected!r} from {len(values)} records",
        )
        anchors = median["anchors"]
        check(
            len(anchors) == 1,
            f"the median {label!r} for condition {condition} has {len(anchors)} anchors, expected one",
        )
        anchor = anchors[0]
        check(
            anchor["in_value"],
            f"the median link {label!r} for condition {condition} is outside the median value",
        )
        check(
            anchor["attrs"].get("title") == label,
            f"the median link {label!r} has the title {anchor['attrs'].get('title')!r}",
        )
        check(
            anchor["attrs"].get("data-run-link") == middle["run_id"],
            f"the median {label!r} links the run {anchor['attrs'].get('data-run-link')!r}, expected {middle['run_id']!r}",
        )
        checked += 1
    say(f"{name}: {checked} medians computed independently from the benchmark records")


def median_record(records: list[dict], key: str) -> dict:
    values = [record for record in records if finite(payload_of(record).get(key))]
    values.sort(key=lambda record: payload_of(record)[key])
    return values[(len(values) - 1) // 2]


def assert_tables_labelled() -> None:
    tables = 0
    for name in PAGES:
        text = read_page(name)
        for match in re.finditer(r"<table\b[^>]*>.*?</table>", text, re.DOTALL | re.IGNORECASE):
            table = match.group(0)
            opening = re.match(r"<table\b[^>]*>", table, re.IGNORECASE)
            has_caption = re.search(r"<caption\b", table, re.IGNORECASE) is not None
            has_labelled = opening is not None and "aria-labelledby" in opening.group(0)
            check(has_caption or has_labelled, f"a table in {name} has no caption or aria-labelledby")
            tables += 1
    say(f"every table has a caption or aria-labelledby ({tables} tables)")


class PercentParser(HTMLParser):
    """Find percentages and probability-shaped decimals in visible text.

    A percentage in a table cell, a verdict or a heading is a probability in the
    wrong place. A percentage inside the opinion block must carry the
    `data-probability` marker. A percentage in prose outside the opinion block
    is data, and a note, a summary or a check detail may show one. A decimal
    follows the same scope, so it may also sit in prose outside the opinion
    block.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, dict[str, str]]] = []
        self.matches: list[dict[str, object]] = []
        self.opinion_numbers: list[dict[str, object]] = []
        self.decimals: list[dict[str, object]] = []
        self.markers: list[tuple[str, str]] = []
        self.marker_texts: list[dict[str, object]] = []
        self.label_capture: dict[str, object] | None = None
        self.opinion_blocks = 0

    def _flags(self) -> dict[str, object]:
        tags = [tag for tag, _ in self.stack]
        classes = [attributes.get("class", "") for _, attributes in self.stack]
        labels = [
            attributes.get("data-opinion-label", "")
            for _, attributes in self.stack
            if "data-opinion-label" in attributes
        ]
        return {
            "in_heading": any(tag in HEADINGS for tag in tags),
            "in_cell": any(tag in ("th", "td") for tag in tags),
            "in_verdict": any("verdict" in value.split() for value in classes),
            "in_opinion": any("data-opinion" in attributes for _, attributes in self.stack),
            "in_probability": any("data-probability" in attributes for _, attributes in self.stack),
            "in_log": any(tag == "pre" or "log" in value.split() for tag, value in zip(tags, classes)),
            "label": " | ".join(labels),
        }

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = {key: value for key, value in attrs}
        self.stack.append((tag, attributes))
        if "data-opinion" in attributes:
            self.opinion_blocks += 1
        if "data-probability" in attributes:
            labels = [
                ancestor.get("data-opinion-label", "")
                for _, ancestor in self.stack
                if "data-opinion-label" in ancestor
            ]
            marker = {
                "label": attributes.get("data-probability", ""),
                "index": len(self.stack) - 1,
                "attrs": attributes,
                "text": [],
                "visible_label": [],
            }
            self.markers.append((marker["label"], " | ".join(labels)))
            self.marker_texts.append(marker)
        if tag == "span" and "prob-label" in (attributes.get("class") or "").split():
            self.label_capture = self.marker_texts[-1] if self.marker_texts else None

    def handle_endtag(self, tag: str) -> None:
        if tag == "span":
            self.label_capture = None
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        if any(tag in ("script", "style", "template") for tag, _ in self.stack):
            return
        if self.marker_texts:
            marker = self.marker_texts[-1]
            index = int(marker["index"])
            if len(self.stack) > index and self.stack[index][1] is marker["attrs"]:
                marker["text"].append(data)
        if self.label_capture is not None:
            self.label_capture["visible_label"].append(data)
        flags = self._flags()
        for match in PERCENT_RE.finditer(data):
            self.matches.append({"value": match.group(0), **flags})
        if flags["in_opinion"]:
            for match in NUMBER_RE.finditer(data):
                self.opinion_numbers.append({"value": match.group(0), **flags})
        if flags["in_log"] or flags["in_probability"]:
            return
        if not (flags["in_heading"] or flags["in_cell"] or flags["in_verdict"] or flags["in_opinion"]):
            return
        for match in DECIMAL_RE.finditer(data):
            value = float(match.group(0))
            if not 0 < value < 1:
                continue
            if re.match(r"\s*[A-Za-z%]", data[match.end() :]):
                continue
            self.decimals.append({"value": match.group(0), **flags})


def clef_label_map() -> dict[str, str]:
    """Read the Clef labels from the app source, so the check and the page agree."""
    text = (SITE / "app/labels.mjs").read_text(encoding="utf-8")
    match = re.search(r"export const CLEF_LABELS\s*=\s*\{(.*?)\n\};", text, re.DOTALL)
    check(match is not None, "the app source has no CLEF_LABELS map")
    return dict(re.findall(r'^\s*([A-Za-z0-9_]+):\s*"([^"]*)"', match.group(1), re.MULTILINE))


def assert_clef_labels(name: str, html: str, expect_probabilities: bool) -> None:
    parser = PercentParser()
    parser.feed(html)
    for match in parser.matches:
        check(not match["in_heading"], f"the percentage {match['value']!r} is in a heading on {name}")
        check(not match["in_cell"], f"the percentage {match['value']!r} is in a table cell on {name}")
        check(not match["in_verdict"], f"the percentage {match['value']!r} is in a verdict on {name}")
        if match["in_probability"]:
            check(
                PROBABILITY_TEXT_RE.match(str(match["value"]).strip()) is not None,
                f"the probability {match['value']!r} on {name} is not a one-decimal percentage",
            )
            check(match["in_opinion"], f"the probability {match['value']!r} is outside an opinion block on {name}")
            label = str(match["label"])
            check(
                "model's opinion" in label.lower(),
                f"the probability {match['value']!r} is not inside a block labelled a model's opinion on {name}: {label!r}",
            )
        elif match["in_opinion"]:
            raise Failure(
                f"the opinion block on {name} shows the percentage {match['value']!r} "
                "with no data-probability marker"
            )
    for number in parser.opinion_numbers:
        check(
            number["in_probability"],
            f"the opinion block on {name} shows the number {number['value']!r} with no data-probability marker",
        )
    for decimal in parser.decimals:
        raise Failure(
            f"the page {name} shows the probability-shaped decimal {decimal['value']!r} "
            "in a table, a verdict, a heading or an opinion block"
        )
    if not expect_probabilities:
        check(not parser.markers, f"the page {name} marks a probability outside the Clef block")
        return
    check(parser.opinion_blocks > 0, f"the page {name} has no opinion block")
    check(parser.markers, f"the page {name} has visible percentages but no data-probability marker")
    for label, ancestor in parser.markers:
        check(ancestor, f"the probability {label!r} is outside a labelled opinion block on {name}")
        check(
            "model's opinion" in ancestor.lower(),
            f"the probability {label!r} is not labelled a model's opinion on {name}: {ancestor!r}",
        )
    clef_labels = clef_label_map()
    for marker in parser.marker_texts:
        text = "".join(marker["text"]).strip()
        numbers = NUMBER_RE.findall(text)
        check(
            len(numbers) == 1 and PERCENT_RE.search(text) is not None,
            f"the probability {marker['label']!r} on {name} shows {numbers!r} and {text!r}, "
            "expected one one-decimal percentage",
        )
        expected_label = clef_labels.get(str(marker["label"]))
        check(expected_label is not None, f"the probability {marker['label']!r} on {name} has no Clef label")
        visible_label = "".join(marker["visible_label"]).strip()
        check(
            visible_label == expected_label,
            f"the probability {marker['label']!r} on {name} shows the label {visible_label!r}, "
            f"expected {expected_label!r}",
        )
    probabilities = sum(1 for match in parser.matches if match["in_probability"])
    check(probabilities, f"the page {name} shows no Clef probability")
    visible = text_of(html).lower()
    check("model's opinion" in visible, f"the page {name} does not show the model's opinion label")
    check("not a measurement" in visible, f"the page {name} does not say the opinion is not a measurement")
    check("not a verdict" in visible, f"the page {name} does not say the opinion is not a verdict")
    say(
        f"{probabilities} probabilities inside {parser.opinion_blocks} "
        + ("labelled opinion block" if parser.opinion_blocks == 1 else "labelled opinion blocks")
        + f" on {name}"
    )


def text_of(fragment: str) -> str:
    class TextParser(HTMLParser):
        def __init__(self) -> None:
            super().__init__(convert_charrefs=True)
            self.parts: list[str] = []

        def handle_data(self, data: str) -> None:
            if data.strip():
                self.parts.append(data)

    parser = TextParser()
    parser.feed(fragment)
    return " ".join(parser.parts)


def assert_frozen_labels() -> None:
    split = read_page("judges-frozen-split")
    split_text = text_of(split)
    check(
        "Some frozen rows are published" in split_text,
        "a split frozen show claims a published comparison",
    )
    check(
        "Frozen comparison published" not in split_text,
        "one frozen arm in each upgrade says the comparison is published",
    )
    check('data-contrast="frozen"' not in split, "a split frozen show draws a frozen contrast")

    pair = read_page("judges-frozen-pair")
    pair_text = text_of(pair)
    check("Frozen comparison published" in pair_text, "a complete frozen pair is not published")
    check('data-contrast="frozen"' in pair, "a complete frozen pair draws no frozen contrast")
    check("One repeat per condition" in pair_text, "the frozen repeat count is not derived from the records")
    check("Frozen, Kalari arm" in pair_text, "the frozen Kalari rows are not labelled frozen")
    check("Frozen, reference arm" in pair_text, "the frozen reference rows are not labelled frozen")

    run = text_of(read_page("run-frozen"))
    check("Frozen comparison run:" in run, "a frozen run page is not titled frozen")
    check("Frozen comparison run" in run, "a frozen run page has no frozen badge")
    check("Pilot run" not in run, "a frozen run page claims to be a pilot run")
    check("Measured pilot run" not in run, "a frozen run page carries the pilot badge")

    session = text_of(read_page("session-frozen"))
    check("Frozen benchmark session" in session, "a frozen session page has no frozen badge")
    check("This is a frozen benchmark session" in session, "a frozen session page claims to be a pilot session")
    check("Pilot benchmark session" not in session, "a frozen session page carries the pilot badge")
    check("This is a pilot benchmark session" not in session, "a frozen session page says the pilot sentence")
    say("one frozen row in each upgrade is not published, and a complete pair and its labels are")


COUNT_WORDS = ("none", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten")


def count_word(value: int) -> str:
    return COUNT_WORDS[value] if 0 <= value < len(COUNT_WORDS) else "more than ten"


def capitalise(value: str) -> str:
    return value[:1].upper() + value[1:] if value else value


def repeat_count(records: list[dict]) -> int:
    return len(
        {
            int(payload_of(record)["repeat"])
            for record in records
            if finite(payload_of(record).get("repeat"))
        }
    )


def repeat_phrase(count: int) -> str:
    return f"{count_word(count)} {'repeat' if count == 1 else 'repeats'}"


def condition_numbers(benchmark: list[dict]) -> set[int]:
    return {
        int(payload_of(record)["condition"])
        for record in benchmark
        if finite(payload_of(record).get("condition"))
    }


def has_frozen_pair(benchmark: list[dict]) -> bool:
    frozen = [
        record
        for record in benchmark
        if payload_of(record).get("provenance") == "frozen" and payload_of(record).get("status") == "valid"
    ]
    for upgrade in {payload_of(record).get("upgrade") for record in frozen}:
        present = {
            int(payload_of(record)["condition"])
            for record in frozen
            if payload_of(record).get("upgrade") == upgrade and finite(payload_of(record).get("condition"))
        }
        if {3, 5} <= present:
            return True
    return False


def assert_not_run_rows(name: str, html: str, benchmark: list[dict]) -> None:
    actual = sorted(int(value) for value in re.findall(r'data-not-run="(\d+)"', html))
    if not benchmark:
        check(not actual, f"the page {name} marks conditions {actual} as not run with an empty store")
        return
    expected = [condition for condition in range(1, 7) if condition not in condition_numbers(benchmark)]
    check(
        actual == expected,
        f"the page {name} marks conditions {actual} as not run, expected {expected} from the records",
    )
    text = text_of(html)
    if expected:
        check(
            "Not run. No record for this condition is in the store." in text,
            f"the page {name} gives no reason for a not-run row",
        )
    else:
        check('class="not-run"' not in html, f"the page {name} shows a not-run block and no condition is missing")


def assert_comparison_copy(name: str, html: str, benchmark: list[dict]) -> None:
    text = text_of(html)
    if not benchmark:
        return
    check("Every condition in this fixture" in text, f"the page {name} does not name the fixture conditions")
    check("Every condition, run by run" not in text, f"the page {name} keeps the old every-condition heading")
    check("Both arms ran" in text, f"the page {name} names no model for the comparison arms")
    for needle in ("bench/RESULTS.md", "bench/FROZEN.md"):
        check(needle in html, f"the page {name} does not link {needle}")
    if has_frozen_pair(benchmark):
        check("The measured before and after" in text, f"the page {name} has a frozen pair and no measured heading")
    else:
        check("The pilot baseline" in text, f"the page {name} is not labelled a pilot baseline")
        check(
            "The measured before and after" not in text,
            f"the page {name} claims the frozen before and after with no pair",
        )


def assert_pilot_copy(name: str, html: str, benchmark: list[dict]) -> None:
    valid = [
        record
        for record in benchmark
        if payload_of(record).get("provenance") != "frozen" and payload_of(record).get("status") == "valid"
    ]
    if not valid:
        return
    fresh = [
        record
        for record in valid
        if payload_of(record).get("condition") == 3 and payload_of(record).get("upgrade") == "settlements"
    ]
    notes = [
        record
        for record in valid
        if payload_of(record).get("condition") == 2 and payload_of(record).get("upgrade") == "settlements"
    ]
    text = text_of(html)
    if not fresh or not notes:
        check(
            "The pilot has no comparable notes-handoff pair for settlements yet." in text,
            f"the page {name} draws no pilot contrast and gives no reason",
        )
        return
    left, right = repeat_count(fresh), repeat_count(notes)
    if left == right:
        phrase = f"{capitalise(repeat_phrase(left))} each"
    else:
        phrase = f"{capitalise(repeat_phrase(left))} on the fresh side, {repeat_phrase(right)} on the notes side"
    check(phrase in text, f"the page {name} does not say {phrase!r} from the records")


def assert_diagnostics_copy(name: str, html: str, benchmark: list[dict]) -> None:
    diagnostics = [record for record in benchmark if payload_of(record).get("status") == "diagnostic"]
    if not diagnostics:
        check("Single-behaviour diagnostics" not in html, f"the page {name} draws a diagnostics table with no records")
        return
    groups: dict[tuple, int] = {}
    for record in diagnostics:
        key = (payload_of(record).get("upgrade"), payload_of(record).get("behaviour"))
        groups[key] = groups.get(key, 0) + 1
    sizes = set(groups.values())
    phrase = (
        f"{capitalise(count_word(sizes.pop()))} sessions for each behaviour"
        if len(sizes) == 1
        else "Several sessions for each behaviour"
    )
    check(phrase in text_of(html), f"the page {name} does not give the diagnostic repeat count from the records")


def assert_redaction() -> None:
    for name, expected in REDACTION_PAGES.items():
        html = read_page(name)
        text = text_of(html)
        check("http://" not in text and "https://" not in text, f"the page {name} shows a URL")
        check(
            PROTOCOL_RELATIVE_TEXT_RE.search(text) is None,
            f"the page {name} shows a protocol-relative URL",
        )
        count = html.count("&lt;endpoint&gt;")
        check(
            count == expected,
            f"the page {name} shows {count} redacted endpoints, expected {expected} display paths",
        )
    say(
        "every displayed store path is redacted on "
        f"{len(REDACTION_PAGES)} pages, including the source, workspace, check id, "
        "change title, change endpoint and decision question"
    )


def assert_served_pages_local(base: str) -> None:
    paths = [
        "/",
        "/session.html",
        "/run.html",
        "/app.css",
        "/favicon.svg",
        "/app/judges.mjs",
        "/app/session.mjs",
        "/app/run.mjs",
        "/app/api.mjs",
        "/app/boot.mjs",
        "/app/views.mjs",
        "/app/format.mjs",
        "/app/labels.mjs",
    ]
    for path in paths:
        status, body, content_type, headers = request(base, path)
        check(status == 200, f"GET {path} answered {status}")
        value = headers.get("Content-Security-Policy", "")
        for directive in CSP_REQUIRED:
            check(directive in value, f"GET {path} has no {directive} in its Content-Security-Policy")
        text = body.decode("utf-8", errors="replace")
        suffix = Path(path).suffix.lower()
        if suffix == ".html" or path == "/":
            problems = scan_html(text)
        elif suffix == ".css":
            problems = scan_css(text)
        elif suffix in (".mjs", ".js"):
            problems = scan_javascript(text)
        elif suffix == ".svg":
            problems = scan_svg(text)
        else:
            problems = scan_html(text)
        for problem in problems:
            raise Failure(f"{problem} in served page {path}")
    say(f"no external URL in {len(paths)} served pages and assets, and every response carries the policy")


def assert_not_published(base: str) -> None:
    benchmark = get_json(base, "/api/benchmark")
    check(benchmark == [], "/api/benchmark is not empty on the no-benchmark server")
    page = read_page("judges-empty")
    text = text_of(page).lower()
    check("not yet published" in text, "the empty benchmark state does not say not yet published")
    check("benchmark" in text, "the empty benchmark state does not explain what is missing")
    check("every figure will link to the run" in text, "the empty state does not explain what will appear")
    say("an empty /api/benchmark renders the not-yet-published state")


def assert_absent_store(base_empty: str) -> None:
    for route in ("/api/sessions", "/api/runs", "/api/lessons", "/api/benchmark"):
        value = get_json(base_empty, route)
        check(value == [], f"{route} on an absent store answered {value!r}, expected []")
    page = read_page("judges-no-store")
    text = text_of(page).lower()
    check("not yet published" in text, "the absent-store page has no empty state")
    check("not in the current evidence store" not in text, "the absent-store page claims a session it does not have")
    check("read a full session" not in text, "the absent-store page draws a session section with no session")
    say("an absent store returns empty arrays on every list route")


def load_inputs() -> dict:
    check(INPUTS.is_file(), "web/fixture/rendered/inputs.json is missing. run `node web/fixture/render.mjs`")
    data = json.loads(INPUTS.read_text(encoding="utf-8"))
    check(data.get("schema") == "kalari.web.inputs.v1", "unexpected snapshot input schema")
    pages = data.get("pages")
    check(isinstance(pages, dict), "the snapshot input file has no page map")
    check(set(pages) == set(PAGES), f"the snapshot inputs are not {', '.join(PAGES)}")
    return pages


def assert_inputs_match_api(base: str, inputs: dict) -> None:
    judges = inputs["judges"]
    for key, route in (
        ("benchmark", "/api/benchmark"),
        ("runs", "/api/runs"),
        ("sessions", "/api/sessions"),
        ("lessons", "/api/lessons"),
    ):
        check(
            judges[key] == get_json(base, route),
            f"the judges snapshot input {key!r} does not match {route}. run `node web/fixture/render.mjs`",
        )
    check(
        judges.get("containment") == get_json(base, f"/api/sessions/{CONTAINMENT_SESSION}"),
        "the judges snapshot input 'containment' does not match the containment session. run `node web/fixture/render.mjs`",
    )
    if "showcase" in judges:
        check(
            judges.get("showcase") == get_json(base, "/api/sessions/showcase-disbursements"),
            "the judges snapshot input 'showcase' does not match the showcase session. run `node web/fixture/render.mjs`",
        )
    if "reference" in judges:
        check(
            judges.get("reference") == get_json(base, f"/api/sessions/{REFERENCE_SESSION}"),
            "the judges snapshot input 'reference' does not match the reference session. run `node web/fixture/render.mjs`",
        )
    check(
        inputs["session"]["records"] == get_json(base, "/api/sessions/payouts-upgrade"),
        "the session snapshot input does not match /api/sessions/payouts-upgrade",
    )
    check(
        inputs["run"]["records"] == get_json(base, "/api/runs/pilot-c3-payouts-r5"),
        "the run snapshot input does not match /api/runs/pilot-c3-payouts-r5",
    )
    say("the snapshot inputs match the live store")


def assert_inputs_valid(inputs: dict) -> None:
    """Every record a snapshot was rendered from passes the evidence contract."""
    for name in PAGES:
        data = inputs[name]
        if name in JUDGES_PAGES:
            records = list(data["benchmark"]) + list(data.get("lessons") or []) + list(data.get("containment") or []) + list(data.get("reference") or []) + list(data.get("showcase") or [])
            if data.get("containment"):
                errors = validate_containment_records(data["containment"])
                check(not errors, f"the snapshot input {name} has a bad containment record: " + "; ".join(errors[:4]))
        elif name in SESSION_PAGES:
            records = list(data["records"]) + list(data.get("lessons") or [])
        else:
            records = data["records"]
        run_ids = set(data.get("runs") or [])
        for record in records:
            if not isinstance(record, dict):
                raise Failure(f"the snapshot input {name} holds a record that is not an object")
            for message in envelope_errors(record):
                raise Failure(f"the snapshot input {name} has a bad record: {message}")
            if record.get("kind") == "benchmark":
                errors = validate_benchmark_record(record, run_ids)
            elif looks_like_benchmark(record):
                errors = [f"a benchmark-shaped record has kind {record.get('kind')!r}"]
            else:
                errors = []
            for message in errors:
                raise Failure(f"the snapshot input {name} has a bad benchmark record: {message}")
    say("every snapshot input record passes the envelope and benchmark contract")


def assert_page_shapes(inputs: dict) -> None:
    for name in JUDGES_PAGES:
        data = inputs[name]
        benchmark = data["benchmark"]
        run_ids = set(data["runs"])
        html = read_page(name)
        assert_cell_counts(name, html, judges_cell_counts(benchmark))
        assert_values_match_records(name, html, benchmark, run_ids)
        assert_containment(name, html, data.get("containment") or [], run_ids)
        assert_hero(name, html, benchmark, run_ids, data.get("containment") or [])
        assert_reference_panel(name, html, data.get("reference") or [], run_ids)
        assert_reference_excluded(name, benchmark, data.get("reference") or [])
        assert_showcase(name, html, data.get("showcase") or [], run_ids, data.get("sessions") or [])
        assert_showcase_excluded(name, benchmark, data.get("showcase") or [])
        assert_model_tags(name, html)
        if benchmark:
            assert_medians(name, html, benchmark)
            assert_comparison_copy(name, html, benchmark)
            assert_pilot_copy(name, html, benchmark)
            assert_diagnostics_copy(name, html, benchmark)
        assert_not_run_rows(name, html, benchmark)
        assert_anchor_containers(name, html)
        assert_sessions(name, html, data.get("sessions") or [], data.get("showcase") or [], run_ids)
        assert_measure_link_count(name, html, benchmark, run_ids, "judges")
    for name in SESSION_PAGES:
        data = inputs[name]
        records = data["records"]
        run_ids = set(data["runs"])
        html = read_page(name)
        assert_cell_counts(name, html, session_cell_counts(records))
        benchmark = [record for record in records if isinstance(record, dict) and record.get("kind") == "benchmark"]
        assert_values_match_records(name, html, benchmark, run_ids)
        assert_anchor_containers(name, html)
        assert_model_tags(name, html)
        if name == "session-showcase":
            assert_showcase_session(name, html, records)
        assert_measure_link_count(name, html, benchmark, run_ids, "session")
    for name in RUN_PAGES:
        records = inputs[name]["records"]
        html = read_page(name)
        assert_cell_counts(name, html, Counter({None: 3 * len(records)}))
        assert_anchor_containers(name, html)
        assert_model_tags(name, html)
        assert_measure_link_count(name, html, [], set(inputs[name]["runs"]), "run")
        if name in ("run-containment", "run-containment-earlier"):
            assert_containment_run_page(name, html, records)
        if name == "run-reference":
            assert_reference_run_page(name, html, records)
        if name == "run-showcase":
            assert_showcase_run_page(name, html, records)
    say("every page carries the table cells and links its records require")


def main() -> int:
    print("web check")
    assert_no_external_urls()
    assert_github_pins()
    assert_private_data_is_absent()
    assert_rendered_pages_private()
    assert_published_has_no_banner()
    assert_csp_shells()
    assert_footer_landmark()
    assert_manifest()
    inputs = load_inputs()
    assert_inputs_valid(inputs)
    with Server() as server:
        assert_live_entry_points(server.base)
        assert_csp_headers(server.base)
        assert_fixture_isolation(server.base)
        assert_api_contract(server.base)
        assert_inputs_match_api(server.base, inputs)
        errors = validate_containment_records(get_json(server.base, f"/api/sessions/{CONTAINMENT_SESSION}"))
        check(not errors, "the containment evidence contract: " + "; ".join(errors[:6]))
        say("the containment evidence passes its contract and traces to its run and check records")
        reference = get_json(server.base, f"/api/sessions/{REFERENCE_SESSION}")
        check(reference, "the reference session has no records")
        for record in reference:
            for message in envelope_errors(record):
                raise Failure(f"the reference session has a bad record: {message}")
        check(
            reference_record_of(reference) is not None,
            "the reference session has no kalari.reference.v1 record",
        )
        check(
            all(record.get("kind") != "benchmark" for record in reference),
            "the reference session holds a benchmark record",
        )
        run_records = get_json(server.base, id_path(server.base, "runs", REFERENCE_RUN))
        check(run_records == reference, "the reference run page does not show the reference record")
        say("the reference run passes its envelope and stays outside the benchmark route")
        runs = set(get_json(server.base, "/api/runs"))
        benchmark = get_json(server.base, "/api/benchmark")
        benchmark_run_ids = {
            record["run_id"]
            for record in benchmark
            if record.get("kind") == "benchmark" and isinstance(record.get("run_id"), str)
        }
        assert_numbers_link_to_runs(server.base, read_page("judges"), runs, benchmark_run_ids)
        assert_page_shapes(inputs)
        assert_tables_labelled()
        for name in PAGES:
            expect = name in ("session", "run-illustrative")
            assert_clef_labels(name, read_page(name), expect)
        assert_frozen_labels()
        assert_redaction()
        assert_served_pages_local(server.base)
    with Server("--no-benchmark") as server:
        assert_not_published(server.base)
    with Server("--store", str(FIXTURE / "this-store-does-not-exist.jsonl")) as server:
        assert_absent_store(server.base)
    print("web check passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Failure as error:
        print(f"web check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
