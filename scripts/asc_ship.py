#!/usr/bin/env python3
"""Start Xcode Cloud if needed, wait for a VALID build, and submit for review.

Intended for GitHub Actions on merge to main (including Grok Bot merges) and
for Xcode Cloud post-upload. Linux-safe: openssl + App Store Connect API.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_status as asc  # noqa: E402

EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
    "WAITING_FOR_REVIEW",
}
LIVE_STATES = {"READY_FOR_SALE", "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE"}
def resolve_workflow_id(token: str, app_id: str, configured: str) -> str:
    if configured:
        return configured
    products = asc.api_get("/v1/ciProducts", token, {"limit": "50"})
    product_id = None
    for product in products.get("data") or []:
        rel = ((product.get("relationships") or {}).get("app") or {}).get("data") or {}
        if rel.get("id") == app_id:
            product_id = product.get("id")
            break
    if not product_id:
        raise asc.StatusError(f"no Xcode Cloud product for app {app_id}")
    workflows = asc.api_get(f"/v1/ciProducts/{product_id}/workflows", token, {"limit": "20"})
    enabled = []
    for workflow in workflows.get("data") or []:
        attributes = workflow.get("attributes") or {}
        name = str(attributes.get("name") or "")
        if name.lower() == "default":
            return str(workflow["id"])
        if attributes.get("isEnabled") is not False:
            enabled.append(workflow)
    if enabled:
        return str(enabled[0]["id"])
    raise asc.StatusError(f"no Xcode Cloud workflow for app {app_id}")


def marketing_version(root: Path) -> str:
    pbxproj = list(root.rglob("*.pbxproj"))
    for path in pbxproj:
        match = re.search(r"MARKETING_VERSION = ([0-9]+(?:\.[0-9]+){1,3});", path.read_text(encoding="utf-8"))
        if match:
            return match.group(1)
    for path in root.rglob("project.yml"):
        match = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', path.read_text(encoding="utf-8"))
        if match:
            return match.group(1)
    for path in root.rglob("Info.plist"):
        match = re.search(
            r"<key>CFBundleShortVersionString</key>\s*<string>([^$(][^<]*)</string>",
            path.read_text(encoding="utf-8"),
        )
        if match:
            return match.group(1).strip()
    for path in root.rglob("app.config.ts"):
        match = re.search(r"version:\s*'([^']+)'", path.read_text(encoding="utf-8"))
        if match:
            return match.group(1)
    raise asc.StatusError("could not determine marketing version from the repo")


def default_whats_new(root: Path) -> str:
    configured = os.environ.get("ASC_WHATS_NEW", "").strip()
    if configured:
        return configured
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "log", "-1", "--pretty=%s"],
            check=True,
            capture_output=True,
            text=True,
        )
        subject = result.stdout.strip()
        if subject:
            return f"{subject}\n\nBug fixes and improvements."
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass
    return "Bug fixes and improvements."


def commit_sha_of(run: dict[str, Any]) -> str:
    attributes = run.get("attributes") or {}
    source = attributes.get("sourceCommit")
    if isinstance(source, dict):
        return str(source.get("commitSha") or source.get("sha") or "")
    if isinstance(source, str):
        return source
    return ""


def find_run_for_commit(token: str, workflow_id: str, commit: str) -> dict[str, Any] | None:
    payload = asc.api_get(
        f"/v1/ciWorkflows/{workflow_id}/buildRuns",
        token,
        {"sort": "-number", "limit": "20", "fields[ciBuildRuns]": "number,completionStatus,executionProgress,sourceCommit"},
    )
    short = commit[:12]
    for run in payload.get("data") or []:
        sha = commit_sha_of(run)
        if commit and (sha == commit or (sha and sha.startswith(short))):
            return run
    return None


def start_cloud_run(token: str, workflow_id: str) -> dict[str, Any]:
    return asc.api_request(
        "POST",
        "/v1/ciBuildRuns",
        token,
        body={
            "data": {
                "type": "ciBuildRuns",
                "relationships": {
                    "workflow": {"data": {"type": "ciWorkflows", "id": workflow_id}},
                },
            }
        },
    )


def wait_for_run(token: str, workflow_id: str, commit: str, timeout: int) -> dict[str, Any]:
    deadline = time.time() + timeout
    last: dict[str, Any] | None = None
    while time.time() < deadline:
        last = find_run_for_commit(token, workflow_id, commit)
        if last:
            status = (last.get("attributes") or {}).get("completionStatus") or ""
            progress = (last.get("attributes") or {}).get("executionProgress") or ""
            print(f"Xcode Cloud #{(last.get('attributes') or {}).get('number')} {status} {progress}")
            if status in FAILED_CLOUD:
                raise asc.StatusError(f"Xcode Cloud run {last.get('id')} ended with {status}")
            if status == "SUCCEEDED":
                return last
        time.sleep(30)
    raise asc.StatusError("timed out waiting for Xcode Cloud to finish")


def latest_valid_build(token: str, app_id: str, build_number: str | None) -> dict[str, Any]:
    parameters = {
        "filter[app]": app_id,
        "sort": "-uploadedDate",
        "limit": "10",
        "fields[builds]": "version,processingState,uploadedDate",
    }
    if build_number:
        parameters["filter[version]"] = build_number
    payload = asc.api_get("/v1/builds", token, parameters)
    for build in payload.get("data") or []:
        state = (build.get("attributes") or {}).get("processingState")
        if state == "VALID":
            return build
        if state in {"FAILED", "INVALID"}:
            continue
    raise asc.StatusError("no VALID App Store Connect build is available yet")


def ensure_version(token: str, app_id: str, version: str) -> tuple[str, str]:
    payload = asc.api_get(
        f"/v1/apps/{app_id}/appStoreVersions",
        token,
        {"filter[platform]": "IOS", "limit": "20", "fields[appStoreVersions]": "versionString,appStoreState"},
    )
    for item in payload.get("data") or []:
        attributes = item.get("attributes") or {}
        if attributes.get("versionString") == version:
            return str(item["id"]), str(attributes.get("appStoreState") or "")
    created = asc.api_request(
        "POST",
        "/v1/appStoreVersions",
        token,
        body={
            "data": {
                "type": "appStoreVersions",
                "attributes": {
                    "platform": "IOS",
                    "versionString": version,
                    "releaseType": "AFTER_APPROVAL",
                },
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            }
        },
    )
    return str(created["data"]["id"]), str((created["data"].get("attributes") or {}).get("appStoreState") or "PREPARE_FOR_SUBMISSION")


def set_whats_new(token: str, version_id: str, whats_new: str, promo: str) -> None:
    payload = asc.api_get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations", token, {"limit": "20"})
    localization = None
    for item in payload.get("data") or []:
        if (item.get("attributes") or {}).get("locale") == "en-US":
            localization = item
            break
    if localization is None and payload.get("data"):
        localization = payload["data"][0]
    if localization is None:
        raise asc.StatusError("App Store version has no localizations")
    attributes: dict[str, str] = {"whatsNew": whats_new}
    if promo:
        attributes["promotionalText"] = promo
    asc.api_request(
        "PATCH",
        f"/v1/appStoreVersionLocalizations/{localization['id']}",
        token,
        body={
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": localization["id"],
                "attributes": attributes,
            }
        },
    )


def submit_review(token: str, app_id: str, version_id: str, version: str, build_id: str, state: str) -> None:
    if state in LIVE_STATES:
        raise asc.StatusError(
            f"version {version} is {state}; bump MARKETING_VERSION before submitting another review"
        )
    try:
        asc.api_request(
            "PATCH",
            f"/v1/appStoreVersions/{version_id}/relationships/build",
            token,
            body={"data": {"type": "builds", "id": build_id}},
        )
        print(f"attached build {build_id} to version {version}")
    except asc.StatusError as error:
        print(f"build attach note: {error}")

    submissions = asc.api_get(
        f"/v1/apps/{app_id}/reviewSubmissions",
        token,
        {"filter[platform]": "IOS", "limit": "5"},
    )
    open_submission = None
    for item in submissions.get("data") or []:
        attributes = item.get("attributes") or {}
        if attributes.get("submitted") is False or attributes.get("state") in {"UNSUBMITTED", "READY_FOR_REVIEW"}:
            open_submission = item
            break
    if open_submission is None:
        created = asc.api_request(
            "POST",
            "/v1/reviewSubmissions",
            token,
            body={
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": "IOS"},
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )
        open_submission = created["data"]
    submission_id = open_submission["id"]
    try:
        asc.api_request(
            "POST",
            "/v1/reviewSubmissionItems",
            token,
            body={
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission_id}},
                        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
                    },
                }
            },
        )
    except asc.StatusError as error:
        print(f"review item note: {error}")
    if (open_submission.get("attributes") or {}).get("submitted") is True:
        print(f"version {version} already submitted for review")
        return
    asc.api_request(
        "PATCH",
        f"/v1/reviewSubmissions/{submission_id}",
        token,
        body={"data": {"type": "reviewSubmissions", "id": submission_id, "attributes": {"submitted": True}}},
    )
    print(f"SUBMITTED {version} FOR APP STORE REVIEW")


def token_from_env() -> str:
    missing = asc.missing_credentials()
    if missing:
        raise asc.StatusError("missing " + ", ".join(missing))
    temporary_directory = Path(tempfile.mkdtemp(prefix="asc-ship-"))
    return asc.make_token(
        temporary_directory,
        os.environ["ASC_ISSUER_ID"],
        os.environ["ASC_KEY_ID"],
        asc.write_key(temporary_directory),
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Start Xcode Cloud, wait, and submit for review")
    parser.add_argument("--app-id", default=os.environ.get("ASC_APP_ID", ""))
    parser.add_argument("--workflow-id", default=os.environ.get("ASC_WORKFLOW_ID", ""))
    parser.add_argument("--commit", default=os.environ.get("GITHUB_SHA", ""))
    parser.add_argument("--version", default=os.environ.get("ASC_VERSION", ""))
    parser.add_argument("--build-number", default=os.environ.get("ASC_BUILD_NUMBER") or os.environ.get("CI_BUILD_NUMBER", ""))
    parser.add_argument("--build-id", default=os.environ.get("ASC_BUILD_ID", ""))
    parser.add_argument("--beta-group-id", default=os.environ.get("ASC_BETA_GROUP_ID", ""))
    parser.add_argument("--root", default=".")
    parser.add_argument("--wait-timeout", type=int, default=int(os.environ.get("ASC_WAIT_TIMEOUT", "5400")))
    parser.add_argument("--start-if-needed", action="store_true")
    parser.add_argument("--wait", action="store_true")
    parser.add_argument("--submit", action="store_true")
    parser.add_argument("--submit-only", action="store_true")
    args = parser.parse_args(argv)

    if not args.app_id:
        raise asc.StatusError("set --app-id or ASC_APP_ID")
    root = Path(args.root).resolve()
    token = token_from_env()

    if args.start_if_needed or args.wait:
        args.workflow_id = resolve_workflow_id(token, args.app_id, args.workflow_id)
        if not args.workflow_id:
            raise asc.StatusError("set --workflow-id or ASC_WORKFLOW_ID to start Xcode Cloud")
        print("waiting briefly for a git-triggered Xcode Cloud run (Grok Bot / merge to main)")
        time.sleep(15)
        existing = find_run_for_commit(token, args.workflow_id, args.commit) if args.commit else None
        if existing:
            print(f"Xcode Cloud already running/finished for {args.commit[:12]}: {existing.get('id')}")
        else:
            started = start_cloud_run(token, args.workflow_id)
            print(f"started Xcode Cloud run {started.get('data', {}).get('id')}")

    if args.wait:
        if not args.workflow_id:
            raise asc.StatusError("set --workflow-id to wait for Xcode Cloud")
        wait_for_run(token, args.workflow_id, args.commit, args.wait_timeout)

    if args.submit or args.submit_only:
        version = args.version or marketing_version(root)
        build = (
            {"id": args.build_id}
            if args.build_id
            else latest_valid_build(token, args.app_id, args.build_number or None)
        )
        build_id = str(build["id"])
        if args.beta_group_id:
            try:
                asc.api_request(
                    "POST",
                    f"/v1/betaGroups/{args.beta_group_id}/relationships/builds",
                    token,
                    body={"data": [{"type": "builds", "id": build_id}]},
                )
                print(f"assigned {build_id} to TestFlight group {args.beta_group_id}")
            except asc.StatusError as error:
                print(f"TestFlight assign note: {error}")
        version_id, state = ensure_version(token, args.app_id, version)
        print(f"App Store version {version} is {state} ({version_id})")
        set_whats_new(token, version_id, default_whats_new(root), os.environ.get("ASC_PROMOTIONAL_TEXT", "").strip())
        submit_review(token, args.app_id, version_id, version, build_id, state)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except asc.StatusError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
