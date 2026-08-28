#!/usr/bin/env python3
"""List recent App Store builds and Xcode Cloud runs (Linux-safe).

Uses openssl + the App Store Connect API. Does not archive or upload.
Requires ASC_ISSUER_ID, ASC_KEY_ID, and ASC_PRIVATE_KEY or ASC_PRIVATE_KEY_PATH.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

API_ORIGIN = "api.appstoreconnect.apple.com"


class StatusError(RuntimeError):
    pass


def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def read_der_length(data: bytes, index: int) -> tuple[int, int]:
    if index >= len(data):
        raise StatusError("invalid ECDSA signature length")
    first = data[index]
    index += 1
    if first < 128:
        return first, index
    byte_count = first & 0x7F
    if byte_count == 0 or byte_count > 4 or index + byte_count > len(data):
        raise StatusError("invalid ECDSA signature length")
    length = int.from_bytes(data[index : index + byte_count], "big")
    return length, index + byte_count


def der_es256_to_raw(data: bytes) -> bytes:
    index = 0
    if not data or data[index] != 0x30:
        raise StatusError("invalid ECDSA signature sequence")
    index += 1
    sequence_length, index = read_der_length(data, index)
    sequence_end = index + sequence_length
    if sequence_end != len(data):
        raise StatusError("invalid ECDSA signature sequence length")
    values: list[bytes] = []
    for _ in range(2):
        if index >= sequence_end or data[index] != 0x02:
            raise StatusError("invalid ECDSA signature integer")
        index += 1
        length, index = read_der_length(data, index)
        if length == 0 or index + length > sequence_end:
            raise StatusError("invalid ECDSA signature integer length")
        value = data[index : index + length]
        index += length
        value = value.lstrip(b"\x00")
        if not value or len(value) > 32:
            raise StatusError("invalid ES256 signature integer")
        values.append(value.rjust(32, b"\x00"))
    if index != sequence_end:
        raise StatusError("invalid trailing ECDSA signature data")
    return b"".join(values)


def missing_credentials() -> list[str]:
    missing: list[str] = []
    for name in ("ASC_ISSUER_ID", "ASC_KEY_ID"):
        if not os.environ.get(name):
            missing.append(name)
    if not os.environ.get("ASC_PRIVATE_KEY") and not os.environ.get("ASC_PRIVATE_KEY_PATH"):
        missing.append("ASC_PRIVATE_KEY")
    return missing


def make_token(temporary_directory: Path, issuer_id: str, key_id: str, key_path: Path) -> str:
    now = int(time.time())
    unsigned = (
        b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
        + "."
        + b64url(
            json.dumps(
                {"iss": issuer_id, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                separators=(",", ":"),
            ).encode()
        )
    )
    unsigned_path = temporary_directory / "unsigned"
    signature_path = temporary_directory / "signature.der"
    unsigned_path.write_text(unsigned, encoding="ascii")
    try:
        subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(key_path), "-out", str(signature_path), str(unsigned_path)],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as error:
        raise StatusError("missing required tool: openssl") from error
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()
        raise StatusError(f"could not sign App Store Connect token: {detail}") from error
    return f"{unsigned}.{b64url(der_es256_to_raw(signature_path.read_bytes()))}"


def api_request(
    method: str,
    path: str,
    token: str,
    parameters: dict[str, str] | None = None,
    body: dict[str, Any] | None = None,
) -> dict[str, Any]:
    query = urllib.parse.urlencode(parameters or {})
    url = urllib.parse.urlunsplit(("https", API_ORIGIN, path, query, ""))
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:800]
        raise StatusError(f"{method} {path} -> HTTP {error.code}: {detail}") from error
    if not raw:
        return {}
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise StatusError(f"unexpected response for {method} {path}")
    return payload


def api_get(path: str, token: str, parameters: dict[str, str] | None = None) -> dict[str, Any]:
    return api_request("GET", path, token, parameters=parameters)


def print_builds(token: str, app_id: str, limit: int) -> None:
    payload = api_get(
        "/v1/builds",
        token,
        {
            "filter[app]": app_id,
            "sort": "-uploadedDate",
            "limit": str(limit),
            "fields[builds]": "version,processingState,uploadedDate,expired",
        },
    )
    print(f"ASC builds for app {app_id}")
    for build in payload.get("data") or []:
        attributes = build.get("attributes") or {}
        print(
            f"  {attributes.get('version', '?'):8} "
            f"{attributes.get('processingState', '?'):10} "
            f"{attributes.get('uploadedDate', '')} "
            f"id={build.get('id')}"
        )


def print_cloud_runs(token: str, workflow_id: str, limit: int) -> None:
    payload = api_get(
        f"/v1/ciWorkflows/{workflow_id}/buildRuns",
        token,
        {
            "sort": "-number",
            "limit": str(limit),
            "fields[ciBuildRuns]": "number,completionStatus,executionProgress,createdDate,startedDate,finishedDate,sourceCommit",
        },
    )
    print(f"Xcode Cloud runs for workflow {workflow_id}")
    for run in payload.get("data") or []:
        attributes = run.get("attributes") or {}
        commit = (attributes.get("sourceCommit") or {}).get("commitSha", "")
        if isinstance(attributes.get("sourceCommit"), str):
            commit = attributes["sourceCommit"]
        print(
            f"  #{attributes.get('number', '?')} "
            f"{attributes.get('completionStatus', '?'):12} "
            f"{attributes.get('executionProgress', '?'):12} "
            f"{commit} "
            f"id={run.get('id')}"
        )


def write_key(temporary_directory: Path) -> Path:
    configured = os.environ.get("ASC_PRIVATE_KEY_PATH", "")
    if configured:
        path = Path(configured).expanduser()
        if not path.is_file():
            raise StatusError(f"ASC_PRIVATE_KEY_PATH is not readable: {path}")
        return path
    key_path = temporary_directory / "AuthKey.p8"
    pem = os.environ.get("ASC_PRIVATE_KEY", "")
    if not pem:
        raise StatusError("set ASC_PRIVATE_KEY or ASC_PRIVATE_KEY_PATH")
    key_path.write_text(pem.rstrip("\n") + "\n", encoding="utf-8")
    key_path.chmod(0o600)
    return key_path


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Show App Store Connect / Xcode Cloud status")
    parser.add_argument("--app-id", default=os.environ.get("ASC_APP_ID", ""))
    parser.add_argument("--workflow-id", default=os.environ.get("ASC_WORKFLOW_ID", ""))
    parser.add_argument("--limit", type=int, default=8)
    args = parser.parse_args(argv)

    missing = missing_credentials()
    if missing:
        print("error: missing " + ", ".join(missing), file=sys.stderr)
        return 2

    if not args.app_id and not args.workflow_id:
        print("error: set --app-id and/or --workflow-id", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="asc-status-") as directory:
        temporary_directory = Path(directory)
        token = make_token(
            temporary_directory,
            os.environ["ASC_ISSUER_ID"],
            os.environ["ASC_KEY_ID"],
            write_key(temporary_directory),
        )
        if args.app_id:
            print_builds(token, args.app_id, args.limit)
        if args.workflow_id:
            print_cloud_runs(token, args.workflow_id, args.limit)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except StatusError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
