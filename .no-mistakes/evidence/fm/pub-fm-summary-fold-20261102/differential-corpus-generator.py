import random, sys, os
out = sys.argv[1]; n = int(sys.argv[2]); seed = int(sys.argv[3])
rng = random.Random(seed)
VERBS = ['needs-decision','needs-decision','blocked','blocked','resolved','resolved','captain-held','done','failed',
         'working','answered','note','Needs-decision','needs-decisions','progress','held']
KEYS = ['a','b','c','d','default','x.y-z_1','pending-reply-t1','nm-run1-step','captain-hold-q','remote-reply-continuity-z',
        'bad slug','','a/b','k*','k?','Q9']
STAMPS = ['[at=1793600000]','[at=10:30]','[at=]','[at=2026-11-02T10:30:00Z]','[at=0123]','[at=1793600000][at=1]','[at=9999999999999]']
CORR = ['[corr=abc]','corr=0123456789abcdef','corr=xyz','[corr=0123456789abcdef]']
NOTES = ['pick REST or RPC','question %s here','back\\slash \\n esc','tab\there','glob * ? [x]','$HOME and `cmd`',
         'unicode žák ✓','trailing spaces   ','[key=zz] inside','pending-reply-missed: lost reply',
         'pending-reply-x: ok','with: colon: inside','','   leading',"quote ' and \"",'cr\r','x'*300,
         'choose: A or B','[at=1793600001] stamp in note']
def key_tok(k): return '[key=%s]' % k
def line():
    r = rng.random()
    if r < 0.06: return rng.choice(['', '   ', 'continuation prose without verb', '  indented: prose', '\t'])
    v = rng.choice(VERBS); k = rng.choice(KEYS); note = rng.choice(NOTES)
    head = v
    if rng.random() < 0.25: head += ' ' + rng.choice(STAMPS)
    if rng.random() < 0.12: head += ' ' + rng.choice(CORR)
    form = rng.random()
    if form < 0.35:
        s = '%s %s:%s%s' % (head, key_tok(k), rng.choice([' ', '', '  ']), note)
    elif form < 0.65:
        s = '%s:%s%s%s%s' % (head, rng.choice([' ','','   ']), key_tok(k), rng.choice([' ','','  ']), note)
    elif form < 0.75:
        s = '%s %s%s' % (head, key_tok(k), rng.choice(['', ' trailing words', ' ']))
    elif form < 0.82:
        s = '%s %s: %s %s' % (head, key_tok(k), key_tok(rng.choice(KEYS)), note)
    elif form < 0.88:
        s = '%s %s %s: %s' % (head, key_tok(k), rng.choice(STAMPS + CORR), note)
    else:
        s = '%s: %s' % (head, note)
    if rng.random() < 0.05: s = '  ' + s
    if rng.random() < 0.03: s = s + '\r'
    return s
os.makedirs(out, exist_ok=True)
for i in range(n):
    d = os.path.join(out, 'c%04d' % i); os.makedirs(d, exist_ok=True)
    nl = rng.choice([0,1,2,3,5,8,13,21,34,55,89])
    lines = [line() for _ in range(nl)]
    body = '\n'.join(lines)
    if lines and rng.random() < 0.8: body += '\n'
    with open(os.path.join(d, 'task.status'), 'w', encoding='utf-8', newline='') as f: f.write(body)
    mk = rng.random()
    if mk < 0.8:
        kind = rng.choice(['ship','scout','secondmate','', 'weird'])
        with open(os.path.join(d, 'task.meta'), 'w') as f:
            f.write('kind=%s\n' % kind if kind else 'harness=x\n')
