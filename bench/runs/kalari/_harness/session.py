#!/usr/bin/env python3
"""Prepare trusted Kalari session files; does not execute services or inference.

Suite-aware: payouts uses payout_sync.py and openapi specs; settlements uses
settlement_reconcile.py and graphql specs. The Lambo store path and repo scope
are caller-chosen so condition 5 can keep one store across both upgrades of a
repeat while condition 4 always starts fresh.
"""
import argparse
import json
import os
from pathlib import Path
import shutil

SUITES = {
    'payouts': {
        'consumer': 'payout_sync.py',
        'old_spec': 'specs/openapi-v1.yaml',
        'new_spec': 'specs/openapi-v2.yaml',
        'artifact': 'payouts.jsonl',
    },
    'settlements': {
        'consumer': 'settlement_reconcile.py',
        'old_spec': 'specs/schema-v1.graphql',
        'new_spec': 'specs/schema-v2.graphql',
        'artifact': 'settlements.jsonl',
    },
}

p = argparse.ArgumentParser()
p.add_argument('--directory', type=Path, required=True)
p.add_argument('--workspace-source', type=Path, required=True)
p.add_argument('--tools', type=Path, required=True)
p.add_argument('--api-host', required=True)
p.add_argument('--api-port', type=int, default=18080)
p.add_argument('--key-env', default='VULTR_INFERENCE_API_KEY')
p.add_argument('--suite', choices=sorted(SUITES), default='payouts')
p.add_argument('--lambo-db', type=Path, required=True)
p.add_argument('--repo-scope', default='live')
a = p.parse_args()
import ipaddress
host = str(ipaddress.IPv4Address(a.api_host))
if not 1 <= a.api_port <= 65535 or not a.key_env.isidentifier():
    p.error('invalid port or key environment variable name')
suite = SUITES[a.suite]
tools = a.tools.resolve(strict=True)
source = a.workspace_source.resolve(strict=True)
for name in ('kalari', 'kalari-aashaan', 'msb', 'vimanam', 'lambo'):
    if not (tools / name).is_file() or not os.access(tools / name, os.X_OK):
        p.error('missing executable ' + name)
for name in (suite['consumer'], suite['old_spec'], suite['new_spec']):
    if not (source / name).is_file():
        p.error('missing workspace file ' + name)
a.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
root = a.directory.resolve(strict=True)
shutil.copytree(source, root / 'candidate', symlinks=False)
shutil.copytree(source, root / 'baseline', symlinks=False)
for name in ('checks', 'evidence'):
    (root / name).mkdir(mode=0o700)
lambo_db = a.lambo_db.resolve() if a.lambo_db.exists() else a.lambo_db.absolute()
lambo_db.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
(root / 'lambo.toml').write_text('[store]\nkind = "sqlite"\npath = '+json.dumps(str(lambo_db))+'\n[embedder]\nkind = "fixture"\n[serve]\ndefault_session = "kalari-live"\npromotion_policy = "Solo"\n')
caps = {'timeout_ms': 30000, 'output_cap_bytes': 65536, 'memory_mib': 512}
net = [{'host': host, 'port': a.api_port}]
endpoint = {'endpoint': 'https://api.vultrinference.com/v1', 'model': 'deepseek-v4.1-flash-1017', 'api_key_env': a.key_env}
config = {'models': endpoint, 'decisions': dict(endpoint, endpoint='https://api.vultrinference.com/v1/systemone', model='clef'), 'sandbox': {'backend': 'microsandbox', 'caps': caps, 'allowlist': net}, 'lambo': {'command': [str(tools / 'lambo'), 'serve'], 'config_path': str(root / 'lambo.toml')}}
session = {'session_id': 'live', 'repo_scope': a.repo_scope, 'workspace': str(root / 'candidate'), 'old_spec': str(root / 'candidate' / suite['old_spec']), 'new_spec': str(root / 'candidate' / suite['new_spec']), 'baseline': {'workspace': str(root / 'baseline'), 'command': ['python3', str(root / 'baseline' / suite['consumer']), '--base-url', f'http://{host}:{a.api_port}', '--out', suite['artifact']], 'caps': caps, 'allowlist': net}, 'check_workspace': str(root / 'checks'), 'evidence_workspace': str(root / 'evidence'), 'artifact': suite['artifact'], 'aashaan': str((tools / 'kalari-aashaan').resolve(strict=True)), 'tool_path': str(tools)+':/usr/local/bin:/usr/bin:/bin'}
for name, doc in (('config.json', config), ('session.json', session)):
    path = root / name
    path.write_text(json.dumps(doc, indent=2) + '\n')
    path.chmod(0o600)
print(root)
