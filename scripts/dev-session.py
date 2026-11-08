#!/usr/bin/env python3
"""Switch the shared profile through an app-owned idle quit, then restore stable."""
import fcntl,hashlib,os,plistlib,subprocess,sys,tempfile,time,uuid
from pathlib import Path
def processes():
    r=subprocess.run(['pgrep','-x','VoiceInk'],capture_output=True,text=True)
    if r.returncode==1:return []
    if r.returncode!=0:raise RuntimeError('Cannot establish process state')
    return [int(p) for p in r.stdout.split()]
def validate(candidate):
    subprocess.run(['codesign','--verify','--deep','--strict',str(candidate)],check=True)
    info=plistlib.loads((candidate/'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier']=='com.prakashjoshipax.VoiceInk'
    with tempfile.TemporaryDirectory(prefix='voiceink-dev-cert-',dir='/private/tmp') as directory:
        prefix=str(Path(directory)/'cert')
        subprocess.run(['codesign','-d','--extract-certificates='+prefix,str(candidate)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        assert hashlib.sha256(Path(prefix+'0').read_bytes()).hexdigest()=='fbb0182020b4091415f9ee73f17b156010daac2291f3f700a85ba4c5d7dbdb89','Unexpected signing certificate'
    return info
def run_session(app,stable,home):
    lock_root=home/'Library/Application Support/VoiceInk-Personal-Backups'
    lock_root.mkdir(parents=True,exist_ok=True)
    if lock_root.is_symlink():raise SystemExit('Session root must not be a symlink.')
    descriptor=os.open(lock_root/'dev-session.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        try:fcntl.flock(descriptor,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise SystemExit('Another task dev session is already active.')
        switch(app,stable)
    finally:os.close(descriptor)

def switch(app,stable):
    assert app.name=='VoiceInk.app' and app!=stable and (app/'Contents/MacOS/VoiceInk').is_file()
    validate(app);validate(stable)
    with tempfile.TemporaryDirectory(prefix='voiceink-dev-switch-',dir='/private/tmp') as scratch:
        tool=Path(scratch)/'notify'
        subprocess.run(['swiftc','Tools/DevSwitch/main.swift','-o',str(tool)],check=True)
        current=processes()
        if len(current)>1:raise SystemExit('Multiple VoiceInk copies are running; close the extra copy first.')
        if current:
            pid=current[0]
            executable=subprocess.check_output(['ps','-ww','-p',str(pid),'-o','comm='],text=True).strip()
            if executable!=str(stable/'Contents/MacOS/VoiceInk'):
                raise SystemExit('Another development copy is running. Close it before starting a new session.')
            if validate(stable).get('VoiceInkDevSwitchProtocol')!=1:
                raise SystemExit('This older stable app lacks idle switching. Quit it once with Command-Q and retry; upgraded builds switch automatically.')
            nonce=str(uuid.uuid4())
            subprocess.run([str(tool),str(pid),nonce,'quitWhenIdle',str(os.getpid())],check=True)
            print('Waiting for VoiceInk to finish recording, transcription and audio restoration...',flush=True)
            try:
                deadline=time.monotonic()+1200
                while pid in processes():
                    if time.monotonic()>deadline:raise TimeoutError('VoiceInk is still busy; no process was stopped.')
                    time.sleep(0.2)
            finally:
                if pid in processes():subprocess.run([str(tool),str(pid),nonce,'cancel',str(os.getpid())],check=True)
        if processes():raise SystemExit('VoiceInk reopened; refusing a concurrent profile session.')
        subprocess.run(['python3','scripts/dev-backup.py'],check=True)
        if processes():raise SystemExit('VoiceInk reopened after backup; refusing a concurrent profile session.')
        try:subprocess.run(['open','-n','-W',str(app)],check=True)
        finally:
            if not processes():subprocess.run(['open',str(stable)],check=True)

if __name__ == '__main__':
    if len(sys.argv)!=2:raise SystemExit('Usage: dev-session.py /path/to/VoiceInk.app')
    run_session(Path(sys.argv[1]).resolve(),Path('/Applications/VoiceInk.app'),Path.home())
