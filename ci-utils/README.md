# ci-utils

Imagen única con utilities Python para las Tasks de CI. Una imagen, varios
scripts; cada Task elige qué script ejecutar pasándolo en `args`.

## Layout

```
Dockerfile           # ENTRYPOINT = python; copia scripts/ a /app/scripts/
.tekton/             # PAC: build + scan + push de la imagen
scripts/
└── cleanup_images.py  # Limpieza retentiva de Harbor según despliegues de ArgoCD
```

## Cómo se usa desde una Task

`image:` apunta a la imagen y `args:` selecciona el script:

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

Cada push a `main` dispara `build-scan-push` (vía PAC) y publica la imagen en
Harbor con tag = commit SHA + `latest`.

## Añadir un nuevo script

1. Crear `scripts/<nombre>.py`.
2. Push → la imagen se reconstruye con el nuevo script dentro.
3. Crear/actualizar la Task referenciando `args: ["/app/scripts/<nombre>.py"]`.

## Cuándo crear una imagen distinta

Cuando el tool necesite una base distinta a `python:slim` (ej. `bitnami/kubectl`,
`hashicorp/terraform`, `node:alpine`). En ese caso, añade una subcarpeta con
su propio `Dockerfile` y configurar otro trigger PAC con path filter.
