import importlib.util,tempfile,json
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('backup','scripts/dev-backup.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix='voiceink-backup-tests-',dir='/private/tmp') as fixture:
    home=Path(fixture);source=home/'Library/Application Support/com.prakashjoshipax.VoiceInk';source.mkdir(parents=True)
    (source/'settings').write_text('first');(source/'._literal').write_text('retained')
    module.snapshot(home,lambda:None)
    root=home/'Library/Application Support/VoiceInk-Personal-Backups'
    assert (root/'dev-latest/Application Support/settings').read_text()=='first'
    (source/'settings').write_text('second');module.snapshot(home,lambda:None)
    assert (root/'dev-latest/Application Support/settings').read_text()=='second'
    assert (root/'dev-latest/Application Support/._literal').read_text()=='retained'
    assert sorted(p.name for p in root.iterdir())==['dev-latest']
    with patch.object(module.shutil,'copytree',side_effect=OSError('injected copy failure')):
        try:module.snapshot(home,lambda:None)
        except OSError:pass
        else:raise AssertionError('Copy failure accepted')
    assert (root/'dev-latest/Application Support/settings').read_text()=='second'
    assert sorted(p.name for p in root.iterdir())==['dev-latest']
print('One-slot Dev backup rotation, literal files and failure preservation passed')
