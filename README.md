# agent-box

A self-contained Linux image for agentic software development, built for
**Apple Silicon** (`linux/arm64`). One image, all the tooling, ready to run
on your Mac via Docker Desktop.

## What's inside

| Category | Tools |
| --- | --- |
| Languages | Node.js 22, Python 3.14 (deadsnakes), Go, `uv`, `bun` |
| Cloud / k8s | `gcloud` (Google Cloud SDK), `kubectl` |
| Agents | `opencode` (`opencode-ai`), `bd` (beads), `agent` (Cursor terminal agent) |
| Networking | `wireguard-tools`, `openresolv`, `iptables` |
| Dev utilities | `git`, `gh`, `ripgrep`, `fd`, `jq`, `yq`, `tmux`, `vim`, `build-essential`, Docker CLI + buildx + compose |
| Shell | `bash` (runs as unprivileged user `agent`) |

Pinned versions live in [`versions.env`](versions.env). Bump them and rebuild.

## Quick start

```bash
# 1. (optional) provide API keys / workspace path
cp .env.example .env           # edit as needed

# 2. build the image
docker compose build

# 3. drop into bash inside the container
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

Each of gcloud / kube / wireguard is **profile-switchable at runtime** with an
env var — no copying or renaming. Layout & how the selection works:

| Tool | Env var (default `MI`) | Layout | How it's selected |
| --- | --- | --- | --- |
| gcloud | `GCLOUD_PROFILE` | `configs/gcloud/<P>/` (dir) | mounts that subdir as the whole gcloud config |
| kube | `KUBE_PROFILE` | `configs/kube/<P>` (file) | sets `KUBECONFIG=/home/agent/.kube/<P>` |
| wireguard | `WIREGUARD_PROFILE` | `configs/wireguard/<P>.conf` | entrypoint runs `wg-quick up <P>` |

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



## WireGuard

Drop a `<PROFILE>.conf` (e.g. `configs/wireguard/MI.conf`) and the entrypoint
runs `wg-quick up <PROFILE>` at startup (as root, before dropping to the
`agent` user). The profile comes from `WIREGUARD_PROFILE` (default `MI`); a
legacy `wg0.conf` is still honored as a fallback. The required capabilities and
the `/dev/net/tun` device are already declared in
[`docker-compose.yml`](docker-compose.yml):

```yaml
cap_add: [NET_ADMIN]
devices: [/dev/net/tun]
sysctls: [net.ipv4.ip_forward=1]
```

If you don't use WireGuard, you can remove those lines — the entrypoint simply
skips tunnel setup when no `*.conf` is present.

> **DNS note:** `wg-quick`'s `DNS =` handling normally calls `resolvconf`,
> which on Debian needs systemd-resolved (absent in a container). The image
> ships a tiny `resolvconf` shim (`resolvconf-shim.sh`) that edits
> `/etc/resolv.conf` in place, so tunnel DNS just works — add/remove on
> up/down. To silence the "config is world accessible" warning, run
> `chmod 600 configs/wireguard/wg0.conf` on the host.

## tmux (and persisting sessions)

tmux is installed, with `tmux-resurrect` + `tmux-continuum` preconfigured. There
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
# edit versions.env to bump a tool, then:
docker compose build --no-cache
```

To verify what's installed:

```bash
docker compose run --rm agent bash -lc \
  'node -v; python3 -V; go version; gcloud --version | head -1; kubectl version --client; opencode --version; bd version; agent --version'
```
