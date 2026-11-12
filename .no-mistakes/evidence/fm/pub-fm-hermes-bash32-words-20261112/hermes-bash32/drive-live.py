import json, os, pathlib, shutil, subprocess, sys, time
ROOT=pathlib.Path.cwd()
EVIDENCE=pathlib.Path(__file__).parent
TOOLS=ROOT/'.test-toolchain-hermes'
LAB=TOOLS/'lab'
LAB.mkdir(exist_ok=True)
TMUX=TOOLS/'tmux-3.5a/tmux'
# Relative path keeps the Unix socket below macOS sun_path's size limit.
SOCKET=pathlib.Path('.test-toolchain-hermes/lab/s')
SESSION='fm-lab-hermes-bash32'
ENV=dict(os.environ)
for key in list(ENV):
    if key.startswith(('FM_', 'HERDR_', 'HERMES_')) or key == 'TMUX': ENV.pop(key)
ENV.update(FM_HOME=str(LAB/'home'), FM_CONFIG_OVERRIDE=str(LAB/'home/config'), TERM='xterm-256color', PYTHONDONTWRITEBYTECODE='1')
(LAB/'home/config').mkdir(parents=True,exist_ok=True)
(LAB/'shim').mkdir(exist_ok=True)
(LAB/'shim/tmux').write_text('#!/bin/sh\nexec '+str(TMUX)+' -S '+str(SOCKET)+' "$@"\n')
(LAB/'shim/tmux').chmod(0o755)
ENV['PATH']=str(LAB/'shim')+':'+ENV['PATH']
# Native argv carrier is input to the real process classifier, not a Hermes CLI.
(LAB/'argv-carrier.c').write_text('#include <unistd.h>\nint main(void) { sleep(1200); return 0; }\n')
subprocess.run(['cc',str(LAB/'argv-carrier.c'),'-o',str(LAB/'python3')],check=True)
(LAB/'tui_gateway').mkdir(exist_ok=True)
(LAB/'tui_gateway/entry.py').write_text('import time\nprint("synthetic Hermes module ready",flush=True)\ntime.sleep(1200)\n')
(LAB/'ui-tui/dist').mkdir(parents=True,exist_ok=True)
(LAB/'ui-tui/dist/entry.js').write_text('console.log("synthetic Hermes Node entry ready"); setInterval(()=>{},1000);\n')
ENV['PYTHONPATH']=str(LAB)
shutil.copytree(ROOT/'bin',LAB/'baseline/bin',dirs_exist_ok=True)
shutil.copyfile(EVIDENCE/'baseline-lib.sh',LAB/'baseline/bin/fm-hermes-process-lib.sh')
rows=[]
pane_pids=[]
def command(args,check=True,env=ENV):
    r=subprocess.run([str(a) for a in args],env=env,capture_output=True,text=True,errors="replace",timeout=60)
    if check and r.returncode: raise RuntimeError(f'{args}: {r.returncode}: {r.stderr}')
    return r

def tmux(*args,check=True): return command([TMUX,'-S',SOCKET,*args],check)
def probe(code_root,window,trace=False):
    cmd='set -u; . "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_agent_state tmux "$2"; printf "\\nprobe returned normally\\n"'
    args=['/bin/bash']+(['-x'] if trace else [])+['-c',cmd,'_',str(code_root),SESSION+':'+window]
    return command(args,False)

def record(label,r):
    row={'name':label,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr}
    rows.append(row)
    print(json.dumps(row),flush=True)

print(command(['/bin/bash','--version']).stdout.splitlines()[0],flush=True)
print(command([TMUX,'-V']).stdout.strip(),flush=True)
try:
    tmux('-f','/dev/null','new-session','-d','-x','120','-y','30','-s',SESSION,'-n','idle','-c',ROOT,'/bin/sh','-i')
    for window,cmd in [('python',[str(LAB/'python3'),'-m','tui_gateway.entry']),('node',[shutil.which('node'),str(LAB/'ui-tui/dist/entry.js')]),('decoy',[shutil.which('node'),'-e','console.log("decoy ready"); setInterval(()=>{},1000)',str(LAB/'ui-tui/dist/entry.js')])]:
        tmux('new-window','-d','-t',SESSION+':','-n',window,'-c',ROOT,*cmd)
    time.sleep(1)
    for window in ['idle','python','node','decoy']:
        tmux('set-window-option','-t',SESSION+':'+window,'automatic-rename','off')
        capture=tmux('capture-pane','-p','-t',SESSION+':'+window)
        (EVIDENCE/(window+'-pane.txt')).write_text(capture.stdout)
        info=tmux('display-message','-p','-t',SESSION+':'+window,'#{pane_width}x#{pane_height} #{pane_current_command} #{pane_pid}')
        print(window,info.stdout.strip(),flush=True)
        pane_pids.append(int(info.stdout.split()[-1]))
        ps=command(['ps','-o','args=','-p',str(pane_pids[-1])])
        print(window+' OS argv: '+ps.stdout.strip(),flush=True)
    baseline=probe(LAB/'baseline','idle')
    record('baseline: idle pane on Bash 3.2',baseline)
    assert 'words[@]: unbound variable' in baseline.stderr, 'baseline must reproduce reported failure'
    for window,expected in [('idle','dead'),('python','alive'),('node','alive'),('decoy','ambiguous')]:
        r=probe(ROOT,window)
        record('target: '+window,r)
        assert r.returncode==0 and r.stdout==expected+'\nprobe returned normally\n' and not r.stderr
    traced=probe(ROOT,'idle',True)
    relevant=[line for line in traced.stderr.splitlines() if "fm_hermes_process_matches ''" in line]
    assert relevant, 'live idle probe must actually exercise the empty-argv branch'
    (EVIDENCE/'empty-argv-trace.txt').write_text('\n'.join(relevant)+'\n'+traced.stdout)
    # Focused regression command from the added test.
    for library in [EVIDENCE/'baseline-lib.sh',ROOT/'bin/fm-hermes-process-lib.sh']:
        r=command(['/bin/bash','-c','set -u; . "$1"; fm_hermes_process_matches ""; status=$?; printf "empty status=%s; shell continued\\n" "$status"','_',library],False)
        record('direct regression: '+library.name,r)
        if library.name=='baseline-lib.sh': assert r.returncode!=0 and 'unbound variable' in r.stderr
        else: assert r.returncode==0 and r.stdout=='empty status=1; shell continued\n' and not r.stderr
    print('All three live scenarios passed. Real Node and synthetic Python-shaped native argv; no real Hermes CLI or login used.',flush=True)
finally:
    r=tmux('kill-server',check=False)
    print('private tmux kill-server exit',r.returncode,flush=True)
    # Verify all panes are gone, rather than leaving the server detached.
    r=tmux('list-sessions',check=False)
    print('private tmux list-sessions after cleanup exit',r.returncode,flush=True)
    assert r.returncode!=0
    time.sleep(.3)
    for pid in pane_pids:
        try: os.kill(pid,0)
        except ProcessLookupError: continue
        raise AssertionError('pane process still running: '+str(pid))
    print('all pane process PIDs are gone',flush=True)
    (EVIDENCE/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
