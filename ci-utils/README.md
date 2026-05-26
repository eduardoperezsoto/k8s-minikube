# ci-utils

Single image with Python utilities used by the CI Tasks. One image, multiple
scripts; each Task picks which script to run by passing it in `args`.

## Layout

```
Dockerfile           # ENTRYPOINT = python; copies scripts/ to /app/scripts/
.tekton/             # PAC: build + scan + push of the image
scripts/
└── cleanup_images.py  # Harbor retention cleanup driven by ArgoCD-deployed versions
```

## How to use it from a Task

`image:` points at the image and `args:` selects the script to run:

```yaml
steps:
  - name: cleanup
    image: harbor.harbor.svc.cluster.local:80/cnie-c0-infra/ci-utils:latest
    args: ["/app/scripts/cleanup_images.py"]
    env:
      - name: ARGOCD_URL
        valueFrom: { secretKeyRef: { name: argocd-credentials, key: argocd-url } }
      # ...
```

## Build

Every push to `main` triggers `build-scan-push` (via PAC) and publishes the
image to Harbor tagged with the commit SHA plus `latest`.

## Adding a new script

1. Create `scripts/<name>.py`.
2. Push → the image is rebuilt with the new script baked in.
3. Create or update the Task referencing `args: ["/app/scripts/<name>.py"]`.
