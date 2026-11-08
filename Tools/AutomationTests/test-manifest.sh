#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d /private/tmp/voiceink-manifest-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
source scripts/install.sh
fixture="$work/manifest.json"
python3 - "$fixture" <<'PY'
import json,sys
json.dump(dict(schema=1,tag='plus-v2.25-r4',upstream_version='2.25',revision=4,build=1004,
 asset='VoiceInk-Plus-2.25-r4-AppleSilicon.zip',archive_sha256='a'*64),open(sys.argv[1],'w'))
PY
load_release plus-v2.25-r4 "$fixture" /unused.zip
[[ $VERSION == plus-v2.25-r4 && $BUILD_NUMBER == 1004 && $ARCHIVE_SHA256 == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
# Every manifest is data; shell metacharacters, foreign tags and malformed values fail.
for field in schema tag upstream_version revision build asset archive_sha256; do
    python3 - "$fixture" "$work/bad.json" "$field" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]));m[sys.argv[3]]='$(touch /tmp/voiceink-must-not-run)';json.dump(m,open(sys.argv[2],'w'))
PY
    if (load_release plus-v2.25-r4 "$work/bad.json" /unused.zip) >/dev/null 2>&1; then
        echo "FAIL: malformed $field accepted" >&2;exit 1
    fi
done
if (load_release plus-v2.25-r5 "$fixture" /unused.zip) >/dev/null 2>&1; then exit 1; fi
printf 'Manifest identity, numeric bounds, tag mismatch and data-only rejection checks passed.\n'
