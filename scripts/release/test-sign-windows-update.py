#!/usr/bin/env python3
"""Offline signing regression checks; only synthetic files and ephemeral keys."""
import base64
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.exceptions import InvalidSignature

spec = importlib.util.spec_from_file_location(
    "signer", Path(__file__).with_name("sign-windows-update.py"))
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.seed = self.root / ".private" / "test.seed"
        self.seed.parent.mkdir()
        key = Ed25519PrivateKey.generate()
        self.key = key
        self.seed.write_bytes(key.private_bytes_raw())
        config = self.root / "config" / "updates" / "windows-beta.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({
            "keyId": "synthetic-key", "channel": "beta",
            "publicKey": base64.b64encode(key.public_key().public_bytes(
                serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode(),
        }), encoding="utf-8")
        self.binary = self.root / "ExVPN-0.1.2-23-windows-x64-development.exe"
        self.binary.write_bytes(b"synthetic fixture, never executable")
        self.metadata = {"file": self.binary.name, "version": "0.1.2", "build": 23,
                         "sha256": signer.hashlib.sha256(self.binary.read_bytes()).hexdigest()}
        self.write_metadata()

    def write_metadata(self):
        (self.root / "artifact.json").write_text(json.dumps(self.metadata), encoding="utf-8")

    def sign(self, name, previous=None, resume=False, url=None):
        output = self.root / name
        args = ["sign", "--artifact", str(self.binary), "--url",
                url or "https://github.com/Extectick/ExVPN/releases/download/v0.1.2/" + self.binary.name,
                "--seed-file", str(self.seed), "--output", str(output)]
        if previous:
            args += ["--previous", str(previous)]
        if resume:
            args += ["--resume-identical"]
        with patch.object(signer, "ROOT", self.root), patch.object(sys, "argv", args), redirect_stdout(io.StringIO()):
            signer.main()
        return output

    def rewrite_signed(self, previous, change):
        envelope = json.loads(previous.read_text(encoding="utf-8"))
        payload = json.loads(base64.b64decode(envelope["payload"]))
        change(payload)
        raw = json.dumps(payload, separators=(",", ":")).encode()
        envelope["payload"] = base64.b64encode(raw).decode()
        envelope["signature"] = base64.b64encode(self.key.sign(signer.DOMAIN + raw)).decode()
        previous.write_text(json.dumps(envelope), encoding="utf-8")

    def test_signature_binds_exact_asset_and_next_revision(self):
        previous = self.sign("first.json")
        self.metadata["build"] = 24
        self.write_metadata()
        new = json.loads(self.sign("next.json", previous).read_text(encoding="utf-8"))
        payload = base64.b64decode(new["payload"])
        self.key.public_key().verify(base64.b64decode(new["signature"]), signer.DOMAIN + payload)
        self.assertEqual(json.loads(payload)["build"], 24)
        self.assertEqual(json.loads(payload)["asset"]["sha256"], self.metadata["sha256"])

    def test_replay_downgrade_and_wrong_previous_signature_refused(self):
        previous = self.sign("first.json")
        with self.assertRaises(ValueError):
            self.sign("replay.json", previous)
        self.metadata.update(version="0.1.1", build=24)
        self.write_metadata()
        with self.assertRaises(ValueError):
            self.sign("downgrade.json", previous)
        self.metadata.update(version="0.1.2")
        self.write_metadata()
        old = json.loads(previous.read_text(encoding="utf-8"))
        old["signature"] = base64.b64encode(bytes(64)).decode()
        previous.write_text(json.dumps(old), encoding="utf-8")
        with self.assertRaises(InvalidSignature):
            self.sign("wrong-key.json", previous)
        self.assertFalse((self.root / "replay.json").exists())

    def test_changed_bytes_refused_before_output(self):
        self.binary.write_bytes(b"different bytes")
        with self.assertRaises(ValueError):
            self.sign("bad.json")
        self.assertFalse((self.root / "bad.json").exists())

    def test_explicit_resume_copies_exact_bytes_without_renewal(self):
        previous = self.sign("first.json")
        before = previous.read_bytes()
        resumed = self.sign("resumed.json", previous, resume=True)
        self.assertEqual(before, resumed.read_bytes())
        with self.assertRaises(ValueError):
            self.sign("strict-replay.json", previous)
        with self.assertRaises(FileExistsError):
            self.sign("resumed.json", previous, resume=True)
        with self.assertRaises(ValueError):
            self.sign("no-previous.json", resume=True)

    def test_resume_refuses_same_build_changed_bytes_url_or_version(self):
        previous = self.sign("first.json")
        with self.assertRaises(ValueError):
            self.sign("changed-url.json", previous, resume=True,
                      url="https://github.com/Extectick/ExVPN/releases/download/another/" + self.binary.name)
        self.metadata["version"] = "0.1.3"
        self.write_metadata()
        with self.assertRaises(ValueError):
            self.sign("changed-version.json", previous, resume=True)
        self.metadata["version"] = "0.1.2"
        self.binary.write_bytes(b"replacement bytes also have a valid local artifact hash")
        self.metadata["sha256"] = signer.hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.write_metadata()
        with self.assertRaises(ValueError):
            self.sign("changed-bytes.json", previous, resume=True)

    def test_expired_same_build_refused_but_new_build_can_advance(self):
        previous = self.sign("first.json")
        now = datetime.now(timezone.utc).replace(microsecond=0)
        self.rewrite_signed(previous, lambda p: p.update(
            publishedAt=(now - timedelta(days=20)).isoformat().replace("+00:00", "Z"),
            expiresAt=(now - timedelta(days=6)).isoformat().replace("+00:00", "Z")))
        with self.assertRaises(ValueError):
            self.sign("expired.json", previous, resume=True)
        self.assertFalse((self.root / "expired.json").exists())
        self.metadata["build"] = 24
        self.write_metadata()
        self.assertTrue(self.sign("advance.json", previous, resume=True).is_file())

    def test_authenticated_malformed_previous_cannot_be_resumed(self):
        mutations = {
            "schema": lambda p: p.update(schema=2),
            "bool-schema": lambda p: p.update(schema=True),
            "app": lambda p: p.update(appId="foreign"),
            "platform": lambda p: p.update(platform="android-arm64"),
            "channel": lambda p: p.update(channel="stable"),
            "bad-version": lambda p: p.update(version="0.01.2"),
            "bad-build": lambda p: p.update(build=True),
            "overflow-build": lambda p: p.update(build=2147483648),
            "future": lambda p: p.update(publishedAt="2099-01-01T00:00:00Z"),
            "non-utc": lambda p: p.update(expiresAt="2099-01-01T00:00:00+00:00"),
            "missing-time": lambda p: p.pop("publishedAt"),
            "unknown": lambda p: p.update(extra="ignored?"),
            "foreign-url": lambda p: p["asset"].update(url="https://example.com/private.exe"),
            "path-url": lambda p: p["asset"].update(url="https://github.com/Extectick/ExVPN/releases/download/../file.exe"),
            "hash": lambda p: p["asset"].update(sha256="A" * 64),
            "size": lambda p: p["asset"].update(sizeBytes=0),
            "bool-size": lambda p: p["asset"].update(sizeBytes=True),
            "unknown-asset": lambda p: p["asset"].update(extra=1),
        }
        for name, change in mutations.items():
            with self.subTest(name=name):
                previous = self.sign(name + "-previous.json")
                self.rewrite_signed(previous, change)
                with self.assertRaises(ValueError):
                    self.sign(name + "-refused.json", previous, resume=True)
                self.assertFalse((self.root / (name + "-refused.json")).exists())

    def test_resume_rejects_bad_signature_duplicate_and_unknown_envelope(self):
        for kind in ("signature", "duplicate", "unknown", "bom", "base64"):
            with self.subTest(kind=kind):
                previous = self.sign(kind + "-previous.json")
                envelope = json.loads(previous.read_text(encoding="utf-8"))
                if kind == "signature":
                    envelope["signature"] = base64.b64encode(bytes(64)).decode()
                elif kind == "unknown":
                    envelope["extra"] = "unrecognized"
                elif kind == "base64":
                    # Python's validate=True accepts nonzero unused pad bits;
                    # the native verifier's strict base64 deliberately rejects.
                    encoded = envelope["signature"]
                    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
                    envelope["signature"] = encoded[:-3] + alphabet[alphabet.index(encoded[-3]) + 1] + "=="
                elif kind == "duplicate":
                    raw = base64.b64decode(envelope["payload"]).replace(b'"schema":1', b'"schema":1,"schema":1')
                    envelope["payload"] = base64.b64encode(raw).decode()
                    envelope["signature"] = base64.b64encode(self.key.sign(signer.DOMAIN + raw)).decode()
                previous.write_text(json.dumps(envelope), encoding="utf-8-sig" if kind == "bom" else "utf-8")
                with self.assertRaises((ValueError, InvalidSignature)):
                    self.sign(kind + "-refused.json", previous, resume=True)


@unittest.skipUnless(os.name == "nt", "PowerShell release ownership checks run on Windows")
class FeedOwnershipTests(unittest.TestCase):
    def test_only_exact_owned_empty_or_single_bounded_manifest_is_resumable(self):
        # Extract just the production pure guard, never execute publisher main,
        # GitHub commands, a signer, or any real release/secret operation.
        publisher = Path(__file__).with_name("publish-windows-feed.ps1").resolve()
        code = r'''
$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Publisher parse failed' }
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-FeedResumeAsset'},$true)
. ([ScriptBlock]::Create($fn.Extent.Text))
function Feed { '{"draft":false,"prerelease":true,"tag_name":"windows-beta","name":"title","body":"notes","target_commitish":"commit","author":{"login":"github-actions[bot]"},"assets":[]}' | ConvertFrom-Json }
function Refuse($Value) {
    $blocked=$false
    try { $null=Get-FeedResumeAsset $Value 'commit' 'title' 'notes' } catch { $blocked=$true }
    if (!$blocked) { throw 'Foreign/malformed feed accepted' }
}
$v=Feed; if ($null -ne (Get-FeedResumeAsset $v 'commit' 'title' 'notes')) { throw 'Owned empty feed rejected' }
$v=Feed; $v.target_commitish='other'; Refuse $v
$v=Feed; $v.author.login='other'; Refuse $v
$v=Feed; $v.draft=$true; Refuse $v
$v=Feed; $v.prerelease=$false; Refuse $v
$v=Feed; $v.name='other'; Refuse $v
$v=Feed; $v.body='other'; Refuse $v
$v=Feed; $v.tag_name='other'; Refuse $v
$valid=[pscustomobject]@{name='windows-x64.json';size=512;digest=('sha256:'+('a'*64))}
$v=Feed; $v.assets=@($valid); if ((Get-FeedResumeAsset $v 'commit' 'title' 'notes').name -cne 'windows-x64.json') { throw 'Manifest rejected' }
$v.assets=@($valid,$valid); Refuse $v
foreach($field in @('name','size','digest')) {
    $v=Feed; $bad=$valid | ConvertTo-Json | ConvertFrom-Json
    if($field -ceq 'name'){$bad.name='foreign.exe'}
    if($field -ceq 'size'){$bad.size=32769}
    if($field -ceq 'digest'){$bad.digest='sha256:invalid'}
    $v.assets=@($bad); Refuse $v
}
Write-Host '13 feed ownership guards PASS; no external operation.'
'''
        with tempfile.TemporaryDirectory() as fixture:
            runner = Path(fixture) / "guard-test.ps1"
            runner.write_text(code, encoding="utf-8")
            result = subprocess.run([shutil.which("pwsh") or "pwsh", "-NoProfile", "-NonInteractive",
                                     "-File", str(runner), str(publisher)],
                                    capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
