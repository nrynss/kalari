"""Check generated navigation, assets and fragments for either deployment base."""
import argparse
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit

parser = argparse.ArgumentParser()
parser.add_argument("directory", type=Path)
parser.add_argument("--base", required=True)
args = parser.parse_args()
root = args.directory.resolve()
base = "/" + args.base.strip("/")
origin = "https://docs-check.invalid"


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.links = []
        self.ids = set()
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if "id" in values:
            self.ids.add(values["id"])
        if tag == "a" and "href" in values:
            self.links.append(values["href"])
        if tag in ("img", "script") and "src" in values:
            self.links.append(values["src"])
        if tag == "link" and values.get("rel") in ("stylesheet", "icon", "preload", "modulepreload"):
            if "href" in values:
                self.links.append(values["href"])


pages = {path: Page(path.read_text()) for path in root.rglob("*.html")}
if not pages:
    raise SystemExit("links: no HTML pages found")
failures = []
checked = set()
for path, page in pages.items():
    relative = path.relative_to(root).as_posix()
    route = relative.removesuffix("index.html")
    current = origin + base + "/" + route
    for href in page.links:
        target = urlsplit(urljoin(current, href))
        if target.netloc != "docs-check.invalid" or target.scheme != "https":
            continue
        if target.path != base and not target.path.startswith(base + "/"):
            failures.append(f"{relative}: link escapes base: {href}")
            continue
        suffix = unquote(target.path[len(base):]).lstrip("/")
        dest = root / suffix
        if dest.is_dir():
            dest = dest / "index.html"
        if not dest.is_file():
            failures.append(f"{relative}: missing target: {href}")
            continue
        checked.add(dest)
        fragment = unquote(target.fragment)
        if fragment and dest.suffix == ".html" and fragment not in pages[dest].ids:
            failures.append(f"{relative}: missing fragment: {href}")
if failures:
    raise SystemExit("\n".join(failures))
print(f"links: OK ({len(pages)} pages, {len(checked)} targets, base {base})")
