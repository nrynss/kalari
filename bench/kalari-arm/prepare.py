#!/usr/bin/env python3
"""Write an isolated OpenCode configuration for an already prepared Kalari session."""
import argparse
import json
import os
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--directory', type=Path, required=True)
p.add_argument('--kalari', type=Path, required=True)
p.add_argument('--config', type=Path, required=True)
p.add_argument('--session', type=Path, required=True)
a = p.parse_args()
for path in (a.kalari, a.config, a.session):
    if not path.is_absolute() or not path.is_file():
        p.error(f'expected an absolute existing file: {path}')
if not os.access(a.kalari, os.X_OK):
    p.error('kalari must be executable')
a.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ('data', 'state', 'cache'):
    (a.directory / name).mkdir(mode=0o700)
config = {
    '$schema': 'https://opencode.ai/config.json',
    'providers': {'vultr': {'name': 'Vultr Serverless Inference',
        'env': ['VULTR_INFERENCE_API_KEY'],
        'package': '@opencode/ai/providers/openai-compatible',
        'settings': {'baseURL': 'https://api.vultrinference.com/v1'},
        'body': {'reasoning_effort': 'low'},
        'models': {'deepseek-v4.1-flash-1017': {'name': 'DeepSeek V4.1 Flash'}}}},
    'model': 'vultr/deepseek-v4.1-flash-1017',
    'mcp': {'servers': {'kalari': {'type': 'local', 'codemode': False,
        'command': [str(a.kalari), 'serve', str(a.config), str(a.session)]}}},
    'permissions': [{'action': action, 'resource': '*', 'effect': 'deny'}
        for action in ('shell', 'webfetch', 'websearch', 'external_directory')]
}
path = a.directory / 'opencode.json'
path.write_text(json.dumps(config, indent=2) + '\n')
path.chmod(0o600)
print(path)
