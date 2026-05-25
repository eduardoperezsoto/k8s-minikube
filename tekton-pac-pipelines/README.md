# tekton-pac-pipelines

Central repository of reusable Tekton **Pipelines** and **Tasks**. The
manifests here are fetched on demand by the Tekton git resolver — they are
**not** applied to the cluster directly.

## Layout

```
pipelines/    # Pipeline definitions
tasks/        # Task definitions
```

## How it is consumed

Any PipelineRun (typically defined in a consumer repo under `.tekton/`, or
applied directly to the cluster) references a Pipeline here via the git
resolver:

```yaml
pipelineRef:
  resolver: git
  params:
    - name: repo
      value: tekton-pac-pipelines
    - name: pathInRepo
      value: pipelines/<pipeline-name>.yaml
    # - name: org         # optional; defaults to git-resolver-config default-org
    # - name: revision    # optional; defaults to git-resolver-config default-revision
```

The same mechanism is used inside Pipelines to reference Tasks:

```yaml
taskRef:
  resolver: git
  params:
    - name: repo
      value: tekton-pac-pipelines
    - name: pathInRepo
      value: tasks/<task-name>.yaml
```

The cluster `git-resolver-config` ConfigMap defines the default org, the SCM
type (Gitea, GitHub, …), the server URL and the token secret used to fetch
private content. Consumers in a different org can override the `org` param
explicitly in the resolver block.

## Adding a new Task or Pipeline

1. Add the YAML under `tasks/` or `pipelines/`.
2. Open a PR; merge to `main`.
3. Reference it from a consumer using the resolver block above.

No cluster apply needed — the next PipelineRun will fetch the new revision.

## Versioning

`main` is the live source. To pin a consumer to a specific revision, add a
`revision` param to the resolver block:

```yaml
- name: revision
  value: v1.2.0
```

Tagging the repo (`v1.0.0`, `v1.1.0`, …) is the recommended way to give
consumers a stable target while `main` keeps evolving.
