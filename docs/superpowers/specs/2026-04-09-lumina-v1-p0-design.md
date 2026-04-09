# Lumina v1 P0 Design Spec

> Sessions, Custom Images, Persistent Volumes, VM-to-VM Networking.
> Informed by roundtable debate (Carmack, Hickey, PG) on 2026-04-09.
> Revised after roundtable spec review — fixes for IPC protocol, DiskClone, volumes, networking.

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

NDJSON over Unix domain socket. **This is a separate protocol from the vsock guest protocol** — different senders, different semantics. Defined as `SessionMessage` types in `SessionProtocol.swift`, distinct from `HostMessage`/`GuestMessage` in `Protocol.swift`.

The session server translates between the two: it receives `SessionMessage` from the CLI client, dispatches to the VM actor via the existing `CommandRunner` vsock protocol, and relays results back as `SessionMessage` responses.

**Client → Server messages (`SessionRequest`):**
```
{"type":"exec","cmd":"...","timeout":30,"env":{}}
{"type":"upload","local_path":"/host/file","remote_path":"/guest/file"}
{"type":"download","remote_path":"/guest/file","local_path":"/host/file"}
{"type":"shutdown"}
```

**Server → Client messages (`SessionResponse`):**
```
{"type":"output","stream":"stdout","data":"..."}
{"type":"exit","code":0,"duration_ms":150}
{"type":"error","message":"session_dead"}
{"type":"upload_done","path":"/guest/file"}
{"type":"download_done","path":"/host/file"}
```

### Session crash recovery

**VM crash during exec:** The session server detects EOF on the vsock connection (CommandRunner returns `.connectionFailed`). It returns `{"type":"error","message":"vm_crashed","serial_log_tail":"..."}` to the client. The session enters a terminal `dead` state — no restart, no implicit recovery. The client must start a new session.

**Session process crash (SIGKILL/OOM):** The Unix socket disappears. Next `lumina exec` or `lumina session list` detects stale PID via `kill(pid, 0)`, cleans up the session directory and COW clone, returns `{"error":"session_dead","sid":"..."}`.

**SIGTERM/SIGINT on session process:** Graceful VM shutdown + COW clone removal (reuses existing signal handling).

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

**Note:** `--volume` is only valid on `session start`, not on `exec`. VirtioFS shares are boot-time configuration — they cannot be added to a running VM. Volumes must be declared when the session is created.

### What changes in existing code

| File | Change |
|------|--------|
| `Sources/Lumina/SessionProtocol.swift` | **New.** `SessionRequest`/`SessionResponse` enums + NDJSON encode/decode (separate from vsock `Protocol.swift`) |
| `Sources/Lumina/SessionServer.swift` | **New.** Unix socket listener, accepts IPC connections, translates SessionMessages to CommandRunner calls |
| `Sources/Lumina/SessionClient.swift` | **New.** Connects to session socket, sends SessionRequest, receives SessionResponse stream |
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

Boot a VM from base image, run setup command, save modified rootfs as new named image. `ImageStore.create()` handles the entire image creation lifecycle — DiskClone stays purely ephemeral.

### Image creation flow

1. Resolve base image via `ImageStore.resolve(name:)`
2. Create COW clone via `DiskClone.create()`
3. Boot VM, exec the setup command, wait for exit code 0
4. On success: `ImageStore.create(name:from:rootfsSource:command:)` does:
   a. Create staging dir at `~/.lumina/images/.tmp-<uuid>/`
   b. Copy COW clone's `rootfs.img` (via `DiskClone.rootfs` public property) into staging dir
   c. Create symlinks to base image's `vmlinuz`, `initrd`, `modules/`, `lumina-agent`
   d. Write `meta.json` with lineage info
   e. Atomic `rename()` staging dir to `~/.lumina/images/<new_name>/`
5. DiskClone gets normal `remove()` — it stays ephemeral, no `promote()` method
6. On failure: delete COW clone, clean up staging dir if it exists, report error

**Atomicity:** The staging-dir + `rename()` pattern ensures no partial images. If the process crashes mid-creation, the `.tmp-*` dir is cleaned up on next `ImageStore` operation (same pattern as `DiskClone.cleanOrphans()`).

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
| `Sources/Lumina/ImageStore.swift` | Add `create(name:from:rootfsSource:command:)` with staging-dir atomicity, `remove(name:)` with dependency checking, `inspect(name:)` |
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

# Use with sessions (volumes declared at session start, not exec — VirtioFS is boot-time only)
lumina session start --volume cache:/root/.cache --volume data:/mnt/data
lumina exec $sid "python3 train.py"
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

`VZFileHandleNetworkDeviceAttachment` provides file descriptors for raw ethernet frame I/O. VZ emulates an Ethernet device — frames, not streams — so the file descriptors **must be datagram sockets**. Each VM-to-switch connection uses:

```swift
var fds: [Int32] = [0, 0]
socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds)
// fds[0] → given to VZFileHandleNetworkDeviceAttachment (VM side)
// fds[1] → owned by NetworkSwitch (relay side)
```

**Critical:** `SOCK_DGRAM` is required, not `SOCK_STREAM`. VZ writes complete Ethernet frames as individual datagrams. Stream sockets lose frame boundaries and silently corrupt the network — the VM's network stack hangs with no useful error.

A userspace `NetworkSwitch` reads datagrams from each VM's relay fd and writes them to all other VMs' relay fds (simple hub/broadcast model). Each networked VM gets two interfaces:
- `eth0` — NAT (existing `VZNATNetworkDeviceAttachment`) for internet access
- `eth1` — Private network via `VZFileHandleNetworkDeviceAttachment` for VM-to-VM

### VMOptions wiring

`VMOptions` gains an optional `privateNetworkFd: FileHandle?` field. When set, `VM.boot()` creates a second `VZVirtioNetworkDeviceConfiguration` with `VZFileHandleNetworkDeviceAttachment(fileHandle: privateNetworkFd)` and appends it to `config.networkDevices`. The existing NAT device remains at index 0 (eth0); the private network becomes index 1 (eth1).

### IP assignment and DNS

- IPs assigned deterministically from `192.168.100.0/24` by session index (`.2`, `.3`, `.4`, ...)
- DNS via `/etc/hosts` injection into the initrd overlay

### InitrdPatcher changes

`InitrdPatcher.createCombinedInitrd` gains a new parameter: `networkHosts: [String: String]?` — a hostname-to-IP mapping (e.g., `["db": "192.168.100.2", "api": "192.168.100.3"]`). When non-nil:

1. A `/lumina-hosts` file is added as a cpio entry containing the hosts file content
2. The `customInitScript()` inner init (`/sysroot/sbin/lumina-init`) gains lines to:
   - Copy `/lumina-hosts` to `/sysroot/etc/hosts` (alongside the rootfs mount)
   - Configure `eth1` with the assigned static IP via `ip addr add <ip>/24 dev eth1 && ip link set eth1 up`
3. The assigned IP is passed via kernel cmdline: `lumina_ip=192.168.100.2`

This is a non-trivial addition to `InitrdPatcher` — estimated ~40 lines of init script changes and ~15 lines of cpio generation.

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
| `Sources/Lumina/NetworkSwitch.swift` | **New.** ~200 lines. Userspace SOCK_DGRAM relay between VM file handle pairs (hub model) |
| `Sources/Lumina/Network.swift` | **New.** Network actor: manages switch + session registry + IP assignment + hosts generation |
| `Sources/Lumina/Lumina.swift` | Add `Lumina.withNetwork()` convenience |
| `Sources/Lumina/VM.swift` | Support optional `privateNetworkFd` — creates second `VZVirtioNetworkDeviceConfiguration` with `VZFileHandleNetworkDeviceAttachment` |
| `Sources/Lumina/Types.swift` | Add `privateNetworkFd: FileHandle?` to `VMOptions` |
| `Sources/Lumina/InitrdPatcher.swift` | Add `networkHosts: [String: String]?` param to `createCombinedInitrd`. New cpio entry for `/lumina-hosts`. Init script changes: copy hosts file, configure eth1 with static IP from `lumina_ip` cmdline param (~55 new lines) |
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
| `SessionProtocol.swift` | ~120 | `SessionRequest`/`SessionResponse` enums + NDJSON codec |
| `SessionServer.swift` | ~250 | Unix socket listener, translates SessionMessages → CommandRunner |
| `SessionClient.swift` | ~150 | Connect to session, send SessionRequest, receive SessionResponse |
| `Session.swift` | ~100 | Metadata, paths, PID management |
| `VolumeStore.swift` | ~100 | Named volume CRUD |
| `NetworkSwitch.swift` | ~200 | Userspace SOCK_DGRAM ethernet relay |
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
     │                  └─ ImageStore.create (staging dir atomicity) + image CLI
     └─ SessionServer + SessionClient + session CLI + exec subcommand
```

Each step builds on the last. Sessions are the foundation — custom images, volumes, and networking all integrate with sessions.

### Concurrency notes

**ImageStore concurrent access:** Two concurrent `image create` calls could race on the same image name. The staging-dir + atomic `rename()` pattern handles this — last writer wins, no partial images. Two concurrent `Lumina.run()` calls resolving the same image for read is safe (APFS COW clone from a read-only source).

**Guest agent lifespan:** The existing guest agent (`Guest/lumina-agent/main.go`) already supports multiple exec requests per connection via its `for scanner.Scan()` command loop. No guest agent changes are needed for sessions — the agent stays connected and accepts sequential exec messages. The heartbeat mechanism (5s keepalive when idle) keeps the vsock connection alive between execs.
