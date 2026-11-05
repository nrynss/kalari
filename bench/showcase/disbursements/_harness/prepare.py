#!/usr/bin/env python3
"""Write an isolated OpenCode configuration for an already prepared showcase session.

An adapted copy of bench/runs/kalari/_harness/prepare.py with the model swapped to
qwen3.8-flash-next for the showcase's cheaper-model runs (both arms use it).
"""
import argparse
import json
import os
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--directory', type=Path, required=True)
p.add_argument('--kalari', type=Path, required=True)
p.add_argument('--config', type=Path, required=True)
p.add_argument('--session', type=Path, required=True)
p.add_argument('--model', required=True)
DISPLAY = {'mimo-v2.6-flash': 'MiMo V2.6 Flash', 'qwen3.8-27b': 'Qwen3.8 27B', 'glm-5.3-flash': 'GLM 5.3 Flash', 'muse-glimmer-30b': 'Muse Glimmer 30B', 'qwen3.8-flash-next': 'Qwen3.8 Flash Next', 'deepseek-v4.1-flash-1017': 'DeepSeek V4.1 Flash'}
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
        'models': {a.model: {'name': DISPLAY.get(a.model, a.model)}}}},
    'model': 'vultr/' + a.model,
    'mcp': {'servers': {'kalari': {'type': 'local', 'codemode': False,
        'command': [str(a.kalari), 'serve', str(a.config), str(a.session)]}}},
    'permissions': [{'action': action, 'resource': '*', 'effect': 'deny'}
        for action in ('shell', 'webfetch', 'websearch', 'external_directory')]
}
path = a.directory / 'opencode.json'
path.write_text(json.dumps(config, indent=2) + '\n')
path.chmod(0o600)
print(path)
