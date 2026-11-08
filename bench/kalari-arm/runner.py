#!/usr/bin/env python3
"""Orchestrate one bounded payout session or its offline fixture."""
import argparse
import atexit
import shlex
import urllib.request
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
p.add_argument('--live', action='store_true', help='one approved live payout case; key on stdin')
p.add_argument('--offline-fixture', action='store_true', help='require local fake executables and loopback API')
p.add_argument('--tools', type=Path, required=True)
p.add_argument('--workspace-source', type=Path, default=ROOT / 'bench/workspaces/payout-sync')
p.add_argument('--opencode', type=Path, required=True)
p.add_argument('--api-host', required=True)
p.add_argument('--api-port', type=int, default=18080)
p.add_argument('--grade-port', type=int, default=18090)
p.add_argument('--result', type=Path, required=True, help='new private result directory')
p.add_argument('--timeout', type=int, default=60)
a = p.parse_args()
# Fake mode only admits loopback and a fixture marker.
if a.live == a.offline_fixture:
    p.error('choose exactly one of --live or --offline-fixture')
if a.offline_fixture and not ipaddress.IPv4Address(a.api_host).is_loopback:
    p.error('offline fixture requires a loopback API address')
tools = a.tools.resolve(strict=True)
if a.live:
    for item in ('rg',):
        if not (tools/item).is_file() or not os.access(tools/item, os.X_OK):
            p.error('live tools directory needs executable ' + item)
    if not (ROOT/'bench/apis/payouts/data.py').is_file():
        p.error('hidden grader requires bench/apis/payouts/data.py')
opencode = a.opencode.resolve(strict=True)
if a.offline_fixture and not (tools / '.kalari-offline-fixture').is_file():
    p.error('offline fake tools marker missing')
if not opencode.is_file() or not os.access(opencode, os.X_OK):
    p.error('OpenCode must be executable')
if not 1 <= a.timeout <= 120:
    p.error('timeout must be 1..120 seconds')
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
if a.live:
    key = sys.stdin.readline().rstrip('\r\n')
    if len(key) < 8:
        p.error('live inference key required on stdin')
    env['VULTR_INFERENCE_API_KEY'] = key
    env.pop('KALARI_OFFLINE_FIXTURE')
    env.pop('MSB_LOG')

def usage():
    req = urllib.request.Request('https://api.vultrinference.com/v1/usage', headers={'Authorization': 'Bearer ' + env['VULTR_INFERENCE_API_KEY']})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)

def usage_rows(doc):
    return {row['model']: row for row in doc['usage']['current_month']['chat_usage']}

usage_before = usage() if a.live else None
if a.live:
    snapshot = {model: {'input_tokens': row.get('input_tokens'), 'output_tokens': row.get('output_tokens')} for model, row in usage_rows(usage_before).items()}
    (result/'usage-before.json').write_text(json.dumps(snapshot, indent=2) + '\n')
    (result/'usage-before.json').chmod(0o600)
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
    if a.live:
        # The service invokes msb with a scrubbed environment, so the wrapper
        # embeds private absolute paths and journals every attempted create.
        real_msb = tools / 'msb'
        guarded = temp / 'tools'; guarded.mkdir()
        for item in tools.iterdir():
            if item.name != 'msb': (guarded / item.name).symlink_to(item)
        ledger = result / 'sandbox-names'
        msb_wrapper = guarded / 'msb'
        msb_wrapper.write_text('#!/bin/sh\nif [ "$1" = create ] && [ "$2" = --name ]; then printf "%s\\n" "$3" >> ' + shlex.quote(str(ledger)) + '; fi\nexec ' + shlex.quote(str(real_msb)) + ' "$@"\n')
        msb_wrapper.chmod(0o700)
        before = execute([real_msb, 'list', '--format', 'json'], capture_output=True, text=True)
        existing = {x['name'] for x in json.loads(before.stdout)}
        def cleanup_sandboxes():
            if not ledger.exists(): return None
            errors = []
            names = set(ledger.read_text().splitlines()) - existing
            try:
                rows = execute([real_msb, 'list', '--format', 'json'], capture_output=True, text=True)
                present = {x['name'] for x in json.loads(rows.stdout)}
            except Exception:
                present = names
                errors.append('sandbox cleanup initial listing failed')
            failed = set()
            for name in names:
                if not re.fullmatch(r'kalari-[A-Za-z0-9._-]+', name):
                    errors.append('invalid sandbox name in private ledger')
                    continue
                if name in present:
                    removed = subprocess.run([str(real_msb), 'remove', '-f', name], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    if removed.returncode: failed.add(name)
            try:
                rows = execute([real_msb, 'list', '--format', 'json'], capture_output=True, text=True)
                left = names & {x['name'] for x in json.loads(rows.stdout)}
            except Exception:
                left = sorted(names)
                errors.append('sandbox cleanup verification failed')
            if failed.intersection(left): errors.append('sandbox removal command failed')
            (result/'cleanup.json').write_text(json.dumps({'left': sorted(left), 'tracked': len(names), 'errors': errors}) + '\n')
            if left: errors.append('session sandboxes remain')
            return '; '.join(errors) if errors else None
        def safe_cleanup_sandboxes():
            try:
                return cleanup_sandboxes()
            except Exception:
                return 'sandbox cleanup raised an exception'
        atexit.register(safe_cleanup_sandboxes)
        tools = guarded
        env['PATH'] = str(tools) + ':/usr/local/bin:/usr/bin:/bin'
    execute([sys.executable, HERE/'session.py', '--directory', session, '--workspace-source', a.workspace_source, '--tools', tools, '--api-host', a.api_host, '--api-port', str(a.api_port)], stdout=subprocess.DEVNULL)
    execute([tools/'lambo', 'provision', '--config', session/'lambo.toml'], stdout=subprocess.DEVNULL)
    # Fresh store: no change-kind seeding. The first recall finds no concept.
    setup = json.loads((session/'session.json').read_text())
    xdg = temp/'xdg'
    execute([sys.executable, HERE/'prepare.py', '--directory', xdg, '--kalari', tools/'kalari', '--config', session/'config.json', '--session', session/'session.json'], stdout=subprocess.DEVNULL)
    env.update({'OPENCODE_CONFIG': str(xdg/'opencode.json'), 'XDG_DATA_HOME': str(xdg/'data'), 'XDG_STATE_HOME': str(xdg/'state'), 'XDG_CACHE_HOME': str(xdg/'cache'), 'XDG_CONFIG_HOME': str(xdg/'config')})
    (xdg/'config').mkdir(mode=0o700)
    ver = execute([opencode, '--version'], capture_output=True, text=True).stdout.strip()
    if '2.2.5' not in ver:
        raise SystemExit('OpenCode version must be 2.2.5')
    workspace = Path(setup['workspace'])
    proxy = None
    proxy_state = None
    if a.live:
        import bootstrap_proxy
        proxy, proxy_state = bootstrap_proxy.start('https://api.vultrinference.com/v1', workspace/'README.md')
        provider_config = xdg/'opencode.json'
        provider_doc = json.loads(provider_config.read_text())
        provider_doc['providers']['vultr']['settings']['baseURL'] = f'http://127.0.0.1:{proxy.server_port}/v1'
        provider_config.write_text(json.dumps(provider_doc))
        atexit.register(proxy.shutdown)
    prompt = (ROOT/'bench/prompts/upgrade.txt').read_text().replace('{BASE_URL}', f'http://{a.api_host}:{a.api_port}')
    prompt += ('\nCall kalari_what_changed first, then pass its returned change IDs (not change-kind names) to kalari_blast_radius. Call kalari_recall_lessons with the returned change kinds. After editing, call kalari_run_in_sandbox and then kalari_record_lesson with the returned run_id. '
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
        # Costs are integer hundred-millionths of a dollar. Input, cache
        # reads and writes cost 15 units/token; output and reasoning cost 60.
        # Reasoning may already be included in output; double counting is
        # intentional. This is a soft ceiling: a request already in flight
        # and Clef spend are not visible in completed OpenCode step events.
        cutoff_units = 20_000_000  # $0.20 at recorded list rates
        spent_units = 0
        cutoff_reason = None
        steps = 0
        failures = {}
        seen_failed_calls = set()
        offset = 0
        partial = b''
        try:
            while True:
                with events.open('rb') as stream:
                    stream.seek(offset)
                    block = stream.read()
                    offset = stream.tell()
                partial += block
                lines = partial.split(b'\n')
                partial = lines.pop()
                # A producer can emit a complete JSON object without a newline
                # and keep running. Count it as soon as it parses, otherwise
                # fail closed on a partial record once the producer has exited.
                if partial:
                    try:
                        json.loads(partial)
                    except (ValueError, UnicodeDecodeError):
                        if proc.poll() is not None and events.stat().st_size == offset:
                            cutoff_reason = 'invalid_telemetry'
                    else:
                        lines.append(partial)
                        partial = b''
                for line in lines:
                    if not line.strip():
                        continue
                    try:
                        event = json.loads(line)
                        if event.get('type') == 'tool_use':
                            part = event.get('part') or {}
                            name = part.get('tool')
                            state = part.get('state') or {}
                            status = state.get('status')
                            if isinstance(name, str) and name.startswith('kalari_'):
                                if status == 'error':
                                    call_id = part.get('callID') or part.get('id')
                                    identity = (name, call_id) if isinstance(call_id, str) and call_id else None
                                    if identity is None or identity not in seen_failed_calls:
                                        failures[name] = failures.get(name, 0) + 1
                                        if identity is not None: seen_failed_calls.add(identity)
                                    if failures.get(name, 0) >= 2:
                                        cutoff_reason = 'repeated_tool_failure'
                                        break
                                elif status == 'completed':
                                    failures.pop(name, None)
                            continue
                        if event.get('type') != 'step_finish': continue
                        tokens = event['part']['tokens']
                        cache = tokens.get('cache') or {}
                        counts = [tokens.get('input'), cache.get('read', 0), cache.get('write', 0), tokens.get('output'), tokens.get('reasoning', 0)]
                        if any(type(n) is not int or n < 0 for n in counts):
                            raise ValueError('invalid token count')
                        spent_units += 15 * sum(counts[:3]) + 60 * sum(counts[3:])
                        steps += 1
                    except (ValueError, KeyError, TypeError, AttributeError):
                        cutoff_reason = 'invalid_telemetry'
                        break
                if cutoff_reason is None and spent_units >= cutoff_units:
                    cutoff_reason = 'spend_cutoff'
                if cutoff_reason is None and time.monotonic() - start >= a.timeout:
                    cutoff_reason = 'watchdog'
                if cutoff_reason is not None:
                    timed_out = cutoff_reason == 'watchdog'
                    try: os.killpg(proc.pid, signal.SIGTERM)
                    except ProcessLookupError: pass
                    try: rc = proc.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        try: os.killpg(proc.pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                        rc = proc.wait()
                    break
                if proc.poll() is not None:
                    if events.stat().st_size > offset:
                        continue
                    rc = proc.returncode
                    break
                time.sleep(0.1)
        finally:
            # Reap any descendants still in this session's process group.
            try: os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            for sig, handler in old_handlers.items(): signal.signal(sig, handler)
    elapsed = time.monotonic() - start
    if proxy is not None:
        proxy.shutdown()
        atexit.unregister(proxy.shutdown)
        # A client can disconnect while a daemon request thread is still
        # reading upstream. Report it as active rather than implying EOF.
        deadline = time.monotonic() + 2
        while any(r['active'] for r in proxy_state['requests']) and time.monotonic() < deadline:
            time.sleep(.05)
    # Persist the sanitized session transcript before cleanup can fail. This
    # lets the caller diagnose a cleanup exception without losing telemetry.
    bad = 0
    with (result/'transcript.jsonl').open('w') as out:
        for line in events.open(errors='replace'):
            try: doc = json.loads(line)
            except ValueError:
                bad += 1
                continue
            out.write(json.dumps(sanitize(doc), ensure_ascii=True) + '\n')
    if a.live:
        cleanup_error = safe_cleanup_sandboxes()
    elif (tools/'CLEANUPFAIL').exists():
        cleanup = subprocess.run([str(tools/'msb'), 'remove', '-f', 'kalari-offline-fixture'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cleanup_error = 'sandbox removal command failed' if cleanup.returncode else None
    else:
        cleanup_error = None
    summary = execute([sys.executable, HERE/'summarize.py', result/'transcript.jsonl'], capture_output=True, text=True)
    measures = json.loads(summary.stdout)
    measures.update({'elapsed_seconds': round(elapsed, 3), 'exit_code': rc, 'timed_out': timed_out, 'invalid_event_lines': bad, 'fixture': not a.live, 'cutoff_reason': cutoff_reason, 'completed_steps': steps, 'estimated_step_cost_usd': spent_units / 100_000_000, 'tool_failures': failures, 'interrupted_signal': interrupted['signal'], 'bootstrap': proxy_state})
    if interrupted['signal'] is None:
        grade = temp/'grade'; grade.mkdir()
        execute([HERE/'grade.sh', workspace, ROOT/'bench/harness/grade_runner.py', a.api_host, str(a.grade_port), grade])
        grade_file = grade/'result.jsonl'
        if grade_file.exists():
            shutil.copyfile(grade_file, result/'grader-output.jsonl')
            (result/'grader-output.jsonl').chmod(0o600)
            graded = subprocess.run([sys.executable, str(ROOT/'bench/graders/grade.py'), 'payouts', str(grade_file)], env=env, capture_output=True, text=True)
            try: measures['grade'] = json.loads(graded.stdout)
            except ValueError: measures['grade'] = {'verdict': 'ERROR'}
        else:
            measures['grade'] = {'verdict': 'FAIL', 'reason': 'no output'}
        measures['grader_status'] = (grade/'status').read_text().strip() if (grade/'status').exists() else 'missing'
    else:
        measures['grade'] = {'verdict': 'NOT_RUN', 'reason': 'interrupted'}
    if a.live:
        cleanup_error = safe_cleanup_sandboxes() or cleanup_error
        try:
            before = usage_rows(usage_before); after = usage_rows(usage())
            deltas = {model: {'input': int(after.get(model, {}).get('input_tokens') or 0) - int(before.get(model, {}).get('input_tokens') or 0), 'output': int(after.get(model, {}).get('output_tokens') or 0) - int(before.get(model, {}).get('output_tokens') or 0)} for model in set(before) | set(after)}
            measures['usage_delta'] = deltas
        except Exception:
            measures['usage_delta'] = None
            measures['usage_error'] = 'Usage after session unavailable; actual usage is unknown.'
        measures['cost_note'] = 'Account-wide token deltas may include concurrent sessions; calculate using current model-specific prices.'
    if cleanup_error:
        measures['cleanup_error'] = cleanup_error
    (result/'measures.json').write_text(json.dumps(sanitize(measures), indent=2) + '\n')
    print(json.dumps({'transcript': str(result/'transcript.jsonl'), 'measures': str(result/'measures.json')}))
    if interrupted['signal'] is not None:
        raise SystemExit(128 + interrupted['signal'])
    if cleanup_error:
        raise SystemExit('sandbox cleanup failed; evidence preserved')
