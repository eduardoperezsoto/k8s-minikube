# ansible-node-certs

Instala y actualiza la **CA interna** (`cnie-ca`) en el *trust store* del sistema
operativo de **todos los nodos de Kubernetes** (C0 y C1), vía Ansible/SSH.

Resuelve la VLL-59: una herramienta reejecutable, disponible en explotación, que
se lanza **cada vez que rota la CA o los certificados** y los reinstala en cada
nodo de todos los clústeres.

> La CA es la misma que se hornea en la imagen de CI
> (`tekton-cicd-tools/certs/cnie-ca.crt`). Aquí cubrimos el **nodo** (su SO y, si
> se pide, containerd), no los pods.

## Por qué Ansible (y no un script en Tekton)

Instalar una CA en el trust store del nodo es una operación de **SO del host**.
Los pods de Tekton están aislados del host: para llegar al nodo necesitarían un
DaemonSet privilegiado con `hostPath` o SSH desde el pod, reinventando lo que
Ansible hace de serie. Ansible va por SSH al nodo y es idempotente. Si en el
futuro quisierais disparo automático por GitOps, lo limpio es que **un pipeline
de Tekton lance este playbook** (ver más abajo), no reimplementarlo.

## Layout

```text
ansible.cfg           # inventario, become y opciones por defecto
install-ca.yml        # playbook (autocontenido: tasks + handlers + vars)
inventory/hosts.ini   # nodos por clúster: c0, c1, kube_nodes
files/cnie-ca.crt     # la CA a instalar (reemplázala al rotar)
```

> Se mantiene como **un único playbook autocontenido** a propósito: es una
> herramienta operativa de un solo propósito, no una librería reutilizable. Si
> algún día crece (más certs, config de containerd, invocación desde varios
> sitios), se refactoriza a rol en ese momento.

## Requisitos

- Ansible en la máquina de control (`pipx install ansible` o paquete del SO).
- Acceso SSH a los nodos con un usuario con `sudo`.
- Nodos Debian/Ubuntu o RHEL-family (RHEL/Rocky/Alma). Otra familia → falla con
  mensaje claro.

## Uso

1. Rellena [inventory/hosts.ini](inventory/hosts.ini) con los nodos reales y el
   `ansible_user`.
2. Comprueba conectividad:

   ```bash
   ansible kube_nodes -m ping
   ```

3. Simulacro (no cambia nada, muestra el diff):

   ```bash
   ansible-playbook install-ca.yml --check --diff
   ```

4. Aplicar:

   ```bash
   ansible-playbook install-ca.yml                 # todos los clústeres
   ansible-playbook install-ca.yml --limit c0      # solo C0
   ansible-playbook install-ca.yml --limit c1_workers
   ```

### Rotación de la CA (lo habitual en explotación)

1. Sustituye `files/cnie-ca.crt` por la nueva CA.
2. `ansible-playbook install-ca.yml`.

Es idempotente: si la CA ya está presente e idéntica, no toca nada. Solo cuando
el fichero cambia se regenera el trust store (y, si procede, se reinicia
containerd).

### ¿Reiniciar containerd?

Por defecto **no** se reinicia el runtime (`node_ca_reload_containerd: false`),
lo más seguro en producción. Actívalo solo si el objetivo es que **containerd
confíe en la CA al hacer pull** (p. ej. de Harbor):

```bash
ansible-playbook install-ca.yml -e node_ca_reload_containerd=true
```

Con `serial: 1` se procesa nodo a nodo, evitando reiniciar todos los runtimes a
la vez.

## Disparo desde Tekton (Pipelines as Code)

La rotación se propaga sola: al hacer push de una nueva CA, PaC dispara el
pipeline `install-ca`, que clona este repo y ejecuta el playbook. Las piezas:

| Pieza | Ubicación |
| --- | --- |
| Trigger PaC (al cambiar `files/**`, `install-ca.yml`) | `.tekton/install-ca.yaml` |
| Pipeline (`git-clone` → `ansible-run`) | repo `tekton-pac-pipelines`: `pipelines/install-ca.yaml` |
| Task que ejecuta el playbook | repo `tekton-pac-pipelines`: `tasks/ansible-run.yaml` |
| Registro del repo en PaC + ServiceAccount | repo `infra`: `tekton-pac-deployments/repositories/ansible-playbooks.yaml`, `tekton-pac-deployments/pipeline-serviceaccounts.yaml` (`ansible-run-sa`) |

El `Task` usa una imagen **pública pineada** de Ansible (`alpine/ansible`), igual
que el resto de tasks (`alpine/git`, `skopeo`…). La clave SSH se inyecta como
workspace respaldado por el `Secret` `ansible-node-ssh`.

## Probar en minikube

minikube (driver docker, 1 nodo) hace de "nodo K8s". Inventario de prueba:
[inventory/minikube.ini](inventory/minikube.ini) (host `192.168.49.2`, usuario
`docker`). El runtime de minikube es docker, así que el reinicio de containerd no
aplica y `node_ca_reload_containerd` se queda en `false`.

**A) Playbook directo (rápido, valida SSH y el playbook):**

```bash
pipx install --include-deps ansible   # el devcontainer no trae ansible
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
  -i inventory/minikube.ini install-ca.yml \
  --private-key ~/.minikube/machines/minikube/id_rsa --check --diff
# quita --check para aplicar; comprueba en el nodo:
minikube ssh -- 'ls -l /usr/local/share/ca-certificates/cnie-ca.crt'
```

**B) Flujo Tekton/PaC completo:**

```bash
# Secret con la clave SSH del nodo (test: plano; prod: SealedSecret).
kubectl create secret generic ansible-node-ssh -n tekton-ci \
  --from-file=id_rsa=$HOME/.minikube/machines/minikube/id_rsa
make sync-infra && make sync-pipelines && make sync-ansible-playbooks
# rotación: edita files/cnie-ca.crt y 'make sync-ansible-playbooks' → nuevo PipelineRun
kubectl get pipelineruns -n tekton-ci --sort-by=.metadata.creationTimestamp | tail
```

### Migrar a prod

- En [.tekton/install-ca.yaml](.tekton/install-ca.yaml), cambiar el param
  `inventory` de `inventory/minikube.ini` a `inventory/hosts.ini`.
- Sustituir el `Secret` plano por un **SealedSecret** con la clave SSH real del
  usuario `ansible`.
- Opcional pero recomendado en entorno interno: **mirrorizar** `alpine/ansible`
  a Harbor (añadirla a `tekton-cicd-tools/harbor-public-images.yaml`, pipeline
  `mirror-images`) y apuntar el `image:` de `tasks/ansible-run.yaml` a Harbor,
  para no depender de registries públicos en cada ejecución.
