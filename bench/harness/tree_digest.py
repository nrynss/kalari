#!/usr/bin/env python3
"""Digest a workspace tree by relative path and file content.

The benchmark stages a workspace, copies it to the directory the agent works in,
and must prove the copy is the staged tree. `.git`, OpenCode's own configuration
and condition-2 notes are outside that comparison: the harness creates or attaches
them after staging.
"""
import argparse
import hashlib
import os
import sys

EXCLUDED = frozenset({".git", "opencode.jsonc", "notes-from-upgrade-one", "notes"})


def digest(root, excluded=EXCLUDED):
    if not os.path.isdir(root):
        raise SystemExit(f"tree_digest: not a directory: {root}")
    items = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if d not in excluded)
        for name in sorted(filenames):
            if name in excluded:
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            if os.path.islink(path):
                value = b"link:" + os.readlink(path).encode()
            else:
                h = hashlib.sha256()
                with open(path, "rb") as f:
                    for block in iter(lambda: f.read(1024 * 1024), b""):
                        h.update(block)
                value = b"file:" + h.hexdigest().encode()
            items.append((rel, value))
    h = hashlib.sha256()
    for rel, value in sorted(items):
        h.update(rel.encode() + b"\0" + value + b"\n")
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--manifest", action="store_true", help="print path and content hash per file")
    args = ap.parse_args()
    if args.manifest:
        for dirpath, dirnames, filenames in os.walk(args.root, followlinks=False):
            dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDED)
            for name in sorted(filenames):
                if name in EXCLUDED:
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, args.root).replace(os.sep, "/")
                if os.path.islink(path):
                    h = "link:" + os.readlink(path)
                else:
                    with open(path, "rb") as f:
                        h = hashlib.sha256(f.read()).hexdigest()
                print(f"{h}  {rel}")
    else:
        print(digest(args.root))


if __name__ == "__main__":
    main()
