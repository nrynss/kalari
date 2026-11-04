#!/usr/bin/env python3
"""Narrow, run-local MCP adapter for the baseline pilot's fixed sandbox.

The supervising harness creates and removes the guest. This process can only
execute in that guest and copy the current workspace into it; it cannot select
another sandbox or create mounts, networks, images, snapshots, or secrets.
"""
import json
import os
import pathlib
import subprocess
import sys
import tarfile
import tempfile

GUEST = os.environ['KALARI_PILOT_GUEST']
WORKSPACE = pathlib.Path(os.environ['KALARI_PILOT_WORKSPACE']).resolve(strict=True)
if not GUEST.startswith('kalari-pilot-') or not GUEST.removeprefix('kalari-pilot-').isalnum():
    raise SystemExit('invalid guest name')

# Schemas deliberately omit settings the fixed guest cannot honor.
TOOLS = [
    ('sandbox_create', 'Attach to the prepared isolated Python sandbox.', {'name': {'type':'string'}, 'image': {'type':'string'}, 'workdir': {'type':'string'}, 'volumes': {'type':'array'}, 'lifecycle': {'type':'object'}}, ['name']),
    ('sandbox_exec', 'Run a command in the prepared sandbox.', {'name': {'type':'string'}, 'command': {'type':'string'}, 'args': {'type':'array','items':{'type':'string'}}, 'cwd': {'type':'string'}, 'timeout': {'type':'number'}}, ['name','command']),
    ('sandbox_fs_remove', 'Remove a path inside the sandbox.', {'name': {'type':'string'}, 'path': {'type':'string'}}, ['name','path']),
    ('sandbox_remove', 'Detach from the prepared sandbox.', {'name': {'type':'string'}, 'force': {'type':'boolean'}}, ['name']),
    ('sandbox_list', 'List this session sandbox.', {}, []),
    ('runtime_check', 'Check the prepared sandbox.', {}, []),
    ('image_list', 'List the prepared image.', {}, []),
]
alias = None

def run(*args, timeout=60):
    return subprocess.run(['msb', *args], capture_output=True, text=True, timeout=timeout)

def sync():
    # Tar creation dereferences no links; exclude metadata and any symlink, so
    # the guest receives only files within the explicitly selected workspace.
    with tempfile.NamedTemporaryFile(suffix='.tar') as f:
        with tarfile.open(fileobj=f, mode='w') as tar:
            for p in WORKSPACE.rglob('*'):
                rel = p.relative_to(WORKSPACE)
                if '.git' in rel.parts or p.is_symlink():
                    continue
                if p.is_file() or p.is_dir():
                    tar.add(p, arcname=str(rel), recursive=False)
        f.flush()
        a = run('copy', '-q', f.name, GUEST + ':/tmp/kalari-workspace.tar')
        if a.returncode: raise RuntimeError('workspace copy failed')
        a = run('exec', GUEST, '--', 'tar', '-xf', '/tmp/kalari-workspace.tar', '-C', '/workspace')
        if a.returncode: raise RuntimeError('workspace extraction failed')

def call(name, args):
    global alias
    if name == 'sandbox_create':
        if alias is not None: raise ValueError('sandbox already attached')
        for mount in args.get('volumes', []):
            if (mount.get('kind') != 'bind' or mount.get('guestPath') != '/workspace'
                    or pathlib.Path(mount.get('hostPath', '')).resolve() != WORKSPACE):
                raise ValueError('only the selected workspace is available')
        if args.get('workdir', '/workspace') != '/workspace':
            raise ValueError('only /workspace is available')
        alias = args['name']
        return {'name': alias, 'status':'running'}
    if name == 'runtime_check': return {'available':True}
    if name == 'image_list': return {'images':[{'reference':'python'}]}
    if name == 'sandbox_list': return {'sandboxes': [] if alias is None else [{'name':alias,'status':'running'}]}
    if name not in ('sandbox_exec','sandbox_fs_remove','sandbox_remove') or alias is None or args.get('name') != alias:
        raise ValueError('tool or sandbox not available')
    if name == 'sandbox_remove':
        alias = None
        return {'removed':True}
    if name == 'sandbox_fs_remove':
        path = args['path']
        if not path.startswith('/workspace/') or '..' in pathlib.PurePosixPath(path).parts: raise ValueError('path outside workspace')
        p = run('exec', GUEST, '--', 'rm', '-rf', '--', path)
    else:
        sync()
        cwd = args.get('cwd', '/workspace')
        if not cwd.startswith('/workspace') or '..' in pathlib.PurePosixPath(cwd).parts: raise ValueError('cwd outside workspace')
        command = args['command']
        argv = args.get('args', [])
        if not isinstance(argv, list) or not all(isinstance(a,str) for a in argv): raise ValueError('invalid args')
        import shlex
        shell = 'cd ' + shlex.quote(cwd) + ' && exec ' + ' '.join(map(shlex.quote, [command,*argv]))
        p = run('exec', GUEST, '--', 'sh', '-c', shell, timeout=min(max(int(args.get('timeout',60)),1),180))
    return {'exitCode':p.returncode,'stdout':p.stdout[-50000:],'stderr':p.stderr[-10000:]}

def respond(req):
    method = req.get('method'); params = req.get('params') or {}
    if method == 'initialize': return {'protocolVersion':'2024-11-05','capabilities':{'tools':{}},'serverInfo':{'name':'kalari-pilot','version':'1'}}
    if method == 'ping': return {}
    if method == 'tools/list':
        return {'tools':[{'name':n,'description':d,'inputSchema':{'type':'object','properties':p,'required':r,'additionalProperties':False}} for n,d,p,r in TOOLS]}
    if method == 'tools/call':
        try:
            value = call(params['name'], params.get('arguments') or {})
            return {'content':[{'type':'text','text':json.dumps(value)}], 'structuredContent':value}
        except Exception as e:
            return {'content':[{'type':'text','text':str(e)}], 'isError':True}
    raise ValueError('unsupported method')

for line in sys.stdin:
    try:
        request = json.loads(line)
        if 'id' not in request: continue
        try: output = {'jsonrpc':'2.0','id':request['id'],'result':respond(request)}
        except Exception as e: output = {'jsonrpc':'2.0','id':request['id'],'error':{'code':-32601,'message':str(e)}}
        print(json.dumps(output), flush=True)
    except (ValueError, TypeError):
        continue
