<div align="center">
<pre>
██████╗ ██╗   ██╗███████╗████████╗ ██████╗██╗████████╗██╗   ██╗
██╔══██╗██║   ██║██╔════╝╚══██╔══╝██╔════╝██║╚══██╔══╝╚██╗ ██╔╝
██████╔╝██║   ██║███████╗   ██║   ██║     ██║   ██║    ╚████╔╝ 
██╔══██╗██║   ██║╚════██║   ██║   ██║     ██║   ██║     ╚██╔╝  
██║  ██║╚██████╔╝███████║   ██║   ╚██████╗██║   ██║      ██║   
╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝    ╚═════╝╚═╝   ╚═╝      ╚═╝   
</pre>
</div>

----

# rs-ether — Elixir Sidecar for Multi-World Nodes

## Context

Each Rust node instance represents one game world. For cross-world social features (friends presence, private
messaging, friend/ignore lists), each world runs an Elixir sidecar process called **rs-ether**. The Elixir sidecars form
a BEAM cluster and communicate natively using Erlang distribution. Communication between Rust and its local Elixir
sidecar uses raw binary frames over TCP.

The Rust server automatically spawns, supervises, and kills its sidecar. If the sidecar crashes, it is restarted with
exponential backoff. On startup, the server runs `mix deps.get`, `mix ecto.create`, and `mix ecto.migrate` before
launching the sidecar.

---

## World Identification

All ports derive from `--node-id`:

| World | Node ID | Game Port  | HTTP Port | Ether Port |
|-------|---------|------------|-----------|------------|
| 1     | 10      | 43594      | 8080      | 5010       |
| 2     | 11      | 43595      | 8081      | 5011       |
| N     | 9+N     | 43584+node | 8070+node | 5000+node  |

The `node: u8` field in `UpdateFriendList` uses the node ID (10, 11, etc.) for online status, 0 for offline.

---

## Architecture Overview

```
                          ┌──────────────────────────────────────────┐
                          │           BEAM Cluster Mesh              │
                          │     (Erlang distribution via libcluster) │
                          └────┬──────────────┬──────────────┬───────┘
                               │              │              │
┌──────────────────┐    ┌──────┴───────┐ ┌────┴─────────┐ ┌──┴────────────┐
│  Game Client     │    │  Elixir      │ │  Elixir      │ │  Elixir       │
│  (browser/java)  │    │  world10@    │ │  world11@    │ │  world12@     │
└────────┬─────────┘    └──────┬───────┘ └────┬─────────┘ └───┬───────────┘
         │                     │ localhost TCP  │             │
         │ TCP/WebSocket       │               │              │
         │                ┌────┴─────────┐ ┌───┴──────────┐ ┌─┴────────────┐
         └───────────────►│  Rust World 1│ │  Rust World 2│ │  Rust World 3│
                          │  :43594      │ │  :43595      │ │  :43596      │
                          │  http:8080   │ │  http:8081   │ │  http:8082   │
                          └──────────────┘ └──────────────┘ └──────────────┘
                                                │
                                         ┌──────┴──────┐
                                         │  Postgres   │
                                         │  (shared)   │
                                         └─────────────┘
```

- Each world = 1 Rust process + 1 Elixir sidecar (spawned automatically by Rust)
- Rust talks to its local Elixir sidecar over localhost TCP with raw binary frames
- Elixir nodes form a BEAM mesh via `libcluster` (configurable via `--cluster`)
- Cross-node messages use native Erlang distribution
- Shared Postgres for persistent data (friends, ignores)

### Single World Process Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                        Rust node                               │
│                                                                │
│  ┌──────────┐   ┌────────────┐   ┌──────────────────────────┐  │
│  │ HTTP     │   │ TCP Accept │   │ Engine (600ms tick)      │  │
│  │ Server   │   │ Loop       │   │                          │  │
│  │ :8080    │   │ :43594     │   │  logins()                │  │
│  └──────────┘   └─────┬──────┘   │    ├─ LoginCheck → ether │  │
│                       │          │    └─ accept_login()     │  │
│                       ▼          │  process_ether_inbound() │  │
│                 ┌──────────┐     │    ├─ UpdateFriendList   │  │
│                 │ Socket   │     │    ├─ UpdateIgnoreList   │  │
│                 │ Handshake│     │    ├─ MessagePrivate     │  │
│                 └────┬─────┘     │    ├─ LoginCheckResponse │  │
│                      │           │    └─ EtherReconnected   │  │
│                      ▼           │  logouts()               │  │
│                 LoginRequest ──► │    └─ PlayerLogout → eth │  │
│                                  └──────────┬───────────────┘  │
│                                             │                  │
│  ┌──────────────────────────────────────────┼────────────────┐ │
│  │              Ether Client (Tokio task)   │                │ │
│  │                                          │                │ │
│  │  UnboundedSender<EtherOutbound> ◄────────┘                │ │
│  │         │                                                 │ │
│  │         ▼                                                 │ │
│  │  ┌─────────────┐         ┌──────────────────┐             │ │
│  │  │ TCP Write   │────────►│ Elixir Sidecar   │             │ │
│  │  │ (frames)    │         │ 127.0.0.1:5010   │             │ │
│  │  └─────────────┘         └────────┬─────────┘             │ │
│  │  ┌─────────────┐                  │                       │ │
│  │  │ TCP Read    │◄─────────────────┘                       │ │
│  │  │ (frames)    │                                          │ │
│  │  └──────┬──────┘                                          │ │
│  │         │                                                 │ │
│  │  UnboundedSender<EtherInbound> ──► engine.ether_rx        │ │
│  │                                                           │ │
│  │  Reconnect: backoff 1s → 2s → 4s → ... → 30s              │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              Sidecar Supervisor (Tokio task)             │  │
│  │  Spawns cmd /c elixir ... with stdin=null, stdout=piped  │  │
│  │  Restarts on non-zero exit with backoff                  │  │
│  │  SIDECAR_PID stored in AtomicU32 for shutdown            │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

### Elixir Sidecar Internal Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                      Elixir rs-ether (BEAM VM)                │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │                    Supervision Tree                     │  │
│  │                                                         │  │
│  │  ┌─────────┐  ┌───────────────┐  ┌───────────────────┐  │  │
│  │  │  Repo   │  │ PlayerRegistry│  │ :pg scope :social │  │  │
│  │  │ (Ecto)  │  │  (Registry)   │  │ (cluster-wide)    │  │  │
│  │  └────┬────┘  └───────────────┘  └───────────────────┘  │  │
│  │       │                                                 │  │
│  │  ┌────┴──────────────────────────────────────────────┐  │  │
│  │  │            DynamicSupervisor                      │  │  │
│  │  │                                                   │  │  │
│  │  │  ┌─────────────┐ ┌─────────────┐ ┌────────────┐   │  │  │
│  │  │  │PlayerSession│ │PlayerSession│ │PlayerSession│  │  │  │
│  │  │  │  jordan     │ │  tyler      │ │  admin      │  │  │  │
│  │  │  │             │ │             │ │             │  │  │  │
│  │  │  │ friends: [] │ │ friends: [] │ │ friends: [] │  │  │  │
│  │  │  │ ignores: [] │ │ ignores: [] │ │ ignores: [] │  │  │  │
│  │  │  │ private: 0  │ │ private: 0  │ │ private: 2  │  │  │  │
│  │  │  └─────────────┘ └─────────────┘ └────────────┘   │  │  │
│  │  └───────────────────────────────────────────────────┘  │  │
│  │                                                         │  │
│  │  ┌────────────────┐  ┌────────────────────────────────┐ │  │
│  │  │ ClusterMonitor │  │ Cluster.Supervisor (libcluster)│ │  │
│  │  │ :nodeup/:down  │  │ EPMD strategy                  │ │  │
│  │  └────────────────┘  └────────────────────────────────┘ │  │
│  │                                                         │  │
│  │  ┌────────────────────────────────────────────────────┐ │  │
│  │  │                   WorldLink                        │ │  │
│  │  │  :gen_tcp.listen(5010, packet: 2, ip: 127.0.0.1)   │ │  │
│  │  │                                                    │ │  │
│  │  │  Inbound:  TCP frame → Protocol.decode → dispatch  │ │  │
│  │  │  Outbound: Protocol.encode → :gen_tcp.send         │ │  │
│  │  │                                                    │ │  │
│  │  │  Dispatches to:                                    │ │  │
│  │  │    start_session / stop_session / dispatch_to_sess │ │  │
│  │  │    login_check (:global lock) / refresh_all        │ │  │
│  │  └────────────────────────────────────────────────────┘ │  │
│  └─────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
```

### Cross-World Friend Presence Flow

```
World 1 (jordan logs in)              World 2 (tyler online)
─────────────────────────              ──────────────────────

Rust Engine                            Rust Engine
  │                                      │
  ├─ LoginCheck{jordan} ──► Ether 1      │
  │                                      │
  │  Ether 1:                            │
  │    :global.register_name ──┐         │
  │    LoginCheckResponse ◄────┘         │
  │                                      │
  ├─ accept_login(jordan)                │
  ├─ PlayerLogin{jordan} ──► Ether 1     │
  │                                      │
  │  Ether 1 (jordan session):           │
  │    join :pg {:player, jordan}        │
  │    release :global lock              │
  │    load friends from DB              │
  │    │                                 │
  │    ├─ lookup_presence(tyler, jordan) │
  │    │    :pg lookup ─────────────────►│ tyler session
  │    │    check_visibility ◄───────────│ (checks private_mode)
  │    │    node=11 or 0                 │
  │    │                                 │
  │    ├─ FriendUpdate{jordan,tyler,N} ──► Rust 1 ──► jordan's client
  │    │                                 │
  │    └─ broadcast_online(jordan) ─────►│ tyler session
  │         (respects jordan's           │   │
  │          private_mode)               │   ├─ FriendUpdate{tyler,jordan,10}
  │                                      │   └──► Rust 2 ──► tyler's client
```

### Login Lock (Duplicate Prevention)

```
World 1                    :global (cluster-wide)           World 2
────────                   ─────────────────────            ────────

LoginCheck{jordan}                                    LoginCheck{jordan}
     │                                                      │
     ├─ :pg empty? yes                                      ├─ :pg empty? yes
     │                                                      │
     ├─ :global.register_name ───► lock acquired            │
     │   ({:login_lock, jordan})                            │
     │                                                      ├─ :global.register_name
     │                              lock held! ◄────────────┤   → :no (denied)
     │                                                      │
     ├─ LoginCheckResponse                                  ├─ LoginCheckResponse
     │   {allowed: true}                                    │   {allowed: false}
     │                                                      │
     ▼                                                      ▼
 accept_login()                                    AlreadyLoggedIn → client
     │
 PlayerLogin ──► Ether
     │
 Session init:
   :pg.join (now in :pg)
   :global.unregister_name (lock released)
```

### Sidecar Crash & Recovery

```
Time ──────────────────────────────────────────────────────────►

World 1 Rust         World 1 Ether         World 2 Ether
────────────         ─────────────         ─────────────

  [running]           [running]             [running]
      │                   │                     │
      │               ╳ CRASH ╳                 │
      │                                         │
  TCP close detected                    :nodedown detected
      │                                    │
  backoff 1s...                        ClusterMonitor:
      │                                  refresh_friends
  backoff 2s...                          rebroadcast_presence
      │                                    │
  Sidecar supervisor                       │
  restarts process                         │
      │                                    │
  ether_wait_connected                     │
      ├─ TCP connect ──► [new sidecar]     │
      │                                    │
  EtherReconnected                         │
      │                                    │
  PlayerResync ──────► create sessions     │
  (for each player     with private_mode)  │
      │                                    │
  RefreshAll ────────► refresh_friends   :nodeup detected
                       rebroadcast ─────► ClusterMonitor:
                                           refresh_friends
                                           rebroadcast_presence
```

### Startup Sequence

```
cargo run -p rs-server -- --node-id 10
  │
  ├─ 1. Pack content sources → CacheStore
  ├─ 2. Load RSA key pair
  │
  ├─ 3. Prepare sidecar
  │     ├─ mix deps.get
  │     ├─ mix ecto.create --quiet
  │     └─ mix ecto.migrate --quiet
  │
  ├─ 4. Spawn sidecar (supervised, kill_on_drop)
  │     └─ elixir --name world10@127.0.0.1 --cookie rs_secret -S mix run --no-halt
  │
  ├─ 5. Wait for sidecar TCP ready (ether_wait_connected)
  │
  ├─ 6. Spawn ether client task (persistent TCP connection)
  │
  ├─ 7. Create Engine + spawn tick task (600ms cycle)
  │
  ├─ 8. Spawn hot-reload coordinator (debug only)
  │
  ├─ 9. Spawn HTTP server (:8080)
  │
  └─ 10. Accept TCP game connections (:43594)
```

---

## Responsibilities

- **Social:** friends, ignores, PMs, presence, chat mode visibility
- **Login lock:** prevents duplicate logins across all worlds
- **Resilience:** sidecar auto-restart, session resync on reconnect, cluster monitoring
- **Future:** player saves, hiscores, trade history, moderation logs

---

## Binary Protocol (Rust <-> Elixir over localhost TCP)

Each frame: `u16 big-endian length` + payload. Payload starts with `u8 opcode`.

```
┌──────────┬────────┬──────────────────┐
│ len (u16)│ op (u8)│ payload (varies) │
└──────────┴────────┴──────────────────┘
```

All hash fields (`user37`, `owner37`, `friend37`, etc.) are unsigned 64-bit big-endian.

### Rust -> Elixir (Outbound)

| Op | Name              | Payload                                                |
|----|-------------------|--------------------------------------------------------|
| 0  | WorldRegister     | `node_id: u8`                                          |
| 1  | PlayerLogin       | `user37: u64, pid: u16`                                |
| 2  | PlayerLogout      | `user37: u64`                                          |
| 3  | FriendAdd         | `owner37: u64, friend37: u64`                          |
| 4  | FriendDel         | `owner37: u64, friend37: u64`                          |
| 5  | IgnoreAdd         | `owner37: u64, ignore37: u64`                          |
| 6  | IgnoreDel         | `owner37: u64, ignore37: u64`                          |
| 7  | PrivateMessage    | `sender37: u64, target37: u64, level: u8, bytes: [u8]` |
| 8  | RequestLists      | `user37: u64`                                          |
| 9  | ChatModeUpdate    | `user37: u64, private_mode: u8`                        |
| 10 | PlayerSaveRequest | `user37: u64, save_data: [u8]` (stub)                  |
| 11 | PlayerLoadRequest | `user37: u64` (stub)                                   |
| 12 | PlayerResync      | `user37: u64, pid: u16, private_mode: u8`              |
| 13 | LoginCheck        | `user37: u64`                                          |
| 14 | RefreshAll        | (empty)                                                |

### Elixir -> Rust (Inbound)

| Op  | Name               | Payload                                                                |
|-----|--------------------|------------------------------------------------------------------------|
| 128 | UpdateFriendList   | `target37: u64, friend37: u64, node: u8`                               |
| 129 | UpdateIgnoreList   | `target37: u64, count: u16, [ignore37: u64, ...]`                      |
| 130 | MessagePrivate     | `recipient37: u64, sender37: u64, msg_id: i32, level: u8, bytes: [u8]` |
| 131 | FriendListComplete | `target37: u64`                                                        |
| 132 | PlayerLoadResponse | `user37: u64, save_data: [u8]` (stub)                                  |
| 133 | PlayerSaveAck      | `user37: u64, success: u8` (stub)                                      |
| 134 | LoginCheckResponse | `user37: u64, allowed: u8`                                             |

### Internal (not on wire)

| Name             | Description                                        |
|------------------|----------------------------------------------------|
| EtherReconnected | Sent by ether client to engine when TCP reconnects |

---

## Message Flows

### Player Login (with duplicate prevention)

```
Game Client ──TCP──► Rust World
                       │
                       ├── Same-world check: find_pid_by_hash64
                       │     └── If found → LoginResponse::AlreadyLoggedIn
                       │
                       ├── LoginCheck{user37} ──► Ether sidecar
                       │     Store request in pending_logins
                       │
                       │   Ether sidecar:
                       │     1. Check :pg for existing session → deny if found
                       │     2. :global.register_name({:login_lock, user37})
                       │        → atomic cluster-wide lock
                       │        → deny if lock already held
                       │     3. LoginCheckResponse{allowed} ──► Rust
                       │
                       ├── If allowed:
                       │     LoginResponse::Success ──► Client
                       │     PlayerLogin{user37, pid} ──► Ether
                       │     RequestLists{user37} ──► Ether
                       │
                       └── If denied:
                             LoginResponse::AlreadyLoggedIn ──► Client
                             Connection closed

Ether sidecar on PlayerLogin:
  1. Start PlayerSession GenServer
  2. Join :pg group {:player, user37}
  3. Release :global login lock
  4. Load friends + ignores from Postgres
  5. For each friend: check_visibility via :pg
  6. Send FriendUpdate (online/offline) ──► Rust ──► Client
  7. Send IgnoreListFull ──► Rust ──► Client
  8. Send FriendListComplete ──► Rust
  9. Broadcast presence to reverse-friends (respecting private_mode)

Pending login timeout: 5 ticks → LoginResponse::CouldNotComplete
No ether connection: LoginResponse::LoginServerOffline
```

### Player Logout

```
Rust World:
  1. Run [logout] script trigger
  2. PlayerLogout{user37} ──► Ether
  3. Remove player from engine

Ether sidecar:
  1. Stop PlayerSession (restart: :temporary, no auto-restart)
  2. Leave :pg group
  3. Broadcast offline to reverse-friends
```

### Private Message (Cross-World)

```
Client A (World 1) ──► Rust World 1
                         │
                         └── Unpack bytes, word filter, repack
                             PrivateMessage{sender, target, level, bytes}
                               │
                               ▼
                         Ether node world10@
                           │
                           ├── :pg lookup target → pid on world11@
                           └── GenServer.cast(pid, {:receive_pm, ...})
                                 │
                                 ▼  (BEAM distribution, automatic)
                           Ether node world11@
                             │
                             ├── Check: ignore list, private mode, friends
                             └── PMDeliver ──► Rust World 2 ──► Client B
```

### Chat Mode Update (Private Visibility)

```
Client changes chat settings ──► Rust
  │
  ├── Update player.public/private/trade
  ├── Send ChatFilterSettings to client
  └── ChatModeUpdate{user37, private_mode} ──► Ether
        │
        Ether PlayerSession:
          1. Store private_mode in state
          2. For each reverse-friend:
             - Check visibility (on=all, friends=mutual only, off=none)
             - Send FriendUpdate with node or 0
```

### Sidecar Reconnect (EtherReconnected)

```
Sidecar crashes or restarts
  │
  ▼
Ether client detects TCP close
  └── Reconnect with backoff (1s → 2s → 4s → ... → 30s)

On reconnect:
  1. Send WorldRegister{node_id}
  2. Send EtherReconnected to engine (internal)
  3. Engine sends PlayerResync{user37, pid, private_mode} for each active player
  4. Engine sends RefreshAll

Ether on PlayerResync:
  - Create PlayerSession with correct private_mode
  - Load friends/ignores from DB
  - Broadcast presence (respecting private_mode)

Ether on RefreshAll:
  - All sessions: refresh_friends (re-check all friends' presence)
  - All sessions: rebroadcast_presence (notify reverse-friends)
```

### Cluster Node Up/Down

```
ClusterMonitor detects :nodedown
  └── All local sessions: refresh_friends
      (friends on the downed node show as offline)

ClusterMonitor detects :nodeup
  └── All local sessions: refresh_friends + rebroadcast_presence
      (friends on the recovered node update, and local presence
       is broadcast to the recovered node's sessions)
```

---

## Elixir Project Structure

```
rs-ether/
  mix.exs                          # deps: libcluster, ecto_sql, postgrex
  config/
    config.exs                     # Repo pool size, logger format
    runtime.exs                    # All config from env vars (RS_NODE_ID, RS_ETHER_PORT, RS_DB_*, RS_CLUSTER_HOSTS)
  lib/rs_ether/
    application.ex                 # Supervision tree
    repo.ex                        # Ecto Postgres repo
    cluster_monitor.ex             # Monitors BEAM node up/down events
    world_link.ex                  # gen_tcp server for local Rust connection
    protocol.ex                    # Binary encode/decode for all opcodes
    social/
      player_session.ex            # GenServer per online player (restart: :temporary)
      friend_store.ex              # Postgres CRUD for friends
      ignore_store.ex              # Postgres CRUD for ignores
    saves/
      player_save_store.ex         # Postgres CRUD for player saves (stub)
  priv/repo/migrations/
    20260518000001_create_friends.exs
    20260518000002_create_ignores.exs
    20260518000003_create_player_saves.exs
```

### Supervision Tree

```
Application
  ├── Repo (Ecto Postgres pool)
  ├── Registry (PlayerRegistry, :unique keys)
  ├── :pg scope :social (cluster-wide process groups)
  ├── DynamicSupervisor (SessionSupervisor, for PlayerSessions)
  ├── Cluster.Supervisor (libcluster, Erlang distribution)
  ├── ClusterMonitor (monitors :nodeup/:nodedown)
  └── WorldLink (TCP server, binds 127.0.0.1:{ether_port})
```

---

## Data Model

### Postgres

```sql
CREATE TABLE friends
(
    owner_hash  BIGINT NOT NULL,
    friend_hash BIGINT NOT NULL,
    PRIMARY KEY (owner_hash, friend_hash)
);
CREATE INDEX idx_friends_reverse ON friends (friend_hash);

CREATE TABLE ignores
(
    owner_hash  BIGINT NOT NULL,
    ignore_hash BIGINT NOT NULL,
    PRIMARY KEY (owner_hash, ignore_hash)
);

CREATE TABLE player_saves
(
    user_hash  BIGINT PRIMARY KEY,
    save_data  BYTEA       NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### Runtime State

- **`:pg` process groups** — cluster-wide presence: `{:player, user37}` → PlayerSession pid
- **`:global` names** — `{:login_lock, user37}` → atomic cluster-wide login lock
- **PlayerSession GenServer** — per-player: friends list, ignore list, private_mode (loaded from DB on login/resync)

### Visibility Rules (private_mode)

| Mode    | Value | Visible To          |
|---------|-------|---------------------|
| On      | 0     | Everyone            |
| Friends | 1     | Only mutual friends |
| Off     | 2     | Nobody              |

Applied in: `lookup_presence`, `broadcast_online`, `rebroadcast_presence`, `receive_pm`

---

## Rust-Side Implementation

### CLI Arguments

| Arg            | Default      | Description                     |
|----------------|--------------|---------------------------------|
| `--node-id`    | 10           | World node ID                   |
| `--ether-port` | 5000+node_id | Sidecar TCP port                |
| `--no-ether`   | false        | Disable sidecar                 |
| `--db-host`    | localhost    | Postgres host                   |
| `--db-port`    | 5432         | Postgres port                   |
| `--db-name`    | postgres     | Database name                   |
| `--db-user`    | postgres     | Database user                   |
| `--db-pass`    | password     | Database password               |
| `--cluster`    | ""           | Comma-separated BEAM node names |

All DB and cluster args are passed as env vars to the sidecar.

### Sidecar Lifecycle

1. **Startup**: `prepare_ether_sidecar()` runs `mix deps.get`, `mix ecto.create --quiet`, `mix ecto.migrate --quiet`
2. **Spawn**: `supervise_ether_sidecar()` starts the Elixir process with `kill_on_drop`, piped stdout/stderr routed
   through tracing
3. **Wait**: `ether_wait_connected()` blocks until the sidecar's TCP port accepts connections
4. **Connect**: `ether_client_task()` maintains the persistent TCP connection with reconnect backoff
5. **Supervise**: if the sidecar exits with non-zero status, it is restarted with backoff (1s → 30s max)
6. **Shutdown**: `ShutdownGuard` kills the sidecar on any exit (TUI quit, Ctrl+C, panic)

### Engine Tick Integration

```
cycle():
  world → inputs → npcs → players → logouts → logins → process_ether_inbound → zones → info → outputs → cleanup
```

`process_ether_inbound()` drains up to 100 messages per tick via `try_recv()`. Never blocks.

---

## Deployment

### Single machine (development)

```bash
# Uses cargo aliases from .cargo/config.toml
cargo world1    # --node-id 10, ether auto-spawned
cargo world2    # --node-id 11, ether auto-spawned
```

### Multi-machine (production)

```bash
# Server A (10.0.0.1)
./rs-server --node-id 10 \
  --db-host db.internal --db-name rsserver --db-user app --db-pass secret \
  --cluster "world10@10.0.0.1,world11@10.0.0.2"

# Server B (10.0.0.2)
./rs-server --node-id 11 \
  --db-host db.internal --db-name rsserver --db-user app --db-pass secret \
  --cluster "world10@10.0.0.1,world11@10.0.0.2"
```

### Client URL

```
/client?world=1&detail=high&method=0
```

| Param  | Values    | Maps To                                |
|--------|-----------|----------------------------------------|
| world  | 1, 2, ... | nodeid=9+N, portoff=N-1                |
| detail | high, low | lowmem=0, lowmem=1                     |
| method | 0, 3      | plugin=0 (TypeScript), plugin=3 (Java) |

---

## Verification Checklist

1. Start Postgres
2. `cargo world1` — sidecar auto-starts, runs migrations, connects
3. `cargo world2` — second world, cluster forms automatically
4. Login Player A on World 1, Player B on World 2
5. A adds B as friend → A sees B online with correct node
6. B adds A as friend → B sees A online with correct node
7. A sends PM to B → B receives on World 2
8. B sets private to off → A sees B go offline
9. B logs out → A sees B offline
10. Kill World 2 sidecar → A sees B offline, sidecar restarts, B re-appears online
11. Try double login (same player, two worlds) → second attempt gets AlreadyLoggedIn
12. Try double login (same player, same world) → second attempt gets AlreadyLoggedIn
