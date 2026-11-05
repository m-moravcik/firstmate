import os, signal, json, ssl, socketserver, http.server, threading, subprocess, time, hashlib
from pathlib import Path
from urllib.parse import urlsplit
ROOT=Path.cwd()
E=Path('~/.no-mistakes/evidence/01M6PE6P3PVADA0A483VFFTGJX')
FIX=E/'local-api-fixtures-proof'; FIX.mkdir(exist_ok=True)
NOW='2026-11-05T10:00:00Z'; HEAD='a'*40
# Synthetic credentials. They have no authority outside this loopback emulator.
TOKENS={'owner_acme':'gho_lab_owner_synthetic_9e17','personal':'gho_lab_personal_synthetic_64bd','other_corp':'gho_lab_other_synthetic_3a92'}
LOG=[]; LOCK=threading.Lock(); TRANSCRIPT=[]; RESULTS=[]; PROCESS_COMMANDS=set(); ARGV_LEAKS=[]
def log(s):
    TRANSCRIPT.append(s); print(s,flush=True)
def run(args,env=None,timeout=150):
    proc=subprocess.Popen(args,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    stop=threading.Event()
    def monitor():
        while not stop.is_set():
            rows=subprocess.check_output(['ps','-axo','pid=,ppid=,command='],text=True).splitlines()
            parsed=[]
            for row in rows:
                cols=row.strip().split(None,2)
                if len(cols)==3: parsed.append((int(cols[0]),int(cols[1]),cols[2]))
            owned={proc.pid}
            for _ in range(12):
                owned.update(pid for pid,ppid,cmd in parsed if ppid in owned)
            for pid,ppid,cmd in parsed:
                if pid not in owned: continue
                if any(t in cmd for t in TOKENS.values()): ARGV_LEAKS.append('synthetic credential in owned process argv')
                if 'gh ' in cmd or 'gh auth' in cmd:
                    safe=cmd
                    for token in TOKENS.values():safe=safe.replace(token,'[REDACTED]')
                    PROCESS_COMMANDS.add(safe)
            stop.wait(1.0)
    watcher=threading.Thread(target=monitor);watcher.start()
    try:
        out,err=proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid,signal.SIGTERM)
        try: out,err=proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid,signal.SIGKILL);out,err=proc.communicate()
        raise
    finally:
        stop.set();watcher.join()
    return subprocess.CompletedProcess(args,proc.returncode,out,err)
cert=FIX/'cert.pem'; key=FIX/'key.pem'
p=run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=api.github.com','-addext','subjectAltName=DNS:api.github.com,DNS:github.com'])
assert p.returncode==0,p.stderr
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(cert,key)
class API(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def do_GET(self): self.api()
    def do_POST(self): self.api()
    def api(self):
        payload=self.rfile.read(int(self.headers.get('Content-Length','0')))
        raw=self.headers.get('Authorization','').split(' ')[-1]
        identity=next((k for k,v in TOKENS.items() if raw==v),'unknown')
        path=urlsplit(self.path).path
        data=json.loads(payload or '{}') if payload else {}
        query=data.get('query','')
        row={'identity':identity,'method':self.command,'path':path,'graphql_fields': [f for f in ['headRefOid','reviewDecision','reviewThreads','isDraft','state'] if f in query]}
        with LOCK: LOG.append(row)
        status=200
        owner=path.split('/')[2] if path.startswith('/repos/') else data.get('variables',{}).get('owner')
        if owner is None and 'owner:' in query:
            import re
            m=re.search(r'owner:\s*"([^\"]+)"',query); owner=m.group(1) if m else None
        if identity=='unknown' or (owner=='acme' and identity!='owner_acme') or (owner=='zcorp' and identity!='other_corp'):
            status=404; body={'message':'Not Found'}
        elif path=='/graphql':
            body={'data':{'repository':{'pullRequest':{'headRefOid':HEAD,'reviewDecision':'APPROVED','isDraft':False,'state':'OPEN','reviewThreads':{'nodes':[],'pageInfo':{'hasNextPage':False,'endCursor':None}}}}}}
        elif path.endswith('/check-runs'):
            body={'total_count':1,'check_runs':[{'id':101,'name':'build','status':'completed','conclusion':'success','started_at':NOW}]}
        elif any(path.endswith('/'+x) for x in ['comments','reviews','statuses','events']): body=[]
        elif '/pulls/' in path:
            body={'number':8,'state':'open','user':{'login':'contributor'},'head':{'sha':HEAD},'draft':False,'mergeable':True,'merged_at':None}
        elif '/issues/' in path: body={'number':9,'state':'open','user':{'login':'contributor'},'labels':[]}
        elif path.startswith('/repos/'):
            body={'name':'repo','full_name':f'{owner}/repo','permissions':{'push':True},'default_branch':'main'}
        else: status=404;body={'message':'Unknown local fixture route'}
        encoded=json.dumps(body).encode()
        self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(encoded)));self.end_headers();self.wfile.write(encoded)
class Tunnel(socketserver.BaseRequestHandler):
    def handle(self):
        buf=b''
        while not buf.endswith(b'\r\n\r\n') and len(buf)<16384:
            b=self.request.recv(1)
            if not b:return
            buf+=b
        line=buf.split(b'\r\n')[0]
        if line not in [b'CONNECT api.github.com:443 HTTP/1.1',b'CONNECT github.com:443 HTTP/1.1']:
            self.request.sendall(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n');return
        self.request.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
        with ctx.wrap_socket(self.request,server_side=True) as secured:
            API(secured,self.client_address,self.server)
class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address=True;daemon_threads=True
server=Server(('127.0.0.1',0),Tunnel); thread=threading.Thread(target=server.serve_forever);thread.start()
proxy=f'http://127.0.0.1:{server.server_address[1]}'
base={k:v for k,v in os.environ.items() if not (k.startswith(('FM_','HERDR_','GH_','GITHUB_','TASKS_AXI_')) or k in ['HTTPS_PROXY','HTTP_PROXY','ALL_PROXY','https_proxy','http_proxy','all_proxy','NO_PROXY','no_proxy','TMUX','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR'])}
base.update(HTTPS_PROXY=proxy,HTTP_PROXY=proxy,https_proxy=proxy,http_proxy=proxy,NO_PROXY='',no_proxy='',SSL_CERT_FILE=str(cert),GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1',GH_TOKEN=TOKENS['personal'],GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
base['NO_MISTAKES_GATE']=os.environ.get('NO_MISTAKES_GATE','1')
def make_home(name,mapping=None,owners=('acme',)):
    h=FIX/name;h.mkdir()
    for d in ['data','state','config','projects','gh-config','tmp']: (h/d).mkdir()
    hosts='github.com:\n    user: personal\n    oauth_token: '+TOKENS['personal']+'\n    git_protocol: https\n    users:\n'
    for account,token in TOKENS.items(): hosts+=f'        {account}:\n            oauth_token: {token}\n'
    (h/'gh-config/hosts.yml').write_text(hosts)
    if mapping is not None: (h/'config/github-owner-accounts').write_text(mapping)
    backlog='# Backlog\n\n## Queued\n'
    for i,owner in enumerate(owners):
        task=f'delivery-{i}';url=f'https://github.com/{owner}/repo/pull/8'
        backlog+=f'- [ ] {task} - Observe {owner} {url} (repo: synthetic) (kind: ship)\n'
    (h/'data/backlog.md').write_text(backlog)
    env=base|{'FM_HOME':str(h),'FM_ROOT_OVERRIDE':str(ROOT),'FM_STATE_OVERRIDE':str(h/'state'),'FM_DATA_OVERRIDE':str(h/'data'),'FM_CONFIG_OVERRIDE':str(h/'config'),'FM_PROJECTS_OVERRIDE':str(h/'projects'),'GH_CONFIG_DIR':str(h/'gh-config'),'FM_CONTRIBUTIONS_NOW':NOW,'FM_BEARINGS_NOW':NOW,'FM_CONTRIBUTIONS_REPLY_AGE':'300','FM_CONTRIBUTIONS_BUDGET':'25','TMPDIR':str(h/'tmp')}
    for i,owner in enumerate(owners):
        p=run([str(ROOT/'bin/fm-contributions.sh'),'enroll',f'delivery-{i}',f'https://github.com/{owner}/repo/pull/8'],env)
        assert p.returncode==0,p.stderr
    p=run([str(ROOT/'bin/fm-contributions.sh'),'arm'],env);assert p.returncode==0,p.stderr
    return h,env

def records(h): return [json.loads(p.read_text())['records'][0] for p in sorted((h/'data').glob('*/contributions.json'))]
def snapshot(h,env):
    # Exact product projection consumes canonical fleet input and durable observer output.
    p=run([str(ROOT/'bin/fm-fleet-snapshot.sh'),'--contribution-input'],env); assert p.returncode==0,p.stderr
    (h/'contribution-input.json').write_text(p.stdout)
    p=run([str(ROOT/'bin/fm-contributions.sh'),'snapshot',str(h/'contribution-input.json'),'--all'],env);assert p.returncode==0,p.stderr
    (h/'projection.json').write_text(p.stdout)
    return json.loads(p.stdout)
def check_home(h,env):
    before=(h/'gh-config/hosts.yml').read_bytes();start=len(LOG)
    p=run(['bash',str(h/'state/contributions.check.sh')],env)
    assert p.returncode==0,(p.stdout,p.stderr)
    assert (h/'gh-config/hosts.yml').read_bytes()==before,'observer changed stored account configuration'
    for area in ['data','state','tmp']:
        for f in (h/area).rglob('*'):
            if f.is_file():
                b=f.read_bytes()
                assert not any(v.encode() in b for v in TOKENS.values()),f'token persisted in {f}'
    log(f'{h.name}: bash state/contributions.check.sh -> exit {p.returncode}; stdout={p.stdout.strip()!r}; stderr={p.stderr.strip()!r}')
    return records(h),LOG[start:],p.stdout

def scenario(name,fn):
    start=len(LOG)
    try:
        details=fn();RESULTS.append({'name':name,'result':'pass','live':True,'evidence':'live-transcript.log; local-api-requests.json; '+details,'reason':'Real fm-contributions CLI and installed gh 2.103.0 ran against an isolated loopback TLS GitHub API with synthetic stored accounts. No tenant or production validation.'});log('SCENARIO PASS: '+name)
    except Exception as ex:
        RESULTS.append({'name':name,'result':'fail','live':True,'evidence':'live-transcript.log; local-api-requests.json','reason':repr(ex)});log('SCENARIO FAIL: '+name+' '+repr(ex))

def mapped():
    h,env=make_home('mapped-emu','# owner account\n\nACME owner_acme\nzcorp other_corp\n',('acme','unlisted'))
    calls=[]
    for minute in ['00','05','10','15','20','25']:
        cycle_env=env|{'FM_CONTRIBUTIONS_NOW':f'2026-11-05T10:{minute}:00Z'}
        r,cycle_calls,out=check_home(h,cycle_env);calls+=cycle_calls
        if all(x.get('observation') and x['error'] is None for x in r): break
    env=env|{'FM_CONTRIBUTIONS_NOW':f'2026-11-05T10:{minute}:00Z'}
    assert all(x['error'] is None and x.get('observation') and x['observation']['head']==HEAD for x in r),r
    byowner={x['url'].split('/')[3]:x for x in r}
    assert byowner['acme']['observation']['can_merge'] is False
    assert byowner['unlisted']['observation']['can_merge'] is True
    assert any(x['path']=='/graphql' and 'headRefOid' in x['graphql_fields'] for x in calls),calls
    assert any(x['path']=='/graphql' and 'reviewThreads' in x['graphql_fields'] for x in calls),calls
    assert {x['identity'] for x in calls if x['path'].startswith('/repos/acme/')}=={'owner_acme'}
    assert {x['identity'] for x in calls if x['path'].startswith('/repos/unlisted/')}=={'personal'}
    projection=snapshot(h,env)
    log('mapped-emu: durable observations '+json.dumps([{'url':x['url'],'error':x['error'],'can_merge':x['observation']['can_merge']} for x in r]))
    log('mapped-emu: public projection '+json.dumps(projection))
    assert projection['counts']['maintainer']==1 and projection['counts']['captain']==1,projection
    return 'local-api-fixtures-proof/mapped-emu/projection.json'
def ambient():
    for name,mapping in [('ambient-absent',None),('ambient-unlisted','someone-else owner_acme\n')]:
        h,env=make_home(name,mapping,('unlisted',))
        r,calls,out=check_home(h,env)
        assert r[0]['error'] is None and r[0]['observation']['can_merge'] is True,r
        assert calls and {x['identity'] for x in calls}=={'personal'},calls
        assert (h/'gh-config/hosts.yml').read_text().splitlines()[1]=='    user: personal'
        log(name+': real gh requests all use personal; active account and ambient merge readiness retained')
    return 'local-api-fixtures-proof/ambient-absent/data/delivery-0/contributions.json'
def invalid():
    cases=[('missing-field','acme\n'),('extra-field','acme owner_acme extra\n'),('owner-underscore','ac_me owner_acme\n'),('duplicate-owner','acme owner_acme\nACME other_corp\n'),('account-leading-hyphen','acme -owner\n'),('crlf','acme owner_acme\r\n'),('unreadable-directory',None)]
    for name,mapping in cases:
        h,env=make_home('invalid-'+name,mapping,('acme','unlisted'))
        if name=='unreadable-directory': (h/'config/github-owner-accounts').mkdir()
        r,calls,out=check_home(h,env)
        assert not calls,'invalid config contacted forge'
        assert len(r)==2 and all(x['error'] and 'owner identity configuration' in x['error'] and x.get('retired') is None and x.get('observation') is None for x in r),r
        assert out.count('observation unavailable')==2,out
        log(name+': both mapped and unlisted owners unavailable; zero API requests; no retirement')
    return 'local-api-fixtures-proof/invalid-duplicate-owner/data/delivery-0/contributions.json'
def missing():
    h,env=make_home('missing-login','acme missing_not_stored\n')
    r,calls,out=check_home(h,env)
    assert not calls and 'identity read for missing_not_stored' in r[0]['error'] and r[0].get('retired') is None,(r,calls)
    first_error=r[0]['error']
    r,calls,out=check_home(h,env|{'FM_CONTRIBUTIONS_NOW':'2026-11-05T10:10:00Z'})
    assert not calls and out=='' and r[0]['error'] and r[0].get('retired') is None,(r,calls,out)
    (h/'config/github-owner-accounts').write_text('acme owner_acme\n')
    r,calls,out=check_home(h,env|{'FM_CONTRIBUTIONS_NOW':'2026-11-05T10:20:00Z'})
    assert calls and r[0]['error'] is None and r[0]['observation']['can_merge'] is False,r
    log('missing-login: repeated real gh identity failure stayed unavailable without API fallback; correcting mapping restored observation and cleared error')
    return 'local-api-fixtures-proof/missing-login/data/delivery-0/contributions.json'
try:
    log('Real product: bin/fm-contributions.sh enroll -> arm -> generated contributions.check.sh -> snapshot; gh 2.103.0; loopback TLS proxy, synthetic accounts only.')
    scenario('Local TLS API: mapped EMU accounts read private PRs per owner and never grant merge authority',mapped)
    scenario('Local TLS API: absent mapping and unmapped owners retain ambient identity and merge readiness',ambient)
    scenario('Local CLI: malformed, duplicate, invalid-owner and unreadable configuration blocks every observation',invalid)
    scenario('Local gh: missing stored login refuses fallback, remains in rotation and recovers after correction',missing)
finally:
    server.shutdown();server.server_close();thread.join(timeout=5)
    (E/'local-api-requests.json').write_text(json.dumps(LOG,indent=2)+'\n')
    (E/'live-transcript.log').write_text('\n'.join(TRANSCRIPT)+'\n')
    (E/'live-scenarios.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
    (E/'owned-process-argv.json').write_text(json.dumps({'sampled_gh_commands':sorted(PROCESS_COMMANDS),'token_argv_violations':ARGV_LEAKS},indent=2)+'\n')
    log('Loopback server stopped and joined; all subprocesses reaped.')
    assert not ARGV_LEAKS,ARGV_LEAKS

assert len(RESULTS)==4 and all(x['result']=='pass' for x in RESULTS),RESULTS
