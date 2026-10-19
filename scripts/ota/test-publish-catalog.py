#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""No-network publication tests. Never invokes gh or reads production keys."""
import importlib.util
import io
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

if __name__ == '__main__':
    unittest.main()
