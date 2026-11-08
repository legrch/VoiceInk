"""Stateful offline release lifecycle; no network, keys, tags or publication."""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

root = Path.cwd()
sys.path.insert(0, str(root / 'scripts'))
from release_identity import base_metadata

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

m = load('server_release', 'scripts/ci/server-release.py')
cli = load('request_release', 'scripts/release-tag.py')
SOURCE, OLD, NEXT = 'a'*40, 'b'*40, 'd'*40
base = m.normalize_metadata(dict(schema=1, product='VoiceInk Plus', upstream_version='2.25',
                                 upstream_commit='e'*40, revision=4, build=1004))

class Fake:
    def __init__(self):
        self.refs = {}; self.objects = {}; self.releases = {}; self.assets = {}; self.runs = {}
        self.main = SOURCE; self.calls = []; self.lost_ref = False
        self.publish('plus-v2.25-r4', OLD, 4, 1004)
        self.checks = [dict(id=7, run_attempt=2, head_sha=SOURCE, head_branch='main', event='push',
                           path='.github/workflows/checks.yml', repository={'full_name':m.REPO},
                           status='completed', conclusion='success')]
        self.jobs = [dict(name='macos-build', status='completed', conclusion='success')]
    def publish(self, tag, source, revision, build):
        manifest = dict(schema=1, upstream_version='2.25', revision=revision, build=build, tag=tag,
                        source_commit=source, asset=f'VoiceInk-Plus-2.25-r{revision}-AppleSilicon.zip', archive_sha256='1'*64)
        asset_id = len(self.assets)+1; self.assets[asset_id] = manifest
        assets = [dict(name=n, id=asset_id if n=='release.json' else 90, size=300, state='uploaded',
                       digest='sha256:'+'1'*64) for n in [manifest['asset'],'release.json','install.sh','SHA256SUMS']]
        self.releases[tag] = dict(tag_name=tag, draft=False, prerelease=False, assets=assets)
        self.latest = tag
        if tag not in self.refs:
            oid = f'{len(self.objects)+1:040x}'
            self.objects[oid] = dict(tag=tag, message='Historical release', object=dict(type='commit',sha=source))
            self.refs[tag] = dict(ref='refs/tags/'+tag, object=dict(type='tag',sha=oid))
    def get(self, path, missing=False, asset=False):
        if path == 'releases/latest': value = self.releases[self.latest]
        elif path == 'git/matching-refs/tags/plus-v': value = list(self.refs.values())
        elif path == 'git/ref/heads/main': value = {'object':{'sha':self.main}}
        elif path.startswith('releases/assets/'): value = self.assets[int(path.rsplit('/',1)[1])]
        elif path.startswith('git/ref/tags/'): value = self.refs.get(path.removeprefix('git/ref/tags/'))
        elif path.startswith('git/tags/'): value = self.objects[path.removeprefix('git/tags/')]
        elif path.startswith('releases/tags/'): value = self.releases.get(path.removeprefix('releases/tags/'))
        elif path.startswith('actions/runs/'): value = self.runs[path.removeprefix('actions/runs/')]
        else: raise AssertionError(path)
        if value is None and not missing: raise RuntimeError('unexpected absence')
        return copy.deepcopy(value)
    def post(self, path, data):
        self.calls.append((path,copy.deepcopy(data)))
        if path == 'git/tags':
            oid = f'{len(self.objects)+1:040x}'
            self.objects[oid] = dict(tag=data['tag'],message=data['message'],object=dict(type=data['type'],sha=data['object']))
            return {'sha':oid}
        if path == 'git/refs':
            name = data['ref'].removeprefix('refs/tags/')
            if name in self.refs: raise RuntimeError('ref conflict')
            self.refs[name] = dict(ref=data['ref'],object=dict(type='tag',sha=data['sha']))
            if self.lost_ref: raise RuntimeError('write succeeded; acknowledgement lost')
            return self.refs[name]
        raise AssertionError(path)
    def pages(self,path,key=None):
        return copy.deepcopy(self.checks if path.startswith('actions/workflows/') else self.jobs)
    def failed_origin(self, request, conclusion='failure', status='completed'):
        self.runs[request['run_id']] = dict(head_sha=request['metadata']['source_commit'],
            repository={'full_name':m.REPO},path='.github/workflows/release.yml',status=status,conclusion=conclusion)

def rejects(fn, message):
    try: fn()
    except (RuntimeError,ValueError,TypeError,KeyError,subprocess.CalledProcessError): return
    raise AssertionError(message)

def reserve(api,request,source=SOURCE):
    with patch.object(m,'validate_source',return_value=api.main),patch.object(m,'green_main'):
        return m.reserve(api,request,base,source)

api = Fake(); request = m.choose_request(api,base,SOURCE,'10',True)
assert request['metadata']['revision']==5 and request['metadata']['build']==1005
assert not api.calls
obj = reserve(api,request)
assert [x[0] for x in api.calls]==['git/tags','git/refs']
assert m.read_request(api,'plus-v2.25-r5')==request
assert m.choose_request(api,base,SOURCE,'10',True)==request
reserve(api,request); assert len(api.calls)==2
api.failed_origin(request)
assert m.choose_request(api,base,SOURCE,'11',True)==request

# A corrected source retires a confirmed failed reservation, retaining its consumed numbers.
replacement = m.choose_request(api,base,NEXT,'12',True)
assert replacement['metadata']['revision']==6 and replacement['metadata']['build']==1006
assert replacement['supersedes']==['plus-v2.25-r5']
api.main = NEXT; reserve(api,replacement,NEXT)
with patch.object(m,'validate_source',return_value=NEXT),patch.object(m,'green_main'):
    rejects(lambda:m.verify(api,request,obj),'retired reservation resumed')
assert 'plus-v2.25-r5' in api.refs

# Canceled queued reruns retain any reservation from their earlier attempt.
api.failed_origin(request,conclusion='cancelled')
rejects(lambda:m.choose_request(api,base,SOURCE,'10',True),'queued cancellation erased supersession')

for state,conclusion in [('in_progress',None),('completed','success'),('completed','unknown')]:
    a=Fake();r=m.choose_request(a,base,SOURCE,'20',True);reserve(a,r);a.failed_origin(r,conclusion,state)
    rejects(lambda:m.choose_request(a,base,NEXT,'21',True),'active/unknown reservation superseded')
    assert len(a.calls)==2

# A partial publication is not absence, and cannot be superseded.
a=Fake();r=m.choose_request(a,base,SOURCE,'30',True);reserve(a,r);a.failed_origin(r)
a.releases[r['metadata']['tag']]={'tag_name':r['metadata']['tag'],'draft':True,'prerelease':False,'assets':[]}
rejects(lambda:m.choose_request(a,base,NEXT,'31',True),'draft release bypassed')

# Lost mutation acknowledgement stops effects; explicit original-run reconciliation reuses the tag.
a=Fake();r=m.choose_request(a,base,SOURCE,'40',True);a.lost_ref=True
rejects(lambda:reserve(a,r),'lost response silently retried')
assert len(a.calls)==2 and m.choose_request(a,base,SOURCE,'40',True)==r

# Source drift, allocation drift, moved tag object and malformed annotation fail closed.
a=Fake();r=m.choose_request(a,base,SOURCE,'50',True);a.main=NEXT
rejects(lambda:reserve(a,r),'stale main reserved');assert not a.calls
for field,value in [('revision',6),('build',1006),('source_commit',NEXT),('upstream_commit','f'*40)]:
    a=Fake();r=m.choose_request(a,base,SOURCE,'51',True);r['metadata'][field]=value
    rejects(lambda:reserve(a,r),'altered plan reserved');assert not a.calls

a=Fake();r=m.choose_request(a,base,SOURCE,'52',True);oid=reserve(a,r)
rejects(lambda:m.verify(a,r,'f'*40),'moved tag object accepted')
a.objects[oid]['object']['sha']=NEXT
rejects(lambda:m.read_request(a,r['metadata']['tag']),'moved source accepted')

# Allocation for a new upstream resets only revision; the numeric build never resets.
a=Fake();new_base={**base,'upstream_version':'2.26'};new_base.pop('tag');new_base.pop('asset')
r=m.choose_request(a,new_base,SOURCE,'60',True)
assert (r['metadata']['revision'],r['metadata']['build'])==(1,1005)
higher={**base,'build':1010};assert m.choose_request(a,higher,SOURCE,'61',True)['metadata']['build']==1011
assert m.choose_request(a,base,OLD,'62',True) is None and not a.calls
rejects(lambda:m.choose_request(a,{**base,'build':2147483646},SOURCE,'63',True),'build overflow accepted')

# Dry runs make no reservations, even with an active publish reservation.
a=Fake();r=m.choose_request(a,base,SOURCE,'70',True);reserve(a,r)
d=m.choose_request(a,base,NEXT,'71',False)
assert d['supersedes']==[] and d['metadata']['build']==1006 and len(a.calls)==2

# Strict published-state checks and exact successful main-run/attempt provenance.
a=Fake();a.releases[a.latest]['assets'].pop()
rejects(lambda:m.latest(a),'partial latest release accepted')
a=Fake();m.green_main(a,SOURCE)
for field,value in [('head_sha',NEXT),('head_branch','other'),('event','pull_request'),('path','other.yml'),('conclusion','failure'),('status','in_progress')]:
    a=Fake();a.checks[0][field]=value
    rejects(lambda:m.green_main(a,SOURCE),'bad Checks provenance accepted')
a=Fake();a.jobs[0]['conclusion']='failure'
rejects(lambda:m.green_main(a,SOURCE),'failed macos job accepted')
a=Fake();a.checks.append({**a.checks[0],'id':8,'conclusion':'failure'})
rejects(lambda:m.green_main(a,SOURCE),'old green run hid a newer failure')

# The real task entry point only reads origin/main and dispatches once; it never edits local Git.
before=subprocess.check_output(['git','status','--porcelain'],text=True)
for flag,mode in [([], 'publish'),(['--dry-run'],'dry-run')]:
    calls=[]
    def run(args,**kwargs):
        calls.append((args,kwargs))
        value={'object':{'sha':SOURCE}} if 'git/ref/heads/main' in args[2] else {
            'workflow_run_id':123,'html_url':f'https://github.com/{m.REPO}/actions/runs/123'}
        return subprocess.CompletedProcess(args,0,json.dumps(value),'')
    with patch.object(cli.subprocess,'run',side_effect=run),patch.object(cli.subprocess,'check_output',return_value='git@github.com:legrch/VoiceInk.git\n'),patch.object(sys,'argv',['release-tag.py']+flag),contextlib.redirect_stdout(io.StringIO()):
        cli.main()
    assert len(calls)==2 and json.loads(calls[1][1]['input'])=={'ref':'main','inputs':{'mode':mode,'expected_source':SOURCE}}
assert subprocess.check_output(['git','status','--porcelain'],text=True)==before

workflow=Path('.github/workflows/release.yml').read_text()
assert 'branches: [main]' not in workflow.split('permissions:',1)[0]
assert 'default: dry-run' in workflow and 'cancel-in-progress: false' in workflow
assert "format('voiceink-dry-{0}', github.run_id)" in workflow and "|| 'voiceink-release'" in workflow
assert 'environment: release' in workflow and 'needs.reserve.outputs.tag_object' in workflow
assert 'python3 scripts/ci/server-release.py verify' in workflow
print('Server allocation, immutable reservation/recovery/retirement, exact Checks and no-mutation dispatch tests passed; no GitHub writes.')
