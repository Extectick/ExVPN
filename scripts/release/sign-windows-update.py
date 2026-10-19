"""Offline full-installer manifest signing. Never uploads artifacts or keys.

Requires cryptography==46.0.5; use a dedicated raw Ed25519 seed in .private/.
The public trust configuration is compiled into exvpn-updater.exe.
"""

import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.exceptions import InvalidSignature

DOMAIN = b"ExVPN/windows-update/v1\0"
ANDROID_DOMAIN = b"ExVPN/android-update/v1\0"
PLATFORMS = {
    "windows-x64": (DOMAIN, "windows-beta.json", ".exe"),
    "android": (ANDROID_DOMAIN, "android-beta.json", ".apk"),
}
ROOT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})")


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON field")
        result[key] = value
    return result


def strict_json(raw, limit):
    if not 0 < len(raw) <= limit:
        raise ValueError("Manifest size outside bounds")
    return json.loads(raw.decode("utf-8"), object_pairs_hook=strict_object)


def release_url(raw, platform="windows-x64"):
    if type(raw) is not str or len(raw) > 4096:
        return False
    url = urlsplit(raw)
    parts = url.path.split("/")
    return (url.scheme == "https" and url.netloc == "github.com" and
            not url.query and not url.fragment and "%" not in url.path and
            "\\" not in url.path and len(parts) == 7 and
            parts[1:5] == ["Extectick", "ExVPN", "releases", "download"] and
            all(part and part not in (".", "..") for part in parts[5:]) and
            parts[6].endswith(PLATFORMS[platform][2]))


def verified_previous(raw, config, public_key, now, platform="windows-x64"):
    envelope = strict_json(raw, 32 * 1024)
    if (type(envelope) is not dict or set(envelope) != {"schema", "keyId", "payload", "signature"} or
            type(envelope["schema"]) is not int or envelope["schema"] != 1 or
            envelope["keyId"] != config["keyId"]):
        raise ValueError("Previous feed has a different trust identity")
    payload = base64.b64decode(envelope["payload"], validate=True)
    signature = base64.b64decode(envelope["signature"], validate=True)
    if (base64.b64encode(payload).decode() != envelope["payload"] or
            base64.b64encode(signature).decode() != envelope["signature"]):
        raise ValueError("Previous feed base64 is not canonical")
    public_key.verify(signature, PLATFORMS[platform][0] + payload)
    old = strict_json(payload, 16 * 1024)
    fields = {"schema", "appId", "platform", "channel", "version", "build", "publishedAt", "expiresAt", "asset"}
    if platform == "android":
        fields.add("minSdk")
    if (type(old) is not dict or set(old) != fields or
            type(old["schema"]) is not int or old["schema"] != 1 or
            old["appId"] != "exvpn" or old["platform"] != platform or
            old["channel"] != config["channel"] or type(old["version"]) is not str or
            not VERSION.fullmatch(old["version"]) or type(old["build"]) is not int or
            not 1 <= old["build"] <= 2147483647):
        raise ValueError("Previous feed identity invalid")
    if platform == "android" and (type(old["minSdk"]) is not int or old["minSdk"] != 30):
        raise ValueError("Previous Android compatibility invalid")
    dates = []
    for field in ("publishedAt", "expiresAt"):
        value = old[field]
        if type(value) is not str or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?Z", value):
            raise ValueError("Previous feed time invalid")
        dates.append(datetime.fromisoformat(value.replace("Z", "+00:00")))
    published, expires = dates
    if published > now or not published < expires <= published + timedelta(days=30) or expires > now + timedelta(days=30):
        raise ValueError("Previous feed validity invalid")
    asset = old["asset"]
    if (type(asset) is not dict or set(asset) != {"url", "sizeBytes", "sha256"} or
            not release_url(asset["url"], platform) or type(asset["sizeBytes"]) is not int or
            not 0 < asset["sizeBytes"] <= 512 * 1024**2 or type(asset["sha256"]) is not str or
            not re.fullmatch(r"[a-f0-9]{64}", asset["sha256"])):
        raise ValueError("Previous feed asset invalid")
    return old, expires


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=PLATFORMS, default="windows-x64")
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--seed-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--valid-days", type=int, default=14)
    parser.add_argument("--previous", type=Path,
                        help="Previously published signed feed; refuses replay or downgrade")
    parser.add_argument("--resume-identical", action="store_true",
                        help="Copy an authenticated, unexpired identical previous envelope; never renew or resign it")
    args = parser.parse_args()
    domain, config_name, _ = PLATFORMS[args.platform]
    config = json.loads((ROOT / "config/updates" / config_name).read_text())
    artifact = args.artifact.resolve(strict=True)
    metadata = json.loads((artifact.parent / "artifact.json").read_text(encoding="utf-8-sig"))
    if metadata["file"] != artifact.name or not VERSION.fullmatch(metadata["version"]):
        raise ValueError("Artifact metadata does not match installer")
    if type(metadata["build"]) is not int or not 1 <= metadata["build"] <= 2147483647:
        raise ValueError("Invalid installer build")
    if args.platform == "android":
        expected_name = f'ExVPN-{metadata["version"]}-{metadata["build"]}-android.apk'
        expected_url = f'https://github.com/Extectick/ExVPN/releases/download/v{metadata["version"]}/{expected_name}'
        if artifact.name != expected_name or args.url != expected_url:
            raise ValueError("Android APK name and release URL must match its version and build")
    if not release_url(args.url, args.platform) or urlsplit(args.url).path.rsplit("/", 1)[-1] != artifact.name:
        raise ValueError("Only the exact repository release asset is allowed")
    if not 1 <= args.valid_days <= 30:
        raise ValueError("Manifest validity must be between 1 and 30 days")
    with artifact.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if digest != metadata["sha256"] or not 0 < artifact.stat().st_size <= 512 * 1024**2:
        raise ValueError("Artifact hash or size does not match")
    seed_path = args.seed_file.resolve(strict=True)
    seed_path.relative_to((ROOT / ".private").resolve())
    key = Ed25519PrivateKey.from_private_bytes(seed_path.read_bytes())
    public = base64.b64encode(key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
    if public != config["publicKey"]:
        raise ValueError("Seed does not match the pinned update public key")
    now = datetime.now(timezone.utc).replace(microsecond=0)
    expected_asset = {"url": args.url, "sizeBytes": artifact.stat().st_size, "sha256": digest}
    if args.resume_identical and not args.previous:
        raise ValueError("Resume requires a previous envelope")
    if args.previous:
        previous_raw = args.previous.read_bytes()
        old, expires = verified_previous(previous_raw, config, key.public_key(), now, args.platform)
        if (args.resume_identical and old["version"] == metadata["version"] and
                old["build"] == metadata["build"] and old["asset"] == expected_asset):
            if expires <= now:
                raise ValueError("Expired identical feed requires a newer build")
            # Preserve the exact authenticated envelope, signature and expiry.
            with args.output.open("xb") as output:
                output.write(previous_raw)
            print(f"Verified identical signed {args.platform} manifest resumed; no new signature or validity period.")
            return
        version_parts = lambda value: tuple(map(int, value.split(".")))
        if (version_parts(metadata["version"]) < version_parts(old["version"]) or
                metadata["build"] <= old["build"]):
            raise ValueError("Feed must move forward to a newer build")
    stamp = lambda value: value.isoformat().replace("+00:00", "Z")
    manifest = {
        "schema": 1, "appId": "exvpn", "platform": args.platform,
        "channel": config["channel"], "version": metadata["version"],
        "build": metadata["build"], "publishedAt": stamp(now),
        "expiresAt": stamp(now + timedelta(days=args.valid_days)),
        "asset": expected_asset,
    }
    if args.platform == "android":
        manifest["minSdk"] = 30
    payload = json.dumps(manifest, separators=(",", ":"), ensure_ascii=True).encode()
    envelope = {"schema": 1, "keyId": config["keyId"],
                "payload": base64.b64encode(payload).decode(),
                "signature": base64.b64encode(key.sign(domain + payload)).decode()}
    # Exclusive creation prevents accidentally replacing a previously reviewed feed.
    with args.output.open("x", encoding="utf-8", newline="\n") as output:
        json.dump(envelope, output, separators=(",", ":"))
        output.write("\n")
    print(f"Signed {args.platform} manifest created locally; no files were published.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, InvalidSignature):
        raise SystemExit("Signing refused: inspect artifact, public configuration and private seed locally.")
