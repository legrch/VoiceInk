#!/usr/bin/env python3
"""Plan, reserve and verify an explicit release without editing source files."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from release_identity import base_metadata, normalize_metadata

REPO = 'legrch/VoiceInk'
PREFIX = f'repos/{REPO}'
SHA = r'[a-f0-9]{40}'
TAG = r'plus-v([0-9]+(?:\.[0-9]+){1,2})-r([1-9][0-9]{0,8})'
REQUEST_SCHEMA = 'voiceink-release/v1'


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON field; refusing ambiguous release metadata.')
        result[key] = value
    return result


def request_json(raw):
    require(isinstance(raw, str) and len(raw.encode()) <= 16384, 'Invalid or oversized reservation JSON.')
    return json.loads(raw, object_pairs_hook=unique_object)


class GitHub:
    """No mutation retries: an uncertain effect stops this workflow attempt."""
    def call(self, path, method='GET', data=None, missing=False, asset=False):
        args = ['gh', 'api', path, '--method', method]
        if asset:
            args += ['-H', 'Accept: application/octet-stream']
        if data is not None:
            args += ['--input', '-']
        env = dict(os.environ, GH_HOST='github.com')
        env.pop('GH_DEBUG', None)
        result = subprocess.run(args, input=None if data is None else json.dumps(data),
                                text=True, capture_output=True, env=env)
        if result.returncode:
            if method == 'GET' and missing and re.search(r'\(HTTP 404\)', result.stderr):
                return None
            raise RuntimeError(f'GitHub {method} failed at {path}; reconcile the original run before retrying writes.')
        try:
            require(not asset or len(result.stdout.encode()) <= 16384, 'Oversized published manifest.')
            return json.loads(result.stdout, object_pairs_hook=unique_object)
        except (ValueError, TypeError) as error:
            raise RuntimeError(f'Invalid GitHub response at {path}; no automatic retry.') from error

    def get(self, path, **kwargs):
        return self.call(f'{PREFIX}/{path}', **kwargs)

    def post(self, path, data):
        return self.call(f'{PREFIX}/{path}', 'POST', data)

    def pages(self, path, key=None):
        rows = []
        for page in range(1, 101):
            result = self.get(f'{path}{"&" if "?" in path else "?"}per_page=100&page={page}')
            values = result[key] if key else result
            require(isinstance(values, list), 'Expected a paginated GitHub list.')
            rows.extend(values)
            if len(values) < 100:
                return rows
        raise RuntimeError('GitHub pagination limit reached; refusing incomplete evidence.')


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def tag_ref(api, tag):
    require(re.fullmatch(TAG, tag), 'Invalid release tag.')
    return api.get(f'git/ref/tags/{tag}', missing=True)


def dereference(api, ref):
    obj = ref['object']
    for _ in range(4):
        require(re.fullmatch(SHA, obj.get('sha', '')), 'Invalid Git object identity.')
        if obj['type'] == 'commit':
            return obj['sha']
        require(obj['type'] == 'tag', 'Expected tag or commit object.')
        obj = api.get(f'git/tags/{obj["sha"]}')['object']
    raise RuntimeError('Release tag nesting exceeds the supported limit.')


def release_manifest(api, release):
    require(not release.get('draft') and not release.get('prerelease'), 'Draft/prerelease is not a completed stable release.')
    tag = release['tag_name']
    require(re.fullmatch(TAG, tag), 'Invalid published tag.')
    assets = release.get('assets', [])
    manifests = [a for a in assets if a['name'] == 'release.json']
    require(len(manifests) == 1 and 0 < manifests[0]['size'] <= 16384, 'Missing or invalid published manifest.')
    m = api.get(f'releases/assets/{manifests[0]["id"]}', asset=True)
    require(type(m.get('schema')) is int and m['schema'] == 1 and type(m.get('revision')) is int and type(m.get('build')) is int,
            'Invalid published release numbers.')
    require(0 < m['revision'] < 10**9 and 225 < m['build'] < 2147483647, 'Published release numbers out of range.')
    require(re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', m.get('upstream_version', '')),
            'Invalid published upstream version.')
    require(m.get('tag') == tag == f"plus-v{m['upstream_version']}-r{m['revision']}", 'Published tag mismatch.')
    require(m.get('asset') == f"VoiceInk-Plus-{m['upstream_version']}-r{m['revision']}-AppleSilicon.zip",
            'Published archive name mismatch.')
    require(re.fullmatch(SHA, m.get('source_commit', '')) and
            re.fullmatch(r'[a-f0-9]{64}', m.get('archive_sha256', '')), 'Invalid published source/hash.')
    require({a['name'] for a in assets} == {m['asset'], 'release.json', 'install.sh', 'SHA256SUMS'} and
            all(a.get('state') == 'uploaded' and a.get('size', 0) > 0 for a in assets),
            'Partial or unexpected published assets; inspect without overwriting.')
    archive = next(a for a in assets if a['name'] == m['asset'])
    require(archive.get('digest') == 'sha256:' + m['archive_sha256'], 'Published asset digest mismatch.')
    ref = tag_ref(api, tag)
    require(ref is not None and dereference(api, ref) == m['source_commit'], 'Published tag/source mismatch.')
    return m


def latest(api):
    return release_manifest(api, api.get('releases/latest'))


def validate_request(request, tag=None):
    require(isinstance(request, dict) and set(request) == {'schema', 'metadata', 'run_id', 'supersedes'},
            'Invalid reservation fields.')
    require(request['schema'] == REQUEST_SCHEMA and isinstance(request['run_id'], str) and
            re.fullmatch(r'[1-9][0-9]{0,19}', request['run_id']),
            'Invalid reservation schema/run.')
    m = normalize_metadata(request['metadata'])
    require(re.fullmatch(SHA, m.get('source_commit', '')), 'Reservation must name an exact source commit.')
    require(tag is None or tag == m['tag'], 'Reservation/tag mismatch.')
    retired = request['supersedes']
    require(isinstance(retired, list) and len(retired) <= 32 and len(set(retired)) == len(retired) and
            all(isinstance(t, str) and re.fullmatch(TAG, t) and t != m['tag'] for t in retired),
            'Invalid superseded reservation list.')
    return {**request, 'metadata': m}


def read_request(api, tag, ref=None):
    ref = ref or tag_ref(api, tag)
    require(ref is not None and ref['object']['type'] == 'tag', 'Expected an annotated reserved tag.')
    obj = api.get(f'git/tags/{ref["object"]["sha"]}')
    require(obj.get('tag') == tag and len(obj.get('message', '').encode()) <= 16384, 'Invalid tag annotation.')
    request = validate_request(request_json(obj['message']), tag)
    require(obj['object'].get('type') == 'commit' and obj['object'].get('sha') == request['metadata']['source_commit'],
            'Reservation source does not match its tag object.')
    return request


def inventory(api):
    refs = api.get('git/matching-refs/tags/plus-v')
    require(isinstance(refs, list) and len(refs) <= 10000, 'Incomplete or oversized tag inventory.')
    requests, names = [], []
    for ref in refs:
        tag = ref['ref'].removeprefix('refs/tags/')
        require(re.fullmatch(TAG, tag), 'Unexpected Plus tag; inspect before release.')
        names.append(tag)
        obj = api.get(f'git/tags/{ref["object"]["sha"]}') if ref['object']['type'] == 'tag' else None
        try:
            raw = request_json(obj['message']) if obj else None
        except (ValueError, KeyError):
            raw = None
        if isinstance(raw, dict) and raw.get('schema') == REQUEST_SCHEMA:
            requests.append(read_request(api, tag, ref))
        else:
            historical = api.get(f'releases/tags/{tag}', missing=True)
            require(historical is not None and not historical['draft'] and not historical['prerelease'],
                    f'Unrecognized unpublished tag {tag}; inspect its original request.')
    return requests, names


def retired_tags(requests):
    by_tag = {r['metadata']['tag']: r for r in requests}
    for successor in requests:
        for tag in successor['supersedes']:
            require(tag in by_tag and by_tag[tag]['metadata']['build'] < successor['metadata']['build'],
                    'Invalid reservation retirement lineage; inspect without changing tags.')
    return {t for r in requests for t in r['supersedes']}


def request_matches_base(request, base, source):
    m = request['metadata']
    require(m['source_commit'] == source and all(m[k] == base[k] for k in ('product', 'upstream_version', 'upstream_commit')),
            'Reservation does not match selected source/upstream provenance.')
    require(m['build'] >= base['build'], 'Reservation is below source build floor.')


def completed_origin(api, request):
    run = api.get(f'actions/runs/{request["run_id"]}')
    require(run.get('head_sha') == request['metadata']['source_commit'] and
            run.get('path') == '.github/workflows/release.yml' and
            run.get('repository', {}).get('full_name') == REPO,
            'Reservation origin run provenance mismatch.')
    require(run.get('status') == 'completed' and run.get('conclusion') in ('failure', 'cancelled', 'timed_out', 'action_required'),
            'Original reservation is active, successful or unresolved; inspect it instead of allocating.')


def choose_request(api, base, source, run_id, publish):
    published = latest(api)
    requests, names = inventory(api)
    retired = retired_tags(requests)
    if publish and published['source_commit'] == source:
        return None
    own = [r for r in requests if r['run_id'] == run_id]
    require(len(own) <= 1, 'Ambiguous original run reservation.')
    if own:
        request = own[0]
        request_matches_base(request, base, source)
        require(request['metadata']['tag'] not in retired, 'Original reservation was superseded; do not resume it.')
        return request
    unfinished = []
    for request in requests:
        tag = request['metadata']['tag']
        if tag in retired:
            continue
        release = api.get(f'releases/tags/{tag}', missing=True)
        if release is not None:
            manifest = release_manifest(api, release)
            require(all(manifest[k] == request['metadata'][k] for k in ('tag', 'build', 'revision', 'source_commit')),
                    'Existing publication disagrees with its reservation.')
            if publish and manifest['source_commit'] == source:
                return None
        else:
            unfinished.append(request)
    if publish:
        same = [r for r in unfinished if r['metadata']['source_commit'] == source]
        require(len(same) <= 1, 'Multiple same-source reservations require inspection.')
        if same:
            request_matches_base(same[0], base, source)
            completed_origin(api, same[0])
            return same[0]
        for request in unfinished:
            completed_origin(api, request)
    revisions = [int(match[2]) for tag in names if (match := re.fullmatch(TAG, tag)) and match[1] == base['upstream_version']]
    revision = max(revisions + [0]) + 1
    build = max([base['build'], published['build']] + [r['metadata']['build'] for r in requests]) + 1
    metadata = normalize_metadata({**base, 'revision': revision, 'build': build, 'source_commit': source,
                                   'tag': f"plus-v{base['upstream_version']}-r{revision}",
                                   'asset': f"VoiceInk-Plus-{base['upstream_version']}-r{revision}-AppleSilicon.zip"})
    return validate_request({'schema': REQUEST_SCHEMA, 'metadata': metadata, 'run_id': run_id,
                             'supersedes': sorted(r['metadata']['tag'] for r in unfinished) if publish else []})


def green_main(api, source, wait_seconds=0):
    deadline = time.monotonic() + wait_seconds
    while True:
        runs = api.pages(f'actions/workflows/checks.yml/runs?event=push&branch=main&head_sha={source}', 'workflow_runs')
        if not runs:
            require(time.monotonic() < deadline, 'No main Checks run exists for the selected source.')
            time.sleep(min(15, max(0, deadline - time.monotonic())))
            continue
        run = max(runs, key=lambda r: r['id'])
        require(run.get('head_sha') == source and run.get('head_branch') == 'main' and
                run.get('event') == 'push' and run.get('path') == '.github/workflows/checks.yml' and
                run.get('repository', {}).get('full_name') == REPO, 'Main Checks provenance mismatch.')
        if run['status'] == 'completed':
            require(run.get('conclusion') == 'success', 'Latest main Checks failed or was canceled.')
            jobs = api.pages(f'actions/runs/{run["id"]}/attempts/{run["run_attempt"]}/jobs', 'jobs')
            require(any(j['name'] == 'macos-build' and j['status'] == 'completed' and j['conclusion'] == 'success' for j in jobs),
                    'Exact main run lacks a successful macOS build.')
            return
        require(time.monotonic() < deadline, 'Main Checks are not finished; wait and rerun the release request.')
        time.sleep(min(15, max(0, deadline - time.monotonic())))


def validate_source(api, source):
    require(re.fullmatch(SHA, source) and git('rev-parse', 'HEAD') == source, 'Wrong checkout/source identity.')
    subprocess.run(['git', 'fetch', '--quiet', 'origin', 'main'], cwd=ROOT, check=True)
    main = api.get('git/ref/heads/main')['object']['sha']
    subprocess.run(['git', 'merge-base', '--is-ancestor', source, main], cwd=ROOT, check=True)
    return main


def verify(api, request, expected_object=None):
    request = validate_request(request)
    m = request['metadata']
    ref = tag_ref(api, m['tag'])
    require(ref is not None, 'Reserved tag is missing.')
    require(expected_object is None or ref['object']['sha'] == expected_object, 'Tag object moved after reservation.')
    require(read_request(api, m['tag'], ref) == request, 'Tag annotation changed after planning.')
    requests, _ = inventory(api)
    require(m['tag'] not in retired_tags(requests), 'Reservation was superseded; publication is permanently refused.')
    validate_source(api, m['source_commit'])
    green_main(api, m['source_commit'])
    require(latest(api)['build'] < m['build'], 'A same/newer build is already published; do not replace assets.')
    return ref['object']['sha']


def reserve(api, request, base, source):
    request = validate_request(request)
    request_matches_base(request, base, source)
    m = request['metadata']
    existing = tag_ref(api, m['tag'])
    if existing is not None:
        return verify(api, request)
    require(validate_source(api, source) == source, 'Main moved before new reservation; request current main instead.')
    green_main(api, source)
    require(choose_request(api, base, source, request['run_id'], True) == request, 'Allocation changed before reservation.')
    # No automatic retry after either POST. Preserve the original Actions run on uncertainty.
    obj = api.post('git/tags', {'tag': m['tag'], 'message': json.dumps(request, sort_keys=True), 'object': source, 'type': 'commit'})
    require(re.fullmatch(SHA, obj.get('sha', '')), 'Tag object result is uncertain; inspect the original run.')
    api.post('git/refs', {'ref': 'refs/tags/' + m['tag'], 'sha': obj['sha']})
    return verify(api, request, obj['sha'])


def outputs(values):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        for key, value in values.items():
            text = json.dumps(value, separators=(',', ':'), sort_keys=True) if isinstance(value, dict) else str(value)
            require('\n' not in text and '\r' not in text, 'Invalid workflow output.')
            stream.write(f'{key}={text}\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['plan', 'reserve', 'verify'])
    args = parser.parse_args()
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == REPO,
            'This entrypoint only operates in the selected repository Actions workflow.')
    os.chdir(ROOT)
    api = GitHub()
    source = git('rev-parse', 'HEAD')
    base = base_metadata(ROOT)
    if args.operation == 'plan':
        event, ref = os.environ['GITHUB_EVENT_NAME'], os.environ['GITHUB_REF']
        mode = os.environ.get('RELEASE_MODE', 'dry-run')
        require(event in ('workflow_dispatch', 'push') and mode in ('dry-run', 'publish'), 'Invalid release event/mode.')
        expected = os.environ.get('EXPECTED_SOURCE', '')
        require(not expected or expected == source, 'Main changed after local dispatch; inspect the selected source.')
        publish = event == 'push' or mode == 'publish'
        if event == 'push':
            require(ref.startswith('refs/tags/'), 'Ordinary branch pushes never release.')
            request = read_request(api, ref.removeprefix('refs/tags/'))
            request_matches_base(request, base, source)
            verify(api, request)
        else:
            require(ref.startswith('refs/heads/'), 'Manual requests must select a branch.')
            require(os.environ['GITHUB_SHA'] == source, 'Dispatch source mismatch.')
            if publish:
                require(ref == 'refs/heads/main', 'Publish requests must select main.')
                validate_source(api, source)
                green_main(api, source, wait_seconds=3600)
            request = choose_request(api, base, source, os.environ['GITHUB_RUN_ID'], publish)
        if request is None:
            print('Selected source is already released; no tag or release was created.')
            outputs({'ready': 'false', 'publish': 'false', 'source': source})
        else:
            outputs({'ready': 'true', 'publish': str(publish).lower(), 'source': source,
                     'tag': request['metadata']['tag'], 'metadata': request['metadata'], 'reservation': request})
            print(('Requested release: ' if publish else 'Dry-run candidate: ') + request['metadata']['tag'])
    else:
        raw = os.environ['VOICEINK_RELEASE_RESERVATION']
        request = validate_request(request_json(raw))
        request_matches_base(request, base, source)
        effective = os.environ.get('VOICEINK_RELEASE_METADATA')
        require(effective is None or normalize_metadata(request_json(effective)) == request['metadata'],
                'Build metadata differs from the reserved identity.')
        object_sha = reserve(api, request, base, source) if args.operation == 'reserve' else verify(
            api, request, os.environ.get('VOICEINK_RELEASE_TAG_OBJECT'))
        if args.operation == 'reserve':
            outputs({'tag_object': object_sha})


if __name__ == '__main__':
    main()
