#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""No-network publication tests. Never invokes gh or reads production keys."""
import importlib.util
import io
import hashlib
import json
from pathlib import Path
import sys
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

fixtures = load('catalog_fixtures', 'test-catalog.py')
sys.modules['catalog'] = fixtures.catalog
publisher = load('catalog_publisher', 'publish-catalog.py')

class PublisherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixtures.CatalogTests.setUpClass()

    def setUp(self):
        self.fixture = fixtures.CatalogTests('runTest')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def command(self, catalog_path, extra=()):
        args = ['publish-catalog.py', '--catalog', str(catalog_path)]
        for base in self.fixture.base_paths:
            args += ['--base-receipt', str(base)]
        return args + list(extra)

    def test_dry_run_has_no_mutation(self):
        f = self.fixture
        raw = fixtures.catalog.assemble(f.base_paths, [], 1, f.seed, now=f.now)
        path = f.write('catalog.json', raw)
        calls = []
        def gh(*args, **kwargs):
            calls.append(args)
            if args[0] != 'api' or 'releases?per_page=100' not in args[1]:
                self.fail('dry run attempted mutation')
            return []
        with patch.object(sys, 'argv', self.command(path)), patch.object(publisher, 'gh', gh), redirect_stdout(io.StringIO()) as output:
            publisher.main()
        self.assertEqual(len(calls), 1)
        self.assertFalse(json.loads(output.getvalue())['published'])

    def test_tampered_signed_feed_never_calls_github(self):
        f = self.fixture
        raw = fixtures.catalog.assemble(f.base_paths, [], 1, f.seed, now=f.now)
        value = json.loads(raw)
        value['signature'] = fixtures.base64.b64encode(bytes(64)).decode()
        path = f.write('catalog.json', fixtures.catalog.canonical(value))
        with patch.object(sys, 'argv', self.command(path)), patch.object(publisher, 'gh', side_effect=AssertionError('network forbidden')):
            with self.assertRaisesRegex(ValueError, 'signature_invalid'):
                publisher.main()

    def test_corrupt_diff_rejected_before_upload(self):
        f = self.fixture
        receipt = f.patch_receipt('Windows')
        raw = fixtures.catalog.assemble(f.base_paths, [receipt], 2, f.seed, now=f.now, asset_tag='ota-fixture-p1')
        path = f.write('catalog.json', raw)
        value = json.loads(receipt.read_bytes())
        (receipt.parent / value['artifacts'][0]['diffPath']).write_bytes(b'broken')
        args = ['--patch-receipt', str(receipt), '--asset-tag', 'ota-fixture-p1', '--publish']
        with patch.object(sys, 'argv', self.command(path, args)), patch.object(publisher, 'gh', side_effect=AssertionError('network forbidden')):
            with self.assertRaisesRegex(ValueError, 'receipt_artifact_invalid'):
                publisher.main()

    def publish_draft_fixture(self, resume=False, wrong_tag=False):
        f = self.fixture
        receipt = f.patch_receipt('Windows')
        tag = 'ota-fixture-p1'
        raw = fixtures.catalog.assemble(f.base_paths, [receipt], 2, f.seed, now=f.now, asset_tag=tag)
        path = f.write('catalog.json', raw)
        remote = {'id': 91, 'tag_name': tag, 'target_commitish': 'c' * 40,
                  'draft': True, 'prerelease': True, 'assets': []} if resume else None
        pointer = None
        reference = 'd' * 40 if wrong_tag else None
        pointer_bytes = None
        calls = []

        def snapshot(value):
            return json.loads(json.dumps(value))

        def gh(*args, **kwargs):
            nonlocal remote, pointer, reference, pointer_bytes
            calls.append(args)
            if args[0] == 'api':
                if len(args) > 2 and args[1:3] == ('--method', 'POST'):
                    self.assertEqual(args[3], 'repos/Extectick/ExVPN/git/refs')
                    self.assertIsNone(reference)
                    self.assertIn('ref=refs/tags/' + tag, args)
                    self.assertIn('sha=' + 'c' * 40, args)
                    reference = 'c' * 40
                    return ''
                endpoint = args[1]
                if endpoint.endswith('/releases?per_page=100'):
                    return [snapshot(remote)] if remote else []
                if '/git/matching-refs/tags/' in endpoint:
                    return [{'ref': 'refs/tags/' + tag, 'object': {'type': 'commit', 'sha': reference}}] if reference else []
                if endpoint.endswith('/releases/91'):
                    self.assertIsNotNone(remote)
                    return snapshot(remote)
                if endpoint.endswith('/releases/tags/' + tag):
                    # GitHub's tags endpoint does not return an unpublished
                    # draft. It must only be used after the explicit publish.
                    self.assertIsNotNone(remote)
                    self.assertFalse(remote['draft'], 'draft fetched via tags endpoint')
                    return snapshot(remote)
                if endpoint.endswith('/releases/tags/ota-beta'):
                    self.assertIsNotNone(pointer)
                    return snapshot(pointer)
            if args[:2] == ('release', 'create'):
                if args[2] == tag:
                    self.assertEqual(reference, 'c' * 40, 'immutable tag must exist before draft')
                    self.assertIsNone(remote)
                    self.assertIn('--draft', args)
                    remote = {'id': 91, 'tag_name': tag, 'target_commitish': 'c' * 40,
                              'draft': True, 'prerelease': True, 'assets': []}
                else:
                    self.assertEqual(args[2], 'ota-beta')
                    self.assertFalse(remote['draft'])
                    pointer = {'id': 92, 'tag_name': 'ota-beta', 'target_commitish': 'a' * 40,
                               'draft': False, 'prerelease': True, 'assets': []}
                return ''
            if args[:2] == ('release', 'view'):
                self.assertEqual(args[2], tag)
                return '91'
            if args[:2] == ('release', 'upload'):
                uploaded = Path(args[3])
                content = uploaded.read_bytes()
                item = {'name': uploaded.name, 'digest': 'sha256:' + hashlib.sha256(content).hexdigest(), 'size': len(content)}
                if args[2] == tag:
                    self.assertEqual(reference, 'c' * 40)
                    self.assertTrue(remote['draft'])
                    self.assertNotIn('--clobber', args)
                    remote['assets'].append(item)
                else:
                    self.assertEqual(args[2], 'ota-beta')
                    self.assertFalse(remote['draft'])
                    self.assertIn('--clobber', args)
                    pointer['assets'] = [item]
                    pointer_bytes = content
                return ''
            if args[:2] == ('release', 'edit'):
                self.assertEqual(args[2], tag)
                self.assertIn('--draft=false', args)
                self.assertEqual(len(remote['assets']), 1)
                remote['draft'] = False
                return ''
            if args[:2] == ('release', 'download'):
                self.assertEqual(args[2], 'ota-beta')
                self.assertIsNotNone(pointer_bytes)
                (Path(args[args.index('--dir') + 1]) / 'dart-updates.json').write_bytes(pointer_bytes)
                return ''
            self.fail('unexpected fake GitHub operation: ' + repr(args))

        argv = self.command(path, ['--patch-receipt', str(receipt), '--asset-tag', tag, '--publish'])
        with patch.object(sys, 'argv', argv), patch.object(publisher, 'gh', gh), redirect_stdout(io.StringIO()) as output:
            if wrong_tag:
                with self.assertRaisesRegex(ValueError, 'immutable_tag_source_mismatch'):
                    publisher.main()
                self.assertTrue(all(args[0] == 'api' and '--method' not in args for args in calls))
                return
            publisher.main()
        self.assertTrue(json.loads(output.getvalue())['published'])
        self.assertEqual(pointer_bytes, raw)
        self.assertFalse(remote['draft'])
        self.assertEqual(reference, 'c' * 40)
        self.assertEqual(sum(any(arg.endswith('/releases/91') for arg in args) for args in calls), 1 if resume else 2)

    def test_new_draft_is_read_by_database_id_after_explicit_tag(self):
        self.publish_draft_fixture()

    def test_existing_empty_draft_resumes_without_tags_endpoint(self):
        self.publish_draft_fixture(resume=True)

    def test_existing_immutable_tag_mismatch_never_mutates(self):
        self.publish_draft_fixture(resume=True, wrong_tag=True)

if __name__ == '__main__':
    unittest.main()
