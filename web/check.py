#!/usr/bin/env python3
"""Verify the Chaaya pages, the fixture store and the served static files.

The app is plain ES modules. This check is Python standard library only. It
starts the fixture server on loopback, reads the served pages, parses the
committed rendered snapshots, and verifies that every served file has a
sha256. The snapshots are produced by the same view code the browser runs.

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

from fixture.validate import validate_benchmark_records

REPO = Path(__file__).resolve().parent.parent
WEB = REPO / "web"
SITE = WEB / "site"
FIXTURE = WEB / "fixture"
RENDERED = FIXTURE / "rendered"
MANIFEST = RENDERED / "manifest.json"
EVIDENCE = FIXTURE / "evidence.jsonl"

PAGES = ("judges", "judges-empty", "judges-no-store", "session", "run", "run-illustrative")
NUMBER_RE = re.compile(r"(?<![A-Za-z0-9])[0-9][0-9,.]*(?![A-Za-z0-9])")
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
            return response.status, response.read(), response.headers.get_content_type()
    except urllib.error.HTTPError as error:
        return error.code, error.read(), error.headers.get_content_type()


def get_text(base: str, path: str) -> str:
    status, body, content_type = request(base, path)
    check(status == 200, f"GET {path} answered {status}, expected 200")
    check(
        "text" in (content_type or "") or "javascript" in (content_type or ""),
        f"GET {path} has an unexpected content type: {content_type}",
    )
    return body.decode("utf-8")


def get_json(base: str, path: str):
    status, body, content_type = request(base, path)
    check(status == 200, f"GET {path} answered {status}, expected 200")
    check("json" in (content_type or ""), f"GET {path} is not JSON: {content_type}")
    try:
        return json.loads(body)
    except json.JSONDecodeError as error:
        raise Failure(f"GET {path} did not return valid JSON: {error}") from error


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


def scan_javascript(text: str) -> list[str]:
    problems: list[str] = []
    for match in HTTP_RE.finditer(text):
        problems.append(f"external URL in script near: {text[max(0, match.start() - 20) : match.start() + 80]}")
    for match in QUOTED_PROTOCOL_RELATIVE_RE.finditer(text):
        problems.append(f"quoted protocol-relative URL in script near: {text[match.start() : match.start() + 80]}")
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
    say(f"no external URLs in {len(files)} served files and snapshots")


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


def assert_private_data_is_absent() -> None:
    text = EVIDENCE.read_text(encoding="utf-8")
    check(not IPV4_RE.findall(text), "the fixture evidence store contains an IP address")
    check(not EMAIL_RE.findall(text), "the fixture evidence store contains an email address")
    for pattern in SECRET_RES:
        check(not pattern.search(text), f"the fixture evidence store matches a secret pattern: {pattern.pattern}")
    check("http://" not in text and "https://" not in text, "the fixture evidence store contains a URL")
    say("the fixture evidence store has no IP address, email, key pattern or URL")


def assert_static_pages_have_no_banner() -> None:
    for name in ("index.html", "session.html", "run.html"):
        text = (SITE / name).read_text(encoding="utf-8")
        check("fixture-banner" not in text, f"{name} carries the fixture banner in the published file")
        check('data-fixture="true"' not in text, f"{name} carries fixture mode in the published file")
    css = (SITE / "app.css").read_text(encoding="utf-8")
    check(
        'html[data-fixture="true"] .fixture-banner' in css,
        "the print banner rule is not scoped to fixture mode",
    )
    say("the published static pages carry no fixture banner")


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
        "/check.py",
        "/check.sh",
    ):
        status, _, _ = request(base, path)
        check(status == 404, f"the fixture server served {path}: {status}")
    rendered = get_text(base, "/rendered/judges.html")
    check("fixture-banner" in rendered, "a served rendered page has no fixture banner")
    check('data-fixture="true"' in rendered, "a served rendered page is not marked as fixture mode")
    say("the fixture files are outside the published root and the served snapshots carry the banner")


class JudgesParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, dict[str, str]]] = []
        self.numbers: list[tuple[str, str, str | None]] = []
        self.run_links: list[dict[str, str | None]] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = {key: value for key, value in attrs}
        self.stack.append((tag, attributes))
        if tag == "a":
            href = attributes.get("href", "")
            run_id = run_id_from_href(href)
            data_id = attributes.get("data-run-link")
            classes = set((attributes.get("class") or "").split())
            if run_id is not None or data_id or "run-link" in classes:
                self.run_links.append({"run_id": run_id, "href": href, "data_id": data_id})

    def handle_startendtag(self, tag: str, attrs) -> None:
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        if any(tag in ("script", "style", "noscript", "template") for tag, _ in self.stack):
            return
        for match in NUMBER_RE.finditer(data):
            anchor = next((attributes for tag, attributes in reversed(self.stack) if tag == "a"), None)
            if anchor is None:
                self.numbers.append((match.group(0), data.strip()[:120], None))
            else:
                self.numbers.append(
                    (match.group(0), data.strip()[:120], run_id_from_href(anchor.get("href", "")))
                )


def assert_numbers_link_to_runs(judges_html: str, run_ids: set[str], benchmark_run_ids: set[str]) -> None:
    parser = JudgesParser()
    parser.feed(judges_html)
    check(parser.numbers, "the judges page displays no numbers at all")
    for number, context, run_id in parser.numbers:
        check(run_id is not None, f"the number {number!r} is outside a run link (near {context!r})")
        check(run_id in run_ids, f"the number {number!r} links to run {run_id!r}, which is not in /api/runs")
    for link in parser.run_links:
        run_id = link["run_id"]
        check(run_id is not None, f"a run link has no run id in its href: {link['href']!r}")
        check(
            link["data_id"] == run_id,
            f"a run link has data-run-link {link['data_id']!r} but href id {run_id!r}",
        )
        check(run_id in run_ids, f"a run link points to {run_id!r}, which is not in /api/runs")
    linked = {str(link["run_id"]) for link in parser.run_links}
    missing_benchmark = benchmark_run_ids - linked
    check(
        not missing_benchmark,
        "the judges page does not link every benchmark run. Missing: "
        + ", ".join(sorted(missing_benchmark)),
    )
    missing_runs = run_ids - linked
    check(
        not missing_runs,
        "the judges page does not link every run. Missing: " + ", ".join(sorted(missing_runs)),
    )
    say(f"{len(parser.numbers)} displayed numbers, all inside working run links")
    say(f"{len(linked)} distinct runs linked. Every run in the store is present")


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


class AnchorParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[str] = []
        self.anchor: dict[str, object] | None = None
        self.anchors: list[dict[str, object]] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = {key: value for key, value in attrs}
        if tag == "a":
            self.anchor = {"attrs": attributes, "text": []}
        self.stack.append(tag)

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self.anchor is not None:
            self.anchor["text"] = "".join(self.anchor["text"]).strip()
            self.anchors.append(self.anchor)
            self.anchor = None
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index] == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
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
    return {"PASS": "Passed", "FAIL": "Failed", "exited": "Completed", "killed_timeout": "Stopped by the time cap", "killed_output_cap": "Stopped by the output cap"}.get(value, str(value) if value else "Unknown")


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
        if label in (None, "Run", "Behaviour") or not run_id:
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

    anchor_parser = AnchorParser()
    anchor_parser.feed(judges_html)
    measured = 0
    for anchor in anchor_parser.anchors:
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
        elif title.startswith("Open "):
            check(
                text == run_id,
                f"the run link for {run_id!r} shows {text!r} instead of the run id",
            )
        elif title:
            raise Failure(f"an anchor with data-run-link has an unknown title: {title!r}")
    say(f"{checked} table values and {measured} measure links match their records")


def assert_tables_labelled() -> None:
    tables = 0
    for name in PAGES:
        text = (RENDERED / f"{name}.html").read_text(encoding="utf-8")
        for match in re.finditer(r"<table\b[^>]*>.*?</table>", text, re.DOTALL | re.IGNORECASE):
            table = match.group(0)
            opening = re.match(r"<table\b[^>]*>", table, re.IGNORECASE)
            has_caption = re.search(r"<caption\b", table, re.IGNORECASE) is not None
            has_labelled = opening is not None and "aria-labelledby" in opening.group(0)
            check(has_caption or has_labelled, f"a table in {name} has no caption or aria-labelledby")
            tables += 1
    say(f"every table has a caption or aria-labelledby ({tables} tables)")


def assert_clef_labels(session_html: str) -> None:
    class OpinionParser(HTMLParser):
        def __init__(self) -> None:
            super().__init__(convert_charrefs=True)
            self.stack: list[tuple[str, dict[str, str]]] = []
            self.probabilities: list[tuple[str, str]] = []
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
                self.probabilities.append((attributes.get("data-probability", ""), " | ".join(labels)))

        def handle_endtag(self, tag: str) -> None:
            for index in range(len(self.stack) - 1, -1, -1):
                if self.stack[index][0] == tag:
                    del self.stack[index:]
                    return

    parser = OpinionParser()
    parser.feed(session_html)
    check(parser.probabilities, "the page shows no Clef probabilities")
    check(parser.opinion_blocks > 0, "the page has no opinion block")
    for label, ancestor in parser.probabilities:
        check(ancestor, f"probability {label!r} is outside a labelled opinion block")
        check(
            "model's opinion" in ancestor.lower(),
            f"probability {label!r} is not labelled a model's opinion: {ancestor!r}",
        )
    visible = text_of(session_html).lower()
    check("model's opinion" in visible, "the page does not show the model's opinion label")
    check("not a measurement" in visible, "the page does not say the opinion is not a measurement")
    check("not a verdict" in visible, "the page does not say the opinion is not a verdict")
    say(
        f"{len(parser.probabilities)} probabilities inside {parser.opinion_blocks} "
        + ("labelled opinion block" if parser.opinion_blocks == 1 else "labelled opinion blocks")
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
        "/rendered/judges.html",
        "/rendered/judges-empty.html",
        "/rendered/judges-no-store.html",
        "/rendered/session.html",
        "/rendered/run.html",
        "/rendered/run-illustrative.html",
    ]
    for path in paths:
        status, body, content_type = request(base, path)
        check(status == 200, f"GET {path} answered {status}")
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
    say(f"no external URLs in {len(paths)} served pages and assets")


def assert_api_contract(base: str) -> None:
    sessions = get_json(base, "/api/sessions")
    runs = get_json(base, "/api/runs")
    lessons = get_json(base, "/api/lessons")
    benchmark = get_json(base, "/api/benchmark")
    check(isinstance(sessions, list) and all(isinstance(item, str) for item in sessions), "/api/sessions is not a string array")
    check(isinstance(runs, list) and all(isinstance(item, str) for item in runs), "/api/runs is not a string array")
    check(isinstance(lessons, list), "/api/lessons is not an array")
    check(isinstance(benchmark, list), "/api/benchmark is not an array")
    check(sessions and runs and lessons and benchmark, "the fixture store is unexpectedly empty")
    for record in lessons + benchmark:
        check(isinstance(record, dict), "an evidence record is not an object")
        for key in ("kind", "session_id", "run_id", "change_kinds", "payload"):
            check(key in record, f"an evidence record is missing {key}")
        check(isinstance(record["change_kinds"], list), "change_kinds is not an array")
    errors = validate_benchmark_records(benchmark, set(runs))
    check(not errors, "benchmark record contract: " + "; ".join(errors[:6]))
    session_records = get_json(base, "/api/sessions/payouts-upgrade")
    check(isinstance(session_records, list) and session_records, "the walkthrough session has no records")
    check(any(record.get("kind") == "session" for record in session_records), "the walkthrough session has no metadata record")
    run_records = get_json(base, "/api/runs/pilot-c3-payouts-r5")
    check(isinstance(run_records, list) and run_records, "the capped run has no records")
    check(any(record.get("kind") == "benchmark" for record in run_records), "the capped run has no benchmark record")

    status, _, _ = request(base, "/api/runs/does-not-exist")
    check(status == 404, f"a missing run answered {status}, expected 404")
    status, _, _ = request(base, "/api/sessions/")
    check(status == 400, f"an empty session id answered {status}, expected 400")
    status, _, _ = request(base, "/api/runs", method="POST")
    check(status == 404, f"POST /api/runs answered {status}, expected 404")
    status, _, _ = request(base, "/api/runs", method="POST", data=b"x" * 4096)
    check(status == 400, f"a 4096-byte body answered {status}, expected 400")
    status, _, _ = request(base, "/api/runs", method="POST", data=b"x" * 4097)
    check(status == 413, f"a 4097-byte body answered {status}, expected 413")
    say(
        f"{len(benchmark)} benchmark records, {len(sessions)} sessions, {len(runs)} runs. "
        "The fixture server matches the expected 400, 404 and 413 responses."
    )


def assert_not_published(base: str) -> None:
    benchmark = get_json(base, "/api/benchmark")
    check(benchmark == [], "/api/benchmark is not empty on the no-benchmark server")
    page = (RENDERED / "judges-empty.html").read_text(encoding="utf-8")
    text = text_of(page).lower()
    check("not yet published" in text, "the empty benchmark state does not say not yet published")
    check("benchmark" in text, "the empty benchmark state does not explain what is missing")
    check("every figure will link to the run" in text, "the empty state does not explain what will appear")
    say("an empty /api/benchmark renders the not-yet-published state")


def assert_absent_store(base_empty: str) -> None:
    for route in ("/api/sessions", "/api/runs", "/api/lessons", "/api/benchmark"):
        value = get_json(base_empty, route)
        check(value == [], f"{route} on an absent store answered {value!r}, expected []")
    page = (RENDERED / "judges-no-store.html").read_text(encoding="utf-8")
    text = text_of(page).lower()
    check("not yet published" in text, "the absent-store page has no empty state")
    check("not in the current evidence store" in text, "the absent-store page claims a session it does not have")
    say("an absent store returns empty arrays on every list route")


def main() -> int:
    print("web check")
    assert_no_external_urls()
    assert_private_data_is_absent()
    assert_static_pages_have_no_banner()
    assert_manifest()
    with Server() as server:
        assert_live_entry_points(server.base)
        assert_fixture_isolation(server.base)
        assert_api_contract(server.base)
        judges_html = (RENDERED / "judges.html").read_text(encoding="utf-8")
        session_html = (RENDERED / "session.html").read_text(encoding="utf-8")
        illustrative_run_html = (RENDERED / "run-illustrative.html").read_text(encoding="utf-8")
        runs = set(get_json(server.base, "/api/runs"))
        benchmark = get_json(server.base, "/api/benchmark")
        benchmark_run_ids = {
            record["run_id"]
            for record in benchmark
            if record.get("kind") == "benchmark" and isinstance(record.get("run_id"), str)
        }
        assert_numbers_link_to_runs(judges_html, runs, benchmark_run_ids)
        assert_values_match_records(judges_html, benchmark)
        assert_tables_labelled()
        assert_clef_labels(session_html)
        assert_clef_labels(illustrative_run_html)
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
