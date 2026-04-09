# Presentation Script — Youki Container Runtime

---

## Demo — Namespaces &amp; cgroups (after slides 05 and 06)

### Namespaces

```bash
# PID inside vs outside — shows namespace isolation
podman run --rm --runtime youki alpine cat /proc/1/status | grep -E "Name|NStgid|Pid"
# NStgid shows PID 1 inside the container — on the host it is a different number

# hostname is isolated (UTS namespace)
podman run --rm --runtime youki alpine hostname
hostname
# different values — same kernel, isolated view

# root inside is not root on the host (User namespace)
podman run --rm --runtime youki alpine id
id
# inside: uid=0(root) — on host: your normal user
```

What to say:
> "This process thinks it is PID 1. On the host it has a completely different PID. Same kernel — just a different view. This is what a namespace does."

---

### cgroups

```bash
# run with memory limit — youki writes this to the cgroup
podman run --rm --runtime youki --memory 64m alpine cat /sys/fs/cgroup/memory.max
# output: 67108864  (64 * 1024 * 1024 bytes)

# limit CPU
podman run --rm --runtime youki --cpus 0.5 alpine cat /sys/fs/cgroup/cpu.max
# output: 50000 100000  (50ms every 100ms = 0.5 CPU)

# no limit — kernel default
podman run --rm --runtime youki alpine cat /sys/fs/cgroup/memory.max
# output: max
```

What to say:
> "That number — 67108864 — is exactly 64MB in bytes. The runtime read the config, calculated that value, and wrote it to the cgroup file before starting the process. The kernel enforces it from that point."

> "One important note: this behaviour is the same with youki, runc, or crun. Namespaces and cgroups are Linux kernel features — all OCI runtimes do the same thing here. What changes between runtimes is the speed, the language, and the memory safety of the code that does it."

---

## Borrow Checker — quick demo after slide 16

**File:** `crates/libcontainer/src/namespaces.rs`

Open this file before the talk. Two spots to show — takes under 2 minutes total.

---

### Spot 1 — Borrowed references with implicit lifetimes
**Lines:** 89–99

```rust
pub fn apply_namespaces<F: Fn(CloneFlags) -> bool>(&self, filter: F) -> Result<()> {
    let to_enter: Vec<(&CloneFlags, &LinuxNamespace)> = ORDERED_NAMESPACES
        .iter()
        .filter(|c| filter(**c))
        .filter_map(|c| self.namespace_map.get_key_value(c))
        .collect();

    for (_, ns) in to_enter {
        self.unshare_or_setns(ns)?;
    }
    Ok(())
}
```

What to say:
> "Look at the return type of `collect()` — it is a `Vec` of references: `&CloneFlags` and `&LinuxNamespace`.
> The Borrow Checker tracks that these references point into `self`. It will not compile if `to_enter` outlives `self`.
> No pointer arithmetic. No manual lifetime management. The compiler enforces it."

---

### Spot 2 — Collecting a Result from an iterator
**Lines:** 65–86

```rust
let namespace_map = namespaces
    .unwrap_or(&vec![])
    .iter()
    .map(|ns| match get_clone_flag(ns.typ()) {
        Ok(flag) => Ok((flag, ns.clone())),
        Err(err) => Err(err),
    })
    .collect::<Result<Vec<(CloneFlags, LinuxNamespace)>>>()?
    .into_iter()
    .collect();
```

What to say:
> "This iterator processes every namespace. If any one of them fails, `.collect::<Result<...>>()?` stops immediately and returns the error.
> In C this would be a for loop with a manual `if (ret < 0) return ret` on every iteration — easy to forget one.
> Here the compiler does not let you skip it. The `?` is required because the type is `Result`."

---

## Code Walkthrough — files to open in VSCode

Open the three files before the talk. Keep them on the right lines.
All files are inside `~/youki/crates/libcontainer/src/`.

---

### 1. Container State Machine
**File:** `crates/libcontainer/src/container/state.rs`
**Lines:** 18–44

What to show:
- The `ContainerStatus` enum with all possible states (Creating, Created, Running, Stopped, Paused)
- The `can_kill()` method with the `match` block

What to say:
> "In Go or C, the container state would be a number or a string. Nothing stops you from using the value 99 or 'invalid'.
> In Rust, the compiler rejects any value that is not in the enum. Invalid states become a build error — not a crash in production."

---

### 2. Namespace Setup
**File:** `crates/libcontainer/src/namespaces.rs`
**Lines:** 102–131

What to show:
- The `unshare_or_setns()` function
- The `match` on `namespace.path()`
- The `?` operator after each syscall

What to say:
> "Every syscall that can fail has a `?` at the end. If it fails, the error goes up with full context.
> No `if err != nil`. No manual return code check. The Rust compiler forces you to handle the error. You cannot forget it."

---

### 3. pivot_rootfs — critical operation
**File:** `crates/libcontainer/src/syscall/linux.rs`
**Lines:** 380–433

What to show:
- The sequence of steps: `open → pivot_root → mount → umount2 → fchdir → close`
- The `inspect_err` with a log message on each step
- The `Ok(())` at the end

What to say:
> "pivot_root is the syscall that changes the root filesystem of the container. If this fails in silence, the container can break out to the host filesystem.
> Here, every step has an error check with a log. In C this would be six manual `if (ret < 0)` blocks — easy to miss one. In Rust, the compiler does not let you skip it."

---

## Suggested order for the demo

1. Open `state.rs` → show the enum (30 seconds)
2. Open `namespaces.rs` → show the `?` in action (1 minute)
3. Open `syscall/linux.rs` → show `pivot_rootfs` (1 minute)
4. Switch to terminal → run the benchmark live

---

## Benchmark — ready to run

```bash
# check which runtime is active
podman info --format "{{.Host.OCIRuntime.Name}}"

# startup time — 100 containers (same Podman, only runtime changes)
time for i in $(seq 1 100); do podman run --runtime youki --rm alpine echo hi; done
time for i in $(seq 1 100); do podman run --runtime runc  --rm alpine echo hi; done
time for i in $(seq 1 100); do podman run --runtime crun  --rm alpine echo hi; done

# peak memory (RSS)
{ /usr/bin/time -v podman run --runtime youki --rm alpine echo hi; } 2>&1 | grep "Maximum resident"
{ /usr/bin/time -v podman run --runtime runc  --rm alpine echo hi; } 2>&1 | grep "Maximum resident"
{ /usr/bin/time -v podman run --runtime crun  --rm alpine echo hi; } 2>&1 | grep "Maximum resident"
```

Expected results (measured locally — youki release build):
```
crun:  real ~3.3s  ✓ fastest
youki: real ~3.9s  ✓ beats runc, close to crun
runc:  real ~7.1s  slowest
```
