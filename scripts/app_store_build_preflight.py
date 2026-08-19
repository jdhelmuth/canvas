#!/usr/bin/env python3
"""Fail-closed App Store Connect build-number preflight for Canvas."""

from __future__ import annotations

import base64
import json
import os
import re
import shutil
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
INTEGER_BUILD = re.compile(r"^[0-9]+$")


class PreflightError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> None:
        return None


def require_environment(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise PreflightError(f"set {name} as an environment variable")
    return value


def read_config(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PreflightError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise PreflightError(f"{path} must contain a JSON object")
    return value


def config_string(config: dict[str, Any], key: str) -> str:
    value = config.get(key)
    if not isinstance(value, str) or not value:
        raise PreflightError(f"release config {key!r} must be a non-empty string")
    return value


def show_build_settings(root: Path, project: str, scheme: str) -> dict[str, Any]:
    command = [
        "xcodebuild",
        "-project",
        project,
        "-target",
        scheme,
        "-configuration",
        "Release",
        "-showBuildSettings",
        "-json",
    ]
    try:
        result = subprocess.run(
            command,
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(result.stdout)
    except FileNotFoundError as error:
        raise PreflightError("missing required tool: xcodebuild") from error
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()
        raise PreflightError(f"xcodebuild -showBuildSettings failed: {detail}") from error
    except json.JSONDecodeError as error:
        raise PreflightError("xcodebuild returned invalid build-settings JSON") from error

    if not isinstance(payload, list):
        raise PreflightError("xcodebuild returned an unexpected build-settings response")
    for item in payload:
        if isinstance(item, dict) and item.get("target") == scheme:
            settings = item.get("buildSettings")
            if isinstance(settings, dict):
                return settings
    raise PreflightError(f"xcodebuild did not return Release settings for target {scheme!r}")


def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def read_der_length(data: bytes, index: int) -> tuple[int, int]:
    if index >= len(data):
        raise PreflightError("invalid ECDSA signature length")
    first = data[index]
    index += 1
    if first < 128:
        return first, index
    byte_count = first & 0x7F
    if byte_count == 0 or byte_count > 4 or index + byte_count > len(data):
        raise PreflightError("invalid ECDSA signature length")
    length = int.from_bytes(data[index : index + byte_count], "big")
    return length, index + byte_count


def der_es256_to_raw(data: bytes) -> bytes:
    index = 0
    if not data or data[index] != 0x30:
        raise PreflightError("invalid ECDSA signature sequence")
    index += 1
    sequence_length, index = read_der_length(data, index)
    sequence_end = index + sequence_length
    if sequence_end != len(data):
        raise PreflightError("invalid ECDSA signature sequence length")

    values: list[bytes] = []
    for _ in range(2):
        if index >= sequence_end or data[index] != 0x02:
            raise PreflightError("invalid ECDSA signature integer")
        index += 1
        length, index = read_der_length(data, index)
        if length == 0 or index + length > sequence_end:
            raise PreflightError("invalid ECDSA signature integer length")
        value = data[index : index + length]
        index += length
        value = value.lstrip(b"\x00")
        if not value or len(value) > 32:
            raise PreflightError("invalid ES256 signature integer")
        values.append(value.rjust(32, b"\x00"))

    if index != sequence_end:
        raise PreflightError("invalid trailing ECDSA signature data")
    return b"".join(values)


def make_token(
    temporary_directory: Path,
    issuer_id: str,
    key_id: str,
    key_path: Path,
) -> str:
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 900,
        "aud": "appstoreconnect-v1",
    }
    encoded_header = b64url(
        json.dumps(header, separators=(",", ":"), sort_keys=True).encode("utf-8")
    )
    encoded_payload = b64url(
        json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    )
    unsigned = f"{encoded_header}.{encoded_payload}"
    unsigned_path = temporary_directory / "unsigned"
    signature_path = temporary_directory / "signature.der"
    unsigned_path.write_text(unsigned, encoding="ascii")

    try:
        subprocess.run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-sign",
                str(key_path),
                "-out",
                str(signature_path),
                str(unsigned_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as error:
        raise PreflightError("missing required tool: openssl") from error
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()
        raise PreflightError(f"could not sign App Store Connect token: {detail}") from error

    signature = der_es256_to_raw(signature_path.read_bytes())
    return f"{unsigned}.{b64url(signature)}"


def api_error_detail(body: bytes) -> str:
    try:
        payload = json.loads(body)
        errors = payload.get("errors", [])
        if isinstance(errors, list) and errors and isinstance(errors[0], dict):
            value = errors[0].get("detail") or errors[0].get("title")
            if isinstance(value, str) and value:
                return value
    except (UnicodeDecodeError, json.JSONDecodeError, AttributeError):
        pass
    return "unknown App Store Connect error"


def api_get(url: str, token: str) -> dict[str, Any]:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname != API_ORIGIN:
        raise PreflightError("App Store Connect returned an untrusted pagination URL")

    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.api+json",
        },
    )
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=30) as response:
            body = response.read()
    except urllib.error.HTTPError as error:
        body = error.read()
        raise PreflightError(
            f"App Store Connect returned HTTP {error.code}: {api_error_detail(body)}"
        ) from error
    except urllib.error.URLError as error:
        raise PreflightError(f"App Store Connect request failed: {error.reason}") from error

    try:
        payload = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PreflightError("App Store Connect returned invalid JSON") from error
    if not isinstance(payload, dict):
        raise PreflightError("App Store Connect returned an unexpected response")
    return payload


def api_url(path: str, parameters: dict[str, str | int]) -> str:
    return urllib.parse.urlunsplit(
        ("https", API_ORIGIN, path, urllib.parse.urlencode(parameters), "")
    )


def latest_uploaded_build(
    token: str,
    app_id: str,
    platform: str,
    marketing_version: str,
) -> int:
    prerelease = api_get(
        api_url(
            "/v1/preReleaseVersions",
            {
                "filter[app]": app_id,
                "filter[platform]": platform,
                "filter[version]": marketing_version,
                "limit": 10,
            },
        ),
        token,
    )
    versions = prerelease.get("data")
    if not isinstance(versions, list):
        raise PreflightError("App Store Connect prerelease response has no data list")
    if len(versions) > 1:
        raise PreflightError(
            f"multiple prerelease versions matched {marketing_version}/{platform}"
        )
    if not versions:
        return 0
    if not isinstance(versions[0], dict) or not isinstance(versions[0].get("id"), str):
        raise PreflightError("App Store Connect prerelease response has no version ID")

    latest = 0
    next_url = api_url(
        "/v1/builds",
        {"filter[preReleaseVersion]": versions[0]["id"], "limit": 200},
    )
    while next_url:
        page = api_get(next_url, token)
        builds = page.get("data")
        if not isinstance(builds, list):
            raise PreflightError("App Store Connect builds response has no data list")
        for build in builds:
            try:
                version = build["attributes"]["version"]
            except (KeyError, TypeError):
                raise PreflightError(
                    "App Store Connect returned a build without a version"
                )
            if not isinstance(version, str) or not INTEGER_BUILD.fullmatch(version):
                raise PreflightError(
                    f"build version {version!r} is not an integer; compare builds manually"
                )
            latest = max(latest, int(version))

        links = page.get("links")
        if links is None:
            next_url = ""
        elif isinstance(links, dict):
            value = links.get("next")
            if value is not None and not isinstance(value, str):
                raise PreflightError("App Store Connect returned an invalid next link")
            next_url = value or ""
        else:
            raise PreflightError("App Store Connect returned invalid pagination links")
    return latest


def main(arguments: list[str]) -> int:
    if len(arguments) > 1:
        raise PreflightError(
            "usage: app_store_build_preflight.sh [candidate-build-number]"
        )

    root = Path(
        os.environ.get(
            "CI_PRIMARY_REPOSITORY_PATH",
            str(Path(__file__).resolve().parent.parent),
        )
    ).resolve()
    config = read_config(root / "release/release-requirements.json")
    project = config_string(config, "project")
    scheme = config_string(config, "scheme")
    platform = config_string(config, "platform")

    app_id = require_environment("ASC_APP_ID")
    issuer_id = require_environment("ASC_ISSUER_ID")
    key_id = require_environment("ASC_KEY_ID")
    if not INTEGER_BUILD.fullmatch(app_id):
        raise PreflightError("ASC_APP_ID must be the numeric App Store Connect app ID")

    settings = show_build_settings(root, project, scheme)
    marketing_version = settings.get("MARKETING_VERSION")
    project_build = settings.get("CURRENT_PROJECT_VERSION")
    if not isinstance(marketing_version, str) or not marketing_version:
        raise PreflightError("MARKETING_VERSION is empty")
    if not isinstance(project_build, str) or not INTEGER_BUILD.fullmatch(project_build):
        raise PreflightError(
            f"CURRENT_PROJECT_VERSION must be an integer; got {project_build!r}"
        )

    candidate = (
        arguments[0]
        if arguments
        else os.environ.get("CI_BUILD_NUMBER", project_build)
    )
    if not INTEGER_BUILD.fullmatch(candidate):
        raise PreflightError(f"candidate build number must be an integer; got {candidate!r}")

    if shutil.which("openssl") is None:
        raise PreflightError("missing required tool: openssl")

    with tempfile.TemporaryDirectory(prefix="canvas-asc-preflight-") as directory:
        temporary_directory = Path(directory)
        configured_key_path = os.environ.get("ASC_PRIVATE_KEY_PATH", "")
        if configured_key_path:
            key_path = Path(configured_key_path).expanduser()
            if not key_path.is_absolute():
                key_path = root / key_path
        else:
            private_key = os.environ.get("ASC_PRIVATE_KEY", "")
            if not private_key:
                raise PreflightError(
                    "set secret ASC_PRIVATE_KEY or ASC_PRIVATE_KEY_PATH"
                )
            key_path = temporary_directory / "AuthKey.p8"
            key_path.write_text(private_key.rstrip("\n") + "\n", encoding="utf-8")
            key_path.chmod(0o600)
        if not key_path.is_file() or not os.access(key_path, os.R_OK):
            raise PreflightError("App Store Connect private key is not readable")

        token = make_token(temporary_directory, issuer_id, key_id, key_path)
        latest = latest_uploaded_build(
            token,
            app_id,
            platform,
            marketing_version,
        )

    required_next = latest + 1
    candidate_number = int(candidate)
    if candidate_number <= latest:
        raise PreflightError(
            f"candidate {marketing_version} ({candidate_number}) collides with "
            f"uploaded builds; use build {required_next} or greater"
        )

    print(
        f"App Store build preflight OK: {marketing_version} ({candidate_number}); "
        f"latest uploaded is {latest}, next available is {required_next}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except PreflightError as error:
        print(f"error: App Store build preflight failed: {error}", file=sys.stderr)
        raise SystemExit(1)
