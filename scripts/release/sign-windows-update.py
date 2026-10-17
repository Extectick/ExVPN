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

DOMAIN = b"ExVPN/windows-update/v1\0"
ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--seed-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--valid-days", type=int, default=14)
    args = parser.parse_args()
    config = json.loads((ROOT / "config/updates/windows-beta.json").read_text())
    artifact = args.artifact.resolve(strict=True)
    metadata = json.loads((artifact.parent / "artifact.json").read_text(encoding="utf-8-sig"))
    if metadata["file"] != artifact.name or not re.fullmatch(r"\d+\.\d+\.\d+", metadata["version"]):
        raise ValueError("Artifact metadata does not match installer")
    if type(metadata["build"]) is not int or metadata["build"] < 1:
        raise ValueError("Invalid installer build")
    url = urlsplit(args.url)
    expected = "/Extectick/ExVPN/releases/download/"
    if (url.scheme != "https" or url.netloc != "github.com" or
            not url.path.startswith(expected) or url.query or url.fragment or
            len(url.path.removeprefix(expected).split("/")) != 2 or
            url.path.rsplit("/", 1)[-1] != artifact.name or "%" in url.path):
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
    stamp = lambda value: value.isoformat().replace("+00:00", "Z")
    payload = json.dumps({
        "schema": 1, "appId": "exvpn", "platform": "windows-x64",
        "channel": config["channel"], "version": metadata["version"],
        "build": metadata["build"], "publishedAt": stamp(now),
        "expiresAt": stamp(now + timedelta(days=args.valid_days)),
        "asset": {"url": args.url, "sizeBytes": artifact.stat().st_size, "sha256": digest},
    }, separators=(",", ":"), ensure_ascii=True).encode()
    envelope = {"schema": 1, "keyId": config["keyId"],
                "payload": base64.b64encode(payload).decode(),
                "signature": base64.b64encode(key.sign(DOMAIN + payload)).decode()}
    # Exclusive creation prevents accidentally replacing a previously reviewed feed.
    with args.output.open("x", encoding="utf-8", newline="\n") as output:
        json.dump(envelope, output, separators=(",", ":"))
        output.write("\n")
    print("Signed Windows manifest created locally; no files were published.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError):
        raise SystemExit("Signing refused: inspect artifact, public configuration and private seed locally.")
