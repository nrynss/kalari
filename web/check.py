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
    "session",
    "run",
    "run-containment",
)
JUDGES_PAGES = tuple(name for name in PAGES if name.startswith("judges"))
SESSION_PAGES = ("session",)
RUN_PAGES = ("run", "run-containment")
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
    "DeepSeek V4.1 Flash",
    "GLM 5.3 Flash",
    "MiMo V2.6 Flash",
    "Qwen3.8 27B",
    "Muse Glimmer 30B",
    "OpenCode 2.2.5",
    "Kalari 0.2.3",
}
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
    # inputs.json holds the exact records each snapshot was rendered from.
    # It is never served or rendered.
    files = [path for path in files if path != INPUTS]
    for path in files:
        for problem in scan_file(path):
            raise Failure(f"{problem} in served file {path.relative_to(REPO)}")
    say(f"no external URL and no runtime request outside the relative paths in {len(files)} files and snapshots")


def _commit_exists(ref: str) -> bool:
    result = subprocess.run(
        ["git", "cat-file", "-e", ref],
        cwd=REPO,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def _fetch_pinned_commit(ref: str) -> None:
    # Shallow clones (like CI's default checkout) omit history. Fetch just the
    # pinned commit instead of the whole repository. The commit must already
    # be pushed; unpushed work cannot have resolvable public links.
    result = subprocess.run(
        ["git", "fetch", "--depth", "1", "origin", ref],
        cwd=REPO,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    check(result.returncode == 0, f"EVIDENCE_REF {ref} is not reachable from origin; push the commit that sets it")


def evidence_ref() -> str:
    text = (SITE / "app/views.mjs").read_text(encoding="utf-8")
    match = EVIDENCE_REF_RE.search(text)
    check(match is not None, "views.mjs has no pinned EVIDENCE_REF hash")
    ref = match.group(1)
    if not _commit_exists(ref):
        _fetch_pinned_commit(ref)
    check(_commit_exists(ref), f"EVIDENCE_REF {ref} is not a commit in this repository")
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


def assert_share_content(base: str) -> None:
    class Metadata(HTMLParser):
        def __init__(self):
            super().__init__()
            self.values = {}

        def handle_starttag(self, tag, attrs):
            if tag == "meta":
                data = dict(attrs)
                self.values[data.get("property", data.get("name"))] = data.get("content")

    for route in ("/", "/run.html", "/session.html"):
        text = get_text(base, route)
        metadata = Metadata()
        metadata.feed(text)
        for key in ("og:title", "og:description", "og:url", "og:image",
                    "twitter:title", "twitter:description", "twitter:image"):
            check(bool(metadata.values.get(key)), f"{route} missing {key}")
        check(metadata.values.get("twitter:card") == "summary_large_image", "missing sharing card")
        image = metadata.values["og:image"]
        check(image == "https://kalari.nryn.dev/share.png", "unexpected sharing image")
        main = re.search(r"<main[^>]*>(.*?)</main>", text, re.DOTALL).group(1)
        check("<h1" in main and "/llms.txt" in main and "/docs/" in main, "empty crawler summary")
    status, image, content_type, _ = request(base, "/share.png")
    check(status == 200 and content_type == "image/png" and image.startswith(b"\x89PNG"), "sharing image unavailable")
    check(int.from_bytes(image[16:20], "big") == 1200 and int.from_bytes(image[20:24], "big") == 630, "sharing image dimensions differ")
    guide = get_text(base, "/llms.txt")
    for path in ("/api/runs", "/api/sessions", "/api/benchmark", "/api/lessons", "/docs/mcp/"):
        check(path in guide, f"machine-readable guide missing {path}")
    say("sharing metadata, no-JavaScript summaries, image and machine-readable guide verified")


def assert_live_entry_points(base: str) -> None:
    judges = get_text(base, "/")
    session = get_text(base, "/session.html?id=kalari-payouts-918666ca")
    run = get_text(base, "/run.html?id=kalari-payouts-918666ca")
    check('src="app/judges.mjs"' in judges, "the judges page does not load app/judges.mjs")
    check('src="app/session.mjs"' in session, "the session page does not load app/session.mjs")
    check('src="app/run.mjs"' in run, "the run page does not load app/run.mjs")
    check("fixture-banner" in judges, "the live shell has no fixture banner")
    check("fixture-banner" in session and "fixture-banner" in run, "a live shell has no fixture banner")
    check('data-fixture="true"' in judges, "the fixture server did not mark the page as fixture mode")
    api = get_text(base, "/app/api.mjs")
    check('judges023' in get_text(base, "/app/judges.mjs"), "the judges entry does not load the 0.2.3 view")
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
    check(sessions and runs and benchmark, "the fixture store is unexpectedly empty")
    assert_ids(sessions, "/api/sessions")
    assert_ids(runs, "/api/runs")
    for record in lessons:
        for message in envelope_errors(record):
            raise Failure(f"/api/lessons returned a bad record: {message}")
    assert_route_records(base, benchmark, "/api/benchmark")
    errors = validate_benchmark_records(benchmark, set(runs))
    check(not errors, "benchmark record contract: " + "; ".join(errors[:6]))

    for session_id in sessions:
        records = get_json(base, id_path(base, "sessions", session_id))
        assert_route_records(base, records, f"/api/sessions/{session_id}")
    for run_id in runs:
        records = get_json(base, id_path(base, "runs", run_id))
        assert_route_records(base, records, f"/api/runs/{run_id}")

    session_records = get_json(base, "/api/sessions/kalari-payouts-918666ca")
    check(
        any(
            record.get("kind") == "benchmark"
            and (record.get("payload") or {}).get("schema") == "kalari.repeat.v1"
            for record in session_records
        ),
        "the spot session has no repeat record",
    )
    run_records = get_json(base, "/api/runs/kalari-payouts-918666ca")
    check(
        any(
            record.get("kind") == "benchmark"
            and (record.get("payload") or {}).get("schema") == "kalari.repeat.v1"
            for record in run_records
        ),
        "the spot run has no repeat record",
    )

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
                self.numbers.append((match.group(0), data.strip()[:120], None, self._in_model(), False, ""))
            else:
                self.numbers.append(
                    (match.group(0), data.strip()[:120], run_id_from_href(anchor.get("href", "")), self._in_model(), True, anchor.get("href", ""))
                )



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


def format_seconds1(value) -> str:
    return f"{js_number(value, 1, 1)} s"


def format_count(value) -> str:
    return js_number(value, 0, 0)


def format_money(value) -> str:
    return f"${js_number(value, 4, 4)}"


def format_money3(value) -> str:
    return f"${js_number(value, 3, 3)}"


def format_ratio(value) -> str:
    return f"{js_number(value, 1, 1)}×"


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


def finite(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def payload_of(record: dict) -> dict:
    payload = record.get("payload")
    return payload if isinstance(payload, dict) else {}


def repeats_of(records: list) -> list:
    return [
        record
        for record in records or []
        if isinstance(record, dict)
        and record.get("kind") == "benchmark"
        and payload_of(record).get("schema") == "kalari.repeat.v1"
    ]


def baseline_of(records: list) -> dict | None:
    for record in records or []:
        if (
            isinstance(record, dict)
            and record.get("kind") == "benchmark"
            and payload_of(record).get("schema") == "kalari.baseline.v1"
        ):
            return record
    return None


def median_run(records: list, key: str) -> dict:
    values = [record for record in records if finite(payload_of(record).get(key))]
    values.sort(key=lambda record: payload_of(record)[key])
    return values[(len(values) - 1) // 2]


def mean_of(records: list, key: str):
    values = [payload_of(record).get(key) for record in records]
    if not values or any(not finite(value) for value in values):
        return None
    return sum(values) / len(values)


def arm_sets(repeats: list) -> tuple[list, list]:
    kalari = [r for r in repeats if payload_of(r).get("headline") is True and payload_of(r).get("arm") == "kalari"]
    alone = [r for r in repeats if payload_of(r).get("headline") is True and payload_of(r).get("arm") == "reference"]
    return kalari, alone


def cell_of(repeats: list, model_id: str, scenario: str, arm: str) -> list:
    return [
        record
        for record in repeats
        if payload_of(record).get("headline") is True
        and payload_of(record).get("model_id") == model_id
        and payload_of(record).get("scenario") == scenario
        and payload_of(record).get("arm") == arm
    ]


MODEL_IDS = ("glm-5.3-flash", "deepseek-v4.1-flash-1017", "mimo-v2.6-flash")
UPGRADES = ("payouts", "settlements", "disbursements")


def expected_figures(benchmark: list, containment: list) -> list:
    """Every 0.2.3 figure as (title, run id, text). Mirrors judges023.mjs."""
    repeats = repeats_of(benchmark)
    kalari, alone = arm_sets(repeats)
    figures: list = []
    kal_cost = mean_of(kalari, "cost_usd")
    ref_cost = mean_of(alone, "cost_usd")
    kal_wall = mean_of(kalari, "wall_time_s")
    ref_wall = mean_of(alone, "wall_time_s")
    kal_cost_run = median_run(kalari, "cost_usd")
    ref_cost_run = median_run(alone, "cost_usd")
    kal_wall_run = median_run(kalari, "wall_time_s")
    ref_wall_run = median_run(alone, "wall_time_s")

    def passed(records: list) -> int:
        return sum(1 for record in records if payload_of(record).get("verdict") == "PASS")

    # The problem.
    glm = cell_of(repeats, "glm-5.3-flash", "disbursements", "reference")
    ds = cell_of(repeats, "deepseek-v4.1-flash-1017", "disbursements", "reference")
    mimo = cell_of(repeats, "mimo-v2.6-flash", "disbursements", "reference")
    rep = median_run(glm, "wall_time_s")
    figures += [
        ("Problem records wrong", rep["run_id"], format_count(23)),
        ("Problem records mismatched", rep["run_id"], f"{format_count(23)} changed"),
        ("Problem records mismatched", rep["run_id"], f"{format_count(23)} mismatched records"),
        ("Problem GLM failed", rep["run_id"], f"{format_count(5)} of {format_count(5)}"),
        ("Problem DeepSeek failed", median_run(ds, "wall_time_s")["run_id"], f"{format_count(4)} of {format_count(5)}"),
        ("Problem Mimo failed", median_run(mimo, "wall_time_s")["run_id"], f"{format_count(2)} of {format_count(5)}"),
    ]
    # The headline.
    capped = sorted(
        [r for r in alone if payload_of(r).get("session_capped") is True],
        key=lambda r: r["run_id"],
    )
    figures += [
        ("Kalari pass tally", kal_wall_run["run_id"], f"{format_count(passed(kalari))}/{format_count(len(kalari))}"),
        ("Alone pass tally", ref_wall_run["run_id"], f"{format_count(passed(alone))}/{format_count(len(alone))}"),
        ("Kalari mean cost", kal_cost_run["run_id"], format_money(kal_cost)),
        ("Alone mean cost", ref_cost_run["run_id"], format_money(ref_cost)),
        ("Kalari mean wall time", kal_wall_run["run_id"], format_seconds1(kal_wall)),
        ("Alone mean wall time", ref_wall_run["run_id"], format_seconds1(ref_wall)),
        ("Cost ratio", None, f"{format_ratio(ref_cost / kal_cost)} cheaper"),
        ("Wall time ratio", None, f"{format_ratio(ref_wall / kal_wall)} faster"),
        ("Session cap", capped[0]["run_id"], f"{format_count(900)} s"),
        ("Kalari sessions", kal_cost_run["run_id"], f"{format_count(len(kalari))} sessions"),
        ("Alone sessions", ref_cost_run["run_id"], f"{format_count(len(alone))} sessions"),
    ]
    # Containment.
    containment_record = None
    for record in containment or []:
        if (
            isinstance(record, dict)
            and record.get("kind") == "containment"
            and (payload_of(record).get("result") or {}).get("verdict") == "killed_timeout"
        ):
            containment_record = record
            break
    if containment_record is not None:
        payload = payload_of(containment_record)
        result = payload.get("result") or {}
        config = payload.get("config") or {}
        observed = (payload.get("network") or {}).get("observed") or {}
        figures += [
            ("Containment measured wall time", containment_record["run_id"], f"{format_count(result.get('wall_ms'))} ms"),
            ("Containment time cap", containment_record["run_id"], f"{format_count(config.get('time_cap_ms'))} ms"),
            ("Containment pages fetched", containment_record["run_id"], f"{format_count(result.get('pages_fetched'))} pages"),
            ("Containment retry waits", containment_record["run_id"], f"{format_count(result.get('waits_for_retry_after'))} wait"),
            ("Containment allowed probes", containment_record["run_id"], f"{format_count(observed.get('allowed_attempts'))} allowed"),
            ("Containment refused probes", containment_record["run_id"], f"{format_count(observed.get('denied_attempts'))} refused"),
            ("Containment sandboxes left", containment_record["run_id"], f"{format_count(0)} sandboxes"),
            ("Containment processes left", containment_record["run_id"], f"{format_count(0)} processes"),
        ]
    # The grid.
    for model_id in MODEL_IDS:
        for scenario in UPGRADES:
            for arm in ("kalari", "reference"):
                cell = cell_of(repeats, model_id, scenario, arm)
                median = median_run(cell, "wall_time_s")
                figures.append(("Grid pass tally", median["run_id"], f"{format_count(passed(cell))}/{format_count(len(cell))}"))
    # The easier upgrades.
    easy = [r for r in alone if payload_of(r).get("scenario") != "disbursements"]
    figures.append(("Easier pass tally", median_run(easy, "wall_time_s")["run_id"], f"{format_count(passed(easy))}/{format_count(len(easy))}"))
    # Learning.
    sett = [r for r in kalari if payload_of(r).get("scenario") == "settlements"]
    dis = [r for r in kalari if payload_of(r).get("scenario") == "disbursements"]
    payouts_learn = [r for r in kalari if payload_of(r).get("scenario") == "payouts"]
    recalled = [r for r in dis if payload_of(r).get("lessons_recalled", 0) > 0]
    figures += [
        ("Settlements recalled", median_run(sett, "wall_time_s")["run_id"], f"{format_count(len(sett))}/{format_count(len(sett))}"),
        ("Disbursements recalled", median_run(recalled, "wall_time_s")["run_id"], f"{format_count(len(recalled))}/{format_count(len(dis))}"),
        ("Lessons written", median_run(payouts_learn, "wall_time_s")["run_id"], format_count(sum(payload_of(r).get("lessons_written", 0) for r in payouts_learn))),
    ]
    chain = sorted(
        [r for r in repeats if payload_of(r).get("chain") == "glm3"],
        key=lambda r: UPGRADES.index(payload_of(r).get("scenario")),
    )
    for record in chain:
        payload = payload_of(record)
        grade = payload.get("grade") or {}
        lessons = "1 written" if payload.get("scenario") == "payouts" else "1 recalled"
        figures += [
            ("Chain records", record["run_id"], f"{format_count(grade.get('records'))} of {format_count(grade.get('expected'))}"),
            ("Chain wall time", record["run_id"], format_seconds1(payload.get("wall_time_s"))),
            ("Chain cost", record["run_id"], format_money3(payload.get("cost_usd"))),
            ("Chain lessons", record["run_id"], lessons),
        ]
    # Qwen and Muse.
    def group(model_id: str, arm: str) -> list:
        return sorted(
            [r for r in repeats if payload_of(r).get("model_id") == model_id and payload_of(r).get("arm") == arm],
            key=lambda r: str(payload_of(r).get("scenario")),
        )

    groups = {
        "qwen-kalari": group("qwen3.8-27b", "kalari"),
        "muse-kalari": group("muse-glimmer-30b", "kalari"),
        "qwen-alone": group("qwen3.8-27b", "reference"),
        "muse-alone": group("muse-glimmer-30b", "reference"),
    }
    qwen_dis = next(r for r in groups["qwen-kalari"] if payload_of(r).get("scenario") == "disbursements")
    muse_dis = next(r for r in groups["muse-kalari"] if payload_of(r).get("scenario") == "disbursements")
    qwen_worst = next(r for r in groups["qwen-alone"] if payload_of(r).get("verdict") == "FAIL")
    muse_worst = next(r for r in groups["muse-alone"] if payload_of(r).get("verdict") == "FAIL")
    figures += [
        ("Excluded Qwen Kalari tally", qwen_dis["run_id"], f"{format_count(2)} of {format_count(3)}"),
        ("Excluded wall time", qwen_dis["run_id"], format_seconds1(payload_of(qwen_dis).get("wall_time_s"))),
        ("Excluded Muse Kalari tally", muse_dis["run_id"], f"{format_count(1)} of {format_count(3)}"),
        ("Excluded wall time", muse_dis["run_id"], format_seconds1(payload_of(muse_dis).get("wall_time_s"))),
        ("Excluded Qwen alone tally", qwen_worst["run_id"], f"{format_count(2)} of {format_count(3)}"),
        ("Excluded Muse alone tally", muse_worst["run_id"], f"{format_count(2)} of {format_count(3)}"),
    ]
    # The earlier baseline.
    baseline = baseline_of(benchmark)
    if baseline is not None:
        payload = payload_of(baseline)
        figures += [
            ("Baseline Kalari cost", "github:bench/RESULTS.md", format_money3(payload.get("kalari_cost_usd"))),
            ("Baseline reference cost", "github:bench/RESULTS.md", format_money3(payload.get("reference_cost_usd"))),
        ]
    # Every run.
    for record in repeats:
        payload = payload_of(record)
        grade = payload.get("grade") or {}
        figures += [
            ("Run wall time", record["run_id"], format_seconds1(payload.get("wall_time_s"))),
            ("Run cost", record["run_id"], format_money(payload.get("cost_usd"))),
            ("Run records", record["run_id"], f"{format_count(grade.get('records'))} of {format_count(grade.get('expected'))}"),
            (
                "Run lessons",
                record["run_id"],
                f"{format_count(payload.get('lessons_written'))} written, {format_count(payload.get('lessons_recalled'))} recalled",
            ),
        ]
    return figures


def assert_model_tags(name: str, html: str) -> None:
    """Model names carry digits, but they are names, not figures. Only known
    names may use the marker."""
    parser = JudgesParser()
    parser.feed(html)
    for text in parser.model_texts:
        check(text in MODEL_TAGS, f"on {name}, the model marker names an unknown model: {text!r}")
    if parser.model_texts:
        say(f"{name}: {len(parser.model_texts)} model names marked, all known")


def anchor_target(anchor: dict) -> tuple:
    """Classify a digit-bearing anchor: run, github, section or session link."""
    href = str(anchor["attrs"].get("href", ""))
    text = str(anchor["text"])
    run_id = run_id_from_href(href)
    if run_id is not None:
        return ("run", run_id)
    if re.fullmatch(r"https://github\.com/nrynss/kalari/(blob|tree)/[0-9a-f]{40}/\S+", href):
        return ("github", href)
    if href.startswith("#") and len(href) > 1:
        return ("section", href)
    session_id = session_id_from_href(href)
    if session_id is not None:
        return ("session", session_id)
    return ("other", href)


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


def assert_figures(name: str, html: str, benchmark: list, run_ids: set, containment: list) -> None:
    """Every 0.2.3 figure matches the records, and every figure links its run."""
    expected = expected_figures(benchmark, containment)
    parser = JudgesParser()
    parser.feed(html)
    actual = []
    for anchor in parser.anchors:
        title = anchor["attrs"].get("title", "")
        if title in ("Cost ratio", "Wall time ratio"):
            kind, target = anchor_target(anchor)
            check(kind == "section", f"on {name}, the ratio figure {title!r} does not link its section")
            actual.append((title, None, anchor["text"]))
        elif title in ("Baseline Kalari cost", "Baseline reference cost"):
            kind, target = anchor_target(anchor)
            check(kind == "github", f"on {name}, the baseline figure {title!r} does not link its source")
            actual.append((title, "github:bench/RESULTS.md", anchor["text"]))
        elif title and (title in REPEAT_TITLES or title.startswith("Open run ") or title == "Open containment run"):
            run_id = anchor["attrs"].get("data-run-link")
            if title.startswith("Open run ") or title == "Open containment run":
                continue
            check(run_id, f"on {name}, the figure {title!r} has no data-run-link")
            check(run_id in run_ids, f"on {name}, the figure {title!r} links {run_id!r}, which is not in /api/runs")
            actual.append((title, run_id, anchor["text"]))
    check(
        Counter(actual) == Counter(expected),
        f"on {name}, {len(actual)} figures do not match the {len(expected)} expected from the records",
    )
    say(f"{name}: {len(actual)} figures recomputed from the published rows")


REPEAT_TITLES = {
    "Problem records wrong",
    "Problem records mismatched",
    "Problem GLM failed",
    "Problem DeepSeek failed",
    "Problem Mimo failed",
    "Kalari pass tally",
    "Alone pass tally",
    "Kalari mean cost",
    "Alone mean cost",
    "Kalari mean wall time",
    "Alone mean wall time",
    "Session cap",
    "Kalari sessions",
    "Alone sessions",
    "Grid pass tally",
    "Easier pass tally",
    "Settlements recalled",
    "Disbursements recalled",
    "Lessons written",
    "Chain records",
    "Chain wall time",
    "Chain cost",
    "Chain lessons",
    "Excluded Qwen Kalari tally",
    "Excluded Muse Kalari tally",
    "Excluded Qwen alone tally",
    "Excluded Muse alone tally",
    "Excluded wall time",
    "Containment time cap",
    "Containment measured wall time",
    "Containment pages fetched",
    "Containment retry waits",
    "Containment allowed probes",
    "Containment refused probes",
    "Containment sandboxes left",
    "Containment processes left",
    "Run wall time",
    "Run cost",
    "Run records",
    "Run lessons",
    "Run sandbox runs",
    "Run mismatched",
}


def assert_number_discipline(name: str, html: str, run_ids: set) -> None:
    """Every number on the judges page is either a model name or sits inside a
    working run, GitHub, section or session link."""
    parser = JudgesParser()
    parser.feed(html)
    figures = [item for item in parser.numbers if len(item) < 4 or not item[3]]
    check(figures, f"the page {name} displays no numbers at all")
    for anchor in parser.anchors:
        if not anchor["has_digit"]:
            continue
        kind, target = anchor_target(anchor)
        text = str(anchor["text"])
        title = anchor["attrs"].get("title", "")
        if kind == "run":
            data_id = anchor["attrs"].get("data-run-link")
            check(data_id == target, f"on {name}, the run figure {text!r} has no data-run-link for {target!r}")
            check(target in run_ids, f"on {name}, the figure {text!r} links {target!r}, which is not in /api/runs")
            if text == target:
                check(title == f"Open run {target}", f"on {name}, the run id link has the title {title!r}")
            else:
                check(
                    title in REPEAT_TITLES,
                    f"on {name}, the figure {text!r} carries the unknown title {title!r}",
                )
        elif kind == "github":
            continue
        elif kind == "section":
            check(title in ("Cost ratio", "Wall time ratio"), f"on {name}, the section link {text!r} is not a ratio")
        elif kind == "session":
            check(text == target, f"on {name}, the session link shows {text!r} instead of {target!r}")
        else:
            raise Failure(f"on {name}, the anchor {text!r} shows a number outside a run, source or section link")
    # Every bare number was collected with its anchor above: only numbers
    # outside any anchor fail. Section and GitHub anchors carry figures too.
    bare = [item for item in figures if not item[4]]
    check(not bare, f"on {name}, numbers sit outside any link: {bare[:4]!r}")
    say(f"{name}: every number links its run, row or section")


def assert_reachability(name: str, html: str, benchmark: list, run_ids: set, sessions: list) -> None:
    """Every repeat row is reachable from the grid cell it counts toward, and
    every run and session in the store has a link."""
    repeats = repeats_of(benchmark)
    parser = JudgesParser()
    parser.feed(html)
    run_hrefs = {
        run_id_from_href(str(anchor["href"]))
        for anchor in parser.anchors
        if run_id_from_href(str(anchor["href"])) is not None
    }
    session_hrefs = {
        session_id_from_href(str(anchor["href"]))
        for anchor in parser.anchors
        if session_id_from_href(str(anchor["href"])) is not None
    }
    for record in repeats:
        check(record["run_id"] in run_hrefs, f"on {name}, the repeat row {record['run_id']!r} has no run link")
        check(record["run_id"] in session_hrefs, f"on {name}, the repeat row {record['run_id']!r} has no session link")
    grid_section = html[html.index('id="grid"') : html.index('id="easier"')]
    grid_parser = JudgesParser()
    grid_parser.feed(grid_section)
    grid_runs = {
        run_id_from_href(str(anchor["href"]))
        for anchor in grid_parser.anchors
        if run_id_from_href(str(anchor["href"])) is not None
    }
    headline = {r["run_id"] for r in repeats if payload_of(r).get("headline")}
    check(headline <= grid_runs, f"on {name}, the grid misses headline rows")
    check(len(headline) == 90, f"on {name}, the headline holds {len(headline)} rows, expected 90")
    say(f"{name}: all {len(repeats)} repeat rows are linked, and the grid holds its 90")
    check(set(sessions or []) <= session_hrefs, f"on {name}, a session in the store has no link")
    say(f"{name}: every session in the store has a link")


def assert_copy(name: str, html: str, benchmark: list) -> None:
    text = text_of(html)
    for phrase in (
        "The problem",
        "reported verified",
        "23 payments",
        "The headline",
        "Three models, five repeats",
        "Where the gain sits",
        "entirely in disbursements",
        "Learning, measured",
        "recalled it",
        "this run only",
        "never ran without the lesson",
        "Containment on",
        "never stops",
        "second guest",
        "not a claim of zero blast radius",
        "Outside the headline",
        "code mode",
        "malformed first tool call",
        "The earlier baseline",
        "demoted",
        "contradict",
        "does not verify on its own",
        "Every run",
        "Read a session",
    ):
        check(phrase in text, f"on {name}, the copy lacks {phrase!r}")
    for gone in (
        "showed no benefit",
        "verifies on its own",
        "manufactured",
        "The pilot baseline",
        "zero-lesson",
        "DeepSeek verifies",
    ):
        check(gone not in text, f"on {name}, the copy keeps the retired claim {gone!r}")
    check('id="problem"' in html and 'id="headline"' in html, f"on {name}, a part section is missing")
    for section in ("easier", "learning", "containment", "excluded", "baseline", "runs", "sessions"):
        check(f'id="{section}"' in html, f"on {name}, the {section} section is missing")
    baseline = baseline_of(benchmark)
    assert baseline is not None
    for needle in ("bench/RESULTS.md", "bench/FROZEN.md", "bench/rows-0.2.3/"):
        check(needle in html, f"on {name}, the page does not link {needle}")
    say(f"{name}: all seven parts present, retired claims gone")


def assert_every_run_table(name: str, html: str, benchmark: list, run_ids: set) -> None:
    """Each every-run cell matches the record its row links."""
    repeats = {record["run_id"]: record for record in repeats_of(benchmark)}
    ref = evidence_ref()
    parser = TableParser()
    parser.feed(html)
    by_run: dict = {}
    for cell in parser.cells:
        if cell["run"] is None:
            continue
        titles = [a["attrs"].get("title", "") for a in cell["anchors"]]
        if any(titles) and not all(
            title == f"Open run {cell['run']}" or title.startswith("Run ") for title in titles if title
        ) and not (cell["label"] == "Row" and not any(titles)):
            continue  # a chain or excluded-table cell, checked elsewhere
        by_run.setdefault(cell["run"], {})[cell["label"]] = cell
    check(set(by_run) == set(repeats), f"on {name}, the every-run table covers {len(by_run)} rows, expected {len(repeats)}")
    checked = 0
    for run_id, cells in by_run.items():
        record = repeats[run_id]
        payload = payload_of(record)
        grade = payload.get("grade") or {}
        check(run_id in run_ids, f"on {name}, the table links {run_id!r}, which is not in /api/runs")
        run_cell = cells.get("Run")
        check(run_cell is not None, f"on {name}, the row for {run_id!r} has no run cell")
        anchors = [(a["attrs"].get("title"), a["attrs"].get("data-run-link"), a["text"]) for a in run_cell["anchors"]]
        check(anchors == [(f"Open run {run_id}", run_id, run_id)], f"on {name}, the run cell for {run_id!r} links {anchors}")
        expectations = {
            "Wall time": ("Run wall time", format_seconds1(payload.get("wall_time_s"))),
            "Cost": ("Run cost", format_money(payload.get("cost_usd"))),
            "Records": ("Run records", f"{format_count(grade.get('records'))} of {format_count(grade.get('expected'))}"),
            "Lessons": (
                "Run lessons",
                f"{format_count(payload.get('lessons_written'))} written, {format_count(payload.get('lessons_recalled'))} recalled",
            ),
        }
        for label, (title, text) in expectations.items():
            cell = cells.get(label)
            check(cell is not None, f"on {name}, the row for {run_id!r} has no {label!r} cell")
            got = [(a["attrs"].get("title"), a["attrs"].get("data-run-link"), a["text"]) for a in cell["anchors"]]
            check(got == [(title, run_id, text)], f"on {name}, the {label!r} cell for {run_id!r} is {got}, expected {[(title, run_id, text)]}")
            checked += 1
        for label in ("Verdict", "Model", "Arm", "Upgrade"):
            cell = cells.get(label)
            check(cell is not None and not cell["anchors"], f"on {name}, the {label!r} cell for {run_id!r} links a value")
        row_cell = cells.get("Row")
        check(row_cell is not None, f"on {name}, the row for {run_id!r} has no row cell")
        row_links = [a["attrs"].get("href", "") for a in row_cell["anchors"]]
        source = payload_of(record).get("source", "")
        check(
            row_links == [f"https://github.com/nrynss/kalari/blob/{ref}/{source}"],
            f"on {name}, the row cell for {run_id!r} links {row_links}",
        )
    say(f"{name}: {checked} every-run cells match their records")


CONTAINMENT_SESSION = "containment-023"


def containment_record_of(records: list) -> dict | None:
    found = [
        record
        for record in records or []
        if isinstance(record, dict)
        and record.get("kind") == "containment"
        and payload_of(record).get("schema") == "kalari.containment.v1"
    ]
    for record in found:
        if (payload_of(record).get("result") or {}).get("verdict") == "killed_timeout":
            return record
    return found[0] if found else None


def validate_containment_records(records: list) -> list[str]:
    """The 0.2.3 containment contract: the killed run traces to its run and
    check records, the probe is recorded apart, and cleanup is verified."""
    errors: list[str] = []
    found = [
        record
        for record in records
        if isinstance(record, dict)
        and record.get("kind") == "containment"
        and payload_of(record).get("schema") == "kalari.containment.v1"
    ]
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
            errors.append(tag + "session id is not containment-023")
        if not isinstance(run_id, str) or not ID_RE.match(run_id):
            errors.append(tag + "run id is not a valid id")
        if p.get("benchmark") is not False:
            errors.append(tag + "payload does not say it is not a benchmark")
        config, result = p.get("config") or {}, p.get("result") or {}
        for key in ("time_cap_ms", "output_cap_bytes", "memory_mib"):
            if not (finite(config.get(key)) and config[key] > 0):
                errors.append(tag + f"config.{key} is not a positive number")
        if not (finite(result.get("wall_ms")) and result["wall_ms"] >= 0):
            errors.append(tag + "result.wall_ms is not a number")
        if result.get("verdict") != "killed_timeout" or result.get("passed") is not False:
            errors.append(tag + "result is not killed_timeout with passed=false")
        if not (finite(result.get("pages_fetched")) and result["pages_fetched"] > 0):
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
        runs = [r for r in records if r.get("kind") == "run" and r.get("run_id") == run_id]
        if len(runs) != 1:
            errors.append(tag + "no single run record")
        else:
            rp = payload_of(runs[0])
            if (rp.get("request") or {}).get("caps", {}).get("timeout_ms") != config.get("time_cap_ms"):
                errors.append(tag + "run record time cap differs from the containment config")
            if (rp.get("verdict") or {}).get("wall_ms") != result.get("wall_ms"):
                errors.append(tag + "run record wall_ms differs from the containment result")
            if (rp.get("verdict") or {}).get("verdict") != result.get("verdict"):
                errors.append(tag + "run record verdict differs from the containment result")
        if not [r for r in records if r.get("kind") == "check" and r.get("run_id") == run_id]:
            errors.append(tag + "no check records")
    return errors


def assert_containment_panel(name: str, html: str, containment: list, run_ids: set) -> None:
    """The containment panel matches its record and keeps its claims qualified."""
    record = containment_record_of(containment or [])
    has_section = 'id="containment"' in html
    if record is None:
        check(not has_section, f"on {name}, a containment panel is drawn with no containment record")
        return
    check(has_section, f"on {name}, the containment records have no panel")
    start = html.index('<section id="containment"')
    section = html[start : html.index("</section>", start)]
    p = payload_of(record)
    result = p.get("result") or {}
    config = p.get("config") or {}
    observed = (p.get("network") or {}).get("observed") or {}
    text = text_of(section)
    run_id = record["run_id"]
    expected_bits = [
        f"{format_count(config.get('time_cap_ms'))} ms",
        f"{format_count(result.get('wall_ms'))} ms",
        f"{format_count(result.get('pages_fetched'))} pages",
        f"{format_count(result.get('waits_for_retry_after'))} wait",
        f"{format_count(observed.get('allowed_attempts'))} allowed",
        f"{format_count(observed.get('denied_attempts'))} refused",
        f"{format_count(0)} sandboxes",
        f"{format_count(0)} processes",
    ]
    for bit in expected_bits:
        check(bit in text, f"on {name}, the containment panel lacks {bit!r}")
    for needle in (
        "killed_timeout",
        "passed is false",
        "polling",
        "No fixed overshoot",
        "configuration only",
        "Requested:",
        "second guest",
        "not a benchmark session",
        "not a claim of zero blast radius",
    ):
        check(needle in text, f"on {name}, the containment panel lacks {needle!r}")
    for needle in (
        "tests/live/containment-0.2.3/evidence.jsonl",
        "tests/live/containment-0.2.3/transcript.txt",
    ):
        check(needle in section, f"on {name}, the containment panel lacks the link {needle!r}")
    for attempt in observed.get("attempts") or []:
        check(attempt["label"] in text, f"on {name}, the panel omits the probe {attempt['label']!r}")
    cleanup = p.get("cleanup") or {}
    created = len(cleanup.get("sandboxes_created") or [])
    check(cleanup.get("ok") is True and f"{format_count(created)} sandboxes" in text or "Both sandboxes" in text or "sandboxes it created" in text,
          f"on {name}, the panel does not show verified cleanup")
    check(
        f'href="run.html?id={run_id}"' in section,
        f"on {name}, the panel does not link its run page",
    )
    check(
        f'href="session.html?id={CONTAINMENT_SESSION}"' in section,
        f"on {name}, the panel does not link its session",
    )
    for word in ("demonstration", "deliberate"):
        check(word not in text.lower(), f"on {name}, the panel carries the label {word!r}")
    say(f"{name}: the containment panel matches its record")


def assert_containment_run_page(name: str, html: str, records: list) -> None:
    record = containment_record_of(records)
    check(record is not None, f"{name} has no containment record")
    p = payload_of(record)
    text = text_of(html)
    for needle in (
        "Containment evidence",
        "Configured time cap",
        "Measured wall time",
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
    for needle in (
        "tests/live/containment-0.2.3/evidence.jsonl",
        "tests/live/containment-0.2.3/transcript.txt",
    ):
        check(needle in html, f"on {name}, the containment evidence lacks the link {needle!r}")
    check(html.count("<table") <= 1, f"on {name}, the containment evidence added a table")
    for word in ("demonstration", "deliberate"):
        check(word not in text.lower(), f"on {name}, the run page carries the label {word!r}")


SPOT_RUN = "kalari-payouts-918666ca"


def assert_repeat_run_page(name: str, html: str, records: list, run_ids: set) -> None:
    repeats = [r for r in records if payload_of(r).get("schema") == "kalari.repeat.v1"]
    check(len(repeats) == 1, f"{name} does not hold one repeat record")
    record = repeats[0]
    payload = payload_of(record)
    grade = payload.get("grade") or {}
    text = text_of(html)
    for needle in (
        "Repeat session",
        verdict_word(payload.get("verdict")),
        format_seconds(payload.get("wall_time_s")),
        format_money(payload.get("cost_usd")),
        format_count(payload.get("sandbox_runs")),
        f"{format_count(grade.get('records'))} of {format_count(grade.get('expected'))}",
        f"{format_count(payload.get('lessons_written'))} written",
        f"{format_count(payload.get('lessons_recalled'))} recalled",
        str(payload.get("source") or ""),
    ):
        check(needle in text, f"on {name}, the repeat run page lacks {needle!r}")
    check(html.count("<table") <= 1, f"on {name}, the repeat evidence added a table")


def assert_repeat_session_page(name: str, html: str, records: list) -> None:
    repeats = [r for r in records if payload_of(r).get("schema") == "kalari.repeat.v1"]
    check(len(repeats) == 1, f"{name} does not hold one repeat record")
    text = text_of(html)
    for needle in ("Repeat session", "Back to the evidence index"):
        check(needle in text, f"on {name}, the repeat session page lacks {needle!r}")


def assert_empty(name: str, html: str) -> None:
    text = text_of(html).lower()
    check("not yet published" in text, f"on {name}, the empty state does not say not yet published")
    check("every figure will link" in text, f"on {name}, the empty state does not explain what will appear")


class PercentParser(HTMLParser):
    """Find percentages and probability-shaped decimals in visible text.

    A percentage in a table cell, a verdict or a heading fails. The 0.2.3 page
    carries no opinion block, so any percentage fails.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, dict[str, str]]] = []
        self.matches: list[dict[str, object]] = []
        self.decimals: list[dict[str, object]] = []

    def _flags(self) -> dict[str, object]:
        tags = [tag for tag, _ in self.stack]
        classes = [attributes.get("class", "") for _, attributes in self.stack]
        return {
            "in_heading": any(tag in HEADINGS for tag in tags),
            "in_cell": any(tag in ("th", "td") for tag in tags),
            "in_verdict": any("verdict" in value.split() for value in classes),
        }

    def handle_starttag(self, tag: str, attrs) -> None:
        self.stack.append((tag, {key: value for key, value in attrs}))

    def handle_endtag(self, tag: str) -> None:
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        if any(tag in ("script", "style", "template") for tag, _ in self.stack):
            return
        flags = self._flags()
        for match in PERCENT_RE.finditer(data):
            self.matches.append({"value": match.group(0), **flags})
        for match in DECIMAL_RE.finditer(data):
            value = float(match.group(0))
            if not 0 < value < 1:
                continue
            if re.match(r"\s*[A-Za-z%]", data[match.end() :]):
                continue
            if re.match(r"\.\d", data[match.start() - 1 : match.start()]):
                continue
            self.decimals.append({"value": match.group(0), **flags})


def assert_no_percentages(name: str, html: str) -> None:
    parser = PercentParser()
    parser.feed(html)
    for match in parser.matches:
        raise Failure(f"the page {name} shows the percentage {match['value']!r}")
    for decimal in parser.decimals:
        if decimal["in_heading"] or decimal["in_cell"] or decimal["in_verdict"]:
            raise Failure(f"the page {name} shows the probability-shaped decimal {decimal['value']!r}")
    say(f"{name}: no percentages and no probability-shaped decimals in figures")


def text_of(fragment: str) -> str:
    class TextParser(HTMLParser):
        def __init__(self) -> None:
            super().__init__(convert_charrefs=True)
            self.parts: list[str] = []

        def handle_data(self, data: str) -> None:
            if data.strip():
                self.parts.append(data.strip())

    parser = TextParser()
    parser.feed(fragment)
    return re.sub(r"\s+", " ", " ".join(parser.parts)).strip()


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
    check(
        inputs["session"]["records"] == get_json(base, f"/api/sessions/{SPOT_RUN}"),
        "the session snapshot input does not match the spot session. run `node web/fixture/render.mjs`",
    )
    check(
        inputs["run"]["records"] == get_json(base, f"/api/runs/{SPOT_RUN}"),
        "the run snapshot input does not match the spot run. run `node web/fixture/render.mjs`",
    )
    check(
        inputs["run-containment"]["records"]
        == get_json(base, f"/api/runs/{containment_record_of(get_json(base, f'/api/sessions/{CONTAINMENT_SESSION}'))['run_id']}"),
        "the containment run snapshot input does not match the store. run `node web/fixture/render.mjs`",
    )
    say("the snapshot inputs match the live store")


def assert_inputs_valid(inputs: dict) -> None:
    """Every record a snapshot was rendered from passes the evidence contract."""
    for name in PAGES:
        data = inputs[name]
        if name.startswith("judges"):
            records = list(data["benchmark"]) + list(data.get("lessons") or []) + list(data.get("containment") or [])
            if data.get("containment"):
                errors = validate_containment_records(data["containment"])
                check(not errors, f"the snapshot input {name} has a bad containment record: " + "; ".join(errors[:4]))
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


def load_inputs() -> dict:
    check(INPUTS.is_file(), "web/fixture/rendered/inputs.json is missing. run `node web/fixture/render.mjs`")
    data = json.loads(INPUTS.read_text(encoding="utf-8"))
    check(data.get("schema") == "kalari.web.inputs.v1", "unexpected snapshot input schema")
    pages = data.get("pages")
    check(isinstance(pages, dict), "the snapshot input file has no page map")
    check(set(pages) == set(PAGES), f"the snapshot inputs are not {', '.join(PAGES)}")
    return pages


def assert_page_shapes(inputs: dict) -> None:
    data = inputs["judges"]
    benchmark = data["benchmark"]
    run_ids = set(data["runs"])
    html = read_page("judges")
    assert_figures("judges", html, benchmark, run_ids, data.get("containment") or [])
    assert_number_discipline("judges", html, run_ids)
    assert_reachability("judges", html, benchmark, run_ids, data.get("sessions"))
    assert_copy("judges", html, benchmark)
    assert_every_run_table("judges", html, benchmark, run_ids)
    assert_containment_panel("judges", html, data.get("containment") or [], run_ids)
    assert_model_tags("judges", html)
    assert_no_percentages("judges", html)
    assert_empty("judges-empty", read_page("judges-empty"))
    assert_empty("judges-no-store", read_page("judges-no-store"))
    run_ids_spot = set(inputs["run"]["runs"])
    assert_repeat_run_page("run", read_page("run"), inputs["run"]["records"], run_ids_spot)
    assert_repeat_session_page("session", read_page("session"), inputs["session"]["records"])
    assert_containment_run_page("run-containment", read_page("run-containment"), inputs["run-containment"]["records"])
    assert_model_tags("run", read_page("run"))
    assert_model_tags("session", read_page("session"))
    assert_no_percentages("run", read_page("run"))
    assert_no_percentages("session", read_page("session"))
    assert_no_percentages("run-containment", read_page("run-containment"))
    assert_model_tags("run-containment", read_page("run-containment"))
    say("every page carries the figures and links its records require")


def assert_served_023(base: str) -> None:
    runs = set(get_json(base, "/api/runs"))
    benchmark = get_json(base, "/api/benchmark")
    repeats = repeats_of(benchmark)
    check(len(repeats) == 105, f"/api/benchmark holds {len(repeats)} repeats, expected 105")
    check(baseline_of(benchmark) is not None, "/api/benchmark has no baseline record")
    containment = get_json(base, f"/api/sessions/{CONTAINMENT_SESSION}")
    check(containment_record_of(containment) is not None, "the containment session has no killed run")
    say(f"{len(repeats)} repeats, the baseline and the containment run are served")


def assert_published_rows_match() -> None:
    """The video numbers recomputed from the published rows match results.json."""
    result = subprocess.run(
        [sys.executable, str(REPO / "bench" / "check-023.py")],
        cwd=REPO,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    check(result.returncode == 0, "bench/check-023.py failed:\n" + (result.stdout or ""))
    say("every video number recomputed from the published rows matches results.json")


def assert_published_data_private() -> None:
    """The published 0.2.3 data holds no path, IP, host name or key."""
    targets = sorted((REPO / "bench" / "rows-0.2.3").glob("*.json"))
    targets += [REPO / "bench" / "evidence-023.jsonl"]
    targets += sorted((REPO / "tests" / "live" / "containment-0.2.3").glob("*"))
    ip = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
    host = re.compile(r"[A-Za-z0-9._-]+\.(?:internal|local|dev|com|net|org|io)\b")
    for path in targets:
        if not path.is_file():
            continue
        body = path.read_text(encoding="utf-8")
        name = path.relative_to(REPO)
        check("/home/" not in body, f"{name} contains a home path")
        check(not ip.findall(body), f"{name} contains an IP address")
        check(not EMAIL_RE.findall(body), f"{name} contains an email address")
        for pattern in SECRET_RES:
            check(not pattern.search(body), f"{name} matches a secret pattern: {pattern.pattern}")
        for match in host.findall(body):
            check(
                match in ("host.microsandbox.internal",) or False,
                f"{name} contains a host name: {match}",
            )
        check("kfilm" not in body, f"{name} contains a user name")
    say(f"{len(targets)} published 0.2.3 files hold no path, IP, host name or key")


def assert_not_published(base: str) -> None:
    benchmark = get_json(base, "/api/benchmark")
    check(benchmark == [], "/api/benchmark is not empty on the no-benchmark server")
    page = read_page("judges-empty")
    text = text_of(page).lower()
    check("not yet published" in text, "the empty benchmark state does not say not yet published")
    check("every figure will link" in text, "the empty state does not explain what will appear")
    say("an empty /api/benchmark renders the not-yet-published state")


def assert_absent_store(base: str) -> None:
    for route in ("/api/sessions", "/api/runs", "/api/lessons", "/api/benchmark"):
        value = get_json(base, route)
        check(value == [], f"{route} on an absent store answered {value!r}, expected []")
    page = read_page("judges-no-store")
    text = text_of(page).lower()
    check("not yet published" in text, "the absent-store page has no empty state")
    check("not in the current evidence store" not in text, "the absent-store page claims a session it does not have")
    check("read a session" not in text, "the absent-store page draws a session section with no session")
    say("an absent store returns empty arrays on every list route")


def assert_head_routes(base: str, detail: str) -> None:
    # The fixture server answers HEAD with the GET status and headers and no
    # body. Lean itself is GET-only and 404s HEAD (proved in tests/http-api.sh);
    # this checks the fixture server only.
    paths = ["/api/sessions", "/api/runs", "/api/lessons", "/api/benchmark",
             detail, "/api/runs/does-not-exist", "/api/runs/", "/api/runs?bad"]
    for path in paths:
        status, body, content_type, headers = request(base, path)
        head_status, head_body, head_type, head_headers = request(base, path, method="HEAD")
        check(head_status == status, f"HEAD status differs for {path}")
        check(head_body == b"", f"HEAD returned a body for {path}")
        check(head_type == content_type, f"HEAD content type differs for {path}")
        check(head_headers.get("Content-Length") == headers.get("Content-Length") == str(len(body)),
              f"HEAD content length differs for {path}")
    for size, expected in [(1, 400), (4097, 413)]:
        status, body, _, _ = request(base, "/api/runs", method="HEAD", data=b"x" * size)
        check(status == expected and body == b"", "HEAD body validation failed")


def assert_served_pages_local(base: str) -> None:
    paths = [
        "/",
        "/session.html",
        "/run.html",
        "/app.css",
        "/favicon.svg",
        "/app/judges.mjs",
        "/app/judges023.mjs",
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


def assert_judges_classes_have_css() -> None:
    """Every class the judges page emits has a CSS rule, so no emitted
    block (in particular the 0.2.3 grid) renders as an unstyled list."""

    class ClassParser(HTMLParser):
        def __init__(self) -> None:
            super().__init__(convert_charrefs=True)
            self.found: set[str] = set()

        def handle_starttag(self, tag: str, attrs) -> None:
            for key, value in attrs:
                if key == "class":
                    for token in value.split():
                        self.found.add(token)

    parser = ClassParser()
    parser.feed(read_page("judges"))
    css = css_without_comments((SITE / "app.css").read_text(encoding="utf-8"))
    missing = sorted(
        name for name in parser.found if not re.search(r"\." + re.escape(name) + r"(?![\w-])", css)
    )
    check(not missing, f"the judges page uses classes with no CSS rule: {', '.join(missing)}")
    for name in ("grid-model", "grid-upgrade", "grid-arms", "grid-arm", "grid-arm-name", "grid-cell", "grid-count"):
        check(name in parser.found, f"the judges page no longer emits .{name}")
    say(f"every class the judges page emits has a CSS rule ({len(parser.found)} classes)")


FALLBACK_RETIRED = (
    "manufactured migration showcase",
    "published no lessons",
    "empty recall",
)
FALLBACK_023 = (
    "three models",
    "three upgrades",
    "five repeats",
    "45 of 45",
    "34 of 45",
    "recalled",
    "earlier baseline",
)


def assert_fallback_copy() -> None:
    """The index.html fallback tells the 0.2.3 story, not the retired one."""
    text = (SITE / "index.html").read_text(encoding="utf-8")
    lowered = text.lower()
    for phrase in FALLBACK_RETIRED:
        check(phrase not in lowered, f"index.html still tells the old story: {phrase!r}")
    main_text = re.search(r"<main[^>]*>(.*?)</main>", text, re.DOTALL)
    check(main_text is not None, "index.html has no main element")
    summary = text_of(main_text.group(1)).lower()
    for phrase in FALLBACK_023:
        check(phrase in summary, f"the index.html fallback lacks the 0.2.3 summary phrase {phrase!r}")
    say("the index.html fallback carries the 0.2.3 summary, not the retired story")


def main() -> int:
    print("web check")
    assert_no_external_urls()
    assert_github_pins()
    assert_private_data_is_absent()
    assert_rendered_pages_private()
    assert_published_has_no_banner()
    assert_csp_shells()
    assert_footer_landmark()
    assert_judges_classes_have_css()
    assert_fallback_copy()
    assert_manifest()
    inputs = load_inputs()
    assert_inputs_valid(inputs)
    with Server() as server:
        assert_live_entry_points(server.base)
        assert_share_content(server.base)
        assert_csp_headers(server.base)
        assert_fixture_isolation(server.base)
        assert_api_contract(server.base)
        assert_head_routes(server.base, f"/api/runs/{SPOT_RUN}")
        assert_inputs_match_api(server.base, inputs)
        errors = validate_containment_records(get_json(server.base, f"/api/sessions/{CONTAINMENT_SESSION}"))
        check(not errors, "the containment evidence contract: " + "; ".join(errors[:6]))
        say("the containment evidence passes its contract and traces to its run and check records")
        runs = set(get_json(server.base, "/api/runs"))
        benchmark = get_json(server.base, "/api/benchmark")
        assert_served_023(server.base)
        assert_page_shapes(inputs)
        assert_tables_labelled()
        assert_served_pages_local(server.base)
    with Server("--no-benchmark") as server:
        assert_not_published(server.base)
    with Server("--store", str(FIXTURE / "this-store-does-not-exist.jsonl")) as server:
        assert_absent_store(server.base)
    assert_published_rows_match()
    assert_published_data_private()
    print("web check passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Failure as error:
        print(f"web check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
