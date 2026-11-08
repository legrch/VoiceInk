#!/usr/bin/env python3
"""Keep one verified rolling Dev data snapshot. Never restore or launch an app."""
import fcntl, hashlib, json, os, shutil, subprocess, tempfile
from pathlib import Path

def require(condition, message='Validation failed'):
    if not condition:
        raise RuntimeError(message)
os.umask(63)

def closed():
    if subprocess.run(['pgrep', '-x', 'VoiceInk'], stdout=subprocess.DEVNULL).returncode != 1:
        raise SystemExit('Quit VoiceInk before creating the Dev snapshot.')

def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

def snapshot(home, check_closed):
    check_closed()
    base = home / 'Library/Application Support/VoiceInk-Personal-Backups'
    base.mkdir(parents=True, exist_ok=True)
    if base.is_symlink():
        raise SystemExit('Backup root must not be a symlink.')
    latest = base / 'dev-latest'
    previous = base / 'dev-previous'
    for slot in (latest, previous):
        if slot.is_symlink():
            raise SystemExit('Backup slot must not be a symlink.')
    if previous.exists() and (not latest.exists()):
        previous.rename(latest)
    if previous.exists():
        if not (latest / 'VERIFIED.json').is_file():
            raise SystemExit('Inspect the interrupted Dev snapshot before retrying.')
        shutil.rmtree(previous)
    stage = Path(tempfile.mkdtemp(prefix='dev-staging.', dir=base))
    try:
        (stage / 'INCOMPLETE').write_text('Snapshot is not verified yet.\n')
        pairs = [(home / 'Library/Application Support/com.prakashjoshipax.VoiceInk', 'Application Support'), (home / 'Library/Application Support/VoiceInk/CustomSounds', 'CustomSounds'), (home / 'Library/Preferences/com.prakashjoshipax.VoiceInk.plist', 'Preferences.plist')]
        checks = {}
        for source, label in pairs:
            if not source.exists():
                continue
            if source.is_symlink():
                raise SystemExit('Profile source must not be a symlink.')
            target = stage / label
            if source.is_dir():
                shutil.copytree(source, target, symlinks=True)
            else:
                shutil.copy2(source, target)
            items = list(source.rglob('*')) if source.is_dir() else [source]
            for item in items:
                relative = item.relative_to(source) if source.is_dir() else Path()
                copied = target / relative if source.is_dir() else target
                key = str(Path(label) / relative)
                if item.is_symlink():
                    require(copied.is_symlink() and copied.readlink() == item.readlink(), 'Symlink mismatch')
                    checks[key] = {'symlink': str(item.readlink())}
                elif item.is_file():

                    def digest(path):
                        h = hashlib.sha256()
                        with path.open('rb') as stream:
                            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                                h.update(chunk)
                        return h.hexdigest()
                    value = digest(item)
                    require(value == digest(copied), 'Snapshot content mismatch')
                    checks[key] = {'sha256': value}
                    with copied.open('rb') as stream:
                        os.fsync(stream.fileno())
        check_closed()
        with (stage / 'VERIFIED.json').open('w') as stream:
            json.dump(checks, stream)
            stream.flush()
            os.fsync(stream.fileno())
        (stage / 'INCOMPLETE').unlink()
        directories = [p for p in stage.rglob('*') if p.is_dir() and not p.is_symlink()]
        for directory in sorted(directories, key=lambda p: len(p.parts), reverse=True):
            sync_directory(directory)
        sync_directory(stage)
        if latest.exists():
            latest.rename(previous)
            sync_directory(base)
        try:
            stage.rename(latest)
            sync_directory(base)
        except BaseException:
            if previous.exists() and (not latest.exists()):
                previous.rename(latest)
                sync_directory(base)
            raise
        if previous.exists():
            shutil.rmtree(previous)
            sync_directory(base)
        print('Verified rolling Dev snapshot:', latest)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
if __name__ == '__main__':
    snapshot(Path.home(), closed)
