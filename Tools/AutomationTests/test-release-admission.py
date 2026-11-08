#!/usr/bin/env python3
"""Offline entrypoint admission regressions. No GitHub, Git, or source writes."""
import builtins
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

# Importing source modules must not create bytecode in the shared checkout.
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[2]
SOURCE, OTHER = 'a' * 40, 'b' * 40


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The server imports its sibling; don't leave its temporary search path behind.
with patch.object(sys, 'path', [str(ROOT / 'scripts'), *sys.path]):
    server = load('admission_server', 'scripts/ci/server-release.py')
    cli = load('admission_cli', 'scripts/release-tag.py')


class FakeGitHub:
    def __init__(self):
        self.calls = []
        self.refs = {}
        self.objects = {}
        self.base = server.base_metadata(ROOT)
        self.old_tag = f"plus-v{self.base['upstream_version']}-r1"
        self.archive = f"VoiceInk-Plus-{self.base['upstream_version']}-r1-AppleSilicon.zip"
        self.manifest = dict(schema=1, upstream_version=self.base['upstream_version'], revision=1,
                             build=500, tag=self.old_tag, source_commit=OTHER,
                             asset=self.archive, archive_sha256='1' * 64)
        self.release = dict(tag_name=self.old_tag, draft=False, prerelease=False,
                            assets=[dict(name=n, id=1, size=100, state='uploaded', digest='sha256:'+'1'*64)
                                    for n in (self.archive, 'release.json', 'install.sh', 'SHA256SUMS')])
        self.refs[self.old_tag] = {'ref': 'refs/tags/' + self.old_tag,
                                   'object': {'type': 'commit', 'sha': OTHER}}

    def get(self, path, **kwargs):
        self.calls.append(('GET', path))
        if path == 'releases/latest': result = self.release
        elif path == 'releases/assets/1': result = self.manifest
        elif path == 'git/matching-refs/tags/plus-v': result = list(self.refs.values())
        elif path == 'git/ref/heads/main': result = {'object': {'sha': SOURCE}}
        elif path.startswith('git/ref/tags/'): result = self.refs.get(path[len('git/ref/tags/'):])
        elif path.startswith('git/tags/'): result = self.objects[path[len('git/tags/'):]]
        elif path.startswith('releases/tags/') and kwargs.get('missing'):
            result = self.release if path == 'releases/tags/' + self.old_tag else None
        else: raise AssertionError('Unexpected API read: ' + path)
        return copy.deepcopy(result)

    def post(self, path, data):
        self.calls.append(('POST', path))
        raise AssertionError('Unexpected mutation: ' + path)

    def pages(self, path, key=None):
        self.calls.append(('GET pages', path))
        if 'workflows/checks.yml' in path:
            return [dict(id=10, run_attempt=1, head_sha=SOURCE, head_branch='main', event='push',
                         path='.github/workflows/checks.yml', repository={'full_name': server.REPO},
                         status='completed', conclusion='success')]
        return [dict(name='macos-build', status='completed', conclusion='success')]

    def reservation(self):
        metadata = server.normalize_metadata({**self.base, 'revision': 2, 'build': 501,
                                               'source_commit': SOURCE,
                                               'tag': f"plus-v{self.base['upstream_version']}-r2",
                                               'asset': f"VoiceInk-Plus-{self.base['upstream_version']}-r2-AppleSilicon.zip"})
        return dict(schema=server.REQUEST_SCHEMA, metadata=metadata, run_id='42', supersedes=[])

    def add_reservation(self, request, object_source=SOURCE):
        tag = request['metadata']['tag']
        oid = 'c' * 40
        self.refs[tag] = {'ref': 'refs/tags/' + tag, 'object': {'type': 'tag', 'sha': oid}}
        self.objects[oid] = {'tag': tag, 'message': json.dumps(request),
                             'object': {'type': 'commit', 'sha': object_source}}


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / 'output'
        self.output.write_text('existing=preserved\n')
        self.api = FakeGitHub()
        self.env = dict(GITHUB_ACTIONS='true', GITHUB_REPOSITORY=server.REPO,
                        GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_REF='refs/heads/main',
                        GITHUB_SHA=SOURCE, GITHUB_RUN_ID='42', GITHUB_OUTPUT=str(self.output))
        self.git_calls = []

    def run_server(self, operation='plan', **env):
        def run(args, **kwargs):
            self.git_calls.append(args)
            if args[:2] not in (['git', 'fetch'], ['git', 'merge-base']):
                raise AssertionError('Unexpected subprocess: ' + repr(args))
            return subprocess.CompletedProcess(args, 0, '', '')
        real_open = builtins.open
        def guarded_open(path, mode='r', *args, **kwargs):
            if any(flag in mode for flag in 'wax+') and Path(path) != self.output:
                raise AssertionError('Unexpected file write: ' + str(path))
            return real_open(path, mode, *args, **kwargs)
        with patch('builtins.open', side_effect=guarded_open), \
             patch.dict(os.environ, {**self.env, **env}, clear=True), \
             patch.object(sys, 'argv', ['server-release.py', operation]), \
             patch.object(server, 'GitHub', return_value=self.api), \
             patch.object(server, 'git', return_value=SOURCE), \
             patch.object(server.os, 'chdir'), patch.object(server.subprocess, 'run', side_effect=run), \
             contextlib.redirect_stdout(io.StringIO()):
            server.main()

    def assert_no_effects(self):
        self.assertEqual(self.output.read_text(), 'existing=preserved\n')
        self.assertFalse([c for c in self.api.calls if c[0] == 'POST'], self.api.calls)
        self.assertEqual(self.git_calls, [])

    def test_default_dry_run_has_no_mutations_and_preserves_output_namespace(self):
        self.run_server(GITHUB_REF='refs/heads/feature')
        lines = self.output.read_text().splitlines()
        self.assertEqual(lines[0], 'existing=preserved')
        self.assertIn('publish=false', lines)
        self.assertIn('ready=true', lines)
        self.assertFalse([c for c in self.api.calls if c[0] == 'POST'])
        self.assertEqual(self.git_calls, [])

    def test_manual_publish_main_only(self):
        with self.assertRaisesRegex(RuntimeError, 'select main'):
            self.run_server(RELEASE_MODE='publish', GITHUB_REF='refs/heads/feature')
        self.assert_no_effects()
        self.run_server(RELEASE_MODE='publish')
        self.assertIn('publish=true', self.output.read_text())
        self.assertEqual([c[:2] for c in self.git_calls], [['git', 'fetch'], ['git', 'merge-base']])
        self.assertFalse([c for c in self.api.calls if c[0] == 'POST'])

    def test_rejects_branch_push_wrong_repository_and_expected_sha(self):
        for overrides in (dict(GITHUB_EVENT_NAME='push'),
                          dict(GITHUB_REPOSITORY='someone/other'),
                          dict(EXPECTED_SOURCE=OTHER)):
            with self.subTest(overrides=overrides), self.assertRaises(RuntimeError):
                self.run_server(**overrides)
            self.assert_no_effects()
            self.assertEqual(self.api.calls, [])

    def test_polluted_tag_namespace_blocks_allocation_without_mutation(self):
        for tag in ('plus-v2.25-r99', 'plus-vmalformed'):
            with self.subTest(tag=tag):
                self.api = FakeGitHub()
                self.api.refs[tag] = {'ref': 'refs/tags/' + tag,
                                      'object': {'type': 'commit', 'sha': OTHER}}
                with self.assertRaises(RuntimeError):
                    self.run_server()
                self.assert_no_effects()
                self.assertFalse([c for c in self.api.calls if c[0] == 'POST'])

    def test_tag_push_rejects_mismatched_source_before_verify(self):
        request = self.api.reservation()
        self.api.add_reservation(request, object_source=OTHER)
        with self.assertRaisesRegex(RuntimeError, 'source does not match'):
            self.run_server(GITHUB_EVENT_NAME='push', GITHUB_REF='refs/tags/' + request['metadata']['tag'])
        self.assert_no_effects()
        self.assertEqual([c[0] for c in self.api.calls], ['GET', 'GET'])

    def test_tag_push_rejects_valid_reservation_for_other_checkout(self):
        request = self.api.reservation()
        request['metadata']['source_commit'] = OTHER
        self.api.add_reservation(request, object_source=OTHER)
        with self.assertRaisesRegex(RuntimeError, 'selected source'):
            self.run_server(GITHUB_EVENT_NAME='push', GITHUB_REF='refs/tags/' + request['metadata']['tag'])
        self.assert_no_effects()
        self.assertEqual([c[0] for c in self.api.calls], ['GET', 'GET'])

    def test_reservation_rejects_corrupt_oversized_and_different_metadata(self):
        request = self.api.reservation()
        altered = {**request['metadata'], 'source_commit': OTHER}
        cases = [dict(VOICEINK_RELEASE_RESERVATION='{'),
                 dict(VOICEINK_RELEASE_RESERVATION=' ' * 16385),
                 dict(VOICEINK_RELEASE_RESERVATION=json.dumps(request),
                      VOICEINK_RELEASE_METADATA=json.dumps(altered))]
        for env in cases:
            with self.subTest(env=list(env)), self.assertRaises((RuntimeError, ValueError)):
                self.run_server('reserve', **env)
            self.assert_no_effects()
            self.assertEqual(self.api.calls, [])

    def test_corrupt_and_oversized_tag_annotation_rejected(self):
        request = self.api.reservation()
        self.api.add_reservation(request)
        obj = next(iter(self.api.objects.values()))
        for message in ('{', 'x' * 16385):
            obj['message'] = message
            self.api.calls.clear()
            with self.subTest(size=len(message)), self.assertRaises((RuntimeError, ValueError)):
                self.run_server(GITHUB_EVENT_NAME='push', GITHUB_REF='refs/tags/' + request['metadata']['tag'])
            self.assert_no_effects()
            self.assertEqual([c[0] for c in self.api.calls], ['GET', 'GET'])

    def test_api_404_only_is_absence_and_errors_never_retry(self):
        for status in (404, 403, 500, 503):
            with self.subTest(status=status):
                result = subprocess.CompletedProcess([], 1, '', f'gh: failed (HTTP {status})')
                with patch.object(server.subprocess, 'run', return_value=result) as run:
                    if status == 404:
                        self.assertIsNone(server.GitHub().get('git/ref/tags/missing', missing=True))
                    else:
                        with self.assertRaises(RuntimeError):
                            server.GitHub().get('git/ref/tags/missing', missing=True)
                    self.assertEqual(run.call_count, 1)
        with patch.object(server.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', '(HTTP 404)')) as run:
            with self.assertRaises(RuntimeError):
                server.GitHub().post('git/refs', {'ref': 'x'})
            self.assertEqual(run.call_count, 1)

    def test_invalid_mutation_response_never_retries(self):
        result = subprocess.CompletedProcess([], 0, 'not json', '')
        with patch.object(server.subprocess, 'run', return_value=result) as run:
            with self.assertRaisesRegex(RuntimeError, 'no automatic retry'):
                server.GitHub().post('git/tags', {'tag': 'example'})
            self.assertEqual(run.call_count, 1)

    def test_dispatch_receipts_and_unknown_results_do_not_repeat(self):
        url = f'https://github.com/{server.REPO}/actions/runs/123'
        replies = [('', 0), ('not json', 0), (json.dumps({}), 0),
                   (json.dumps({'workflow_run_id': 123, 'html_url': url + '/wrong'}), 0),
                   ('', 1)]
        for response, code in replies:
            calls = []
            def run(args, **kwargs):
                calls.append((args, kwargs))
                body = json.dumps({'object': {'sha': SOURCE}}) if len(calls) == 1 else response
                return subprocess.CompletedProcess(args, 0 if len(calls) == 1 else code, body, 'failed')
            with self.subTest(response=response, code=code), \
                 patch.object(cli.subprocess, 'check_output', return_value='git@github.com:legrch/VoiceInk.git\n') as git, \
                 patch.object(cli.subprocess, 'run', side_effect=run), \
                 patch.object(sys, 'argv', ['release-tag.py']), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises((RuntimeError, ValueError)):
                    cli.main()
            git.assert_called_once()
            self.assertEqual(len(calls), 2)
            self.assertIn('git/ref/heads/main', calls[0][0][2])
            self.assertIn('actions/workflows/release.yml/dispatches', calls[1][0][2])
            self.assertEqual(json.loads(calls[1][1]['input']),
                             {'ref': 'main', 'inputs': {'mode': 'publish', 'expected_source': SOURCE}})


if __name__ == '__main__':
    unittest.main()
