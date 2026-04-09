# youki — Container Runtime in Rust

`$ youki --present  # Rodrigo · March 2026`


---

## Slide 01 — Title

# youki
### Container Runtime in Rust

---

## Slide 02 — What is youki?

* **Low-level OCI runtime**
* Written in **Rust**
* Name = "container" (容器) in Japanese

---



## Slide 05 — The Container Stack

```
$ podman run alpine
         ↓
     CLI (podman · docker · kubectl)
         ↓
  Container Engine (containerd · dockerd)
         ↓
  High-level Runtime (containerd-shim · cri-o)
         ↓
▶ Low-level Runtime  ← youki
         ↓
  Linux Kernel (namespaces · cgroups · seccomp)
```

> youki replaces **only the low-level runtime** — everything above stays the same

---


## Slide 08 — DEMO: Namespaces & cgroups


---

## Slide 09 — OCI Runtime Specification


- Standard contract
- Lifecycle: `create` · `start` · `kill` · `delete`
- `config.json` — namespaces, cgroups, mounts, capabilities
- Set permanent runtime: `/etc/containers/containers.conf`

```json
// config.json (abbreviated)
{
  "process": { "args": ["/bin/sh"] },
  "linux": {
    "namespaces": [...],
    "resources": {...}
  }
}
```

---

## Slide 10 — How youki Works
Obs: Cool to demonstrate the youki using some tool on linux to show the syscalls

| Step | Action |
|------|--------|
| 1. Parse | Read config.json → validate OCI spec |
| 2. Prepare | Create state dir, set up rootfs, spec validation |
| **3. Fork** | `clone(2)` with namespace flags → child process |
| **4. Setup** | mount rootfs, configure cgroups, apply seccomp |
| **5. Exec** | `pivot_root` → drop caps → `execve(container entrypoint)` |
| 6. Track | Write PID + state, set up hooks, report back |

---

## Slide 11 — youki Architecture

```
$ podman run alpine
       ↓
crates/youki          ← CLI entry point → maps OCI commands to libcontainer calls
       ↓
crates/libcontainer   ← Core logic — namespaces, rootfs mount, seccomp, clone() + pivot_root()
       ↓
libcgroups | oci-spec-rs | nix
       ↓
Linux Kernel (clone · mount · pivot_root · cgroup files)
```

| Crate | Responsibility |
|-------|---------------|
| `crates/youki` | CLI entry point → maps OCI commands to libcontainer |
| `crates/libcontainer` | Core logic — namespaces, rootfs, seccomp, `clone()` + `pivot_root()` |
| `crates/libcgroups` | Writes limits to `/sys/fs/cgroup/` — v1 and v2 |
| `oci-spec-rs` | Parses `config.json` into typed Rust structs |
| `nix` | Safe Rust wrappers over Linux syscalls |

---

## Slide 12 — Why Rust?

> ❓ Why not Go (like runc) or C (like crun)?
> → Rust gives C-level performance + compile-time memory safety

| Property | Benefit |
|----------|---------|
| 🔒 **Memory Safety** | Ownership model — no use-after-free, no buffer overflows at runtime |
| ⚡ **No GC Pauses** | Deterministic latency — critical for a process that creates containers |
| 🧰 **C Interop** | FFI with libseccomp, libc — zero-cost syscall wrappers via `nix` |

```rust
// The borrow checker prevents entire classes of security bugs
fn setup_namespaces(spec: &Spec) -> Result<()> {
    // compile-time guarantee: no double-free, no use-after-free
    let ns = spec.linux().namespaces();  // Option<&Vec<..>>
}
```

---


---

## Slide 14 — DEMO Setup — Same Host, Three Runtimes



---

## Slide 15 — DEMO: Run & Measure

```bash
# Podman · youki — startup time (100 containers)
$ time for i in $(seq 1 100); do
  podman run --runtime youki \
  --rm alpine echo hi; done

# Podman · runc — startup time (100 containers)
$ time for i in $(seq 1 100); do
  podman run --runtime runc \
  --rm alpine echo hi; done
```

- Observe: **real time** — youki vs runc, same Podman, same image
- Only the `--runtime` flag changes

---

## Slide 16 — DEMO: Expected Results

> ❓ Is youki faster than runc?
> → yes — ~1.8x faster on startup; close to crun (only 18% slower)

### Startup time per container (100 containers avg)

| Runtime | Time |
|---------|------|
| crun | ~33ms |
| **youki** | **~39ms** |
| runc | ~71ms |

- **Startup**: youki beats runc — 1.8x faster
- **youki vs crun**: only ~18% slower — close race
- **Behavior**: identical — same container, same output
- youki gives you speed **and** memory safety

---

## Slide 17 — Code Walkthrough — Rust in Action

> ❓ What does the actual Rust code look like?
> → let's open the repo and walk through the key files

- **`container/state.rs`** — `ContainerStatus` enum — invalid states impossible at compile time
- **`namespaces.rs`** — `unshare_or_setns()` — `?` propagates errors at every syscall
- **`syscall/linux.rs`** — `pivot_rootfs()` — every step explicitly error-checked

---

## Slide 18 — youki vs runc — Features

| Feature | youki | runc | crun |
|---------|-------|------|------|
| Language | 🦀 Rust | Go | C |
| OCI Spec compliance | ✓ Full | ✓ Full | ✓ Full |
| cgroups v2 | ✓ Native | ✓ | ✓ |
| Rootless | ✓ | ✓ | ✓ |
| Seccomp / AppArmor | ✓ | ✓ | ✓ |
| Memory (idle) | ~10 MB | ~15–20 MB | ~5 MB |
| Binary size | ~8 MB | ~12 MB | ~700 KB |

---

## Slide 19 — Pros & Cons

> ❓ Should I replace runc with youki in production today?
> → depends — great for Rust-first environments; runc is safer if you need battle-tested stability

### Pros ✅
- Memory safe — compile-time guarantee
- 1.8x faster startup than runc
- Drop-in replacement for runc
- Active community + clean codebase

### Cons ⚠️
- Less battle-tested than runc (prod since 2015)
- Not default in major distros
- Requires Rust toolchain to build
- Slower than crun — C still wins on raw speed

---

## Slide 20 — Runtime Landscape

> ❓ Where does youki fit compared to alternatives?
> → between runc (safety) and crun (speed) — uniquely memory safe without a VM overhead

| Runtime | Language | Best for |
|---------|----------|---------|
| **runc** | Go | Default everywhere · battle-tested |
| **crun** | C | Fastest + smallest · Fedora/RHEL Podman default |
| **youki** ← we are here | Rust | Memory safe · growing community |
| **gVisor (runsc)** | Go | User-space kernel · strong sandbox (Google) |
| **Kata Containers** | — | Lightweight VMs · full kernel isolation (~1s start) |
| **Wasmtime** | Rust | WebAssembly · tiny images · platform-agnostic |

---

## Slide 21 — Q&A

> // end

# Q&A

Questions?

- slides → `youki-presentation.html`
- code → [github.com/containers/youki](https://github.com/containers/youki)
- spec → [opencontainers/runtime-spec](https://github.com/opencontainers/runtime-spec)
