#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline, pinned-key ExVPN Dart catalog assembly; never uploads or builds."""

import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

import cryptography
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

ROOT = Path(__file__).resolve().parents[2]
APP_ID = "ea97a683-02e5-4d86-9aa1-779d6b4bc81e"
ENGINE = "4b936a0c03e13389ddfb1ac48823f187964975c2"
FLUTTER = "5bef02a16146a0effc07da4acccaafe90a2739ce"
KEY_ID = "exvpn-full-update-beta-1"
PUBLIC_KEY = "jqfYwATCfBPz1x8MDwBCj7ova7Ju9fdJIWCnLDGWLNk="
DOMAIN = b"ExVPN/dart-update/v1\0"
MAX_CATALOG = 256 * 1024
MAX_DIFF = 64 * 1024 * 1024
MAX_NUMBER = 2147483647
VERSION = re.compile(r"(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\+[1-9][0-9]{0,8}")
SHA = re.compile(r"[a-f0-9]{64}")
COMMIT = re.compile(r"[a-f0-9]{40}")
TARGETS = {"Windows": {"windows-x64": ("windows", "x86_64")},
           "Android": {"android-arm64": ("android", "aarch64"), "android-x64": ("android", "x86_64")}}


def bad(code="catalog_invalid"):
    raise ValueError(code)


def number(value):
    return type(value) is int and 1 <= value <= MAX_NUMBER


def matches(pattern, value):
    return type(value) is str and pattern.fullmatch(value) is not None


def canonical(value):
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), allow_nan=False).encode("ascii")


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            bad()
        result[key] = value
    return result


def decode_json(raw, limit=MAX_CATALOG, compact=True):
    if type(raw) is not bytes or not 0 < len(raw) <= limit:
        bad()
    try:
        text = raw.decode("ascii" if compact else "utf-8-sig")
        value = json.loads(text, object_pairs_hook=strict_object,
                           parse_constant=lambda _: bad())
        if type(value) is not dict or (compact and canonical(value) != raw.strip()):
            bad()
        return value
    except (UnicodeError, json.JSONDecodeError, TypeError):
        bad()


def fields(value, expected):
    if type(value) is not dict or set(value) != set(expected):
        bad()


def b64(raw, size=None):
    try:
        if type(raw) is not str:
            bad()
        value = base64.b64decode(raw, validate=True)
        if base64.b64encode(value).decode("ascii") != raw or (size is not None and len(value) != size):
            bad()
        return value
    except (ValueError, UnicodeError):
        bad()


def timestamp(value):
    if type(value) is not str or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", value):
        bad()
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
            bad()
        return parsed
    except ValueError:
        bad()


def date_text(value):
    return value.astimezone(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def patch_url(value):
    return (type(value) is str and len(value) <= 2048 and re.fullmatch(
        r"https://github\.com/Extectick/ExVPN/releases/download/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.patch", value) is not None)


def validate_patch(value):
    fields(value, {"platform", "arch", "number", "url", "sha256", "sizeBytes", "aotSha256", "signature"})
    if ((value["platform"], value["arch"]) not in {("windows", "x86_64"), ("android", "aarch64"), ("android", "x86_64")} or
            not number(value["number"]) or type(value["sizeBytes"]) is not int or
            not 1 <= value["sizeBytes"] <= MAX_DIFF or not matches(SHA, value["sha256"]) or
            not matches(SHA, value["aotSha256"]) or not patch_url(value["url"])):
        bad()
    b64(value["signature"], 512)


def validate_body(body, now, allow_expired=False):
    fields(body, {"schema", "appId", "channel", "revision", "publishedAt", "expiresAt", "bases"})
    if (type(body["schema"]) is not int or body["schema"] != 1 or body["appId"] != APP_ID or
            body["channel"] not in {"beta", "stable"} or not number(body["revision"]) or
            type(body["bases"]) is not list or len(body["bases"]) > 16):
        bad()
    published, expires = timestamp(body["publishedAt"]), timestamp(body["expiresAt"])
    if (published > now + timedelta(minutes=2) or not published < expires <= published + timedelta(days=30) or
            (not allow_expired and expires <= now)):
        bad("catalog_expired")
    versions = set()
    for base in body["bases"]:
        fields(base, {"version", "engineRevision", "compatibilitySha256", "patches", "revoked"})
        if (not matches(VERSION, base["version"]) or base["engineRevision"] != ENGINE or
                not matches(SHA, base["compatibilitySha256"]) or base["version"] in versions or
                type(base["patches"]) is not list or len(base["patches"]) > 3 or
                type(base["revoked"]) is not list or len(base["revoked"]) > 4096 or
                any(not number(n) for n in base["revoked"]) or len(set(base["revoked"])) != len(base["revoked"])):
            bad()
        versions.add(base["version"])
        targets = set()
        for patch in base["patches"]:
            validate_patch(patch)
            target = patch["platform"], patch["arch"]
            if target in targets or patch["number"] in base["revoked"]:
                bad()
            targets.add(target)


def verify(raw, now=None, allow_expired=False):
    now = now or datetime.now(timezone.utc)
    envelope = decode_json(raw)
    fields(envelope, {"schema", "keyId", "payload", "signature"})
    if type(envelope["schema"]) is not int or envelope["schema"] != 1 or envelope["keyId"] != KEY_ID:
        bad()
    payload, signature = b64(envelope["payload"]), b64(envelope["signature"], 64)
    try:
        Ed25519PublicKey.from_public_bytes(b64(PUBLIC_KEY, 32)).verify(signature, DOMAIN + payload)
    except InvalidSignature:
        bad("signature_invalid")
    body = decode_json(payload, MAX_CATALOG * 3 // 4)
    validate_body(body, now, allow_expired)
    return body


def no_links(path):
    path = Path(os.path.abspath(path))
    for item in (path, *path.parents):
        if item.is_symlink() or (hasattr(item, "is_junction") and item.is_junction()):
            bad("catalog_path_link")
        if item.exists() and item.is_file() and item.stat().st_nlink != 1:
            bad("catalog_path_link")
    return path


def read_bounded(path, limit):
    path = no_links(path)
    if not path.is_file() or not 0 < path.stat().st_size <= limit:
        bad("receipt_invalid")
    with path.open("rb") as source:
        raw = source.read(limit + 1)
    if len(raw) > limit:
        bad("receipt_invalid")
    return raw


def relative_file(directory, relative):
    if (type(relative) is not str or not relative or "\\" in relative or
            not re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", relative) or
            any(part in {".", ".."} for part in relative.split("/"))):
        bad("receipt_path_invalid")
    return no_links(Path(directory) / relative)


def file_hash(path, expected_hash, expected_size, limit, arch=None):
    path = no_links(path)
    if (not matches(SHA, expected_hash) or type(expected_size) is not int or not 1 <= expected_size <= limit or
            not path.is_file() or path.stat().st_size != expected_size):
        bad("receipt_artifact_invalid")
    with path.open("rb") as source:
        header = source.read(64)
        source.seek(0)
        actual = hashlib.file_digest(source, "sha256").hexdigest()
    if actual != expected_hash:
        bad("receipt_artifact_invalid")
    if arch is not None and (expected_size < 4096 or len(header) != 64 or header[:6] != b"\x7fELF\x02\x01" or
                             int.from_bytes(header[18:20], "little") != {"x86_64": 62, "aarch64": 183}[arch]):
        bad("receipt_aot_invalid")


def load_base(paths):
    records = []
    for path in paths:
        path = no_links(path)
        raw = read_bounded(path, 16 * 1024 * 1024)
        receipt = decode_json(raw, 16 * 1024 * 1024, compact=False)
        target = receipt.get("target")
        if (type(receipt.get("schemaVersion")) is not int or receipt["schemaVersion"] != 1 or
                receipt.get("delivery") != "independent" or receipt.get("published") is not False or
                not matches(VERSION, receipt.get("version")) or target not in TARGETS or
                not matches(COMMIT, receipt.get("sourceCommit")) or receipt.get("engineRevision") != ENGINE or
                receipt.get("flutterRevision") != FLUTTER or not matches(SHA, receipt.get("protectedInputsSha256")) or
                receipt.get("appRoot") != "apps/exvpn" or receipt.get("dartEntrypoint") != "lib/main.dart" or
                receipt.get("sourceUpdaterPolicyUnchanged") is not True or receipt.get("autoUpdate") is not False or
                receipt.get("patchVerification") != "strict" or receipt.get("packagedUpdaterEndpoint") != "http://127.0.0.1:57791"):
            bad("base_receipt_invalid")
        public = receipt.get("signingPublicKey")
        if type(public) is not dict or public.get("path") != "config/signing/shorebird-beta-public.pem" or not matches(SHA, public.get("sha256")):
            bad("base_receipt_invalid")
        public_bytes = read_bounded(relative_file(ROOT, public["path"]), 16384)
        if hashlib.sha256(public_bytes).hexdigest() != public["sha256"]:
            bad("rsa_key_mismatch")
        public_key = serialization.load_pem_public_key(public_bytes)
        if not isinstance(public_key, rsa.RSAPublicKey) or public_key.key_size != 4096:
            bad("rsa_key_mismatch")
        if type(receipt.get("baseAot")) is not dict or set(receipt["baseAot"]) != set(TARGETS[target]):
            bad("base_receipt_invalid")
        for key, (_, arch) in TARGETS[target].items():
            value = receipt["baseAot"][key]
            if type(value) is not dict:
                bad("base_receipt_invalid")
            file_hash(relative_file(path.parent, value.get("path")), value.get("sha256"), value.get("size"), 128 * 1024 * 1024, arch)
        records.append((receipt, raw, public_key))
    if not records or len(records) > 2 or len({r[0]["target"] for r in records}) != len(records):
        bad("base_receipt_invalid")
    first = records[0][0]
    for receipt, _, _ in records:
        for name in ("version", "sourceCommit", "protectedInputsSha256", "signingPublicKey"):
            if receipt[name] != first[name]:
                bad("base_receipt_mismatch")
    return records


def receipt_patches(paths, bases, asset_tag):
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", asset_tag or "") or asset_tag in {"ota-beta", "ota-stable", ".", ".."}:
        bad("immutable_asset_tag_required")
    by_target = {r[0]["target"]: r for r in bases}
    patches, targets = [], set()
    for path in paths:
        path = no_links(path)
        receipt = decode_json(read_bounded(path, 1024 * 1024), 1024 * 1024, compact=False)
        target = receipt.get("target")
        if target not in by_target:
            bad("patch_base_receipt_missing")
        base, base_raw, public_key = by_target[target]
        if (type(receipt.get("schemaVersion")) is not int or receipt["schemaVersion"] != 1 or
                receipt.get("version") != base["version"] or receipt.get("baseSourceCommit") != base["sourceCommit"] or
                not matches(COMMIT, receipt.get("sourceCommit")) or not number(receipt.get("patchNumber")) or
                receipt.get("engineRevision") != ENGINE or receipt.get("flutterRevision") != FLUTTER or
                receipt.get("protectedInputsSha256") != base["protectedInputsSha256"] or
                receipt.get("baseReceiptSha256") != hashlib.sha256(base_raw).hexdigest() or
                receipt.get("signingPublicKeySha256") != base["signingPublicKey"]["sha256"] or
                receipt.get("cloudCalls") is not False or receipt.get("nativeBuild") is not False or
                type(receipt.get("artifacts")) is not list or len(receipt["artifacts"]) != len(TARGETS[target])):
            bad("patch_receipt_invalid")
        seen = set()
        for artifact in receipt["artifacts"]:
            if type(artifact) is not dict or artifact.get("key") not in TARGETS[target]:
                bad("patch_receipt_invalid")
            key = artifact["key"]
            platform, arch = TARGETS[target][key]
            if key in seen or artifact.get("arch") != arch or artifact.get("baseSha256") != base["baseAot"][key]["sha256"]:
                bad("patch_receipt_invalid")
            seen.add(key)
            file_hash(relative_file(path.parent, artifact.get("diffPath")), artifact.get("diffSha256"), artifact.get("diffSize"), MAX_DIFF)
            file_hash(relative_file(path.parent, artifact.get("aotPath")), artifact.get("aotSha256"), artifact.get("aotSize"), 128 * 1024 * 1024, arch)
            signature = b64(artifact.get("hashSignature"), 512)
            try:
                public_key.verify(signature, artifact["aotSha256"].encode("ascii"), padding.PKCS1v15(), hashes.SHA256())
            except InvalidSignature:
                bad("rsa_signature_invalid")
            identity = platform, arch
            if identity in targets:
                bad("patch_target_duplicate")
            targets.add(identity)
            version = base["version"].replace("+", "-")
            filename = f"ExVPN-{version}-{platform}-{arch}-p{receipt['patchNumber']}.patch"
            patches.append({"platform": platform, "arch": arch, "number": receipt["patchNumber"],
                            "url": f"https://github.com/Extectick/ExVPN/releases/download/{asset_tag}/{filename}",
                            "sha256": artifact["diffSha256"], "sizeBytes": artifact["diffSize"],
                            "aotSha256": artifact["aotSha256"], "signature": artifact["hashSignature"]})
    return patches


def successor(body, previous):
    if body["revision"] <= previous["revision"]:
        bad("catalog_replayed")
    by_version = {base["version"]: base for base in body["bases"]}
    for old in previous["bases"]:
        current = by_version.get(old["version"])
        if current is None or current["compatibilitySha256"] != old["compatibilitySha256"]:
            bad("base_history_missing")
        if not set(old["revoked"]).issubset(current["revoked"]):
            bad("withdrawal_replayed")
        targets = {(p["platform"], p["arch"]): p for p in current["patches"]}
        for patch in old["patches"]:
            next_patch = targets.get((patch["platform"], patch["arch"]))
            if next_patch is None:
                if patch["number"] not in current["revoked"]:
                    bad("withdrawal_missing")
            elif next_patch["number"] < patch["number"] or (next_patch["number"] == patch["number"] and next_patch != patch):
                bad("patch_replayed")


def assemble(base_paths, patch_paths, revision, key_file, *, previous=None, withdrawals=(),
             asset_tag=None, valid_days=14, now=None, channel="beta"):
    now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc).replace(microsecond=0)
    if not number(revision) or type(valid_days) is not int or not 1 <= valid_days <= 30 or channel not in {"beta", "stable"}:
        bad()
    bases = load_base(base_paths)
    first = bases[0][0]
    old = verify(previous, now, allow_expired=True) if previous is not None else None
    if old is not None and old["channel"] != channel:
        bad("catalog_channel_mismatch")
    body = {"schema": 1, "appId": APP_ID, "channel": channel, "revision": revision,
            "publishedAt": date_text(now), "expiresAt": date_text(now + timedelta(days=valid_days)),
            "bases": json.loads(json.dumps(old["bases"])) if old is not None else []}
    current = next((b for b in body["bases"] if b["version"] == first["version"]), None)
    if current is None:
        current = {"version": first["version"], "engineRevision": ENGINE,
                   "compatibilitySha256": first["protectedInputsSha256"], "patches": [], "revoked": []}
        body["bases"].append(current)
    elif current["compatibilitySha256"] != first["protectedInputsSha256"]:
        bad("base_receipt_mismatch")
    old_numbers = current["revoked"] + [p["number"] for p in current["patches"]]
    high_water = max(old_numbers, default=0)
    withdrawal_set = set()
    for value in withdrawals:
        if not number(value):
            bad("withdrawal_invalid")
        withdrawal_set.add(value)
    additions = receipt_patches(patch_paths, bases, asset_tag) if patch_paths else []
    for patch in additions:
        existing = next((p for p in current["patches"] if (p["platform"], p["arch"]) == (patch["platform"], patch["arch"])), None)
        if patch["number"] in current["revoked"] or patch["number"] in withdrawal_set:
            bad("patch_revoked")
        if patch["number"] <= high_water and patch != existing:
            bad("patch_replayed")
        current["patches"] = [p for p in current["patches"] if (p["platform"], p["arch"]) != (patch["platform"], patch["arch"])]
        current["patches"].append(patch)
    current["revoked"] = sorted(set(current["revoked"]) | withdrawal_set)
    current["patches"] = sorted([p for p in current["patches"] if p["number"] not in withdrawal_set],
                                key=lambda p: (p["platform"], p["arch"]))
    validate_body(body, now)
    if old is not None:
        successor(body, old)
    key_path = no_links(key_file)
    try:
        key_path.relative_to(no_links(ROOT / ".private"))
    except ValueError:
        bad("private_key_location_invalid")
    seed = read_bounded(key_path, 32)
    if len(seed) != 32:
        bad("private_key_invalid")
    key = Ed25519PrivateKey.from_private_bytes(seed)
    if base64.b64encode(key.public_key().public_bytes_raw()).decode("ascii") != PUBLIC_KEY:
        bad("signing_key_mismatch")
    payload = canonical(body)
    envelope = canonical({"schema": 1, "keyId": KEY_ID, "payload": base64.b64encode(payload).decode("ascii"),
                          "signature": base64.b64encode(key.sign(DOMAIN + payload)).decode("ascii")})
    verify(envelope, now)
    return envelope


def summary(body):
    return {"revision": body["revision"], "channel": body["channel"], "bases": len(body["bases"]),
            "activeTargets": sum(len(b["patches"]) for b in body["bases"]),
            "revokedNumbers": sum(len(b["revoked"]) for b in body["bases"]),
            "expiresAt": body["expiresAt"], "verified": True, "cloudCalls": False, "nativeBuild": False}


def write_new(path, raw):
    path = no_links(path)
    if path.exists():
        bad("catalog_output_exists")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="catalog-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
        # Atomic publication without overwriting an existing output on any OS.
        os.link(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", type=Path, help="Read-only validation of a signed catalog")
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--base-receipt", type=Path, action="append", default=[])
    parser.add_argument("--patch-receipt", type=Path, action="append", default=[])
    parser.add_argument("--withdraw", type=int, action="append", default=[])
    parser.add_argument("--revision", type=int)
    parser.add_argument("--asset-tag", help="Immutable release tag for patch assets; never ota-beta")
    parser.add_argument("--valid-days", type=int, default=14)
    parser.add_argument("--channel", choices=("beta", "stable"), default="beta")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--key-file", type=Path)
    args = parser.parse_args(argv)
    if cryptography.__version__ != "46.0.5":
        bad("signing_dependency_version_mismatch")
    if args.verify:
        if any((args.previous, args.base_receipt, args.patch_receipt, args.withdraw, args.revision, args.asset_tag, args.output, args.key_file)):
            bad("verify_arguments_invalid")
        raw = read_bounded(args.verify, MAX_CATALOG)
    else:
        if not args.base_receipt or args.revision is None or args.output is None or args.key_file is None:
            bad("signing_arguments_missing")
        previous = read_bounded(args.previous, MAX_CATALOG) if args.previous else None
        raw = assemble(args.base_receipt, args.patch_receipt, args.revision, args.key_file,
                       previous=previous, withdrawals=args.withdraw, asset_tag=args.asset_tag,
                       valid_days=args.valid_days, channel=args.channel)
        write_new(args.output, raw)
    print(json.dumps(summary(verify(raw)), separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        code = str(error)
        if not re.fullmatch(r"[a-z][a-z0-9_]{1,80}", code):
            code = "catalog_operation_failed"
        print(json.dumps({"error": code}, separators=(",", ":")), file=sys.stderr)
        raise SystemExit(1)
