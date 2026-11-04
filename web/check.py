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
from html.parser import HTMLParser
from pathlib import Path

from fixture.validate import envelope_errors, validate_benchmark_records

REPO = Path(__file__).resolve().parent.parent
WEB = REPO / "web"
SITE = WEB / "site"
FIXTURE = WEB / "fixture"
RENDERED = FIXTURE / "rendered"
MANIFEST = RENDERED / "manifest.json"
EVIDENCE = FIXTURE / "evidence.jsonl"

PAGES = (
    "judges",
    "judges-empty",
    "judges-no-store",
    "judges-frozen-pair",
    "judges-frozen-split",
    "session",
    "session-frozen",
    "run",
    "run-frozen",
    "run-illustrative",
    "run-endpoint",
)
MAIN_PAGES = ("judges", "session", "run")
SHELLS = ("index.html", "session.html", "run.html")

ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
NUMBER_RE = re.compile(r"(?<![A-Za-z0-9])[0-9][0-9,.]*(?![A-Za-z0-9])")
PERCENT_RE = re.compile(r"[0-9]+(?:[.,][0-9]+)?\s*%")
IPV4_RE = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
HTTP_RE = re.compile(r"https?://", re.IGNORECASE)
SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
QUOTED_PROTOCOL_RELATIVE_RE = re.compile(r"""["'`](?:https?:)?//""", re.IGNORECASE)
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
CSP_REQUIRED = ("default-src 'self'", "connect-src 'self'")
HEADINGS = {"h1", "h2", "h3", "h4", "h5", "h6"}

# A deliberate view change updates these counts. They stop an extra number or
# an extra table cell from appearing without a new measure.
EXPECTED_MEASURE_LINKS = {"judges": 656, "session": 0, "run": 0}
EXPECTED_NUMBER_ANCHORS = {"judges": 879, "session": 24, "run": 1}
EXPECTED_TABLE_CELLS = {"judges": 1040, "session": 57, "run": 3}
EXPECTED_NUMERIC_CELLS = {"judges": 830, "session": 19, "run": 1}


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


class ExternalHTMLParser(HTMLParser):
    """Find external URLs in attributes or text after entity decoding."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.problems: list[str] = []

    def _check_url(self, name: str, value: str) -> None:
        value = html_module.unescape(value).strip()
        if not value or value.startswith("#"):
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
            if name in URL_ATTRIBUTES:
                if name == "srcset":
                    self._check_srcset(name, value)
                else:
                    self._check_url(name, value)
            elif name == "style":
                self._check_style(value)
            elif name.startswith("on") and HTTP_RE.search(value):
                self.problems.append(f"{name} is external: {value}")

    def handle_data(self, data: str) -> None:
        if HTTP_RE.search(data):
            self.problems.append(f"text is external: {data.strip()[:120]}")


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
        if value.startswith("//") or HTTP_RE.search(value):
            problems.append(f"{name} is external: {value}")
    for match in HTTP_RE.finditer(text):
        tail = text[match.start() : match.start() + len(SVG_NAMESPACE)]
        if tail != SVG_NAMESPACE:
            problems.append("raw external URL in SVG")
    return problems


def scan_css(text: str) -> list[str]:
    problems: list[str] = []
    for match in re.finditer(r"url\(\s*(['\"]?)(.*?)\1\s*\)", text, re.IGNORECASE | re.DOTALL):
        value = match.group(2).strip()
        if value.startswith("#"):
            continue
        if value.startswith("//") or HTTP_RE.search(value):
            problems.append(f"css url is external: {value}")
    for match in HTTP_RE.finditer(text):
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
        problems.append(f"external URL in script near: {text[max(0, match.start() - 20) : match.start() + 80]}")
    for match in QUOTED_PROTOCOL_RELATIVE_RE.finditer(text):
        problems.append(f"quoted protocol-relative URL in script near: {text[match.start() : match.start() + 80]}")
    if "String.fromCharCode" in text:
        problems.append("script assembles a string with String.fromCharCode")
    if "XMLHttpRequest" in text:
        problems.append("script can send a request outside the app's relative paths")
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
    for path in files:
        for problem in scan_file(path):
            raise Failure(f"{problem} in served file {path.relative_to(REPO)}")
    say(f"no external URL and no runtime request outside the relative paths in {len(files)} files and snapshots")


def assert_private_data_is_absent() -> None:
    text = EVIDENCE.read_text(encoding="utf-8")
    check(not IPV4_RE.findall(text), "the fixture evidence store contains an IP address")
    check(not EMAIL_RE.findall(text), "the fixture evidence store contains an email address")
    for pattern in SECRET_RES:
        check(not pattern.search(text), f"the fixture evidence store matches a secret pattern: {pattern.pattern}")
    check("http://" not in text and "https://" not in text, "the fixture evidence store contains a URL")
    say("the fixture evidence store has no IP address, email, key pattern or URL")


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
    for path in ("/", "/app.css", "/api/benchmark"):
        status, _body, _content_type, headers = request(base, path)
        check(status == 200, f"GET {path} answered {status}")
        value = headers.get("Content-Security-Policy", "")
        for directive in CSP_REQUIRED:
            check(directive in value, f"GET {path} has no {directive} in its Content-Security-Policy")
    say("the fixture server sends the same Content-Security-Policy on every route")


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
    say(
        f"{len(pages)} rendered page hashes, {len(site_files)} served file hashes, "
        "and the fixture evidence hash verified"
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
    """Collect numbers, anchors and run links from the judges page."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, dict[str, str]]] = []
        self.numbers: list[tuple[str, str, str | None]] = []
        self.anchors: list[dict[str, object]] = []
        self.anchor: dict[str, object] | None = None

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = {key: value for key, value in attrs}
        self.stack.append((tag, attributes))
        if tag == "a":
            self.anchor = {"attrs": attributes, "text": [], "href": attributes.get("href", "")}

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
            if self.stack[index][0] == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        if any(tag in ("script", "style", "noscript", "template") for tag, _ in self.stack):
            return
        if self.anchor is not None:
            self.anchor["text"].append(data)
        for match in NUMBER_RE.finditer(data):
            anchor = next((attributes for tag, attributes in reversed(self.stack) if tag == "a"), None)
            if anchor is None:
                self.numbers.append((match.group(0), data.strip()[:120], None))
            else:
                self.numbers.append(
                    (match.group(0), data.strip()[:120], run_id_from_href(anchor.get("href", "")))
                )


def assert_numbers_link_to_runs(base: str, judges_html: str, run_ids: set[str], benchmark_run_ids: set[str]) -> None:
    parser = JudgesParser()
    parser.feed(judges_html)
    check(parser.numbers, "the judges page displays no numbers at all")
    for number, context, run_id in parser.numbers:
        check(run_id is not None, f"the number {number!r} is outside a run link (near {context!r})")
        check(run_id in run_ids, f"the number {number!r} links to run {run_id!r}, which is not in /api/runs")

    linked: set[str] = set()
    measure_links = 0
    digit_anchors = 0
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
            digit_anchors += 1
            check(data_id is not None, f"an anchor shows a number but is not a run link: {anchor['text']!r}")
            check(
                data_id == run_id,
                f"an anchor shows a number but data-run-link {data_id!r} does not equal href id {run_id!r}",
            )
            check(
                title in TITLE_FIELDS or title == f"Open run {run_id}",
                f"an anchor shows a number with an unknown title: {title!r}",
            )
            if title in TITLE_FIELDS:
                measure_links += 1

    check(
        measure_links == EXPECTED_MEASURE_LINKS["judges"],
        f"the judges page has {measure_links} measure links, expected {EXPECTED_MEASURE_LINKS['judges']}",
    )
    check(
        digit_anchors == EXPECTED_NUMBER_ANCHORS["judges"],
        f"the judges page has {digit_anchors} anchors with a number, expected {EXPECTED_NUMBER_ANCHORS['judges']}",
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
    say(f"{measure_links} measure links and {digit_anchors} anchors with a number, both at the expected count")


class TableParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[str] = []
        self.row_run: str | None = None
        self.cell: dict[str, object] | None = None
        self.cells: list[dict[str, object]] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = {key: value for key, value in attrs}
        if tag == "tr":
            self.row_run = None
        if tag == "td":
            self.cell = {"label": attributes.get("data-label"), "run": None, "text": []}
        if tag == "a" and self.cell is not None:
            data_id = attributes.get("data-run-link")
            if data_id:
                self.cell["run"] = self.cell["run"] or data_id
                self.row_run = self.row_run or data_id
        self.stack.append(tag)

    def handle_endtag(self, tag: str) -> None:
        if tag == "td" and self.cell is not None:
            text = "".join(self.cell["text"]).strip()
            self.cells.append(
                {
                    "label": self.cell["label"],
                    "run": self.cell["run"] or self.row_run,
                    "text": text,
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


def assert_values_match_records(judges_html: str, benchmark: list[dict]) -> None:
    records = {
        record["run_id"]: record
        for record in benchmark
        if isinstance(record, dict) and isinstance(record.get("run_id"), str)
    }
    table_parser = TableParser()
    table_parser.feed(judges_html)
    checked = 0
    for cell in table_parser.cells:
        label = cell["label"]
        run_id = cell["run"]
        text = cell["text"]
        if label == "Behaviour":
            check(re.search(r"\bB[1-5]\b", text) is not None, f"a behaviour cell has no behaviour code: {text!r}")
            continue
        if label == "Run":
            check(bool(run_id), "a run cell has no run link")
            check(text == run_id, f"a run cell shows {text!r} instead of {run_id!r}")
            continue
        if label is None:
            check(not re.search(r"\d", text), f"an unlabelled table cell shows a number: {text!r}")
            continue
        if not run_id:
            check(not re.search(r"\d", text), f"the table cell {label!r} shows a number but has no run link")
            continue
        record = records.get(run_id)
        check(record is not None, f"a table cell links to {run_id!r}, which has no benchmark record")
        if label == "Verdict":
            expected = verdict_word((record.get("payload") or {}).get("verdict"))
        elif label == "Right first time":
            expected = bool_word((record.get("payload") or {}).get("right_first_time"))
        elif label == "Grade":
            expected = verdict_word(((record.get("payload") or {}).get("grade") or {}).get("verdict"))
        elif label in CELL_FIELDS:
            source, key, formatter = CELL_FIELDS[label]
            expected = expected_value(record, source, key, formatter)
        else:
            check(not re.search(r"\d", text), f"the table cell {label!r} is not a known measure")
            continue
        check(
            text == expected,
            f"the table value for {label!r} on {run_id!r} is {text!r}, expected {expected!r}",
        )
        checked += 1

    parser = JudgesParser()
    parser.feed(judges_html)
    measured = 0
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
            measured += 1
        elif title == f"Open run {run_id}":
            check(
                text == run_id,
                f"the run link for {run_id!r} shows {text!r} instead of the run id",
            )
        elif title:
            raise Failure(f"an anchor with data-run-link has an unknown title: {title!r}")
    say(f"{checked} table values and {measured} measure links match their records")


def assert_page_counts() -> None:
    for name in MAIN_PAGES:
        text = read_page(name)
        table_parser = TableParser()
        table_parser.feed(text)
        anchor_parser = JudgesParser()
        anchor_parser.feed(text)
        measure_links = sum(1 for anchor in anchor_parser.anchors if anchor["attrs"].get("title") in TITLE_FIELDS)
        digit_anchors = sum(1 for anchor in anchor_parser.anchors if anchor["has_digit"])
        numeric_cells = sum(1 for cell in table_parser.cells if re.search(r"\d", str(cell["text"])))
        check(
            measure_links == EXPECTED_MEASURE_LINKS[name],
            f"{name} has {measure_links} measure links, expected {EXPECTED_MEASURE_LINKS[name]}",
        )
        check(
            digit_anchors == EXPECTED_NUMBER_ANCHORS[name],
            f"{name} has {digit_anchors} anchors with a number, expected {EXPECTED_NUMBER_ANCHORS[name]}",
        )
        check(
            len(table_parser.cells) == EXPECTED_TABLE_CELLS[name],
            f"{name} has {len(table_parser.cells)} table cells, expected {EXPECTED_TABLE_CELLS[name]}",
        )
        check(
            numeric_cells == EXPECTED_NUMERIC_CELLS[name],
            f"{name} has {numeric_cells} table cells with a number, expected {EXPECTED_NUMERIC_CELLS[name]}",
        )
    say("every page carries the expected number of measure links, number anchors and table cells")


class ContrastParser(HTMLParser):
    """Read each contrast column and every median line inside it."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, dict[str, str]]] = []
        self.column: dict[str, object] | None = None
        self.column_level = 0
        self.title: list[str] = []
        self.in_title = False
        self.median: dict[str, str] | None = None
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
        elif self.column is not None and tag == "a" and attributes.get("data-run-link"):
            self.column["runs"].append(attributes["data-run-link"])
        elif self.column is not None and tag == "p" and "median-line" in classes:
            self.median = {"label": "", "value": ""}
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
            self.median[self.capture] += data


def assert_medians(judges_html: str, benchmark: list[dict]) -> None:
    parser = ContrastParser()
    parser.feed(judges_html)
    check(parser.medians, "the judges page shows no median line")
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
        expected = formatter(values[(len(values) - 1) // 2])
        check(
            median["value"] == expected,
            f"the median {label!r} in the {provenance} column for condition {condition} is "
            f"{median['value']!r}, expected {expected!r} from {len(values)} records",
        )
        checked += 1
    say(f"{checked} medians computed independently from the benchmark records")


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
    """Find every percent in visible text and the nearest opinion label."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, dict[str, str]]] = []
        self.matches: list[dict[str, object]] = []
        self.markers: list[tuple[str, str]] = []
        self.opinion_blocks = 0

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
            self.markers.append((attributes.get("data-probability", ""), " | ".join(labels)))

    def handle_endtag(self, tag: str) -> None:
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        if any(tag in ("script", "style", "template") for tag, _ in self.stack):
            return
        for match in PERCENT_RE.finditer(data):
            tags = [tag for tag, _ in self.stack]
            classes = [attributes.get("class", "") for _, attributes in self.stack]
            labels = [
                attributes.get("data-opinion-label", "")
                for _, attributes in self.stack
                if "data-opinion-label" in attributes
            ]
            self.matches.append(
                {
                    "value": match.group(0),
                    "in_heading": any(tag in HEADINGS for tag in tags),
                    "in_cell": any(tag in ("th", "td") for tag in tags),
                    "in_verdict": any("verdict" in value.split() for value in classes),
                    "in_opinion": any("data-opinion" in attributes for _, attributes in self.stack),
                    "label": " | ".join(labels),
                }
            )


def assert_clef_labels(name: str, html: str, expect_probabilities: bool) -> None:
    parser = PercentParser()
    parser.feed(html)
    if not expect_probabilities:
        check(not parser.matches, f"the page {name} shows a probability outside the Clef block")
        check(not parser.markers, f"the page {name} marks a probability outside the Clef block")
        return
    check(parser.matches, f"the page {name} shows no Clef probability")
    check(parser.opinion_blocks > 0, f"the page {name} has no opinion block")
    for match in parser.matches:
        check(not match["in_heading"], f"the probability {match['value']!r} is in a heading on {name}")
        check(not match["in_cell"], f"the probability {match['value']!r} is in a table cell on {name}")
        check(not match["in_verdict"], f"the probability {match['value']!r} is in a verdict on {name}")
        check(match["in_opinion"], f"the probability {match['value']!r} is outside an opinion block on {name}")
        label = str(match["label"])
        check(
            "model's opinion" in label.lower(),
            f"the probability {match['value']!r} is not inside a block labelled a model's opinion on {name}: {label!r}",
        )
    check(parser.markers, f"the page {name} has visible percentages but no data-probability marker")
    for label, ancestor in parser.markers:
        check(ancestor, f"the probability {label!r} is outside a labelled opinion block on {name}")
        check(
            "model's opinion" in ancestor.lower(),
            f"the probability {label!r} is not labelled a model's opinion on {name}: {ancestor!r}",
        )
    visible = text_of(html).lower()
    check("model's opinion" in visible, f"the page {name} does not show the model's opinion label")
    check("not a measurement" in visible, f"the page {name} does not say the opinion is not a measurement")
    check("not a verdict" in visible, f"the page {name} does not say the opinion is not a verdict")
    say(
        f"{len(parser.matches)} probabilities inside {parser.opinion_blocks} "
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


def assert_not_run_and_baseline() -> None:
    text = text_of(read_page("judges"))
    check("Every condition in this fixture" in text, "the section still says every condition, run by run")
    check("Every condition, run by run" not in text, "the old every-condition heading is still on the page")
    check("The pilot baseline" in text, "the pilot contrast is not labelled a pilot baseline")
    check("The measured before and after" not in text, "the pilot baseline claims the frozen before and after")
    check("Five repeats each" in text, "the pilot repeat count is not derived from the records")
    check("Five sessions for each behaviour" in text, "the diagnostic repeat count is not derived from the records")
    html = read_page("judges")
    check('data-not-run="4"' in html, "condition four has no not-run row")
    check('data-not-run="5"' in html, "condition five has no not-run row")
    check("Not run. No record for this condition is in the store." in text, "a not-run row gives no reason")
    say("conditions four and five show explicit not-run rows, and the baseline and repeat counts are labelled")


def assert_redaction() -> None:
    text = text_of(read_page("run-endpoint"))
    check("https://" not in text, "a URL in a run log reached the rendered page")
    check("<endpoint>" in text, "the run log did not redact the URL")
    say("every run log and detail string is redacted before display")


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
    check("not in the current evidence store" in text, "the absent-store page claims a session it does not have")
    say("an absent store returns empty arrays on every list route")


def main() -> int:
    print("web check")
    assert_no_external_urls()
    assert_private_data_is_absent()
    assert_rendered_pages_private()
    assert_published_has_no_banner()
    assert_csp_shells()
    assert_footer_landmark()
    assert_manifest()
    with Server() as server:
        assert_live_entry_points(server.base)
        assert_csp_headers(server.base)
        assert_fixture_isolation(server.base)
        assert_api_contract(server.base)
        judges_html = read_page("judges")
        runs = set(get_json(server.base, "/api/runs"))
        benchmark = get_json(server.base, "/api/benchmark")
        benchmark_run_ids = {
            record["run_id"]
            for record in benchmark
            if record.get("kind") == "benchmark" and isinstance(record.get("run_id"), str)
        }
        assert_numbers_link_to_runs(server.base, judges_html, runs, benchmark_run_ids)
        assert_values_match_records(judges_html, benchmark)
        assert_page_counts()
        assert_medians(judges_html, benchmark)
        assert_tables_labelled()
        for name in PAGES:
            expect = name in ("session", "run-illustrative")
            assert_clef_labels(name, read_page(name), expect)
        assert_frozen_labels()
        assert_not_run_and_baseline()
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
