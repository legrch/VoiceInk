"""Exercise production build invocations without compiling or accessing Keychain."""
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path

repo = Path.cwd()
fingerprint = 'C5C6F16ED5A3D8B28CF3A4CA19638284E9190C6B'
with tempfile.TemporaryDirectory(prefix='voiceink-signing-tests-', dir='/private/tmp') as scratch:
    root = Path(scratch)
    tools = root / 'bin'
    tools.mkdir()
    home = root / 'home'
    (home / 'VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework').mkdir(parents=True)
    fixtures = {
        'xcodebuild': '''#!/bin/bash
set -eu
identity=; derived=
while [[ $# -gt 0 ]]; do
  case "$1" in
    CODE_SIGN_IDENTITY=*) identity=${1#*=} ;;
    -derivedDataPath) shift; derived=$1 ;;
  esac
  shift
done
[[ "$identity" == "$EXPECTED_IDENTITY" ]] || exit 81
mkdir -p "$derived/Build/Products/Release/VoiceInk.app/Contents"
cp VoiceInk/Info.plist "$derived/Build/Products/Release/VoiceInk.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.prakashjoshipax.VoiceInk" "$derived/Build/Products/Release/VoiceInk.app/Contents/Info.plist"
printf 'xcodebuild:%s\\n' "$identity" >> "$INVOCATIONS"
''',
        'codesign': '''#!/bin/bash
set -eu
case "$1" in
  --force)
    [[ "$2" == --options && "$3" == runtime && "$4" == --sign && "$5" == "$EXPECTED_IDENTITY" ]] || exit 82
    printf 'codesign:%s\\n' "$5" >> "$INVOCATIONS" ;;
  --display) echo 'CodeDirectory v=20400 size=100 flags=0x10000(runtime)' >&2 ;;
  --verify) ;;
  *) exit 83 ;;
esac
'''
    }
    for name, source in fixtures.items():
        path = tools / name
        path.write_text(source)
        path.chmod(0o755)
    for mode, override, expected in [('dev', None, fingerprint), ('dev', fingerprint, fingerprint), ('ci', None, '-')]:
        case = root / f'{mode}-{override is not None}'
        case.mkdir()
        log = case / 'calls'
        env = dict(os.environ, HOME=str(home), PATH=str(tools) + ':' + os.environ['PATH'],
                   VOICEINK_DERIVED_DATA=str(case / 'derived'), VOICEINK_BUILD_OUTPUT=str(case / 'output'),
                   EXPECTED_IDENTITY=expected, INVOCATIONS=str(log))
        env.pop('VOICEINK_SIGNING_IDENTITY', None)
        if override is not None:
            env['VOICEINK_SIGNING_IDENTITY'] = override
        subprocess.run(['bash', 'scripts/build-app.sh', mode], env=env, check=True)
        assert log.read_text().splitlines() == [f'xcodebuild:{expected}', f'codesign:{expected}']
        info = plistlib.loads((case / 'output/VoiceInk.app/Contents/Info.plist').read_bytes())
        assert info['VoiceInkSourceCommit']
print('Production build uses an exact default identity at both signing sites; CI remains ad-hoc. No Keychain access.')
