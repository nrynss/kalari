#!/usr/bin/env python3
"""Prepare trusted payout session files; does not execute services or inference."""
import argparse
import json
import os
from pathlib import Path
import shutil

p = argparse.ArgumentParser()
p.add_argument('--directory', type=Path, required=True)
p.add_argument('--workspace-source', type=Path, required=True)
p.add_argument('--tools', type=Path, required=True)
p.add_argument('--api-host', required=True)
p.add_argument('--api-port', type=int, default=18080)
p.add_argument('--key-env', default='VULTR_INFERENCE_API_KEY')
a = p.parse_args()
import ipaddress
host = str(ipaddress.IPv4Address(a.api_host))
if not 1 <= a.api_port <= 65535 or not a.key_env.isidentifier():
    p.error('invalid port or key environment variable name')
tools = a.tools.resolve(strict=True)
source = a.workspace_source.resolve(strict=True)
for name in ('kalari', 'kalari-aashaan', 'msb', 'vimanam', 'lambo'):
    if not (tools / name).is_file() or not os.access(tools / name, os.X_OK):
        p.error('missing executable ' + name)
for name in ('payout_sync.py', 'specs/openapi-v1.yaml', 'specs/openapi-v2.yaml'):
    if not (source / name).is_file():
        p.error('missing workspace file ' + name)
a.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
root = a.directory.resolve(strict=True)
shutil.copytree(source, root / 'candidate', symlinks=False)
shutil.copytree(source, root / 'baseline', symlinks=False)
for name in ('checks', 'evidence'):
    (root / name).mkdir(mode=0o700)
(root / 'lambo.toml').write_text('[store]\nkind = "sqlite"\npath = '+json.dumps(str(root / 'lambo.db'))+'\n[embedder]\nkind = "fixture"\n[serve]\ndefault_session = "kalari-live"\n')
caps = {'timeout_ms': 30000, 'output_cap_bytes': 65536, 'memory_mib': 512}
net = [{'host': host, 'port': a.api_port}]
endpoint = {'endpoint': 'https://api.vultrinference.com/v1', 'model': 'deepseek-v4.1-flash-1017', 'api_key_env': a.key_env}
config = {'models': endpoint, 'decisions': dict(endpoint, endpoint='https://api.vultrinference.com/v1/systemone', model='clef'), 'sandbox': {'backend': 'microsandbox', 'caps': caps, 'allowlist': net}, 'lambo': {'command': [str(tools / 'lambo'), 'serve'], 'config_path': str(root / 'lambo.toml')}}
session = {'session_id': 'live', 'repo_scope': 'live', 'workspace': str(root / 'candidate'), 'old_spec': str(root / 'candidate/specs/openapi-v1.yaml'), 'new_spec': str(root / 'candidate/specs/openapi-v2.yaml'), 'baseline': {'workspace': str(root / 'baseline'), 'command': ['python3', str(root / 'baseline/payout_sync.py'), '--base-url', f'http://{host}:{a.api_port}', '--out', 'payouts.jsonl'], 'caps': caps, 'allowlist': net}, 'check_workspace': str(root / 'checks'), 'evidence_workspace': str(root / 'evidence'), 'artifact': 'payouts.jsonl', 'aashaan': str(tools / 'kalari-aashaan'), 'tool_path': str(tools)+':/usr/local/bin:/usr/bin:/bin'}
for name, doc in (('config.json', config), ('session.json', session)):
    path = root / name
    path.write_text(json.dumps(doc, indent=2) + '\n')
    path.chmod(0o600)
print(root)
