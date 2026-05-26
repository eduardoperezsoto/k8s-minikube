#!/usr/bin/env python3
"""
Cleanup old Harbor images.

Retention policy:
  - KEEP:   all versions newer than the currently deployed one (undeployed builds)
  - KEEP:   the version currently deployed by ArgoCD
  - KEEP:   the immediately previous version by push date (rollback target)
  - DELETE: everything older than the previous version

Required environment variables:
  ARGOCD_URL
  ARGOCD_USER
  ARGOCD_PASS
  HARBOR_URL
  HARBOR_USER
  HARBOR_PASS
"""

import base64
import json
import os
import ssl
import sys
from urllib import error as urlerror
from urllib import request as urlrequest
from urllib.parse import quote, urlencode


# ─── Config ───────────────────────────────────────────────────────────────────

ARGOCD_URL  = os.environ["ARGOCD_URL"].rstrip("/")
ARGOCD_USER = os.environ["ARGOCD_USER"]
ARGOCD_PASS = os.environ["ARGOCD_PASS"]
HARBOR_URL  = os.environ["HARBOR_URL"].rstrip("/")
HARBOR_USER = os.environ["HARBOR_USER"]
HARBOR_PASS = os.environ["HARBOR_PASS"]

HARBOR_AUTH = "Basic " + base64.b64encode(f"{HARBOR_USER}:{HARBOR_PASS}".encode()).decode()
SSL_CTX = ssl._create_unverified_context()  # TBR


# ─── HTTP helper ──────────────────────────────────────────────────────────────

def _request(method: str, url: str, *, headers: dict | None = None,
             body: dict | None = None, timeout: int = 30):
    data = None
    headers = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        headers.setdefault("Content-Type", "application/json")
    req = urlrequest.Request(url, data=data, headers=headers, method=method)
    return urlrequest.urlopen(req, context=SSL_CTX, timeout=timeout)


# ─── ArgoCD ───────────────────────────────────────────────────────────────────

def argocd_login() -> str:
    resp = _request(
        "POST",
        f"{ARGOCD_URL}/api/v1/session",
        body={"username": ARGOCD_USER, "password": ARGOCD_PASS},
        timeout=15,
    )
    return json.loads(resp.read().decode())["token"]


def get_images_in_use(token: str) -> dict[str, str]:
    resp = _request(
        "GET",
        f"{ARGOCD_URL}/api/v1/applications",
        headers={"Authorization": f"Bearer {token}"},
        timeout=15,
    )
    payload = json.loads(resp.read().decode())

    in_use: dict[str, str] = {}
    for app in payload.get("items") or []:
        app_name = app["metadata"]["name"]
        images = app.get("status", {}).get("summary", {}).get("images") or []
        for image in images:
            if ":" not in image:
                continue
            ref, tag = image.rsplit(":", 1)
            in_use[ref] = tag
            print(f"  [ArgoCD] {app_name}: {ref}:{tag}")

    return in_use


# ─── Harbor ───────────────────────────────────────────────────────────────────

def _harbor(method: str, path: str, *, params: dict | None = None,
            body: dict | None = None):
    url = f"{HARBOR_URL}{path}"
    if params:
        url = f"{url}?{urlencode(params)}"
    return _request(
        method, url,
        headers={"Authorization": HARBOR_AUTH},
        body=body,
        timeout=30,
    )


def _harbor_all(path: str, **params) -> list:
    results, page = [], 1
    while True:
        resp = _harbor("GET", path, params={"page_size": 100, "page": page, **params})
        batch = json.loads(resp.read().decode())
        results.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return results


def get_projects() -> list[str]:
    items = _harbor_all("/api/v2.0/projects")
    return [p["name"] for p in items if not p.get("registry_id")]


def get_repositories(project: str) -> list[str]:
    items = _harbor_all(f"/api/v2.0/projects/{project}/repositories")
    return [r["name"].split("/", 1)[-1] for r in items]


def get_artifacts(project: str, repo: str) -> list[dict]:
    encoded = quote(repo, safe="")
    return _harbor_all(
        f"/api/v2.0/projects/{project}/repositories/{encoded}/artifacts",
        with_tag=True,
    )


def delete_artifact(project: str, repo: str, digest: str) -> None:
    encoded_repo   = quote(repo, safe="")
    encoded_digest = quote(digest, safe="")
    _harbor("DELETE", f"/api/v2.0/projects/{project}/repositories/{encoded_repo}/artifacts/{encoded_digest}")


# ─── Retention logic ──────────────────────────────────────────────────────────

def process_repository(project: str, repo: str, images_in_use: dict[str, str]) -> tuple[int, int]:
    harbor_registry = HARBOR_URL.split("://")[-1]
    full_ref = f"{harbor_registry}/{project}/{repo}"
    artifacts_raw = get_artifacts(project, repo)

    versioned = []
    for a in artifacts_raw:
        tags = [t["name"] for t in (a.get("tags") or []) if t["name"] != "latest"]
        if not tags:
            continue
        versioned.append({
            "digest":    a["digest"],
            "tags":      tags,
            "push_time": a["push_time"],
        })

    if not versioned:
        print(f"  SKIP  {full_ref}: no versioned artifacts found")
        return 0, 0

    versioned.sort(key=lambda x: x["push_time"], reverse=True)

    current_tag = images_in_use.get(full_ref)
    if not current_tag:
        print(f"  WARN  {full_ref}: not found in ArgoCD, skipping deletion")
        return 0, len(versioned)

    current_idx = next(
        (i for i, a in enumerate(versioned) if current_tag in a["tags"]),
        None,
    )
    if current_idx is None:
        print(f"  WARN  {full_ref}: deployed tag '{current_tag}' not found in Harbor, skipping deletion")
        return 0, len(versioned)

    keep = set(range(current_idx + 1))
    if current_idx + 1 < len(versioned):
        keep.add(current_idx + 1)

    deleted = kept = 0
    for i, artifact in enumerate(versioned):
        tag_str = ", ".join(artifact["tags"])
        if i in keep:
            print(f"  KEEP    {full_ref}:{tag_str}  (pushed: {artifact['push_time']})")
            kept += 1
        else:
            print(f"  DELETE  {full_ref}:{tag_str}  (pushed: {artifact['push_time']})")
            try:
                delete_artifact(project, repo, artifact["digest"])
                deleted += 1
            except urlerror.HTTPError as exc:
                print(f"    ERROR deleting digest {artifact['digest'][:16]}...: {exc}")

    return deleted, kept


# ─── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    print("=" * 60)
    print("  Harbor Image Cleanup")
    print("=" * 60)

    print("\n[1/4] Authenticating with ArgoCD...")
    try:
        token = argocd_login()
    except Exception as exc:
        print(f"ERROR: could not connect to ArgoCD: {exc}")
        return 1

    print("\n[2/4] Fetching images deployed by ArgoCD...")
    try:
        images_in_use = get_images_in_use(token)
    except Exception as exc:
        print(f"ERROR: could not retrieve ArgoCD applications: {exc}")
        return 1

    if not images_in_use:
        print("  No images found in use. Aborting to avoid unintended deletions.")
        return 1

    print("\n[3/4] Listing Harbor repositories...")
    try:
        projects = get_projects()
    except Exception as exc:
        print(f"ERROR: could not list Harbor projects: {exc}")
        return 1

    print(f"  Projects found: {projects}")

    print("\n[4/4] Applying retention policy...\n")
    total_deleted = total_kept = 0
    errors = False

    for project in projects:
        try:
            repos = get_repositories(project)
        except Exception as exc:
            print(f"ERROR: could not list repositories for project '{project}': {exc}")
            errors = True
            continue

        for repo in repos:
            try:
                deleted, kept = process_repository(project, repo, images_in_use)
                total_deleted += deleted
                total_kept    += kept
            except Exception as exc:
                print(f"ERROR processing {project}/{repo}: {exc}")
                errors = True

    status = "FAILURE" if errors else "SUCCESS"
    print("\n" + "=" * 60)
    print(f"  Final report")
    print(f"  Deleted : {total_deleted} images")
    print(f"  Kept    : {total_kept} images")
    print(f"  Status  : {status}")
    print("=" * 60)

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
