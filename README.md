# Youki — Notas de Estudo

Anotações e explicações sobre o Youki Container Runtime, coletadas durante a preparação da apresentação.

---

## Container Runtimes — Panorama

### Hierarquia de componentes

```
Docker CLI / Podman CLI
        │
        ▼
Container Engine (Docker daemon / Podman daemonless)
        │
        ▼
High-level Runtime (containerd / conmon)
        │
        ▼
Low-level OCI Runtime ← aqui ficam: runc · youki · crun · gVisor · kata
        │
        ▼
Linux Kernel (namespaces + cgroups)
```

O **low-level runtime** é quem realmente cria o container: configura namespaces, monta o filesystem, aplica cgroups e executa o processo.

### O que é o High-level Runtime

O high-level runtime é a camada entre o engine e o low-level runtime. Ele é responsável por **preparar tudo** antes de chamar o runc/youki/crun.

O que ele faz:

1. **Recebe a imagem** do engine (já baixada) e monta o filesystem em camadas (overlay)
2. **Cria o OCI bundle** — uma pasta com dois itens:
   - `rootfs/` → o filesystem do container
   - `config.json` → todas as configurações (namespaces, cgroups, capabilities, mounts)
3. **Chama o low-level runtime** passando esse bundle
4. **Gerencia o ciclo de vida** — monitora o processo, coleta o exit code, faz cleanup

```
Engine (podman)
    │
    │  "run alpine with these params"
    ▼
High-level Runtime (containerd-shim / conmon)
    │  mounts overlay filesystem
    │  generates config.json (OCI spec)
    │  creates bundle at /run/containers/...
    ▼
Low-level Runtime (youki / runc / crun)
    │  reads config.json
    │  calls clone(), mount(), pivot_root()
    ▼
Kernel
```

**Por que essa separação existe?**

O low-level runtime é intencionalmente simples — ele só faz uma coisa: pegar um bundle e criar o container. Toda a complexidade de imagens, networking, volumes e logs fica nas camadas acima. Esse é o contrato definido pela **OCI Runtime Specification** — qualquer ferramenta que gere um bundle válido pode usar qualquer low-level runtime. É por isso que trocar o youki por runc é uma linha de config: as camadas de cima não precisam saber qual runtime está embaixo.

**No Podman especificamente**, o componente que faz esse papel é o **conmon** (container monitor) — um processo C pequeno que fica rodando após o youki/runc criar o container, monitorando o processo filho e coletando logs e exit code.

---

## Os três principais runtimes OCI

| Runtime | Linguagem | Default em | Observação |
|---------|-----------|------------|------------|
| runc    | Go        | Docker, containerd | referência, battle-tested desde 2015 |
| crun    | C         | Podman (Fedora/RHEL) | mais rápido, menor overhead |
| youki   | Rust      | opt-in | memory safe, sem GC |

---

## Podman vs Docker

- **Docker** tem o `dockerd` rodando como daemon em background
- **Podman** é daemonless — não tem processo central; cada `podman run` é um processo independente
- Os dois coexistem no mesmo servidor sem conflito porque usam sockets diferentes:

```
Docker:  /var/run/docker.sock
Podman:  /run/podman/podman.sock              (rootful)
         /run/user/1000/podman/podman.sock    (rootless)
```

---

## Runtime padrão do Podman

O default do Podman **não é runc** — é **crun**.

```bash
$ podman info --format "{{.Host.OCIRuntime.Name}}"
crun
```

Isso é relevante porque a comparação mais honesta do Youki é contra o crun (Podman) e o runc (Docker).

---

## Como verificar o runtime sem container rodando

```bash
# Podman — runtime configurado no sistema
podman info --format "{{.Host.OCIRuntime.Name}}"
podman info --format "{{.Host.OCIRuntime.Path}}"

# Docker — runtime padrão
docker info | grep -i runtime

# Após subir um container — confirmar qual runtime foi usado
podman inspect <nome> --format "{{.OCIRuntime}}"
```

---

## Performance — youki vs crun vs runc

Ordem geral de startup time (medido localmente, 100 containers em sequência, **release build**):

```
crun  <  youki  <  runc
(C)      (Rust)    (Go)

crun   real 3.3s · sys 1.0s
youki  real 3.9s · sys 1.0s
runc   real 7.1s · sys 1.0s
```

- **crun ainda ganha** — mas por pouca margem (~18%)
- **youki bate o runc** — 1.8x mais rápido com release build
- **sys time igual para todos** (~1s) — o custo das syscalls do kernel é o mesmo independente do runtime
- A diferença entre dev e release build é enorme em Rust — o dev build do youki tinha 23s, o release tem 3.9s

### Dev build vs Release build

| Build | youki startup (100 containers) |
|-------|-------------------------------|
| `just youki-dev` (padrão) | ~23s |
| `just youki-release` | ~3.9s |

O dev build não tem otimizações do compilador — nunca use para benchmark ou produção. Sempre use `--release`.

### O que é Maximum Resident Set Size (RSS)

RSS é a quantidade máxima de **memória física (RAM)** que o processo ocupou durante sua execução — a porção que estava realmente na RAM, excluindo swap.

```
processo na memória
┌─────────────────────────────┐
│  código (text)              │ ← carregado na RAM
│  variáveis (stack/heap)     │ ← carregado na RAM
│  bibliotecas compartilhadas │ ← pode estar na RAM
│  páginas em swap            │ ← NÃO conta no RSS
└─────────────────────────────┘
         ↑
    isso é o RSS
```

Quando medimos `{ /usr/bin/time -v podman run --rm alpine echo hi } 2>&1 | grep "Maximum resident"`, o RSS capturado é o pico de memória do **processo do runtime** (youki/runc/crun) — não do container em si. Ou seja, quanto RAM o runtime consome só para criar e destruir o container.

### Por que não há diferença visível de RSS entre os runtimes

Na prática, o RSS medido é muito similar entre youki, runc e crun. Isso acontece por três razões:

1. **O container filho domina o RSS** — o processo `alpine echo hi` é incluído na medição. Todos os runtimes criam o mesmo processo filho, então o RSS total fica parecido.

2. **O runtime vive pouco** — o tempo de vida do processo do runtime é tão curto que o SO mal aloca páginas diferentes entre eles.

3. **O trabalho é o mesmo** — todos os runtimes executam as mesmas syscalls (clone, mount, pivot_root). O custo de memória dessas operações é igual independente da linguagem.

A vantagem do Rust em memória não está na **quantidade consumida**, mas na **segurança**: sem memory leaks, sem use-after-free, sem buffer overflows — garantido em tempo de compilação. Isso importa mais para projetos de longo prazo e ambientes de alta densidade do que para uma medição de RSS por container.

**Por que o `2>&1` precisa estar no subshell:**  `/usr/bin/time -v` escreve na stderr do próprio processo `time`, não do comando filho. O `2>&1` aplicado só ao `podman run` não captura isso. O subshell `{ }` garante que o stderr do `time` também seja redirecionado antes do pipe:

```bash
# errado — grep não encontra nada
/usr/bin/time -v podman run --rm alpine echo hi 2>&1 | grep "Maximum resident"

# correto — subshell captura stderr do time
{ /usr/bin/time -v podman run --rm alpine echo hi; } 2>&1 | grep "Maximum resident"
```

### Por que runc é mais lento?

runc é escrito em Go, que tem **garbage collector (GC)**. O GC roda automaticamente em background para liberar memória, e ocasionalmente **pausa a execução do processo** para fazer a limpeza — são as "GC pauses".

```
docker run alpine echo hi
      │
      └─▶ runc executa
              │
              ├─ setup namespaces
              ├─ monta filesystem
              ├─ ← GC pause possível aqui (alguns ms)
              └─ exec do processo final
```

**Impacto real:** para um container simples, o efeito é mínimo. runc é um processo de curta duração — ele sobe, configura o container e termina. O GC quase não tem tempo de acumular garbage. O problema aparece em **alta densidade** (centenas de containers subindo simultaneamente), onde as pausas se acumulam.

**Rust não tem esse problema** porque não tem GC. A memória é gerenciada em tempo de compilação via *ownership* — quando uma variável sai de escopo, a memória é liberada ali mesmo, sem coletor rodando em background.

### Conclusão honesta sobre performance

O argumento mais sólido do Youki **não é** performance pura — é **memory safety**. Se o único critério for velocidade de startup, crun ganha. O Youki faz sentido quando:

- Segurança de memória é prioridade (ambientes de alta densidade, multi-tenant)
- O time já trabalha com Rust
- Você quer contribuir com open-source em containers

---

## Trade-offs do Youki

### Prós
- Memory safe — o compilador Rust garante: sem use-after-free, sem buffer overflow
- Sem GC pauses — gerenciamento de memória em tempo de compilação
- Drop-in replacement para runc — funciona com Docker, Podman, containerd
- Comunidade ativa, boa experiência para contribuidores
- Codebase limpa em Rust — excelente para aprendizado

### Contras
- Mais lento que crun (C) — se velocidade pura for o único critério, crun ganha
- Menos battle-tested que runc (em produção desde 2015)
- Ainda não é default em nenhuma distro major
- Build requer Rust toolchain
- Alguns edge cases da OCI spec ainda WIP

---

## Memory Safety — por que importa

runc (Go) e crun (C) têm histórico de CVEs relacionados a bugs de memória:

- **C (crun):** gerenciamento manual de memória → use-after-free, buffer overflow possíveis
- **Go (runc):** GC gerencia a heap, mas ainda há vulnerabilidades em código unsafe e interfaces com C

**Rust** resolve isso em tempo de compilação via sistema de ownership:
- O compilador rejeita código que causaria use-after-free
- Sem necessidade de GC
- Zero-cost abstractions — segurança sem sacrificar performance

---

## Namespaces — o que são e como demonstrar

Namespaces são uma feature do **kernel Linux** que dão a um processo uma visão isolada de um recurso do sistema. O processo acha que tem aquele recurso só para ele — mas na verdade compartilha o mesmo kernel com todos os outros.

### Tipos de namespace

| Namespace | Isola | Syscall |
|-----------|-------|---------|
| PID | árvore de processos | `clone(CLONE_NEWPID)` |
| Network | interfaces, rotas, firewall | `clone(CLONE_NEWNET)` |
| Mount | filesystem tree | `clone(CLONE_NEWNS)` |
| UTS | hostname, domainname | `clone(CLONE_NEWUTS)` |
| IPC | shared memory, semáforos | `clone(CLONE_NEWIPC)` |
| User | UID/GID mapping | `clone(CLONE_NEWUSER)` |

### Demo — PID namespace

```bash
# fora do container — PID real no host
ps aux | grep alpine

# dentro do container — PID 1 (namespace isolado)
podman run --rm --runtime youki alpine cat /proc/1/status | grep -E "Name|NStgid|Pid"
# NStgid mostra o PID dentro do namespace (1)
# Pid mostra o PID real no host (ex: 12345)
```

### Demo — UTS namespace (hostname)

```bash
# hostname do host
hostname

# hostname isolado dentro do container
podman run --rm --runtime youki alpine hostname
# valor diferente — mesmo kernel, visão isolada
```

### Demo — User namespace (root inside ≠ root on host)

```bash
# dentro do container: uid=0 (root)
podman run --rm --runtime youki alpine id

# no host: usuário normal
id
# uid diferente — o "root" do container não tem privilégios no host
```

---

## cgroups — o que são e como demonstrar

cgroups (control groups) são uma feature do **kernel Linux** para **limitar e monitorar recursos** de um grupo de processos. Enquanto namespaces controlam o que um processo **vê**, cgroups controlam o que um processo pode **usar**.

### O que o runtime faz

Quando você passa `--memory 64m` para o podman, o runtime (youki/runc/crun) calcula o valor em bytes e escreve no arquivo do cgroup **antes** de iniciar o processo:

```
podman run --memory 64m alpine
    │
    ▼
youki lê config.json
youki escreve 67108864 → /sys/fs/cgroup/<id>/memory.max
    │
    ▼
kernel enforce o limite a partir desse ponto
```

### Demo — memory limit

```bash
# com limite — youki escreve o valor no cgroup
podman run --rm --runtime youki --memory 64m alpine cat /sys/fs/cgroup/memory.max
# output: 67108864  (64 * 1024 * 1024 bytes)

# sem limite — kernel default
podman run --rm --runtime youki alpine cat /sys/fs/cgroup/memory.max
# output: max
```

### Demo — CPU limit

```bash
# 0.5 CPU = 50ms de CPU a cada 100ms
podman run --rm --runtime youki --cpus 0.5 alpine cat /sys/fs/cgroup/cpu.max
# output: 50000 100000
```

### Importante — não é exclusivo do youki

Namespaces e cgroups funcionam **exatamente igual** com youki, runc ou crun. São primitivas do kernel Linux — todos os runtimes OCI-compliant produzem o mesmo resultado. O que muda entre os runtimes é a velocidade, a linguagem e a segurança do código que faz essas chamadas.

---

## Setup da Demo

Mesmo host, dois runtimes lado a lado:

```
mesmo host
├── podman  →  youki   (configurado em containers.conf)
└── docker  →  runc    (default)
```

### Confirmar runtimes antes da demo

```bash
# Podman + youki
podman info --format "{{.Host.OCIRuntime.Name}}"

# Docker + runc
docker info | grep -i runtime
```

### Benchmark de startup

```bash
# Podman + youki
time podman run --rm alpine echo hi

# Docker + runc
time docker run --rm alpine echo hi
```

### Benchmark de memória (RSS)

```bash
# Podman + youki
{ /usr/bin/time -v podman run --rm alpine echo hi; } 2>&1 | grep "Maximum resident"

# Docker + runc
{ /usr/bin/time -v docker run --rm alpine echo hi; } 2>&1 | grep "Maximum resident"
```
