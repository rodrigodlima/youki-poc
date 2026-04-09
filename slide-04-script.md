# Slide 04 — The Container Stack · Speaking Script

---

"Before I talk about youki, I want to show you where it lives inside the container world."

---

## CLI — podman · docker · nerdctl

"When you type `podman run`, you are using the CLI. It is just the tool you type commands in. It does not do the hard work."

**Note:** podman is daemonless — it does the CLI and the engine work in the same process, with no daemon running in the background. So with podman, the stack is shorter: podman calls conmon directly, no container engine in between.

---

## Container Engine — containerd · dockerd

"The CLI calls the engine. The engine takes care of images, networks, and volumes. It is the brain."

---

## High-level Runtime — conmon · cri-o

"The engine calls conmon. conmon is a small process that stays alive while the container runs. It is the one that gives you logs and lets you run commands inside the container."

---

## Low-level Runtime — youki  ← WE ARE HERE

"And here is youki. The low-level runtime gets a folder with a config file and does one thing: it creates the container — sets up the isolation — and then it exits. Small piece, but this is where the real work happens."

---

## Linux Kernel — namespaces · cgroups · seccomp

"Under everything, it is the Linux kernel that does the actual isolation. youki just knows how to talk to it."

---

## Key point

"youki only replaces this one piece at the bottom. Everything above — podman, containerd, conmon — stays the same. You just swap this part."
