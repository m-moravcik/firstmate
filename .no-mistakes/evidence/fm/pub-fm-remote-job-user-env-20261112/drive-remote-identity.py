import os, pathlib, shutil, subprocess, tempfile
root = pathlib.Path.cwd()
evidence = pathlib.Path('~/.no-mistakes/evidence/01M779C4EE7AJ75RVQRWN1CX6D')
fixture = pathlib.Path(tempfile.mkdtemp(prefix='.identity-live-', dir=root))
log = []
def run(argv, **kw):
    return subprocess.run(argv, check=True, text=True, capture_output=True, timeout=180, **kw)
try:
    remote = fixture/'remote-root'
    (remote/'bin').mkdir(parents=True)
    account = fixture/'account'
    home = fixture/'home'
    account.mkdir(); home.mkdir()
    for name in ['fm-remote-job-lib.sh', 'fm-remote-job-worker.sh']:
        shutil.copy2(root/'bin'/name, remote/'bin'/name)
    # Only the local disposable repository needs this root marker.
    (remote/'AGENTS.md').write_text('Disposable executable-interface fixture.\n')
    probe = remote/'bin/fm-identity-observe.sh'
    probe.write_text('''#!/bin/bash
set -eu
printf 'USER=%s\\nLOGNAME=%s\\n' "${USER-<unset>}" "${LOGNAME-<unset>}"
printf 'ambient-secret=%s\\n' "${IDENTITY_TEST_SECRET-<unset>}"
printf 'active=%s\\n' "$FM_REMOTE_JOB_ACTIVE"
printf 'arg=%s\\n' "$1"
IFS= read -r line
printf 'stdin=%s\\n' "$line"
''')
    probe.chmod(0o755)
    run(['git','init','-q',str(remote)])
    run(['git','-C',str(remote),'add','bin','AGENTS.md'])
    baseline = run(['git','show','a02b089835a114844cc53d0429570155dfe4ef3a:bin/fm-remote-job-worker.sh']).stdout
    driver = '''set -eu
. "$LIVE_ROOT/bin/fm-remote-job-lib.sh"
fm_remote_job_stage "$HOME" "$LIVE_ROOT" "$LIVE_HOME" fm-identity-observe.sh 'two words $(not executed)' <<< 'preserved input' >/dev/null
job=$FM_REMOTE_JOB_ID
/bin/bash "$LIVE_ROOT/bin/fm-remote-job-worker.sh" --lane "$job"
fm_remote_job_wait "$HOME" "$job"
if [ "$FM_REMOTE_JOB_EXIT" != 0 ]; then
  printf 'job exit=%s\n' "$FM_REMOTE_JOB_EXIT" >&2
  cat "$FM_REMOTE_JOB_STDERR" >&2
  exit 1
fi
cat "$FM_REMOTE_JOB_STDOUT"
[ ! -s "$FM_REMOTE_JOB_STDERR" ]
fm_remote_job_reap "$HOME" "$job"
'''
    cases = [
        ('base-both-set', 'user sample $(false)', 'login sample', False),
        ('target-both-set', 'user sample $(false)', 'login sample', True),
        ('target-user-only', 'user sample $(false)', None, True),
        ('target-logname-only', None, 'login sample', True),
        ('target-both-unset', None, None, True),
        ('target-both-empty', '', '', True),
    ]
    worker = remote/'bin/fm-remote-job-worker.sh'
    for name, user, login, target in cases:
        if target:
            shutil.copy2(root/'bin/fm-remote-job-worker.sh', worker)
        else:
            worker.write_text(baseline)
            worker.chmod(0o755)
        env = dict(os.environ)
        for key in list(env):
            if key.startswith('FM_') or key in ('USER','LOGNAME','HOME'):
                env.pop(key)
        env.update(HOME=str(account), LIVE_ROOT=str(remote), LIVE_HOME=str(home),
                   FM_ROOT_OVERRIDE=str(remote), FM_REMOTE_JOB_STATE_ROOT=str(fixture/name),
                   FM_REMOTE_JOB_TIMEOUT='90', FM_REMOTE_JOB_QUEUE_TIMEOUT='120',
                   IDENTITY_TEST_SECRET='synthetic-do-not-propagate')
        if user is not None: env['USER'] = user
        if login is not None: env['LOGNAME'] = login
        try:
            result = run(['/bin/bash','-c',driver], env=env, cwd=root)
        except subprocess.CalledProcessError as exc:
            log.extend([f'CASE {name} execution failed exit={exc.returncode}', exc.stdout, exc.stderr])
            raise
        observed = dict(line.split('=',1) for line in result.stdout.splitlines())
        expected_user = user if target and user else '<unset>'
        expected_login = login if target and login else '<unset>'
        assert observed == {'USER':expected_user, 'LOGNAME':expected_login,
                            'ambient-secret':'<unset>', 'active':'1',
                            'arg':'two words $(not executed)', 'stdin':'preserved input'}, observed
        log.extend([f'CASE {name}: worker exit=0, result consumed and reaped', result.stdout.strip()])
    log.append('Oracle: supplied nonempty identity values survive exactly; missing/empty identities stay absent; unrelated synthetic secret stays absent; argv and stdin remain unchanged.')
    log.append('Counterfactual: the base worker dropped both supplied identity values; target preserved them.')
finally:
    shutil.rmtree(fixture)
    log.append('Disposable account, queue, and executable repository removed; all synchronous lane children awaited.')
    (evidence/'remote-identity-live.log').write_text('\n'.join(log)+'\n')
print('\n'.join(log))
