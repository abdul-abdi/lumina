# Lumina v1 P0 Design Spec

> Sessions, Custom Images, Persistent Volumes, VM-to-VM Networking.
> Informed by roundtable debate (Carmack, Hickey, PG) on 2026-04-09.

---

## 1. Sessions (CLI-exposed lifecycle API)

### Architecture

Per-session background process + Unix domain socket. No daemon. Each session is an independent process managing one VM actor.

**Decision rationale:** Roundtable unanimous — per-session processes preserve the "no shared mutable state" invariant, contain blast radius (session crash doesn't affect others), and the process table serves as the session registry. The repo's split trigger ("persistent coordinator managing multiple VM actors") is deliberately not crossed.

### Session lifecycle

1. `lumina session start` spawns a background process (`lumina-session` subcommand)
2. Background process boots VM via existing `VM.boot()`, listens on Unix socket
3. CLI client prints session ID to stdout (JSON: `{"sid":"<uuid>"}`)
4. `lumina exec <sid> "cmd"` connects to socket, sends exec, receives streaming output
5. `lumina session stop <sid>` sends shutdown message, process exits, cleanup runs
6. `lumina session list` scans `~/.lumina/sessions/`, checks PID liveness

### Filesystem layout

```
~/.lumina/sessions/<sid>/
├── control.sock     # Unix domain socket for IPC
├── meta.json        # {"pid":1234,"image":"default","cpus":2,"memory":"512MB","created":"..."}
└── run/             # DiskClone COW clone directory (same as one-shot runs)
```

### IPC protocol (over Unix socket)

NDJSON, same shape as vsock protocol. Agent-consumer-first design.

```
Client → Server: {"type":"exec","cmd":"...","timeout":30,"env":{},"volumes":[{"name":"x","guest_path":"/mnt/x"}]}
Server → Client: {"type":"output","stream":"stdout","data":"..."}
Server → Client: {"type":"exit","code":0,"duration_ms":150}
Client → Server: {"type":"shutdown"}
```

Additional messages for file operations:
```
Client → Server: {"type":"upload","path":"/guest/path","data":"<base64>","seq":0}
Server → Client: {"type":"upload_ack","seq":0}
Client → Server: {"type":"download_req","path":"/guest/path"}
Server → Client: {"type":"download_data","path":"/guest/path","data":"<base64>"}
```

### CLI interface

```bash
sid=$(lumina session start)
sid=$(lumina session start --image python --cpus 4 --memory 1GB --volume cache:/root/.cache)
lumina exec $sid "pip install pandas"
lumina exec $sid --stream "make test"
lumina exec $sid --copy local.txt:/tmp/local.txt "cat /tmp/local.txt"
lumina exec $sid --download /tmp/result.txt:./result.txt "generate-report"
lumina session stop $sid
lumina session list                    # JSON array of session metadata
lumina session list --text             # human-readable table
```

### Failure recovery

- **Stale session detection:** On connect, if socket fails, check PID via `kill(pid, 0)`. If dead: remove session directory, clean COW clone via existing `DiskClone` orphan logic, return `{"error":"session_dead","sid":"..."}`.
- **`lumina session list`:** Marks dead sessions with `"status":"dead"`. `lumina clean` garbage-collects them.
- **SIGTERM/SIGINT on session process:** Graceful VM shutdown + COW clone removal (reuses existing signal handling).
- **Hard crash (SIGKILL/OOM):** Next `exec` or `list` detects stale PID, triggers cleanup.

### What changes in existing code

| File | Change |
|------|--------|
| `Sources/Lumina/SessionServer.swift` | **New.** Unix socket listener, accepts IPC connections, dispatches to VM actor |
| `Sources/Lumina/SessionClient.swift` | **New.** Connects to session socket, sends commands, receives output stream |
| `Sources/Lumina/Session.swift` | **New.** Session metadata, filesystem paths, PID management |
| `Sources/Lumina/Lumina.swift` | Add `Lumina.session(start:)`, `Lumina.exec(sid:)`, `Lumina.sessionStop(sid:)` |
| `Sources/Lumina/Types.swift` | Add `SessionOptions`, `SessionInfo`, `SessionState` types |
| `Sources/lumina-cli/main.swift` | Add `session start/stop/list` and `exec` subcommands |
| `Sources/lumina-cli/SessionDaemon.swift` | **New.** Entry point for background session process (`lumina-session` hidden subcommand) |

### Invariants

- Each session process manages exactly one VM actor. No multi-VM processes (except networking, see Section 4).
- No "session manager" object that coordinates across sessions. Filesystem is the registry.
- Session process must be fully functional without any other session process running.
- All session types must be `Sendable`.

---

## 2. Custom Images

### Mechanism

Boot a VM from base image, run setup command, save modified rootfs as new named image. The DiskClone COW copy is promoted to ImageStore instead of deleted.

### Image creation flow

1. Resolve base image via `ImageStore.resolve(name:)`
2. Create COW clone via `DiskClone.create()`
3. Boot VM, exec the setup command, wait for exit code 0
4. On success: copy COW clone's `rootfs.img` to `~/.lumina/images/<new_name>/`
5. Symlink shared assets from base: `vmlinuz`, `initrd`, `modules/`, `lumina-agent`
6. Write `meta.json` with lineage info
7. On failure: delete COW clone, report error

### Filesystem layout

```
~/.lumina/images/python/
├── rootfs.img           # Modified rootfs (full copy, not COW — survives base deletion)
├── vmlinuz -> ../default/vmlinuz
├── initrd -> ../default/initrd
├── modules -> ../default/modules
├── lumina-agent -> ../default/lumina-agent
└── meta.json            # {"base":"default","command":"apk add python3 py3-pip","created":"..."}
```

### CLI interface

```bash
lumina image create python --from default --run "apk add python3 py3-pip"
lumina image create ml --from python --run "pip install numpy pandas scikit-learn"
lumina image list                         # name, base, size, created
lumina image remove python                # refuses if dependents exist
lumina image inspect python               # full metadata
```

### What changes in existing code

| File | Change |
|------|--------|
| `Sources/Lumina/ImageStore.swift` | Add `create(name:from:command:)`, `remove(name:)`, `inspect(name:)`, dependency checking |
| `Sources/Lumina/DiskClone.swift` | Add `promote(to:)` — moves COW clone rootfs to target path instead of deleting |
| `Sources/Lumina/Lumina.swift` | Add `Lumina.createImage(name:from:command:)` convenience |
| `Sources/Lumina/Types.swift` | Add `ImageInfo` type (name, base, size, created, command) |
| `Sources/lumina-cli/main.swift` | Add `image create`, `image remove`, `image inspect` subcommands |

### Invariants

- Image creation is atomic: either the full image directory exists with all files, or it doesn't. No partial images.
- `image remove` refuses if other images list this as their base (check all `meta.json` files).
- The `default` image (pulled from GitHub Releases) cannot be removed.
- Image creation reuses the same VM boot path as `Lumina.run()` — no special image-building VM.

---

## 3. Persistent Volumes

### Model

Named host directories under `~/.lumina/volumes/<name>/`, mounted into VMs via existing VirtioFS plumbing. Volumes have their own lifecycle, independent of VMs and sessions.

### Filesystem layout

```
~/.lumina/volumes/<name>/
├── data/                # The actual shared directory (VirtioFS mount target)
└── meta.json            # {"created":"...","last_used":"..."}
```

### CLI interface

```bash
lumina volume create pycache
lumina volume list                                    # name, size, last_used
lumina volume remove pycache
lumina volume inspect pycache                         # size, last_used, created

# Use with one-shot runs
lumina run --volume pycache:/root/.cache/pip "pip install pandas"

# Use with sessions
lumina session start --volume cache:/root/.cache
lumina exec $sid --volume data:/mnt/data "python3 train.py"
```

### Concurrency semantics

Multiple VMs can mount the same volume simultaneously. VirtioFS is a passthrough — host filesystem semantics apply. No locking. Concurrent writes to the same file are undefined behavior (same as Docker volumes).

### What changes in existing code

| File | Change |
|------|--------|
| `Sources/Lumina/VolumeStore.swift` | **New.** ~100 lines. `create(name:)`, `remove(name:)`, `resolve(name:) -> URL`, `list()`, `inspect(name:)` |
| `Sources/Lumina/Types.swift` | Add `VolumeMount` type (name + guest path), add `volumes` field to `RunOptions` and `VMOptions` |
| `Sources/Lumina/VM.swift` | Resolve volume names to host paths, add as VirtioFS shares in `VZVirtualMachineConfiguration` |
| `Sources/lumina-cli/main.swift` | Add `volume create/list/remove/inspect` subcommands, `--volume name:path` flag |

### Invariants

- Volumes are just managed directories. No disk images, no quotas (deferred to P2).
- `volume remove` deletes the directory. No refcounting — if a VM has it mounted, the mount becomes empty.
- `last_used` updated on every VM boot that references the volume.

---

## 4. VM-to-VM Networking

### Scope

**Group-based networking only.** VMs launched together in a single process share a virtual switch. Cross-session networking (VMs from separate CLI invocations finding each other) is deferred — it requires cross-process coordination that approaches daemon territory.

### Mechanism

`VZFileHandleNetworkDeviceAttachment` provides file descriptors for raw ethernet frame I/O. A userspace `NetworkSwitch` relays frames between connected VMs via socketpairs.

Each networked VM gets two interfaces:
- `eth0` — NAT (existing `VZNATNetworkDeviceAttachment`) for internet access
- `eth1` — Private network via `VZFileHandleNetworkDeviceAttachment` for VM-to-VM

### IP assignment and DNS

- IPs assigned deterministically from `192.168.100.0/24` by session index (`.2`, `.3`, `.4`, ...)
- DNS via `/etc/hosts` injection: `InitrdPatcher` writes host entries for all peers before boot
- No dnsmasq, no dynamic DNS. Static hosts file is sufficient for group-based networks.

### Library API

```swift
try await Lumina.withNetwork("mynet") { network in
    let db = try await network.session(name: "db", image: "postgres")
    let api = try await network.session(name: "api", image: "node")
    let result = try await api.exec("curl http://db:5432")
}
// All VMs shut down, network torn down
```

### CLI interface

```bash
# From manifest file
lumina network run --file stack.json

# stack.json:
# {
#   "sessions": [
#     {"name": "db", "image": "postgres"},
#     {"name": "api", "image": "node", "volumes": ["code:/app"]}
#   ]
# }

# All sessions share a private network. Ctrl-C tears down everything.
```

### What changes in existing code

| File | Change |
|------|--------|
| `Sources/Lumina/NetworkSwitch.swift` | **New.** ~200 lines. Userspace ethernet frame relay between file handle pairs |
| `Sources/Lumina/Network.swift` | **New.** Network actor: manages switch + session registry + IP assignment + hosts generation |
| `Sources/Lumina/Lumina.swift` | Add `Lumina.withNetwork()` convenience |
| `Sources/Lumina/VM.swift` | Support optional second network interface via `VZFileHandleNetworkDeviceAttachment` |
| `Sources/Lumina/InitrdPatcher.swift` | Inject `/etc/hosts` entries for network peers |
| `Guest/lumina-agent/main.go` | Configure `eth1` with static IP if network config present (or handle in init script) |
| `Sources/lumina-cli/main.swift` | Add `network run` subcommand |

### What's explicitly deferred

- `lumina network create/remove` as standalone lifecycle commands (needs daemon)
- Cross-session networking (needs shared state across processes)
- Dynamic DNS / adding VMs to a running network
- Network policies / firewalling between VMs

### Invariants

- A `NetworkSwitch` lives within a single process. No cross-process frame relay.
- All VMs on a network are booted and managed by the same `Network` actor.
- Internet access (NAT on eth0) always works alongside private networking (eth1).
- Network teardown is automatic when the `withNetwork` scope exits.

---

## Cross-cutting concerns

### New module inventory

| Module | Lines (est.) | Purpose |
|--------|-------------|---------|
| `SessionServer.swift` | ~250 | Unix socket listener + IPC dispatch |
| `SessionClient.swift` | ~150 | Connect to session, send/receive |
| `Session.swift` | ~100 | Metadata, paths, PID management |
| `VolumeStore.swift` | ~100 | Named volume CRUD |
| `NetworkSwitch.swift` | ~200 | Userspace ethernet relay |
| `Network.swift` | ~200 | Network actor, IP assignment, hosts |

### Types additions (Types.swift)

```swift
public struct SessionOptions: Sendable { ... }
public struct SessionInfo: Sendable { ... }
public enum SessionState: String, Sendable { case running, dead }
public struct ImageInfo: Sendable { ... }
public struct VolumeMount: Sendable { ... }
public struct NetworkConfig: Sendable { ... }
```

### Testing strategy

**Unit tests (no VM required):**
- Session IPC protocol encode/decode
- Session metadata serialization
- ImageStore create/remove/dependency checking (mock filesystem)
- VolumeStore CRUD
- NetworkSwitch frame relay (mock file handles)
- IP assignment determinism
- Hosts file generation

**Integration tests (require VM):**
- Session start → exec → stop lifecycle
- Session crash recovery (kill session process, verify cleanup)
- Image create from base → use in session
- Volume mount → write file → remount in new session → read file
- Two VMs on network → ping/curl between them

### Implementation order

```
1. Sessions ──→ 2. Custom Images ──→ 3. Volumes ──→ 4. Networking
     │                  │                  │               │
     │                  │                  │               └─ NetworkSwitch + Network actor + dual-interface VM
     │                  │                  └─ VolumeStore + --volume flag + VirtioFS wiring
     │                  └─ ImageStore.create + DiskClone.promote + image CLI
     └─ SessionServer + SessionClient + session CLI + exec subcommand
```

Each step builds on the last. Sessions are the foundation — custom images, volumes, and networking all integrate with sessions.
