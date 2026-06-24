# Guía de migración a producción — Pipelines Tekton

Asumimos que en prod ya están instalados ArgoCD, cert-manager, sealed-secrets, Gitea, Harbor, Tekton + PAC e ingress controller; y que los repos `cnie-c0-infra/infra` y `cnie-c0-infra/tekton-pac-pipelines` ya existen y están configurados como Application en ArgoCD.

## 1. Contenido a portar al repo `tekton-pac-pipelines`

Copiar tal cual al repo de prod:

- [pipelines/build-scan-push.yaml](tekton-pac-pipelines/pipelines/build-scan-push.yaml)
- [pipelines/cleanup-harbor-images.yaml](tekton-pac-pipelines/pipelines/cleanup-harbor-images.yaml)
- [tasks/git-clone.yaml](tekton-pac-pipelines/tasks/git-clone.yaml)
- [tasks/kaniko-build.yaml](tekton-pac-pipelines/tasks/kaniko-build.yaml)
- [tasks/trivy-scan.yaml](tekton-pac-pipelines/tasks/trivy-scan.yaml)
- [tasks/skopeo-push.yaml](tekton-pac-pipelines/tasks/skopeo-push.yaml)
- [tasks/cleanup-harbor-images.yaml](tekton-pac-pipelines/tasks/cleanup-harbor-images.yaml)

Recomendación: taggear el repo (`v1.0.0`) para que los consumidores puedan pinear `revision`. Hoy todos resuelven `main` por `default-revision`.

## 2. Contenido a añadir al repo `infra`

| Fichero | Para qué sirve |
|---|---|
| [git-resolver-config.yaml](infra/tekton-deployments/git-resolver-config.yaml) | Config del git resolver: `default-org`, `server-url` de Gitea, secret del token |
| [tekton-pac-deployments/repositories/app.yaml](infra/tekton-pac-deployments/repositories/app.yaml) | Registra cada repo de app ante PAC (uno por app) |
| [rbac.yaml](infra/tekton-deployments/rbac.yaml) | Dos SAs por función: **`build-push-sa`** (build) con `secrets: [gitea-creds, harbor-creds]` — Tekton auto-inyecta `.git-credentials` + `~/.docker/config.json`; PAC lo inyecta como SA por defecto via `default-pipelinerun-service-account` en su ConfigMap. **`cleanup-harbor-images-sa`** (maintenance) con `imagePullSecret: harbor-creds` para tirar la imagen `tekton-cicd-tools`; referenciado explícito en su PipelineRun. + Role para que el Dashboard pueda relanzar/borrar PipelineRuns |
| [cleanup/cleanup-images-cronjob.yaml](infra/tekton-deployments/cleanup/cleanup-images-cronjob.yaml) | CronJob diario que crea un PipelineRun de `cleanup-images` |
| [cleanup/cleanup-images-pipelinerun.yaml](infra/tekton-deployments/cleanup/cleanup-images-pipelinerun.yaml) | Plantilla del PipelineRun que lanza el CronJob (vía ConfigMap) |
| [cleanup/cleanup-images.py](infra/tekton-deployments/cleanup/cleanup-images.py) | Script de retención usado por la task `cleanup-images` (vía ConfigMap) |
| [cleanup/pipelinerun-pruner-cronjob.yaml](infra/tekton-deployments/cleanup/pipelinerun-pruner-cronjob.yaml) | CronJob que borra PipelineRuns completados de más de 7 días |
| [namespace.yaml](infra/tekton-deployments/namespace.yaml) | Namespace `cnie-pipelines-as-code` (si no existe ya) |
| [kustomization.yaml](infra/tekton-deployments/kustomization.yaml) | Genera los ConfigMap `cleanup-script` y `cleanup-pipelinerun-manifest` en `cnie-pipelines-as-code` — sin esto el cleanup no funciona |

## 3. Cambios en los YAML antes de subir (los `#TBR`)

| Fichero | Línea | Qué cambiar |
|---|---|---|
| [git-resolver-config.yaml](infra/tekton-deployments/git-resolver-config.yaml#L16) | `server-url` | URL in-cluster real de Gitea en prod (si el Service vive en otro ns/nombre) |
| [tekton-pac-deployments/repositories/app.yaml](infra/tekton-pac-deployments/repositories/app.yaml#L7) | `spec.url` | URL **externa real** del repo en Gitea prod, no `127.0.0.1.nip.io`. Es la que Gitea pone en el webhook; PAC compara contra ella |
| [tekton-pac-deployments/repositories/app.yaml](infra/tekton-pac-deployments/repositories/app.yaml#L10) | `git_provider.url` | Service in-cluster de Gitea |
| [build-scan-push.yaml](tekton-pac-pipelines/pipelines/build-scan-push.yaml#L24-L28) | defaults `gitea-base` / `harbor-registry` | Solo si los Services internos cambian de nombre/puerto |
| [app/.tekton/build-scan-push.yaml](app/.tekton/build-scan-push.yaml#L29) | `storageClassName` | SC válido en prod (probablemente no `standard`) |

## 4. TLS — qué quitar cuando Harbor/ArgoCD vayan por HTTPS válido

Solo aplica si en prod el tráfico Tekton → Harbor y Tekton → ArgoCD va por TLS real. Si seguís llamando al Service in-cluster por HTTP, dejarlo como está.

- [skopeo-push.yaml:40-47](tekton-pac-pipelines/tasks/skopeo-push.yaml#L40-L47) — quitar `--src-tls-verify=false` y `--dest-tls-verify=false`.
- [cleanup-images.py:25](infra/tekton-deployments/cleanup/cleanup-images.py#L25) — quitar `disable_warnings()`.
- [cleanup-images.py:44,56,84](infra/tekton-deployments/cleanup/cleanup-images.py#L44) — quitar todos los `verify=False`.

## 5. SealedSecrets (a sellar y commitear en `infra`)

Hoy estos secretos están hechos a mano. En prod tienen que vivir en git ya sellados:

| Secret | Namespace | Claves | Lo consume |
|---|---|---|---|
| `gitea-resolver-token` | `tekton-pipelines-resolvers` | `token` | git resolver — [git-resolver-config.yaml:17-19](infra/tekton-deployments/git-resolver-config.yaml#L17-L19) |
| `pac-gitea-secret` | `cnie-pipelines-as-code` | `provider.token` (callback a Gitea), `webhook.secret` (PAC valida firma) | PAC — [app.yaml:11-16](infra/tekton-pac-deployments/repositories/app.yaml#L11-L16) |
| `gitea-creds` | `cnie-pipelines-as-code` | `username`, `password` (tipo `kubernetes.io/basic-auth`, anotación `tekton.dev/git-0=<url-gitea>`) | git-clone — Tekton inyecta auto via SA [rbac.yaml](infra/tekton-deployments/rbac.yaml) |
| `harbor-dockerconfig` | `cnie-pipelines-as-code` | `.dockerconfigjson` (tipo `kubernetes.io/dockerconfigjson`, anotación `tekton.dev/docker-0=<harbor-url>`) | `imagePullSecret` del SA + Tekton inyecta `~/.docker/config.json` auto en skopeo push |
| `harbor-creds` | `cnie-pipelines-as-code` | `url`, `username`, `password` (tipo `Opaque`) | cleanup API via secretKeyRef ([cleanup-harbor-images.yaml:37-51](tekton-pac-pipelines/tasks/cleanup-harbor-images.yaml#L37-L51)) |
| `argocd-creds` | `cnie-pipelines-as-code` | `url`, `username`, `password` | cleanup — [cleanup-harbor-images.yaml:22-36](tekton-pac-pipelines/tasks/cleanup-harbor-images.yaml#L22-L36) |

Flujo por cada secret:

1. Crear el Secret en local con los valores reales (`kubectl create secret ... --dry-run=client -o yaml > s.yaml`).
2. `kubeseal --controller-namespace=<ns-sealed-secrets> -o yaml < s.yaml > sealed.yaml`.
3. Commit en `infra/tekton-deployments/secrets/`.
4. Añadirlo al `kustomization.yaml`.

## 6. Webhook de Gitea → PAC

Por cada repo en `cnie-c0-apps` registrar el webhook en Gitea apuntando al controller de PAC:

- **URL**: la del Service/Ingress del controller PAC en prod.
- **Secret**: mismo valor que la clave `webhook.secret` de `pac-gitea-secret`.
- **Eventos**: push + pull request.

## 7. Por cada app que entre al CI

1. En `cnie-c0-apps/<app>` añadir `.tekton/build-scan-push.yaml` — copia de [app/.tekton/build-scan-push.yaml](app/.tekton/build-scan-push.yaml) con el `storageClassName` ajustado.
2. En `infra` añadir un PAC `Repository` por app (clon de [tekton-pac-deployments/repositories/app.yaml](infra/tekton-pac-deployments/repositories/app.yaml) con `name` y `spec.url` reales) y añadirlo al `kustomization.yaml`.
3. En Harbor crear el proyecto: el pipeline deriva su nombre del `gitea-org` quitando el prefijo `cnie-` vía la task `resolve-harbor-project` (`cnie-c0-apps` → `c0-apps`). Si quieres otro nombre, pásalo explícito en el param `harbor-project` — [build-scan-push.yaml](tekton-pac-pipelines/pipelines/build-scan-push.yaml).
4. Registrar el webhook (sección 6).

## 8. Orden de aplicación

1. Push del contenido al repo `tekton-pac-pipelines` (con flags TLS ajustados si aplica).
2. Commit de los SealedSecrets en `infra`.
3. Commit del subárbol de Tekton en `infra` (sección 2, con los `#TBR` resueltos).
4. ArgoCD sincroniza → namespace `cnie-pipelines-as-code` queda listo.
5. Registrar webhook en Gitea por cada repo de app.
6. Push en una app → debería dispararse el PipelineRun.

## 9. Checklist final

- [ ] `spec.url` del PAC `Repository` apunta a la URL externa real, no a `nip.io`.
- [ ] `storageClassName` del workspace `source` válido en prod.
- [ ] Flags TLS en `skopeo-push.yaml` y `cleanup-images.py` ajustados a la realidad de prod.
- [ ] Los SealedSecrets aplicados **antes** de que Argo sincronice el SA `default` (si no, se queda con `imagePullSecret` colgando).
- [ ] Tag `v1.0.0` en `tekton-pac-pipelines` (opcional, para pinear `revision` en consumidores).
- [ ] Proyecto en Harbor con el nombre derivado (`cnie-c0-apps` → `c0-apps`), o `harbor-project` explícito.
- [ ] El tag `:latest` extra que pone [skopeo-push.yaml:44-49](tekton-pac-pipelines/tasks/skopeo-push.yaml#L44-L49) es aceptable en prod (el cleanup ya lo excluye en [cleanup-images.py:135](infra/tekton-deployments/cleanup/cleanup-images.py#L135)).
