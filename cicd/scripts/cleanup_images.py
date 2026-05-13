#!/usr/bin/env python3
"""
Cleanup old Harbor images.

Retention policy:
  - KEEP:   the version currently deployed by ArgoCD
  - KEEP:   the immediately previous version by push date (rollback target)
  - DELETE: everything else (newer undeployed versions + older ones)

Required environment variables:
  ARGOCD_URL    http://argocd.127.0.0.1.nip.io:8080
  ARGOCD_USER   admin
  ARGOCD_PASS   <password>
  HARBOR_URL    registry.127.0.0.1.nip.io:8080
  HARBOR_USER   admin
  HARBOR_PASS   <password>
"""

import os
import sys
import requests
from urllib.parse import quote

requests.packages.urllib3.disable_warnings()  # Harbor may use self-signed TLS


# ─── Config ───────────────────────────────────────────────────────────────────

ARGOCD_URL  = os.environ["ARGOCD_URL"].rstrip("/")
ARGOCD_USER = os.environ["ARGOCD_USER"]
ARGOCD_PASS = os.environ["ARGOCD_PASS"]
HARBOR_URL  = os.environ["HARBOR_URL"].rstrip("/")
HARBOR_USER = os.environ["HARBOR_USER"]
HARBOR_PASS = os.environ["HARBOR_PASS"]

# Registry host prefix as it appears in ArgoCD image references.
# Usually matches HARBOR_URL; override if a domain alias is in use.
HARBOR_REGISTRY_HOST = os.environ.get("HARBOR_REGISTRY_HOST", HARBOR_URL)


# ─── ArgoCD ───────────────────────────────────────────────────────────────────

def argocd_login() -> str:
    resp = requests.post(
        f"{ARGOCD_URL}/api/v1/session",
        json={"username": ARGOCD_USER, "password": ARGOCD_PASS},
        verify=False,
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()["token"]


def get_images_in_use(token: str) -> dict[str, str]:
    """Return {image_ref_without_tag: deployed_tag}."""
    headers = {"Authorization": f"Bearer {token}"}
    resp = requests.get(
        f"{ARGOCD_URL}/api/v1/applications",
        headers=headers,
        verify=False,
        timeout=15,
    )
    resp.raise_for_status()

    in_use: dict[str, str] = {}
    for app in resp.json().get("items", []):
        app_name = app["metadata"]["name"]
        images = app.get("status", {}).get("summary", {}).get("images", [])
        for image in images:
            if ":" not in image:
                continue
            ref, tag = image.rsplit(":", 1)
            in_use[ref] = tag
            print(f"  [ArgoCD] {app_name}: {ref}:{tag}")

    return in_use


# ─── Harbor ───────────────────────────────────────────────────────────────────

def _harbor(method: str, path: str, **kwargs):
    url = f"http://{HARBOR_URL}{path}"
    resp = requests.request(
        method,
        url,
        auth=(HARBOR_USER, HARBOR_PASS),
        verify=False,
        timeout=30,
        **kwargs,
    )
    resp.raise_for_status()
    return resp


def get_projects() -> list[str]:
    resp = _harbor("GET", "/api/v2.0/projects", params={"page_size": 100})
    return [p["name"] for p in resp.json() if not p.get("registry_id")]  # skip proxy caches


def get_repositories(project: str) -> list[str]:
    resp = _harbor(
        "GET",
        f"/api/v2.0/projects/{project}/repositories",
        params={"page_size": 100},
    )
    # Harbor returns "project/repo"; strip the project prefix
    return [r["name"].split("/", 1)[-1] for r in resp.json()]


def get_artifacts(project: str, repo: str) -> list[dict]:
    encoded = quote(repo, safe="")
    resp = _harbor(
        "GET",
        f"/api/v2.0/projects/{project}/repositories/{encoded}/artifacts",
        params={"page_size": 100, "with_tag": True},
    )
    return resp.json()


def delete_artifact(project: str, repo: str, digest: str) -> None:
    encoded_repo   = quote(repo, safe="")
    encoded_digest = quote(digest, safe="")
    _harbor("DELETE", f"/api/v2.0/projects/{project}/repositories/{encoded_repo}/artifacts/{encoded_digest}")


# ─── Retention logic ──────────────────────────────────────────────────────────

def process_repository(project: str, repo: str, images_in_use: dict[str, str]) -> tuple[int, int]:
    """Apply retention policy to one Harbor repository. Returns (deleted, kept)."""
    full_ref = f"{HARBOR_REGISTRY_HOST}/{project}/{repo}"
    artifacts_raw = get_artifacts(project, repo)

    # Keep only versioned artifacts (skip untagged and the floating 'latest' tag)
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

    # Sort by push date descending (newest first)
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

    # Keep: deployed version + the one immediately before it by push date
    keep = {current_idx}
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
            except requests.HTTPError as exc:
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
