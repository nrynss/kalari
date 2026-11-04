#!/usr/bin/env python3
"""Orchestrate one payout session. Only a local fake fixture may run for now."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
p = argparse.ArgumentParser()
p.add_argument('--offline-fixture', action='store_true', help='require local fake executables and loopback API')
p.add_argument('--tools', type=Path, required=True)
p.add_argument('--workspace-source', type=Path, default=ROOT / 'bench/workspaces/payout-sync')
p.add_argument('--opencode', type=Path, required=True)
p.add_argument('--api-host', required=True)
p.add_argument('--api-port', type=int, default=18080)
p.add_argument('--grade-port', type=int, default=18090)
p.add_argument('--result', type=Path, required=True, help='new private result directory')
p.add_argument('--timeout', type=int, default=1200)
a = p.parse_args()
# There is deliberately no bypass until the request-time budget guard covers
# both OpenCode and Clef. Fake mode only admits loopback and a fixture marker.
if not a.offline_fixture:
    p.error('live execution disabled: shared OpenCode and Clef budget guard required')
if not ipaddress.IPv4Address(a.api_host).is_loopback:
    p.error('offline fixture requires a loopback API address')
tools = a.tools.resolve(strict=True)
opencode = a.opencode.resolve(strict=True)
if not (tools / '.kalari-offline-fixture').is_file():
    p.error('offline fake tools marker missing')
if not opencode.is_file() or not os.access(opencode, os.X_OK):
    p.error('fake OpenCode must be executable')
if not 1 <= a.timeout <= 1200:
    p.error('timeout must be 1..1200 seconds')
a.result.mkdir(mode=0o700, parents=True, exist_ok=False)
result = a.result.resolve(strict=True)
# Fixture subprocesses receive a small, explicit environment. This is not a
# network sandbox: the marker only establishes that this is trusted test data.
env = {
    'PATH': str(tools) + ':/usr/local/bin:/usr/bin:/bin',
    'HOME': str(Path.home()),
    'LANG': 'C.UTF-8',
    'LC_ALL': 'C.UTF-8',
    'KALARI_OFFLINE_FIXTURE': '1',
    'VULTR_INFERENCE_API_KEY': 'offline-fixture-invalid-key',
    'MSB_LOG': str(a.result.parent / 'msb.log'),
}
# A separate temporary workspace prevents raw event and credential material
# from being published. Only redacted, structured events reach result/.

def execute(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, env=env, **kwargs)

def sanitize(value):
    if isinstance(value, str):
        value = value.replace(env['VULTR_INFERENCE_API_KEY'], '[redacted]')
        value = value.replace(str(Path.home()), '~')
        return re.sub(r'\b(?:\d{1,3}\.){3}\d{1,3}\b', '[address]', value)
    if isinstance(value, list):
        return [sanitize(v) for v in value]
    if isinstance(value, dict):
        return {k: sanitize(v) for k, v in value.items()}
    return value

with tempfile.TemporaryDirectory(prefix='kalari-arm-') as td:
    temp = Path(td)
    session = temp / 'session'
    execute([sys.executable, HERE/'session.py', '--directory', session, '--workspace-source', a.workspace_source, '--tools', tools, '--api-host', a.api_host, '--api-port', str(a.api_port)], stdout=subprocess.DEVNULL)
    execute([tools/'lambo', 'provision', '--config', session/'lambo.toml'], stdout=subprocess.DEVNULL)
    setup = json.loads((session/'session.json').read_text())
    diff = execute([tools/'vimanam', 'diff', '--format', 'json', setup['old_spec'], setup['new_spec']], capture_output=True, text=True)
    for kind in sorted({item['kind'] for item in json.loads(diff.stdout)['changes']}):
        execute([tools/'lambo', 'derive', '--config', session/'lambo.toml', '--session', 'kalari-live', '--agent', 'kalari-live', '--content', kind, '--kind', 'resource'], stdout=subprocess.DEVNULL)
    xdg = temp/'xdg'
    execute([sys.executable, HERE/'prepare.py', '--directory', xdg, '--kalari', tools/'kalari', '--config', session/'config.json', '--session', session/'session.json'], stdout=subprocess.DEVNULL)
    env.update({'OPENCODE_CONFIG': str(xdg/'opencode.json'), 'XDG_DATA_HOME': str(xdg/'data'), 'XDG_STATE_HOME': str(xdg/'state'), 'XDG_CACHE_HOME': str(xdg/'cache'), 'XDG_CONFIG_HOME': str(xdg/'config')})
    (xdg/'config').mkdir(mode=0o700)
    ver = execute([opencode, '--version'], capture_output=True, text=True).stdout.strip()
    if '2.2.5' not in ver:
        raise SystemExit('OpenCode version must be 2.2.5')
    workspace = Path(setup['workspace'])
    prompt = (ROOT/'bench/prompts/upgrade.txt').read_text().replace('{BASE_URL}', f'http://{a.api_host}:{a.api_port}')
    prompt += ('\nUse the Kalari tools to inspect the change and affected code, recall lessons, run the candidate, and propose a lesson. '
               f'The trusted specs are {setup["old_spec"]} and {setup["new_spec"]}; workspace is {workspace}. '
               f'The allowed endpoint is {a.api_host}:{a.api_port}; maximum caps are 30000 ms, 65536 bytes, 512 MiB.\n')
    start = time.monotonic()
    events = temp/'events.jsonl'
    stderr = temp/'stderr'
    with events.open('wb') as out, stderr.open('wb') as err:
        proc = subprocess.Popen([str(opencode), 'run', '--standalone', '--format', 'json', '--auto', prompt], cwd=workspace, env=env, stdout=out, stderr=err, start_new_session=True)
        timed_out = False
        interrupted = {'signal': None}
        old_handlers = {}
        def stop_group(signum, _frame):
            interrupted['signal'] = signum
            try: os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError: pass
        for sig in (signal.SIGTERM, signal.SIGINT):
            old_handlers[sig] = signal.signal(sig, stop_group)
        try:
            try:
                rc = proc.wait(timeout=a.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                try: os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                try:
                    rc = proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try: os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                    rc = proc.wait()
        finally:
            # Reap any descendants still in this session's process group.
            try: os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            for sig, handler in old_handlers.items(): signal.signal(sig, handler)
        if interrupted['signal'] is not None:
            raise SystemExit(128 + interrupted['signal'])
    elapsed = time.monotonic() - start
    bad = 0
    with (result/'transcript.jsonl').open('w') as out:
        for line in events.open(errors='replace'):
            try: doc = json.loads(line)
            except ValueError:
                bad += 1
                continue
            out.write(json.dumps(sanitize(doc), ensure_ascii=True) + '\n')
    summary = execute([sys.executable, HERE/'summarize.py', result/'transcript.jsonl'], capture_output=True, text=True)
    measures = json.loads(summary.stdout)
    measures.update({'elapsed_seconds': round(elapsed, 3), 'exit_code': rc, 'timed_out': timed_out, 'invalid_event_lines': bad, 'fixture': True})
    grade = temp/'grade'; grade.mkdir()
    execute([HERE/'grade.sh', workspace, ROOT/'bench/harness/grade_runner.py', a.api_host, str(a.grade_port), grade])
    grade_file = grade/'result.jsonl'
    if grade_file.exists():
        graded = subprocess.run([sys.executable, str(ROOT/'bench/graders/grade.py'), 'payouts', str(grade_file)], env=env, capture_output=True, text=True)
        try: measures['grade'] = json.loads(graded.stdout)
        except ValueError: measures['grade'] = {'verdict': 'ERROR'}
    else:
        measures['grade'] = {'verdict': 'FAIL', 'reason': 'no output'}
    measures['grader_status'] = (grade/'status').read_text().strip() if (grade/'status').exists() else 'missing'
    (result/'measures.json').write_text(json.dumps(sanitize(measures), indent=2) + '\n')
    print(json.dumps({'transcript': str(result/'transcript.jsonl'), 'measures': str(result/'measures.json')}))
