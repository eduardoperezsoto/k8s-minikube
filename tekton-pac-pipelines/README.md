# tekton-pac-pipelines

Reusable Tekton Pipeline and Task definitions used by every app in the
`cnie-c0-apps` org. Fetched on demand by the Tekton git resolver — these
manifests are **not** applied to the cluster directly.

## Layout

```
pipelines/    # Pipeline definitions
tasks/        # Task definitions referenced by the Pipelines
```

## How it is consumed

1. Each app repo has a `.tekton/build-scan-push.yaml` (PaC PipelineRun) that
   references a Pipeline here via the git resolver:

   ```yaml
   pipelineRef:
     resolver: git
     params:
       - name: repo
         value: tekton-pac-pipelines
       - name: pathInRepo
         value: pipelines/build-scan-push.yaml
   ```

2. The resolver looks up `org` (default `cnie-c0-infra`) and `revision`
   (default `main`) from the cluster `git-resolver-config` ConfigMap.

3. The Pipeline in turn references the Tasks here through the same resolver.

## Adding a new Task or Pipeline

1. Add the YAML under `tasks/` or `pipelines/`.
2. Open a PR; merge to `main`.
3. Reference it from an app's `.tekton/` (or from another Pipeline) using:

   ```yaml
   resolver: git
   params:
     - name: repo
       value: tekton-pac-pipelines
     - name: pathInRepo
       value: tasks/<your-task>.yaml
   ```

No cluster apply needed — the next PipelineRun will fetch the new revision.

## Versioning

`main` is the live source. To pin an app to a specific revision, add a
`revision` param to the resolver block:

```yaml
- name: revision
  value: v1.2.0
```
