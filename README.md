# agent-box

A self-contained Linux image for agentic software development, built for
**Apple Silicon** (`linux/arm64`). One image, all the tooling, ready to run
on your Mac via Docker Desktop.

## What's inside

| Category | Tools |
| --- | --- |
| Languages | Node.js 22, Python 3.14 (deadsnakes), Go, `uv`, `bun` |
| Cloud / k8s | `gcloud` (Google Cloud SDK), `kubectl` |
| Agents | `claude` (Claude Code, pinned), `opencode` (`opencode-ai`), `bd` (beads), `agent` (Cursor terminal agent) |
| Fleet | `sol` / `solomonar` (prebuilt linux/arm64 binary from a local checkout) |
| Networking | `wireguard-tools`, `tailscale` + `tailscaled` (pinned), `iptables`, resolvconf shim |
| Dev utilities | `git`, `gh`, `ripgrep`, `fd`, `jq`, `yq`, `tmux` 3.7b (built from source), `vim`, `build-essential`, Docker CLI + buildx + compose |
| Shell | `bash` (runs as unprivileged user `agent`) |

Pinned versions live in [`versions.env`](versions.env) (mirrored as `ARG`
defaults in the Dockerfile — bump both, or pass `--build-arg`) and rebuild.

## Quick start

```bash
# 1. (optional) provide API keys / workspace path
cp .env.example .env           # edit as needed

# 2. build the solomonar binary the image COPYs in (bin/ is gitignored)
scripts/fetch-solomonar.sh     # default checkout: ~/Projects/code-factory-workspace/solomonar
                               # or: scripts/fetch-solomonar.sh /path/to/solomonar

# 3. build the image
docker compose build

# 4. drop into bash inside the container
docker compose run --rm agent
```

Inside the container:

```bash
opencode        # launch the OpenCode agent
agent           # launch the Cursor terminal agent
bd version      # beads CLI
kubectl get pods
gcloud auth list
```

## Profiles: one long-lived container per project

Each project runs as its own compose project (`-p <name>-agent`) from the same
`docker-compose.yml`, selected by an env file in [`profiles/`](profiles):

| Container | Profile file | Workspace | gcloud | kube | WireGuard | Tailscale | Claude state |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `mi-agent` | `profiles/MI.env` | `workspaces/MI` | `MI` | `MI` | `MI.conf` | off | `configs/claude/MI` |
| `go-agent` | `profiles/GO.env` | `workspaces/GO` | `GO` | `GO` | `GO.conf` | off | `configs/claude/GO` |
| `em-agent` | `profiles/EM.env` | `workspaces/EM` (gym-system, the-kluster) | `EM` | `VTS` (the-kluster) | none | on, `em-agent` | `configs/claude/EM` |

```bash
# Pass .env FIRST (secrets: GH_TOKEN, API keys, TS_AUTHKEY), then the profile,
# which overrides the profile vars. A lone --env-file replaces .env entirely,
# so `--env-file profiles/EM.env` on its own would drop GH_TOKEN.
docker compose -p em-agent --env-file .env --env-file profiles/EM.env up -d agent-daemon
docker compose -p em-agent exec --user agent agent-daemon bash
```

Profile variables (`GCLOUD_PROFILE`, `KUBE_PROFILE`, `WIREGUARD_PROFILE`,
`CLAUDE_PROFILE`, `TAILSCALE_PROFILE`) each default to `WORKSPACE_PROFILE`,
which defaults to `MI`. Missing per-profile host dirs (e.g. `configs/gcloud/EM`
on first start) are created empty by compose; gcloud then simply starts with no
credentials (`gcloud auth login` inside the container persists into that dir).

### Creating em-agent

```bash
mkdir -p workspaces/EM && git -C workspaces/EM clone <gym-system-url> && git -C workspaces/EM clone <the-kluster-url>
scripts/fetch-solomonar.sh && docker compose build
docker compose -p em-agent --env-file .env --env-file profiles/EM.env up -d agent-daemon
docker compose -p em-agent logs agent-daemon          # entrypoint: tailscale login hint
docker exec -it em-agent-agent-daemon-1 tailscale up --hostname=em-agent --accept-routes   # once, unless TS_AUTHKEY is set
docker compose -p em-agent exec --user agent agent-daemon claude   # log in to Claude once
```

## Mounting your project

Your code is bind-mounted at `/workspace`. Keep one dir per profile under
`./workspaces/` and pick it with `WORKSPACE_PROFILE`:

```
workspaces/
├── MI/     # your populated project (default)
├── GO/
└── VTS/
```

```bash
docker compose run --rm agent                       # -> workspaces/MI
WORKSPACE_PROFILE=GO docker compose run --rm agent  # -> workspaces/GO
WORKSPACE_PROFILE=VTS docker compose run --rm agent
```

Need to mount a repo that lives outside this folder? Set `WORKSPACE` to an
absolute host path — it overrides the profile:

```bash
WORKSPACE=/Users/vlad/Projects/some-repo docker compose run --rm agent
```

## Credentials & config

Each container gets **its own** per-project config — not your host defaults.
Everything lives under [`configs/`](configs) and is bind-mounted read/write:

| Host path | Container path | Purpose |
| --- | --- | --- |
| `configs/gcloud/<PROFILE>` | `/home/agent/.config/gcloud` | gcloud credentials + config (one profile dir per project) |
| `configs/kube/<PROFILE>` | `/home/agent/.kube/<PROFILE>` | kubeconfig (one file per profile) |
| `configs/opencode` | `/home/agent/.config/opencode` | `opencode.json`, auth, agents, commands |
| `configs/cursor` | `/home/agent/.cursor` | Cursor agent settings + session state |
| `configs/wireguard/<PROFILE>.conf` | `/etc/wireguard/<PROFILE>.conf` | WireGuard config (one file per profile) |
| `configs/claude/<PROFILE>` | `/home/agent/.claude` | Claude Code credentials, settings, `.claude.json`, session transcripts |
| `configs/tailscale/<PROFILE>` | `/var/lib/tailscale` | Tailscale node state (identity / login) |

Each of gcloud / kube / wireguard is **profile-switchable at runtime** with an
env var — no copying or renaming. Layout & how the selection works:

| Tool | Env var (default `WORKSPACE_PROFILE`, else `MI`) | Layout | How it's selected |
| --- | --- | --- | --- |
| gcloud | `GCLOUD_PROFILE` | `configs/gcloud/<P>/` (dir) | mounts that subdir as the whole gcloud config |
| kube | `KUBE_PROFILE` | `configs/kube/<P>` (file) | sets `KUBECONFIG=/home/agent/.kube/<P>` |
| wireguard | `WIREGUARD_PROFILE` | `configs/wireguard/<P>.conf` | entrypoint runs `wg-quick up <P>`; `none` = no tunnel |
| claude | `CLAUDE_PROFILE` | `configs/claude/<P>/` (dir) | mounted at `~/.claude` (= `CLAUDE_CONFIG_DIR`) |
| tailscale | `TAILSCALE_PROFILE` | `configs/tailscale/<P>/` (dir) | mounted at `/var/lib/tailscale` |

```bash
# defaults: all MI
docker compose run --rm agent
# mix & match per run
KUBE_PROFILE=VTS                       docker compose run --rm agent
WIREGUARD_PROFILE=GO GCLOUD_PROFILE=GO docker compose run --rm agent
```

Seed them from your host (one-time):

```bash
# gcloud: one profile dir per project, e.g. MI (MobileInsight) and GO.
# Copy the full ~/.config/gcloud tree into each, then strip the regenerable
# junk (logs/ alone is ~800 MB) — only auth + config files are needed.
for p in MI GO; do
  mkdir -p "configs/gcloud/$p"
  cp -R ~/.config/gcloud/* "configs/gcloud/$p/"
  rm -rf "configs/gcloud/$p"/{logs,cache,gce,access_tokens.db,hidden_gcloud_config_universe_descriptor_data_cache_configs.db}
done

# kube: one file per profile (name = profile, e.g. MI, GO, VTS)
cp ~/.kube/config configs/kube/MI

# wireguard: one <PROFILE>.conf per profile (no need for wg0.conf)
cp ~/path/to/mi.conf configs/wireguard/MI.conf

cp -R ~/.config/opencode/* configs/opencode/
```

> **Tip:** to set a gcloud profile's default project without disturbing your
> host default, run
> `CLOUDSDK_CONFIG=$(pwd)/configs/gcloud/MI gcloud config set project api-project-604594715070`.

> **kubeconfig caveat:** entries pointing at `localhost`/`127.0.0.1` won't
> resolve inside the container. Replace them with a real host IP or DNS name.

These folders are gitignored (except `.gitkeep`), so secrets stay local.

### API keys

Two options (both work):

1. **In config** — put keys directly in `configs/opencode/opencode.json`.
2. **As env** — reference them with `{env:ANTHROPIC_API_KEY}` in the config and
   set the value in `.env` (see [`.env.example`](.env.example)). Compose passes
   `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENCODE_API_KEY`, `GEMINI_API_KEY`,
   and `CURSOR_API_KEY` into the container automatically.

The Cursor agent authenticates with `CURSOR_API_KEY` (env) or `agent login`
(browser OAuth) — no config file required.

### GitHub

Set `GH_TOKEN` in `.env` to a **classic Personal Access Token** (`ghp_…`) and
both `gh` and `git` work with no further steps:

1. Create the token at <https://github.com/settings/tokens> → **Tokens
   (classic)** → *Generate new token (classic)*.
2. Scopes: `repo`, `workflow`, `read:org` (add `gist` if you use gists).
   Classic tokens work across **all** your repos — no per-repo selection like
   fine-grained tokens.
3. Put it in `.env`: `GH_TOKEN=ghp_xxxxxxxxxxxx`.

On startup the entrypoint:
- exposes the token to `gh` via `GH_TOKEN` (so `gh …` is authenticated), and
- writes `git config --global credential.helper store` + a mode-`600`
  `~/.git-credentials`, so `git clone/push https://github.com/org/repo` works
  unattended.

Verify inside the container:

```bash
gh auth status            # should show logged in as your user
git ls-remote https://github.com/<you>/<private-repo>.git   # should succeed
```

(GITHUB_TOKEN is also read as a fallback.)

## Personal agent instructions

Each project has its own shared `AGENTS.md` that you don't want to touch. To
layer **your own** rules on top, use these per-agent mechanisms — none of them
modify the project files.

### opencode (global, auto-applied to every project)

Edit **[`configs/opencode/agent-rules.md`](configs/opencode/agent-rules.md)**.
It's wired in via [`configs/opencode/opencode.json`](configs/opencode/opencode.json)
(`"instructions": ["agent-rules.md"]`), so opencode merges it on top of every
project's `AGENTS.md`. Verify it's loaded:

```bash
opencode debug config | grep -A3 instructions
```

### Cursor

Cursor reads `.cursor/rules/*.mdc`. The container mounts `configs/cursor/` at
`~/.cursor`, so **[`configs/cursor/rules/personal.mdc`](configs/cursor/rules/personal.mdc)**
is a global `alwaysApply` rule for the Cursor IDE. The **terminal agent** reads
the project's own `.cursor/rules/` — to reuse the same personal rule there
without duplicating it, symlink once per project:

```bash
mkdir -p .cursor/rules
ln -s ~/.cursor/rules/personal.mdc .cursor/rules/personal.mdc
```

### beads (persistent cross-project memory)

For facts you want the agent to remember across sessions and projects:

```bash
bd remember deploy "deploys go through the CI pipeline, never from a laptop"
bd recall deploy        # retrieve
bd memories             # list all
```



## Claude Code state (persistence)

The image sets `CLAUDE_CONFIG_DIR=/home/agent/.claude`, which makes Claude Code
keep **everything** in that one dir — `.credentials.json`, `settings.json`,
`projects/` (session transcripts), `history.jsonl`, and the global
`.claude.json` (which otherwise lives at `~/.claude.json`; verified with
Claude Code 2.1.284). Compose bind-mounts `configs/claude/<CLAUDE_PROFILE>`
there, so recreating or rebuilding the container keeps logins and every
conversation. `configs/claude/` is gitignored (it holds credentials).

### Before recreating mi-agent / go-agent: copy their state out

The **currently running** `mi-agent` (container `agent-daemon`) and `go-agent`
(container `go-agent-agent-daemon-1`) were created before this mount existed:
their `~/.claude` (~9 GB each) and `~/.claude.json` live only in the container's
writable layer. **Any recreate — `docker compose up` after a compose/image
change, `down`, `rm` — deletes them.** Copy them out first (a stopped container
still allows `docker cp`, and stopping first gives a consistent snapshot):

```bash
cd ~/Projects/vts/docker-for-agents
mkdir -p configs/claude          # configs/claude/MI and /GO must NOT exist yet,
                                 # otherwise docker cp nests it as MI/.claude

# mi-agent
docker stop agent-daemon
docker cp agent-daemon:/home/agent/.claude      configs/claude/MI
docker cp agent-daemon:/home/agent/.claude.json configs/claude/MI/.claude.json
ls -la configs/claude/MI/.credentials.json configs/claude/MI/.claude.json && du -sh configs/claude/MI

# go-agent
docker stop go-agent-agent-daemon-1
docker cp go-agent-agent-daemon-1:/home/agent/.claude      configs/claude/GO
docker cp go-agent-agent-daemon-1:/home/agent/.claude.json configs/claude/GO/.claude.json
ls -la configs/claude/GO/.credentials.json configs/claude/GO/.claude.json && du -sh configs/claude/GO

# only then recreate on the new image + compose file
docker compose -p mi-agent --env-file .env --env-file profiles/MI.env up -d agent-daemon
docker compose -p go-agent --env-file .env --env-file profiles/GO.env up -d agent-daemon
```

Other things those two containers got by hand and will **lose** on recreate
(copy out what you need the same way): `~/.bashrc` additions (aliases, env such
as mi's `DATABASE_URL`) — move them to `workspaces/<P>/.bashrc`; `~/.gitconfig`
user name/email; extra binaries in `/usr/local/bin` (mi: `helm`, `crane`,
older `solomonar.*`); pip / pip-installed tools (go: numpy, pytest, black, …).
The new mi container will also be named `mi-agent-agent-daemon-1` rather than
`agent-daemon`.

## Tailscale

Off by default. The entrypoint starts `tailscaled` (kernel mode, through the
same `/dev/net/tun` + `NET_ADMIN` WireGuard uses; state in
`configs/tailscale/<TAILSCALE_PROFILE>` → `/var/lib/tailscale`) when
`TAILSCALE_ENABLE=1` **or** that dir already holds a `tailscaled.state`. Then:

- `TS_AUTHKEY` set (put it in `.env`) → `tailscale up --authkey=… --hostname=<TAILSCALE_HOSTNAME> --accept-routes`.
- otherwise → saved state is reused; if not logged in yet, the log prints the
  one-time command, e.g.
  `docker exec -it em-agent-agent-daemon-1 tailscale up --hostname=em-agent --accept-routes`.

`TAILSCALE_HOSTNAME` defaults to `<profile>-agent` (lowercase);
`TAILSCALE_EXTRA_ARGS` appends flags (e.g. `--accept-dns=false`). Tailscale
errors are logged (`/var/log/tailscaled.log`) and never stop the container.

## WireGuard

Drop a `<PROFILE>.conf` (e.g. `configs/wireguard/MI.conf`) and the entrypoint
runs `wg-quick up <PROFILE>` at startup (as root, before dropping to the
`agent` user). The profile comes from `WIREGUARD_PROFILE` (default:
`WORKSPACE_PROFILE`):

- `<P>` set and `<P>.conf` exists → that tunnel, and only that one.
- `<P>` set but `<P>.conf` missing → **no tunnel** (one log line). It never
  falls back to another profile's config, so a new project can't silently land
  on someone else's VPN.
- `none` → explicit opt-out (EM does this; it uses Tailscale).
- explicitly empty (`WIREGUARD_PROFILE=`) → legacy fallback: `wg0.conf`, else
  the first `*.conf`.

The required capabilities and
the `/dev/net/tun` device are already declared in
[`docker-compose.yml`](docker-compose.yml):

```yaml
cap_add: [NET_ADMIN]
devices: [/dev/net/tun]
sysctls: [net.ipv4.ip_forward=1]
```

Keep them if you use Tailscale too (it runs in kernel mode on the same device).

> **DNS note:** `wg-quick`'s `DNS =` handling normally calls `resolvconf`,
> which on Debian needs systemd-resolved (absent in a container). The image
> ships a tiny `resolvconf` shim (`resolvconf-shim.sh`) that edits
> `/etc/resolv.conf` in place, so tunnel DNS just works — add/remove on
> up/down. To silence the "config is world accessible" warning, run
> `chmod 600 configs/wireguard/wg0.conf` on the host.

## tmux (and persisting sessions)

tmux 3.7b (built from the release tarball — Ubuntu ships 3.4, solomonar needs
\>= 3.2 and the fleet uses 3.7 features) is installed, with `tmux-resurrect` +
`tmux-continuum` preconfigured. There
are two levels of "persistence":

### 1. Live sessions — use the long-lived container (recommended)

`docker compose run --rm agent` creates a fresh container each time, so a tmux
server (and its sessions) die when it exits. To keep sessions alive across
attach/detach, run the **daemon** service instead and `exec` into it:

```bash
docker compose up -d agent-daemon                       # start it once
docker compose exec --user agent agent-daemon tmux new -s main   # first attach
docker compose exec --user agent agent-daemon tmux attach -t main
# detach inside tmux: Ctrl-b d
# ...later, from any terminal...
docker compose exec --user agent agent-daemon tmux attach -t main
docker compose stop agent-daemon                        # tear down when done
```

The tmux server lives as long as the daemon container, so sessions, windows,
and running processes all survive between `exec`s. (`--user agent` makes the
shell/tmux run as the unprivileged user; the entrypoint already ran as root to
bring up WireGuard.)

Tip — shorten it with a shell alias:

```bash
alias ax='docker compose exec --user agent agent-daemon'
ax tmux attach -t main
ax bash
```

### 2. Layout snapshots — auto-saved into the workspace

continuum auto-saves the session layout (windows, panes, working dirs) every
15 min to `/workspace/.tmux/resurrect`, so it travels with the project. If you
ever fully restart the container (losing the live server), restore the last
layout manually inside tmux:

```
Ctrl-b Ctrl-r      # restore last snapshot
Ctrl-b Ctrl-s      # save a snapshot now
```

> Note: tmux sessions are held by the running server process — they are not
> plain files, so the auto-restore path is best-effort. The daemon (option 1)
> is the reliable way to keep live sessions; the snapshots are a fallback for
> recovering layout after a full restart. If you don't want the snapshots in
> your repo, add `.tmux/` to your project's `.gitignore`.

You can also run a one-off tmux (sessions die when it exits):

```bash
docker compose run --rm agent tmux
```

## Docker from inside the container

The host's Docker socket is mounted, so `docker`, `docker buildx`, and
`docker compose` work against the host daemon. The `agent` user is added to the
`root` group so it can reach the socket (which is `root:root` mode `0660` on
Docker Desktop). Builds you start inside the container build on your Mac.

> **Linux hosts:** if your socket belongs to a `docker` group, add it at runtime
> instead — e.g. `docker compose run --rm --group-add "$(getent group docker | cut -d: -f3)" agent`.

## Multiple containers

Because every container reads its config from `./configs/...`, you can clone
this folder per project and keep credentials isolated. Image layers are shared
across all of them — only the config volumes differ.

## Rebuilding / upgrading

```bash
# edit versions.env (and the matching ARG in the Dockerfile) to bump a tool, then:
docker compose build --no-cache

# new solomonar: rebuild the binary from the checkout, then the (cheap) last layer
scripts/fetch-solomonar.sh && docker compose build
```

Rebuilding retags `agent-box`; running containers keep their old image until
recreated — and recreating mi-agent/go-agent before their Claude state is
copied out loses it (see "Claude Code state" above).

To verify what's installed:

```bash
docker compose run --rm agent bash -lc \
  'node -v; python3 -V; go version; gcloud --version | head -1; kubectl version --client; opencode --version; bd version; agent --version; claude --version; tmux -V; sol --version; tailscale version'
```
