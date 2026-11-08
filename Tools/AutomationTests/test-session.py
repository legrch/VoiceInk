import importlib.util,subprocess,tempfile
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('session','scripts/dev-session.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with tempfile.TemporaryDirectory(prefix='voiceink-session-tests-',dir='/private/tmp') as directory:
    root=Path(directory);dev=root/'Dev/VoiceInk.app';stable=root/'Stable/VoiceInk.app'
    for app in (dev,stable):(app/'Contents/MacOS').mkdir(parents=True);(app/'Contents/MacOS/VoiceInk').touch()
    def scenario(protocol=1, timeout=False):
        events=[];state={'polls':0,'requested':False}
        def processes():
            if state['requested'] and not timeout:
                state['polls']+=1
                if state['polls']>2:return []
            return [123] if not state.get('exited') else []
        def run(args,**kwargs):
            if 'quitWhenIdle' in args:events.append('request');state['requested']=True
            elif 'cancel' in args:events.append('cancel')
            elif args[0]=='python3':events.append('backup');state['exited']=True
            elif args[0]=='open':events.append('dev' if '-W' in args else 'stable')
            return subprocess.CompletedProcess(args,0)
        clock=iter([0,1300]) if timeout else iter([0,0,0,0,0,0])
        with patch.object(m,'validate',return_value={'VoiceInkDevSwitchProtocol':protocol}),patch.object(m,'processes',side_effect=processes),patch.object(m.subprocess,'run',side_effect=run),patch.object(m.subprocess,'check_output',return_value=str(stable/'Contents/MacOS/VoiceInk')),patch.object(m.time,'sleep'),patch.object(m.time,'monotonic',side_effect=lambda:next(clock)):
            try:m.run_session(dev,stable,root)
            except (SystemExit,TimeoutError):events.append('stopped')
        return events
    assert scenario()==['request','backup','dev','stable']
    assert scenario(protocol=0)==['stopped']
    assert scenario(timeout=True)==['request','cancel','stopped']
print('Dev session waits before backup, returns to stable, refuses legacy guessing and cancels on timeout')
