# k8s-cilium-ansible

Automatización con **Ansible** para desplegar un clúster de **Kubernetes** con `kubeadm` sobre **Rocky Linux 9**:

- **1 nodo master** (control plane único, sin HA) que **también ejecuta cargas de trabajo** (se le quita el taint `NoSchedule`).
- **N nodos worker** (N ≥ 1, se define al generar el inventario).
- **containerd** como runtime de contenedores (cgroup driver `systemd`).
- **Cilium** como CNI (IPAM en modo `kubernetes`, túnel VXLAN) + **Hubble** y **Hubble UI** para observabilidad de red.

> La guía rápida original está en [`Instrucciones.md`](Instrucciones.md). Este README la amplía.

---

## Índice

1. [Estructura del proyecto](#estructura-del-proyecto)
2. [Requisitos](#requisitos)
3. [Qué hace cada playbook](#qué-hace-cada-playbook)
4. [Variables configurables](#variables-configurables)
5. [Puertos de firewall](#puertos-de-firewall)
6. [Instalación paso a paso](#instalación-paso-a-paso)
7. [Verificación del clúster](#verificación-del-clúster)
8. [Hubble y Hubble UI](#hubble-y-hubble-ui)
9. [Aplicación de prueba (nginx-demo)](#aplicación-de-prueba-nginx-demo)
10. [Agregar workers después](#agregar-workers-después)
11. [Resetear el clúster](#resetear-el-clúster)
12. [Solución de problemas](#solución-de-problemas)
13. [Limitaciones y problemas conocidos](#limitaciones-y-problemas-conocidos)

---

## Estructura del proyecto

```
k8s-cilium-ansible/
├── ansible.cfg                 # Inventario por defecto, become=True, forks=10, sin host_key_checking
├── requirements.yml            # Colecciones: ansible.posix, community.general
├── setup-inventory.sh          # Script interactivo que genera inventory/hosts.ini
├── site.yml                    # Playbook principal (importa 01 → 05)
├── 01-prepare.yml              # Preparación del SO (hostname, swap, SELinux, kernel, firewalld)
├── 02-containerd.yml           # Instalación y configuración de containerd
├── 03-kubetools.yml            # Instalación de kubeadm, kubelet y kubectl
├── 04-master.yml               # kubeadm init + Cilium + Hubble en el master
├── 05-workers.yml              # kubeadm join de los workers
├── reset.yml                   # Desmantela el clúster (Cilium + kubeadm reset)
├── inventory/
│   ├── hosts.ini               # Inventario (generado por setup-inventory.sh)
│   └── group_vars/
│       ├── all.yml             # Variables globales (versión k8s, CIDRs, usuario...)
│       ├── masters.yml         # Puertos de firewall del master
│       └── workers.yml         # Puertos de firewall de los workers
├── manifests/
│   └── nginx-demo.yaml         # Deployment + Service NodePort (30080) de prueba
├── Instrucciones.md            # Guía rápida original
└── README.md                   # Este archivo
```

### Flujo de `site.yml`

```
01-prepare     →  todos los nodos (grupo k8s)
02-containerd  →  todos los nodos
03-kubetools   →  todos los nodos
04-master      →  grupo masters   (kubeadm init, Cilium, Hubble)
05-workers     →  grupo workers   (kubeadm join)
```

---

## Requisitos

### Nodos (master y workers)

| Requisito | Detalle |
|-----------|---------|
| Sistema operativo | Rocky Linux 9 (o compatible RHEL 9: AlmaLinux 9, RHEL 9) |
| Arquitectura | `x86_64` / `amd64` por defecto (ver `cilium_cli_arch`) |
| CPU / RAM | Mínimo **2 vCPU** y **2 GB RAM** por nodo (requisito de kubeadm); se recomiendan 4 GB en el master |
| Red | Todos los nodos deben verse entre sí por IP y tener **salida a Internet** (repos de Docker, pkgs.k8s.io, GitHub, registros de imágenes) |
| Unicidad | Hostname, dirección MAC y `product_uuid` únicos por nodo (importante si clonas VMs) |
| firewalld | Instalado (el playbook lo habilita y arranca) |
| Usuario | Usuario `ansible` con sudo sin contraseña (ver paso 1) |

### Nodo de control de Ansible

Según `Instrucciones.md`, Ansible se ejecuta **desde el propio master01** con el usuario `ansible`. Necesita:

- `ansible-core` (en Rocky 9: `sudo dnf install -y ansible-core`)
- Las colecciones de `requirements.yml`
- Acceso SSH por llave a **todos** los nodos, **incluido él mismo**

---

## Qué hace cada playbook

### `01-prepare.yml` — Preparación del sistema (todos los nodos)
- Define el hostname de cada nodo según el nombre en el inventario.
- Registra todos los nodos en `/etc/hosts` (así `control_plane_endpoint` se resuelve sin DNS).
- Desactiva el swap y lo comenta en `/etc/fstab`.
- Pone SELinux en modo **permissive**.
- Carga y persiste los módulos `overlay` y `br_netfilter`.
- Ajusta sysctl: `net.bridge.bridge-nf-call-iptables`, `net.bridge.bridge-nf-call-ip6tables`, `net.ipv4.ip_forward` = 1.
- Activa **firewalld**, abre los puertos del rol (`fw_ports`), agrega `pod_cidr` y `service_cidr` a la zona `trusted` y habilita masquerade.

### `02-containerd.yml` — Runtime de contenedores (todos los nodos)
- Agrega el repositorio de Docker CE y instala `containerd.io`.
- Genera `/etc/containerd/config.toml` por defecto (solo si aún no tiene configuración CRI).
- Configura `SystemdCgroup = true` y reinicia containerd si hubo cambios.

### `03-kubetools.yml` — Herramientas de Kubernetes (todos los nodos)
- Agrega el repositorio oficial `pkgs.k8s.io` para la versión `k8s_minor`.
- Instala `kubelet`, `kubeadm` y `kubectl` (los paquetes quedan excluidos del repo para evitar actualizaciones accidentales con `dnf update`).
- Habilita `kubelet`.

### `04-master.yml` — Control plane + CNI (grupo `masters`)
- Ejecuta `kubeadm init` con `control_plane_endpoint`, la IP del master, `pod_cidr` y `service_cidr` (idempotente: se omite si ya existe `/etc/kubernetes/admin.conf`).
- Copia el kubeconfig a `/home/<ansible_user>/.kube/config`.
- Quita el taint `node-role.kubernetes.io/control-plane:NoSchedule` → **el master también recibe pods**.
- Instala `tar` y `gzip` (necesarios para descomprimir cilium-cli; suelen faltar en instalaciones mínimas) y descarga la última versión estable de **cilium-cli** a `/usr/local/bin/cilium`.
- Instala **Cilium** (`cilium install --set ipam.mode=kubernetes`) y habilita **Hubble + Hubble UI** (`cilium hubble enable --ui`), solo si Cilium no estaba instalado.
- Espera a que Cilium esté listo y a que el nodo pase a `Ready`.

### `05-workers.yml` — Unión de workers (grupo `workers`)
- Genera un token de join en el master (`kubeadm token create --print-join-command`).
- Ejecuta `kubeadm join` en cada worker (se omite si ya existe `/etc/kubernetes/kubelet.conf`).
- Espera a que cada worker quede `Ready`.

### `reset.yml` — Desmantelar el clúster (todos los nodos)
- Desinstala Cilium (desde el master), ejecuta `kubeadm reset -f`, borra `/etc/cni/net.d` y `~/.kube`, y elimina las interfaces `cilium_host`, `cilium_net` y `cilium_vxlan`.

---

## Variables configurables

Archivo `inventory/group_vars/all.yml`:

| Variable | Valor por defecto | Descripción |
|----------|-------------------|-------------|
| `ansible_user` | `ansible` | Usuario SSH con sudo en todos los nodos (lo ajusta `setup-inventory.sh`) |
| `k8s_minor` | `v1.36` | Versión menor de Kubernetes (define el repositorio de `pkgs.k8s.io`) |
| `control_plane_endpoint` | `k8s.master01` | Endpoint del API server; igual al hostname del master (lo ajusta `setup-inventory.sh`) |
| `pod_cidr` | `10.244.0.0/16` | Red de pods. kubeadm la asigna y Cilium la usa vía `ipam.mode=kubernetes` |
| `service_cidr` | `10.96.0.0/12` | Red de servicios (ClusterIP) |
| `cilium_cli_arch` | `amd64` | Arquitectura del binario cilium-cli (`amd64` o `arm64`) |

> ⚠️ `pod_cidr` y `service_cidr` **no deben solaparse** con la red física de los nodos (en el ejemplo, `192.168.6.0/24`).

Archivos `inventory/group_vars/masters.yml` y `workers.yml`: lista `fw_ports` con los puertos que se abren en firewalld (ver siguiente sección).

### Inventario (`inventory/hosts.ini`)

Lo genera `setup-inventory.sh`, pero también puede editarse a mano:

```ini
[masters]
k8s.master01 ansible_host=192.168.6.128

[workers]
k8s.worker01 ansible_host=192.168.6.129
k8s.worker02 ansible_host=192.168.6.130

[k8s:children]
masters
workers
```

- El nombre de cada host se usa como **hostname del nodo** y como **nombre del nodo en Kubernetes**.
- Solo se soporta **un** host en `[masters]`.

---

## Puertos de firewall

| Puerto | Protocolo | Master | Worker | Uso |
|--------|-----------|:------:|:------:|-----|
| 6443 | TCP | ✅ | | API server de Kubernetes |
| 2379-2380 | TCP | ✅ | | etcd |
| 10250 | TCP | ✅ | ✅ | kubelet API |
| 10256 | TCP | | ✅ | Health check de kube-proxy |
| 10257 | TCP | ✅ | | kube-controller-manager |
| 10259 | TCP | ✅ | | kube-scheduler |
| 8472 | UDP | ✅ | ✅ | Túnel VXLAN de Cilium |
| 4240 | TCP | ✅ | ✅ | Health checks de Cilium entre nodos |
| 4244 | TCP | ✅ | ✅ | Servidor Hubble (agente ← Hubble Relay) |
| 30000-32767 | TCP | ✅ | ✅ | Servicios NodePort |

Además, `pod_cidr` y `service_cidr` se agregan a la zona `trusted` y se habilita **masquerade**.

---

## Instalación paso a paso

### 1. Crear el usuario `ansible` en **todos** los nodos (como root)

```bash
useradd -m ansible
passwd ansible
echo 'ansible ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/ansible
chmod 0440 /etc/sudoers.d/ansible
```

### 2. Preparar Ansible en el master01 (como usuario `ansible`)

```bash
sudo dnf install -y ansible-core          # si aún no está instalado
cd ~/k8s-ansible                          # o donde hayas copiado el proyecto
ansible-galaxy collection install -r requirements.yml
```

### 3. Distribuir la llave SSH a todos los nodos (incluido el propio master)

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id ansible@192.168.6.128   # master (sí, a sí mismo)
ssh-copy-id ansible@192.168.6.129   # worker 1
ssh-copy-id ansible@192.168.6.130   # worker 2
# ... repetir para cada worker
```

### 4. Generar el inventario

```bash
./setup-inventory.sh
```

El script pregunta interactivamente:

1. Usuario SSH (por defecto `ansible`)
2. Hostname del master (por defecto `k8s.master01`) y su IP
3. Número de workers (por defecto `2`)
4. Hostname (por defecto `k8s.workerNN`) e IP de cada worker

Resultado: **sobrescribe** `inventory/hosts.ini` y actualiza `ansible_user` y `control_plane_endpoint` en `inventory/group_vars/all.yml`.

> El script puede ejecutarse desde cualquier ruta (hace `cd` a su propio directorio).

### 5. Verificar conectividad

```bash
ansible k8s -m ping
```

Todos los nodos deben responder `pong`.

### 6. (Opcional) Limpiar un clúster previo

```bash
ansible-playbook reset.yml
```

### 7. Desplegar el clúster

```bash
ansible-playbook site.yml
```

También se pueden ejecutar las fases por separado, en orden:

```bash
ansible-playbook 01-prepare.yml
ansible-playbook 02-containerd.yml
ansible-playbook 03-kubetools.yml
ansible-playbook 04-master.yml
ansible-playbook 05-workers.yml
```

Útiles para depurar: `--check` (simulación), `-v`/`-vvv` (más detalle), `--limit <host>`.

---

## Verificación del clúster

En el master, como usuario `ansible` (ya tiene su `~/.kube/config`):

```bash
kubectl get nodes -o wide              # todos los nodos en Ready
kubectl get pods -A                    # pods del sistema en Running
cilium status                          # estado de Cilium, Hubble Relay y Hubble UI
```

Prueba de conectividad completa de Cilium (tarda varios minutos y crea namespaces `cilium-test*`):

```bash
cilium connectivity test
kubectl get ns | grep cilium-test      # al terminar, borrarlos:
kubectl delete ns <nombre-del-namespace>
```

---

## Hubble y Hubble UI

El playbook habilita **Hubble Relay** y **Hubble UI**, pero **no** instala el cliente de línea de comandos `hubble`.

### Instalar la CLI de Hubble (en el master)

```bash
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/main/stable.txt)
HUBBLE_ARCH=amd64
curl -L --fail --remote-name-all \
  https://github.com/cilium/hubble/releases/download/$HUBBLE_VERSION/hubble-linux-${HUBBLE_ARCH}.tar.gz{,.sha256sum}
sha256sum --check hubble-linux-${HUBBLE_ARCH}.tar.gz.sha256sum
sudo tar xzvfC hubble-linux-${HUBBLE_ARCH}.tar.gz /usr/local/bin
rm hubble-linux-${HUBBLE_ARCH}.tar.gz{,.sha256sum}
```

### Observar flujos de red

```bash
cilium hubble port-forward &           # expone Hubble Relay en localhost:4245
hubble status
hubble observe                         # flujos en tiempo real
hubble observe --namespace default --follow
```

### Acceder a Hubble UI

**Opción A — port-forward** (desde el master):

```bash
cilium hubble ui                       # abre localhost:12000
```

Para abrirlo desde otra máquina de la red:

```bash
sudo firewall-cmd --add-port=12000/tcp     # temporal
kubectl -n kube-system port-forward svc/hubble-ui 12000:80 --address 0.0.0.0
# Navegador: http://192.168.6.128:12000
```

**Opción B — NodePort** (permanente, el rango 30000-32767 ya está abierto):

```bash
kubectl -n kube-system patch svc hubble-ui -p '{"spec":{"type":"NodePort"}}'
kubectl -n kube-system get svc hubble-ui   # ver el puerto asignado (3xxxx)
# Navegador: http://<IP-de-cualquier-nodo>:<nodePort>
```

---

## Aplicación de prueba (nginx-demo)

`manifests/nginx-demo.yaml` crea un Deployment de 2 réplicas de nginx y un Service NodePort en el puerto **30080**.

```bash
kubectl apply -f manifests/nginx-demo.yaml
kubectl get pods -o wide -l app=nginx-demo
curl http://192.168.6.128:30080        # funciona con la IP de cualquier nodo
```

Con Hubble puedes ver el tráfico:

```bash
hubble observe --label app=nginx-demo --follow
```

Eliminar:

```bash
kubectl delete -f manifests/nginx-demo.yaml
```

---

## Agregar workers después

1. En el nuevo nodo, crear el usuario `ansible` (paso 1) y copiarle la llave SSH desde el master (paso 3).
2. Agregar el nodo a `[workers]` en `inventory/hosts.ini` (a mano; **no** vuelvas a ejecutar `setup-inventory.sh` si no quieres reescribir el inventario completo).
3. Ejecutar la preparación en **todos** los nodos (para que `/etc/hosts` se actualice en todos) y las fases 02-03 y 05 sobre el nuevo worker:

```bash
ansible-playbook 01-prepare.yml
ansible-playbook 02-containerd.yml 03-kubetools.yml --limit k8s.worker03
ansible-playbook 05-workers.yml
```

> No es necesario ejecutar `04-master.yml` de nuevo. Como alternativa, también puedes volver a ejecutar `ansible-playbook site.yml` completo: los playbooks son re-ejecutables y omiten lo que ya está instalado (kubeadm init, Cilium, joins existentes).

---

## Resetear el clúster

```bash
ansible-playbook reset.yml
```

**Qué limpia:** Cilium, estado de kubeadm (`/etc/kubernetes`, etcd, etc.), `/etc/cni/net.d`, `~/.kube` e interfaces de Cilium.

**Qué NO limpia:** paquetes instalados (containerd, kubeadm, kubelet, kubectl, cilium-cli), reglas de firewalld, entradas de `/etc/hosts`, configuración de SELinux/sysctl/swap. Esto permite volver a ejecutar `site.yml` directamente después del reset.

---

## Solución de problemas

| Síntoma | Causa probable / Solución |
|---------|---------------------------|
| `ansible k8s -m ping` falla con `Permission denied` | La llave SSH no se copió a ese nodo (incluido el propio master). Repetir `ssh-copy-id`. |
| `Missing sudo password` | Falta `/etc/sudoers.d/ansible` con `NOPASSWD` en ese nodo. |
| Error `couldn't resolve module/action 'ansible.posix...'` | No se instalaron las colecciones: `ansible-galaxy collection install -r requirements.yml`. |
| `kubeadm init` falla en preflight | Revisar CPU/RAM mínimos, swap y que el puerto 6443 no esté en uso. Ver `journalctl -u kubelet`. |
| Nodos en `NotReady` | Cilium aún no está listo: `cilium status`, `kubectl -n kube-system get pods -l k8s-app=cilium`. Revisar que el puerto 8472/udp esté abierto entre nodos. |
| Pods de distintos nodos no se comunican | Firewall entre nodos (8472/udp, 4240/tcp) o `pod_cidr` solapado con la red física. |
| `kubeadm join` falla | Verificar que el worker resuelve `control_plane_endpoint` (`/etc/hosts`) y alcanza `<IP-master>:6443`. |
| Hubble UI sin datos | `cilium status` debe mostrar Hubble Relay `OK`; verificar el puerto 4244/tcp entre nodos. |
| Error al descomprimir cilium-cli (`unable to find required 'tar'` o similar) | El playbook ya instala `tar` y `gzip` automáticamente. Si persiste, instalarlos a mano en el master: `sudo dnf install -y tar gzip`. |
| Nodos clonados con problemas raros | `product_uuid` o MAC duplicados: `cat /sys/class/dmi/id/product_uuid`, `ip link`. |

Logs útiles:

```bash
journalctl -u kubelet -f
journalctl -u containerd -f
kubectl -n kube-system logs ds/cilium
```

---

## Limitaciones y problemas conocidos

- **Un solo master:** no hay alta disponibilidad del control plane. Aunque se usa `--control-plane-endpoint` (lo que facilitaría migrar a HA en el futuro), los playbooks solo inicializan `groups['masters'][0]`.
- **Versiones no fijadas:** cilium-cli se descarga en su última versión estable, y esta instala la versión de Cilium que trae por defecto. Kubernetes se fija solo a nivel de versión menor (`k8s_minor`).
- **SELinux en permissive** y **kube-proxy** activo (Cilium no se configura en modo *kube-proxy replacement*).
- El kubeconfig se copia a `/home/<ansible_user>/.kube`, por lo que se asume que el home del usuario está en `/home`.
- **Hubble UI solo es accesible dentro del clúster:** el servicio `hubble-ui` se crea como `ClusterIP`. Para abrirlo desde fuera hay que usar port-forward (el puerto 12000 no se abre por defecto en el firewall) o cambiar el servicio a `NodePort`. Ver [Hubble y Hubble UI](#hubble-y-hubble-ui).
