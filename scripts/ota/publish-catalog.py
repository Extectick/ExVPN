#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Publish verified immutable diffs, then the signed ExVPN beta catalog."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import catalog

REPO = 'Extectick/ExVPN'
POINTER = 'ota-beta'
ASSET = 'dart-updates.json'


def gh(*args, json_result=False):
    result = subprocess.run(['gh', *args], capture_output=True, timeout=300)
    if result.returncode:
        catalog.bad('github_operation_failed')
    return json.loads(result.stdout) if json_result else result.stdout.decode('utf-8').strip()


def release(tag, releases):
    matches = [r for r in releases if r['tag_name'] == tag]
    if len(matches) > 1:
        catalog.bad('github_release_ambiguous')
    return matches[0] if matches else None


def digest_asset(remote, name, expected_hash, expected_size):
    matches = [a for a in remote['assets'] if a['name'] == name]
    if len(matches) != 1 or matches[0]['digest'] != 'sha256:' + expected_hash or matches[0]['size'] != expected_size:
        catalog.bad('github_asset_mismatch')


def tag_commit(tag):
    refs = gh('api', f'repos/{REPO}/git/matching-refs/tags/{tag}', json_result=True)
    exact = [r for r in refs if r['ref'] == 'refs/tags/' + tag]
    if not exact:
        return None
    if len(exact) != 1:
        catalog.bad('immutable_tag_ambiguous')
    obj = exact[0]['object']
    for _ in range(5):
        if not catalog.matches(catalog.COMMIT, obj.get('sha')):
            catalog.bad('immutable_tag_invalid')
        if obj['type'] == 'commit':
            return obj['sha']
        if obj['type'] != 'tag':
            catalog.bad('immutable_tag_invalid')
        obj = gh('api', f"repos/{REPO}/git/tags/{obj['sha']}", json_result=True)['object']
    catalog.bad('immutable_tag_invalid')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, required=True)
    parser.add_argument('--base-receipt', type=Path, required=True, action='append')
    parser.add_argument('--patch-receipt', type=Path, action='append', default=[])
    parser.add_argument('--asset-tag')
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    if catalog.cryptography.__version__ != '46.0.5':
        catalog.bad('signing_dependency_version_mismatch')
    raw = catalog.read_bounded(args.catalog, catalog.MAX_CATALOG)
    body = catalog.verify(raw)
    if body['channel'] != 'beta':
        catalog.bad('catalog_channel_mismatch')
    bases = catalog.load_base(args.base_receipt)
    first = bases[0][0]
    matching = [b for b in body['bases'] if b['version'] == first['version'] and b['compatibilitySha256'] == first['protectedInputsSha256']]
    if len(matching) != 1:
        catalog.bad('base_receipt_mismatch')
    patches = catalog.receipt_patches(args.patch_receipt, bases, args.asset_tag) if args.patch_receipt else []
    for p in patches:
        if p not in matching[0]['patches']:
            catalog.bad('catalog_patch_binding_mismatch')
    # Build an upload map only from RSA-verified receipt outputs, never arbitrary
    # filenames or unsigned catalog input. Existing versions stay immutable.
    upload = {}
    patch_commits = set()
    for path in args.patch_receipt:
        receipt = catalog.decode_json(catalog.read_bounded(path, 16 * 1024 * 1024), 16 * 1024 * 1024, compact=False)
        patch_commits.add(receipt['sourceCommit'])
        for artifact in receipt['artifacts']:
            platform = receipt['target'].lower()
            name = f"ExVPN-{first['version'].replace('+', '-')}-{platform}-{artifact['arch']}-p{receipt['patchNumber']}.patch"
            source = catalog.relative_file(path.resolve().parent, artifact['diffPath'])
            if name in upload:
                catalog.bad('duplicate_patch_artifact')
            upload[name] = (source, artifact['diffSha256'], artifact['diffSize'])
    if len(patch_commits) > 1:
        catalog.bad('patch_sources_differ')
    releases = gh('api', f'repos/{REPO}/releases?per_page=100', json_result=True)
    pointer = release(POINTER, releases)
    previous_hash = None
    if pointer:
        if pointer['draft'] or not pointer['prerelease']:
            catalog.bad('catalog_pointer_release_invalid')
        candidates = [a for a in pointer['assets'] if a['name'] == ASSET]
        if len(candidates) != 1:
            catalog.bad('catalog_pointer_asset_missing')
        with tempfile.TemporaryDirectory(prefix='exvpn-catalog-read-') as temp:
            gh('release', 'download', POINTER, '--repo', REPO, '--pattern', ASSET, '--dir', temp)
            previous = catalog.read_bounded(Path(temp) / ASSET, catalog.MAX_CATALOG)
        previous_hash = hashlib.sha256(previous).hexdigest()
        digest_asset(pointer, ASSET, previous_hash, len(previous))
        if previous != raw:
            catalog.successor(body, catalog.verify(previous, allow_expired=True))
    summary = catalog.summary(body) | {'published': False, 'immutablePatchFiles': len(upload)}
    if not args.publish:
        print(json.dumps(summary, separators=(',', ':')))
        return
    with tempfile.TemporaryDirectory(prefix='exvpn-catalog-publish-') as temp:
        staging = Path(temp)
        if upload:
            remote = release(args.asset_tag, releases)
            source_commit = next(iter(patch_commits))
            existing_commit = tag_commit(args.asset_tag)
            if existing_commit is not None and existing_commit != source_commit:
                catalog.bad('immutable_tag_source_mismatch')
            if existing_commit is None:
                # A draft release does not create a Git ref. Pin the source
                # before uploading; never ask GitHub to resolve a moving branch.
                gh('api', '--method', 'POST', f'repos/{REPO}/git/refs',
                   '-f', 'ref=refs/tags/' + args.asset_tag, '-f', 'sha=' + source_commit)
            if remote:
                if remote['target_commitish'] != source_commit or not remote['prerelease']:
                    catalog.bad('immutable_patch_release_invalid')
            else:
                gh('release', 'create', args.asset_tag, '--repo', REPO, '--target', source_commit,
                   '--title', f"ExVPN UI {first['version']}", '--notes', 'Signed ExVPN AOT patches. Native base unchanged.',
                   '--draft', '--prerelease', '--latest=false')
                release_id = gh('release', 'view', args.asset_tag, '--repo', REPO,
                                '--json', 'databaseId', '--jq', '.databaseId')
                if not release_id.isdecimal():
                    catalog.bad('github_release_identity_invalid')
                remote = gh('api', f'repos/{REPO}/releases/{release_id}', json_result=True)
            if tag_commit(args.asset_tag) != source_commit:
                catalog.bad('immutable_tag_source_mismatch')
            expected_names = set(upload)
            if any(a['name'] not in expected_names for a in remote['assets']):
                catalog.bad('immutable_patch_asset_set_mismatch')
            existing = {a['name'] for a in remote['assets']}
            for name, (source, digest, size) in upload.items():
                if name in existing:
                    digest_asset(remote, name, digest, size)
                else:
                    if not remote['draft']:
                        catalog.bad('immutable_patch_release_incomplete')
                    target = staging / name
                    target.write_bytes(source.read_bytes())
                    gh('release', 'upload', args.asset_tag, str(target), '--repo', REPO)
            remote = gh('api', f"repos/{REPO}/releases/{remote['id']}", json_result=True)
            for name, (_, digest, size) in upload.items():
                digest_asset(remote, name, digest, size)
            if remote['draft']:
                gh('release', 'edit', args.asset_tag, '--repo', REPO, '--draft=false', '--prerelease', '--latest=false')
        # Verify every advertised URL against immutable GitHub asset metadata
        # before replacing the small signed pointer. No --clobber on code assets.
        inspected = {}
        for base in body['bases']:
            for patch in base['patches']:
                tag, name = patch['url'].split('/')[-2:]
                if tag not in inspected:
                    inspected[tag] = gh('api', f'repos/{REPO}/releases/tags/{tag}', json_result=True)
                if inspected[tag]['draft']:
                    catalog.bad('patch_release_not_public')
                digest_asset(inspected[tag], name, patch['sha256'], patch['sizeBytes'])
        if pointer:
            # Optimistic concurrency: refuse an intervening publisher. Workflow
            # concurrency additionally serializes trusted writers.
            current = gh('api', f"repos/{REPO}/releases/{pointer['id']}", json_result=True)
            digest_asset(current, ASSET, previous_hash, next(a['size'] for a in pointer['assets'] if a['name'] == ASSET))
        else:
            gh('release', 'create', POINTER, '--repo', REPO, '--target', first['sourceCommit'],
               '--title', 'ExVPN signed Dart beta catalog', '--notes', 'Signed ExVPN update metadata.',
               '--prerelease', '--latest=false')
        target = staging / ASSET
        target.write_bytes(raw)
        gh('release', 'upload', POINTER, str(target), '--repo', REPO, '--clobber')
        remote = gh('api', f'repos/{REPO}/releases/tags/{POINTER}', json_result=True)
        digest_asset(remote, ASSET, hashlib.sha256(raw).hexdigest(), len(raw))
        download = staging / 'readback'
        download.mkdir()
        gh('release', 'download', POINTER, '--repo', REPO, '--pattern', ASSET, '--dir', str(download))
        if catalog.read_bounded(download / ASSET, catalog.MAX_CATALOG) != raw:
            catalog.bad('catalog_public_readback_mismatch')
        summary['published'] = True
        print(json.dumps(summary, separators=(',', ':')))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        code = str(error)
        if not catalog.re.fullmatch(r'[a-z][a-z0-9_]{1,80}', code):
            code = 'catalog_publication_failed'
        print(json.dumps({'error': code}, separators=(',', ':')), file=sys.stderr)
        raise SystemExit(1)
