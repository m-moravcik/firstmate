import os, pathlib, subprocess, json
root=pathlib.Path.cwd()
work=root/'.live-validation'
lab=work/'lab'
log=[]
def run(label,args,env=None):
 p=subprocess.run(args,cwd=root,env=env,capture_output=True,text=True,timeout=100)
 log.append({'check':label,'argv':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 return p
base=os.environ.copy()
for k in list(base):
 if k.startswith(('FM_','HERDR_','TASKS_AXI_')) or k in ('ANTHROPIC_API_KEY','CLAUDE_CODE_OAUTH_TOKEN','CLAUDE_CONFIG_DIR','TMUX','SHELLOPTS','BASH_ENV','ENV'): base.pop(k,None)
base['TMPDIR']=str(work/'tmp')
base['HOME']=str(work/'user-home')
base['FM_HOME']=str(lab)
pathlib.Path(base['HOME']).mkdir(exist_ok=True)
run('Create disposable marked lab home',['bash','bin/fm-lab-home.sh','create',str(lab)],base)
(lab/'config/backlog-backend').write_text('manual\n')
first=work/'first'; second=work/'second'
first.mkdir(exist_ok=True); second.mkdir(exist_ok=True)
# Only these two operator-provisioned synthetic items may be read.
for account in ('first','second'):
 for explicit in (False,True):
  args=['security','find-generic-password','-s','fm-livetest-8327','-a',account,'-w']
  if explicit: args.append('~/fleet/homes/oss/data/pub-fm-keychain-token-20261102/livetest-keychain/fm-livetest-8327.keychain-db')
  p=subprocess.run(args,capture_output=True,timeout=10)
  log.append({'check':'Prepared synthetic item availability','account':account,'explicit_keychain':explicit,'exit':p.returncode,'nonempty':bool(p.stdout.strip()),'stderr':p.stderr.decode(errors='replace')})
def source(account):
 return {'claude':{'source':'macos-keychain','service':'fm-livetest-8327','account':account}}
sourcefile=lab/'config/claude-account-credential-source.json'
sourcefile.write_text(json.dumps(source('first')))
def spawn(label,*extra):
 ident=label
 p=run(label,['bash','bin/fm-spawn.sh',ident,str(root),'--mode','no-mistakes','--yolo','off','--harness','claude','--backend','tmux',*extra],base)
 log[-1]['task_record_exists']=(lab/'state'/f'{ident}.meta').exists()
 return p
orphan=spawn('unbound-source')
assert orphan.returncode==1 and 'requires a Claude account pin' in orphan.stderr, orphan.stderr
(lab/'config/claude-account').write_text(str(first)+'\n')
sourcefile.write_text(json.dumps({'claude':{**source('first')['claude'],'unexpected':'invalid'}}))
malformed=spawn('malformed-source')
assert malformed.returncode==1 and 'malformed' in malformed.stderr, malformed.stderr
sourcefile.write_text(json.dumps(source('first')))
base['ANTHROPIC_API_KEY']='synthetic-ambient-key'
base['CLAUDE_CODE_OAUTH_TOKEN']='synthetic-ambient-token'
unavailable=spawn('unavailable-source')
assert unavailable.returncode==1 and 'never falls back' in unavailable.stderr, unavailable.stderr
# Switch to the operator-requested pool configuration without modifying any credential.
(lab/'config/claude-account').rename(lab/'config/pin.saved')
sourcefile.rename(lab/'config/source.saved')
for account in ('first','second'):
 (lab/'config'/f'claude-account-credential-source-{account}.json').write_text(json.dumps(source(account)))
(lab/'config/claude-accounts').write_text(f'{first}\tclaude-account-credential-source-first.json\n{second}\tclaude-account-credential-source-second.json\n')
quota=run('Real quota reading for two empty isolated roots',['bash','bin/fm-claude-account-quota.sh'],base)
assert quota.returncode==0 and str(first) in quota.stdout and str(second) in quota.stdout
explicit=spawn('explicit-second','--account',str(second))
assert explicit.returncode==1 and 'token could not be loaded' in explicit.stderr, explicit.stderr
# Exercise the real helper under inherited bash tracing. No replacement security or Claude.
traceenv=base.copy(); traceenv['SHELLOPTS']='xtrace'; traceenv['CLAUDE_CONFIG_DIR']=str(second)
trace=run('Traced real helper with unreadable prepared source',['bash','bin/fm-claude-token.sh','exec',str(lab/'config/claude-account-credential-source-second.json'),'--','claude','auth','status'],traceenv)
assert trace.returncode==3 and 'is unavailable' in trace.stderr
assert not any((lab/'state').glob('*.meta'))
log.append({'check':'Isolation postcondition','task_records':0,'runtime_started':False,'keychain_mutations':0,'note':'No successful first read was possible; worker delivery, relaunch and second-read transition remain unproven.'})
path=pathlib.Path('~/.no-mistakes/evidence/01M7877KGYFCYZC5D4WMDHHF0J/live-product.json')
path.write_text(json.dumps(log,indent=2)+'\n')
for entry in log:
 print(entry['check'], 'exit='+str(entry.get('exit','n/a')))
print('Evidence:',path)
