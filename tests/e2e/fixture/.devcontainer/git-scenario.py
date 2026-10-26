import json
import os
import subprocess
import sys
import time

root, workspace, session, public_key, budget = sys.argv[1:]
budget = int(budget)
cwd = root + '/dev-' + session
round_number = None
timings = []
failure = None
operation = 'setup'


def run(name, args, expected=None, directory=None):
    global operation
    operation = name
    started = time.monotonic()
    ok = False
    try:
        result = subprocess.run(['timeout', '--kill-after=1s', str(budget / 1000) + 's', *args], cwd=directory or cwd, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.returncode, result.stderr[-8192:])
        if expected is not None and result.stdout != expected:
            raise AssertionError()
        ok = True
        return result.stdout
    finally:
        timings.append({'operation': name, 'elapsedMs': round((time.monotonic() - started) * 1000), 'ok': ok})


def git(*args):
    return run('git-' + (args[2] if args[0] == '-C' else args[0]), ['git', *args])


try:
    run('isolation', ['cat', root + '/isolation.txt'], 'workspace-' + workspace, root)
    assert public_key in run('agent-keys', ['ssh-add', '-L'], directory=root).splitlines()
    run('nested-ssh', ['ssh', '-F', '/dev/null', '-p', '2222', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', 'localhost', 'id', '-un'], 'developer\n', root)
    run('mkdir', ['mkdir', cwd], directory=root)
    run('file-edit', ['sh', '-ec', 'printf edit > first; mv first renamed; ln -s renamed link'])
    run('file-read', ['cat', 'link'], 'edit')
    run('file-executable', ['sh', '-ec', "printf '#!/bin/sh\\nprintf executable' > executable; chmod +x executable"])
    run('file-execute', ['./executable'], 'executable')
    run('file-remove', ['rm', 'link', 'renamed'])
    assert 'renamed' not in run('file-list', ['ls']).splitlines()
    git('init', '-q', '-b', 'task-' + session)
    for key, value in {'user.name': 'E2E', 'user.email': 'e2e@example.invalid', 'gpg.format': 'ssh', 'user.signingkey': public_key, 'gpg.ssh.allowedSignersFile': os.environ['HOME'] + '/e2e/allowed_signers'}.items():
        git('config', key, value)
    identity = 'w-' + workspace + '-s-' + session
    run('identity-write', ['sh', '-ec', 'printf %s "$1" > identity', 'sh', identity])
    git('add', 'identity', 'executable')
    git('commit', '-qm', 'initial', '-S')
    git('verify-commit', 'HEAD')
    url = 'http://127.0.0.1:18080/w-' + workspace + '.git'
    git('remote', 'add', 'origin', url)
    git('push', '-q', '-u', 'origin', 'HEAD')
    git('clone', '-q', '--branch', 'task-' + session, url, '../clone-' + session)
    run('clone-identity', ['cat', '../clone-' + session + '/identity'], identity)
    for round_number in range(5):
        run('identity-update', ['sh', '-ec', 'printf update >> identity'])
        git('commit', '-qam', 'update-' + str(round_number), '-S')
        git('push', '-q')
        git('-C', '../clone-' + session, 'fetch', '-q')
        git('-C', '../clone-' + session, 'reset', '-q', '--hard', 'origin/task-' + session)
        run('clone-identity', ['cat', '../clone-' + session + '/identity'], identity + 'update' * (round_number + 1))
except (RuntimeError, AssertionError, OSError) as error:
    failure = {'operation': operation, 'round': round_number}
    if isinstance(error, RuntimeError):
        failure.update(exitCode=error.args[0], timedOut=error.args[0] in (124, 137), stderr=error.args[1])
    try:
        for key, args in [('effective', []), ('global', ['--global', '--includes'])]:
            value = subprocess.run(['git', 'config', *args, '--get', 'core.createObject'], cwd=cwd, capture_output=True, text=True, timeout=2).stdout.strip() or 'unset'
            failure[key] = value if value in ('rename', 'link', 'unset') else 'other'
    except (OSError, subprocess.TimeoutExpired):
        failure['unavailable'] = True
print(json.dumps({'timings': timings, **({'failure': failure} if failure else {})}))
