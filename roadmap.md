# Presentation Script — Youki Container Runtime


---

## Borrow Checker — quick demo after slide 16

**File:** `crates/libcontainer/src/namespaces.rs`

Open this file before the talk. Two spots to show — takes under 2 minutes total.

---

### Spot 2 — Borrowed references
**Lines:** 89–100

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
> "The `&` symbols mean this code is borrowing data instead of copying it. Rust's Borrow Checker ensures you can never use data that no longer exists — the compiler rejects it before the code even runs."

---

## Code Walkthrough — files to open in VSCode

Open the three files before the talk. Keep them on the right lines.
All files are inside `~/youki/crates/libcontainer/src/`.

---

### 1. Container State Machine
**File:** `crates/libcontainer/src/container/state.rs`
**Lines:** 18–46

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
> "Every syscall that can fail has a `?`question mark at the end. If it fails, the error goes up with full context.
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
> Here, every step has an error check with a log. In Golang, this would be six manual `if (ret < 0)` if ret is less than zero blocks — easy to miss one. In Rust, the compiler does not let you skip it."

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
