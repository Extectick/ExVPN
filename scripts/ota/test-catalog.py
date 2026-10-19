#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline catalog behavior checks; synthetic keys stay in .private fixtures."""

import base64
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

spec = importlib.util.spec_from_file_location("ota_catalog", Path(__file__).with_name("catalog.py"))
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


class CatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rsa = rsa.generate_private_key(public_exponent=65537, key_size=4096)

    def setUp(self):
        private_root = catalog.ROOT / ".private"
        private_root.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="ota-catalog-fixtures-", dir=private_root)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.key = Ed25519PrivateKey.generate()
        self.public = base64.b64encode(self.key.public_key().public_bytes_raw()).decode("ascii")
        for name, value in (("ROOT", self.root), ("PUBLIC_KEY", self.public)):
            context = patch.object(catalog, name, value)
            context.start()
            self.addCleanup(context.stop)
        self.now = datetime.now(timezone.utc).replace(microsecond=0)
        self.seed = self.write(".private/synthetic.seed", self.key.private_bytes_raw())
        public = self.rsa.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
        self.write("config/signing/shorebird-beta-public.pem", public)
        self.public_sha = hashlib.sha256(public).hexdigest()
        self.base_paths = []
        self.base_records = {}
        for target in ("Windows", "Android"):
            aot = {}
            for key, (_, arch) in catalog.TARGETS[target].items():
                raw = self.elf(arch)
                relative = key + "/app.so"
                self.write("base-" + target + "/" + relative, raw)
                aot[key] = {"path": relative, "sha256": hashlib.sha256(raw).hexdigest(), "size": len(raw)}
            receipt = {"schemaVersion": 1, "delivery": "independent", "published": False,
                       "version": "0.1.10+31", "target": target, "sourceCommit": "a" * 40,
                       "flutterRevision": catalog.FLUTTER, "engineRevision": catalog.ENGINE,
                       "appRoot": "apps/exvpn", "dartEntrypoint": "lib/main.dart",
                       "protectedInputsSha256": "b" * 64, "baseAot": aot,
                       "signingPublicKey": {"path": "config/signing/shorebird-beta-public.pem", "sha256": self.public_sha},
                       "sourceUpdaterPolicyUnchanged": True, "autoUpdate": False,
                       "patchVerification": "strict", "packagedUpdaterEndpoint": "http://127.0.0.1:57791"}
            path = self.write_json("base-" + target + "/base-receipt.json", receipt)
            self.base_paths.append(path)
            self.base_records[target] = (path, receipt)

    def write(self, name, raw):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        return path

    def write_json(self, name, value):
        return self.write(name, json.dumps(value, indent=2).encode("utf-8"))

    @staticmethod
    def elf(arch, revision=0):
        raw = bytearray(4096)
        raw[:6] = b"\x7fELF\x02\x01"
        raw[18:20] = {"x86_64": 62, "aarch64": 183}[arch].to_bytes(2, "little")
        raw[100] = revision
        return bytes(raw)

    def patch_receipt(self, target, number=1, revision=1):
        base_path, base = self.base_records[target]
        artifacts = []
        directory = f"patch-{target}-{number}-{revision}"
        for key, (_, arch) in catalog.TARGETS[target].items():
            aot = self.elf(arch, revision)
            aot_sha = hashlib.sha256(aot).hexdigest()
            diff = b"synthetic bounded patch " + target.encode() + key.encode() + bytes([revision])
            self.write(directory + "/" + key + "/diff.patch", diff)
            self.write(directory + "/" + key + "/app.so", aot)
            signature = self.rsa.sign(aot_sha.encode("ascii"), padding.PKCS1v15(), hashes.SHA256())
            artifacts.append({"arch": arch, "key": key, "baseSha256": base["baseAot"][key]["sha256"],
                              "aotSha256": aot_sha, "aotSize": len(aot),
                              "hashSignature": base64.b64encode(signature).decode("ascii"),
                              "diffPath": key + "/diff.patch", "diffSha256": hashlib.sha256(diff).hexdigest(),
                              "diffSize": len(diff), "aotPath": key + "/app.so"})
        receipt = {"schemaVersion": 1, "version": base["version"], "baseSourceCommit": base["sourceCommit"],
                   "sourceCommit": "c" * 40, "target": target, "patchNumber": number,
                   "flutterRevision": catalog.FLUTTER, "engineRevision": catalog.ENGINE,
                   "protectedInputsSha256": base["protectedInputsSha256"],
                   "baseReceiptSha256": hashlib.sha256(base_path.read_bytes()).hexdigest(),
                   "signingPublicKeySha256": self.public_sha, "artifacts": artifacts,
                   "cloudCalls": False, "nativeBuild": False}
        return self.write_json(directory + "/patch-receipt.json", receipt)

    def make(self, patches=(), revision=1, **kwargs):
        return catalog.assemble(self.base_paths, list(patches), revision, self.seed,
                                asset_tag="ota-0.1.10-31-p1", now=self.now, **kwargs)

    def resign(self, raw, change):
        body = catalog.verify(raw, self.now, allow_expired=True)
        change(body)
        payload = catalog.canonical(body)
        return catalog.canonical({"schema": 1, "keyId": catalog.KEY_ID,
                                  "payload": base64.b64encode(payload).decode("ascii"),
                                  "signature": base64.b64encode(self.key.sign(catalog.DOMAIN + payload)).decode("ascii")})

    def test_fresh_base_without_patch_is_valid_and_has_no_source_metadata(self):
        raw = self.make()
        body = catalog.verify(raw, self.now)
        self.assertEqual(len(body["bases"]), 1)
        self.assertEqual(body["bases"][0]["patches"], [])
        self.assertEqual(body["bases"][0]["revoked"], [])
        self.assertNotIn("sourceCommit", body["bases"][0])
        self.assertEqual(raw, catalog.canonical(json.loads(raw)))

    def test_both_platforms_bind_rsa_and_exact_patch_bytes(self):
        raw = self.make([self.patch_receipt("Windows"), self.patch_receipt("Android")])
        body = catalog.verify(raw, self.now)
        patches = body["bases"][0]["patches"]
        self.assertEqual(len(patches), 3)
        self.assertEqual({p["number"] for p in patches}, {1})
        self.assertTrue(all("/ota-0.1.10-31-p1/ExVPN-0.1.10-31-" in p["url"] for p in patches))
        self.assertTrue(all(p["url"].endswith("-p1.patch") for p in patches))

    def test_cumulative_withdrawal_removes_all_architectures_and_forbids_reuse(self):
        receipts = [self.patch_receipt("Windows"), self.patch_receipt("Android")]
        original = self.make(receipts)
        withdrawn = self.make(revision=2, previous=original, withdrawals=[1])
        body = catalog.verify(withdrawn, self.now)
        self.assertEqual(body["bases"][0]["patches"], [])
        self.assertEqual(body["bases"][0]["revoked"], [1])
        renewed = self.make(revision=3, previous=withdrawn)
        self.assertEqual(catalog.verify(renewed, self.now)["bases"][0]["revoked"], [1])
        with self.assertRaisesRegex(ValueError, "patch_revoked"):
            self.make(receipts, revision=3, previous=withdrawn)

    def test_revision_and_patch_number_are_monotonic(self):
        old = self.make([self.patch_receipt("Windows", 3)])
        with self.assertRaisesRegex(ValueError, "catalog_replayed"):
            self.make(revision=1, previous=old)
        with self.assertRaisesRegex(ValueError, "patch_replayed"):
            self.make([self.patch_receipt("Android", 2)], revision=2, previous=old)
        updated = self.make([self.patch_receipt("Windows", 4)], revision=2, previous=old)
        self.assertEqual(catalog.verify(updated, self.now)["bases"][0]["patches"][0]["number"], 4)

    def test_active_patch_number_never_acquires_new_bytes_or_url(self):
        old = self.make([self.patch_receipt("Windows", 1, 1)])
        with self.assertRaisesRegex(ValueError, "patch_replayed"):
            self.make([self.patch_receipt("Windows", 1, 2)], revision=2, previous=old)
        same = self.make([self.patch_receipt("Windows", 1, 1)], revision=2, previous=old)
        self.assertEqual(catalog.verify(same, self.now)["bases"][0]["patches"],
                         catalog.verify(old, self.now)["bases"][0]["patches"])

    def test_new_base_preserves_all_old_bases_and_revocation_history(self):
        old = self.make(revision=1, withdrawals=[7])
        for target, (path, receipt) in self.base_records.items():
            receipt["version"] = "0.1.11+32"
            self.write_json(str(path.relative_to(self.root)), receipt)
        updated = self.make(revision=2, previous=old)
        body = catalog.verify(updated, self.now)
        self.assertEqual([b["version"] for b in body["bases"]], ["0.1.10+31", "0.1.11+32"])
        self.assertEqual(body["bases"][0]["revoked"], [7])
        changed = json.loads(json.dumps(body))
        changed["bases"].pop(0)
        with self.assertRaisesRegex(ValueError, "base_history_missing"):
            catalog.successor(changed, catalog.verify(old, self.now))

    def test_lifetime_bounds_and_expired_previous_can_be_renewed(self):
        for days in (0, 31, True):
            with self.assertRaises(ValueError):
                self.make(valid_days=days)
        raw = self.make(valid_days=1)
        expired_now = self.now + timedelta(days=2)
        with self.assertRaisesRegex(ValueError, "catalog_expired"):
            catalog.verify(raw, expired_now)
        renewed = catalog.assemble(self.base_paths, [], 2, self.seed, previous=raw, now=expired_now)
        catalog.verify(renewed, expired_now)
        future = self.resign(raw, lambda b: b.update(publishedAt=catalog.date_text(self.now + timedelta(minutes=3))))
        with self.assertRaises(ValueError):
            catalog.verify(future, self.now)

    def test_signature_domain_and_exact_canonical_bytes_are_required(self):
        raw = self.make()
        envelope = json.loads(raw)
        envelope["signature"] = base64.b64encode(self.key.sign(b"wrong-domain" + base64.b64decode(envelope["payload"]))).decode()
        with self.assertRaisesRegex(ValueError, "signature_invalid"):
            catalog.verify(catalog.canonical(envelope), self.now)
        for invalid in (json.dumps(json.loads(raw), indent=2).encode(), raw.replace(b'"schema":1', b'"schema":1,"schema":1', 1), b"\xef\xbb\xbf" + raw):
            with self.assertRaises(ValueError):
                catalog.verify(invalid, self.now)

    def test_wrong_ed25519_key_is_refused_without_output(self):
        self.seed.write_bytes(Ed25519PrivateKey.generate().private_bytes_raw())
        with self.assertRaisesRegex(ValueError, "signing_key_mismatch"):
            self.make()

    def test_changed_base_receipt_bytes_or_mismatched_compatibility_rejected(self):
        patch_path = self.patch_receipt("Windows")
        path, receipt = self.base_records["Windows"]
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "patch_receipt_invalid"):
            self.make([patch_path])
        receipt["protectedInputsSha256"] = "d" * 64
        self.write_json(str(path.relative_to(self.root)), receipt)
        with self.assertRaisesRegex(ValueError, "base_receipt_mismatch"):
            self.make()

    def test_changed_patch_or_rsa_signature_rejected(self):
        path = self.patch_receipt("Windows")
        receipt = json.loads(path.read_bytes())
        diff = path.parent / receipt["artifacts"][0]["diffPath"]
        diff.write_bytes(diff.read_bytes()[:-1] + b"x")
        with self.assertRaisesRegex(ValueError, "receipt_artifact_invalid"):
            self.make([path])
        path = self.patch_receipt("Windows")
        receipt["artifacts"][0]["hashSignature"] = base64.b64encode(bytes(512)).decode()
        self.write_json(str(path.relative_to(self.root)), receipt)
        with self.assertRaisesRegex(ValueError, "rsa_signature_invalid"):
            self.make([path])

    def test_diff_bound_and_architecture_binding_rejected(self):
        path = self.patch_receipt("Windows")
        receipt = json.loads(path.read_bytes())
        receipt["artifacts"][0]["diffSize"] = catalog.MAX_DIFF + 1
        self.write_json(str(path.relative_to(self.root)), receipt)
        with self.assertRaises(ValueError):
            self.make([path])
        path = self.patch_receipt("Windows")
        receipt = json.loads(path.read_bytes())
        receipt["artifacts"][0]["arch"] = "aarch64"
        self.write_json(str(path.relative_to(self.root)), receipt)
        with self.assertRaisesRegex(ValueError, "patch_receipt_invalid"):
            self.make([path])

    def test_mutable_asset_tag_and_foreign_urls_rejected(self):
        bases = catalog.load_base(self.base_paths)
        for tag in (None, "ota-beta", "ota-stable", "../other", "https://evil.invalid", ".", ".."):
            with self.assertRaisesRegex(ValueError, "immutable_asset_tag_required"):
                catalog.receipt_patches([self.patch_receipt("Windows")], bases, tag)
        for url in ("https://evil.invalid/p.patch", "https://github.com/Other/ExVPN/releases/download/v1/p.patch",
                    "https://github.com/Extectick/ExVPN/releases/download/v1/p.patch?secret=1",
                    "https://github.com/Extectick/ExVPN/releases/download/v1/p.exe"):
            self.assertFalse(catalog.patch_url(url))

    def test_catalog_bounds_numbers_duplicate_targets_and_withdrawal_rollback(self):
        original = self.make([self.patch_receipt("Windows")], withdrawals=[7])
        changes = [lambda b: b.update(revision=True),
                   lambda b: b["bases"][0].update(revoked=[1, 1]),
                   lambda b: b["bases"][0].update(revoked=[0]),
                   lambda b: b["bases"][0].update(patches=b["bases"][0]["patches"] * 2),
                   lambda b: b.update(bases=b["bases"] * 17)]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(ValueError):
                catalog.verify(self.resign(original, change), self.now)
        previous = catalog.verify(original, self.now)
        next_body = json.loads(json.dumps(previous))
        next_body["revision"] += 1
        next_body["bases"][0]["revoked"] = []
        with self.assertRaisesRegex(ValueError, "withdrawal_replayed"):
            catalog.successor(next_body, previous)
        for n in (0, -1, True, catalog.MAX_NUMBER + 1):
            with self.assertRaises(ValueError):
                self.make(withdrawals=[n])

    def test_receipt_path_traversal_and_hardlinks_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "receipt_path_invalid"):
            catalog.relative_file(self.root, "../other")
        alias = self.root / "seed-hardlink"
        os.link(self.seed, alias)
        try:
            with self.assertRaisesRegex(ValueError, "catalog_path_link"):
                self.make()
        finally:
            alias.unlink()
        external = self.write("outside.seed", self.key.private_bytes_raw())
        with self.assertRaisesRegex(ValueError, "private_key_location_invalid"):
            catalog.assemble(self.base_paths, [], 1, external, now=self.now)

    def test_cli_sign_verify_metadata_and_atomic_no_overwrite(self):
        output = self.root / "catalog.json"
        args = ["--revision", "1", "--output", str(output), "--key-file", str(self.seed)]
        for base in self.base_paths:
            args += ["--base-receipt", str(base)]
        with redirect_stdout(io.StringIO()) as stdout:
            catalog.main(args)
        metadata = json.loads(stdout.getvalue())
        self.assertTrue(metadata["verified"])
        self.assertFalse(metadata["cloudCalls"])
        self.assertNotIn("payload", metadata)
        with redirect_stdout(io.StringIO()) as stdout:
            catalog.main(["--verify", str(output)])
        self.assertEqual(json.loads(stdout.getvalue())["revision"], 1)
        before = output.read_bytes()
        with self.assertRaisesRegex(ValueError, "catalog_output_exists"):
            catalog.main(args)
        self.assertEqual(output.read_bytes(), before)
        with self.assertRaisesRegex(ValueError, "verify_arguments_invalid"):
            catalog.main(["--verify", str(output), "--output", str(output)])


if __name__ == "__main__":
    unittest.main()
