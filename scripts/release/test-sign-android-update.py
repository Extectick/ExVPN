#!/usr/bin/env python3
"""Android feed signing checks; synthetic APK bytes and ephemeral keys only."""
import base64
from contextlib import redirect_stdout
from datetime import datetime, timezone
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

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

spec = importlib.util.spec_from_file_location("android_signer", Path(__file__).with_name("sign-windows-update.py"))
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)


class AndroidSigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.key = Ed25519PrivateKey.generate()
        self.seed = self.root / ".private" / "fixture.seed"
        self.seed.parent.mkdir()
        self.seed.write_bytes(self.key.private_bytes_raw())
        self.config = {"keyId": "test-key", "channel": "beta",
                       "publicKey": base64.b64encode(self.key.public_key().public_bytes_raw()).decode()}
        configs = self.root / "config" / "updates"
        configs.mkdir(parents=True)
        for name in ("android-beta.json", "windows-beta.json"):
            (configs / name).write_text(json.dumps(self.config), encoding="utf-8")
        self.apk = self.root / "ExVPN-0.1.5-26-android.apk"
        self.apk.write_bytes(b"synthetic, never installable")
        self.metadata = {"file": self.apk.name, "version": "0.1.5", "build": 26,
                         "sha256": signer.hashlib.sha256(self.apk.read_bytes()).hexdigest()}
        self.write_metadata()

    def write_metadata(self):
        (self.root / "artifact.json").write_text(json.dumps(self.metadata), encoding="utf-8")

    def sign(self, name="feed.json", previous=None, resume=False, platform="android", url=None):
        output = self.root / name
        args = ["sign", "--platform", platform, "--artifact", str(self.apk),
                "--url", url or "https://github.com/Extectick/ExVPN/releases/download/v0.1.5/" + self.apk.name,
                "--seed-file", str(self.seed), "--output", str(output)]
        if previous:
            args += ["--previous", str(previous)]
        if resume:
            args += ["--resume-identical"]
        with patch.object(signer, "ROOT", self.root), patch.object(sys, "argv", args), redirect_stdout(io.StringIO()):
            signer.main()
        return output

    def test_signed_apk_has_distinct_platform_domain_and_compatibility(self):
        envelope = json.loads(self.sign().read_text())
        payload = base64.b64decode(envelope["payload"])
        signature = base64.b64decode(envelope["signature"])
        self.key.public_key().verify(signature, signer.ANDROID_DOMAIN + payload)
        with self.assertRaises(InvalidSignature):
            self.key.public_key().verify(signature, signer.DOMAIN + payload)
        data = json.loads(payload)
        self.assertEqual((data["platform"], data["minSdk"], data["build"]), ("android", 30, 26))
        self.assertEqual(data["asset"]["sha256"], self.metadata["sha256"])

    def test_windows_cannot_sign_apk_and_android_cannot_sign_exe(self):
        with self.assertRaises(ValueError):
            self.sign(platform="windows-x64")
        for url in ("http://github.com/Extectick/ExVPN/releases/download/v0.1.5/a.apk",
                    "https://example.invalid/a.apk",
                    "https://github.com/Extectick/ExVPN/releases/download/v0.1.5/a.exe",
                    "https://github.com/Extectick/ExVPN/releases/download/v0.1.5/a.apk?x=1"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.sign(url=url)

    def test_hash_and_seed_mismatch_refused(self):
        self.apk.write_bytes(b"changed")
        with self.assertRaises(ValueError):
            self.sign()
        self.metadata["sha256"] = signer.hashlib.sha256(self.apk.read_bytes()).hexdigest()
        self.write_metadata()
        self.seed.write_bytes(Ed25519PrivateKey.generate().private_bytes_raw())
        with self.assertRaises(ValueError):
            self.sign()

    def test_resume_exact_bytes_no_new_validity_and_no_replay(self):
        first = self.sign()
        resumed = self.sign("resumed.json", previous=first, resume=True)
        self.assertEqual(first.read_bytes(), resumed.read_bytes())
        with self.assertRaises(ValueError):
            self.sign("replay.json", previous=first)
        self.metadata["build"] = 27
        renamed = self.root / "ExVPN-0.1.5-27-android.apk"
        self.apk.rename(renamed)
        self.apk = renamed
        self.metadata["file"] = self.apk.name
        self.write_metadata()
        self.assertTrue(self.sign("next.json", previous=first).is_file())

    def test_apk_name_and_tag_must_match_version_and_build(self):
        self.metadata["build"] = 27
        self.write_metadata()
        with self.assertRaises(ValueError):
            self.sign("wrong-build.json")
        self.metadata["build"] = 26
        self.metadata["version"] = "0.1.6"
        self.write_metadata()
        with self.assertRaises(ValueError):
            self.sign("wrong-version.json")
        self.metadata["version"] = "0.1.5"
        self.write_metadata()
        with self.assertRaises(ValueError):
            self.sign("wrong-tag.json", url="https://github.com/Extectick/ExVPN/releases/download/v0.1.4/" + self.apk.name)

    def test_wrong_domain_and_invalid_compatibility_refused_even_if_signed(self):
        original = json.loads(self.sign().read_text())
        now = datetime.now(timezone.utc)
        for kind in ("domain", "sdk", "sdk_bool", "platform", "duplicate", "size"):
            envelope = dict(original)
            payload = json.loads(base64.b64decode(envelope["payload"]))
            if kind == "sdk": payload["minSdk"] = 29
            if kind == "sdk_bool": payload["minSdk"] = True
            if kind == "platform": payload["platform"] = "windows-x64"
            if kind == "size": payload["asset"]["sizeBytes"] = 512 * 1024**2 + 1
            raw = json.dumps(payload, separators=(",", ":")).encode()
            if kind == "duplicate": raw = raw.replace(b'"schema":1', b'"schema":1,"schema":1')
            domain = signer.DOMAIN if kind == "domain" else signer.ANDROID_DOMAIN
            envelope["payload"] = base64.b64encode(raw).decode()
            envelope["signature"] = base64.b64encode(self.key.sign(domain + raw)).decode()
            with self.subTest(kind=kind), self.assertRaises((ValueError, InvalidSignature)):
                signer.verified_previous(json.dumps(envelope).encode(), self.config,
                                         self.key.public_key(), now, "android")

    @unittest.skipUnless(os.name == "nt", "PowerShell release guards run on Windows")
    def test_android_feed_guard_refuses_windows_or_foreign_pointer(self):
        code = r'''
$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Publisher parse failed'}
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-FeedResumeAsset'},$true)
. ([ScriptBlock]::Create($fn.Extent.Text))
$f='{"draft":false,"prerelease":true,"tag_name":"android-beta","name":"title","body":"notes","target_commitish":"commit","author":{"login":"github-actions[bot]"},"assets":[]}'|ConvertFrom-Json
if($null-ne(Get-FeedResumeAsset $f 'commit' 'title' 'notes' 'android-beta' 'android.json')){throw 'Owned empty feed refused'}
$f.assets=@([pscustomobject]@{name='android.json';size=1024;digest=('sha256:'+('a'*64))})
if((Get-FeedResumeAsset $f 'commit' 'title' 'notes' 'android-beta' 'android.json').name-cne'android.json'){throw 'Android pointer refused'}
$f.assets[0].name='windows-x64.json'; $refused=$false
try{$null=Get-FeedResumeAsset $f 'commit' 'title' 'notes' 'android-beta' 'android.json'}catch{$refused=$true}
if(!$refused){throw 'Foreign pointer accepted'}
'''
        probe = self.root / "ownership.ps1"
        probe.write_text(code, encoding="utf-8")
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(probe),
                                 str(Path(__file__).with_name("publish-windows-feed.ps1").resolve())],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
