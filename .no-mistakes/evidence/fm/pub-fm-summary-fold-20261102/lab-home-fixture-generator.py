# gen-home.py <lab-home> <seed> <transitions-per-secondmate>
# Populates a disposable lab FM_HOME with long-lived secondmate status logs plus
# ship/scout children, shaped like a long-running secondmate home.
import os, random, sys
home, seed, ntrans = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rng = random.Random(seed)
st = os.path.join(home, 'state'); data = os.path.join(home, 'data')
def meta(tid, **kv):
    with open(os.path.join(st, tid + '.meta'), 'w') as f:
        for k, v in kv.items(): f.write('%s=%s\n' % (k, v))
epoch = 1793500000
def stamp():
    global epoch
    epoch += rng.randint(5, 600)
    return ' [at=%d]' % epoch if rng.random() < 0.6 else ''
def secondmate_log(tid, n):
    open_keys = []; seq = 0; lines = []; trans = 0
    while trans < n:
        r = rng.random()
        if r < 0.45:
            lines.append('working%s: step %d of the %s queue' % (stamp(), len(lines), tid)); continue
        trans += 1
        if r < 0.62 or not open_keys:
            seq += 1; k = '%s-q%d' % (tid, seq); open_keys.append(k)
            if rng.random() < 0.5:
                lines.append('needs-decision%s [key=%s]: choose option %d for %s' % (stamp(), k, seq, tid))
            else:
                lines.append('needs-decision%s: [key=%s] choose option %d for %s' % (stamp(), k, seq, tid))
        elif r < 0.70:
            seq += 1; k = '%s-b%d' % (tid, seq); open_keys.append(k)
            lines.append('blocked%s [key=%s]: waiting on external %d' % (stamp(), k, seq))
        elif r < 0.88:
            k = open_keys.pop(rng.randrange(len(open_keys)))
            lines.append('resolved%s [key=%s]: answered' % (stamp(), k))
        elif r < 0.93:
            k = rng.choice(open_keys)
            lines.append('needs-decision%s [key=%s]: re-asked %s' % (stamp(), k, k))
        elif r < 0.97:
            lines.append('done%s: finished an unrelated child handoff' % stamp())
        else:
            k = open_keys.pop(rng.randrange(len(open_keys)))
            lines.append('captain-held%s [key=%s]: handed to captain' % (stamp(), k))
    with open(os.path.join(st, tid + '.status'), 'w') as f: f.write('\n'.join(lines) + '\n')
    return len(lines), len(open_keys)
for i, tid in enumerate(['mate-alpha', 'mate-beta', 'mate-gamma']):
    meta(tid, window='fm-lab:fm-' + tid, worktree=os.path.join(home, 'projects', tid), project=tid,
         harness='claude', kind='secondmate', mode='secondmate', home=os.path.join(home, 'projects', tid), projects='sample')
    nl, no = secondmate_log(tid, ntrans + i * (ntrans // 4))
    print('%s lines=%d open=%d' % (tid, nl, no))
meta('ship-open', window='fm-lab:fm-ship-open', worktree=os.path.join(home, 'projects', 'ship-wt'), project='sample',
     harness='claude', kind='ship', mode='no-mistakes')
with open(os.path.join(st, 'ship-open.status'), 'w') as f:
    f.write('working: building\nneeds-decision [key=api-shape]: pick REST or RPC\nblocked: [key=ci] runner offline\nresolved [key=ci]: runner back\n')
meta('scout-done', window='fm-lab:fm-scout-done', worktree=os.path.join(home, 'projects', 'ship-wt'), project='sample',
     harness='claude', kind='scout', mode='scout')
with open(os.path.join(st, 'scout-done.status'), 'w') as f:
    f.write('needs-decision [key=scope]: how deep\ndone: report ready\n')
os.makedirs(os.path.join(home, 'projects', 'ship-wt'), exist_ok=True)
with open(os.path.join(data, 'backlog.md'), 'w') as f:
    f.write('# Backlog\n\n## In flight\n- [ ] ship-open - Ship the open thing (repo: sample) (kind: ship) (since 2026-10-30)\n'
            '- [ ] scout-done - Investigate the thing (repo: sample) (kind: scout) (since 2026-10-30)\n\n## Queued\n\n## Done\n')
