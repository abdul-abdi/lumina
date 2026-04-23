# Lumina image recipes

Declarative specs for agent-path images, inspired by [apko](https://github.com/chainguard-dev/apko)'s
YAML schema. A recipe describes what goes into a custom image; the
`lumina images build-recipe` command evaluates it by booting a VM,
running the specified package + command steps, and saving the
resulting rootfs as a named image under `~/.lumina/images/`.

## Why recipes

- **Reproducible**: the same recipe on the same base image always
  produces a functionally-equivalent rootfs, regardless of who runs it.
- **Reviewable**: a recipe is ~30 lines of YAML. Fits in a PR. No
  Dockerfile sprawl.
- **Sharable**: recipes live in version control next to the code that
  depends on them. A repo can ship its own `lumina-recipes/` and
  agents pulling the repo build images on demand.

## Schema

```yaml
# Guest/recipes/openclaw/recipe.yaml
apiVersion: lumina.dev/v1alpha1
kind: AgentImage
metadata:
  name: openclaw
  displayName: "OpenClaw — pentest toolchain"
  tags: [agent, security, tooling]

# Base image to derive from. Must already be in ~/.lumina/images/.
from: default

# Alpine packages to install before any `run` steps. Equivalent to
# `apk add --no-cache <packages>` inside the build VM. Using APK is
# preferred over `run: apk add ...` because the builder can batch
# the install and cache deps across recipe evaluations.
packages:
  - gdb
  - lldb
  - radare2
  - binutils
  - gcc
  - musl-dev

# Shell commands to execute in the VM, in order, after packages are
# installed. Each entry runs under /bin/sh in a fresh exec (same VM,
# but no shared env across steps). Fail-fast: the first non-zero exit
# aborts the build and does NOT promote the staging dir.
run:
  - echo "OpenClaw build complete — installed $(radare2 -v | head -1)"

# Optional: enable Rosetta so the resulting image can run x86_64
# binaries via Lumina's --rosetta agent path. Stored in the image's
# meta.json; callers get it automatically.
rosetta: false
```

## Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `apiVersion` | string | yes | Pinned to `lumina.dev/v1alpha1` (v0.7.1 schema). |
| `kind` | string | yes | Always `AgentImage` for now; `DesktopImage` is v0.8 runway. |
| `metadata.name` | string | yes | Image id. Becomes `~/.lumina/images/<name>/`. Filesystem-safe chars only. |
| `metadata.displayName` | string | no | Human-friendly label for Desktop UI. |
| `metadata.tags` | [string] | no | Free-form tags (mirrors `AgentImageCatalog` tags). |
| `from` | string | no | Base image id. Defaults to `default`. Must exist locally (or `lumina images pull` first). |
| `packages` | [string] | no | Alpine APK packages to install via `apk add`. |
| `run` | [string] | no | Shell commands to execute sequentially. |
| `rosetta` | bool | no | Defaults to false. Enable x86_64 translation in the resulting image. |

## Building

```bash
# Directly from a recipe file:
lumina images build-recipe Guest/recipes/openclaw/recipe.yaml

# From a recipe directory (uses recipe.yaml inside):
lumina images build-recipe Guest/recipes/openclaw

# With progress output:
LUMINA_RECIPE_VERBOSE=1 lumina images build-recipe Guest/recipes/openclaw
```

Behind the scenes, `build-recipe` just translates the YAML into the
equivalent `Lumina.createImage(name:, from:, commands:, rosetta:)`
library call. The `packages` field becomes a prepended `apk add`
command. The resulting image lands in the same place as images created
via `lumina images create --from default --run "..."`.

## Sample recipes

- `Guest/recipes/openclaw/` — pentest toolchain
- `Guest/recipes/hermes/` — Python + ML agent toolchain
- `Guest/recipes/sample-minimal/` — the smallest useful recipe; good
  starting point for forks.

## Contributing a recipe

1. Add `Guest/recipes/<name>/recipe.yaml` following the schema above.
2. `lumina images build-recipe Guest/recipes/<name>` locally to verify it builds.
3. Optionally: add a row to `AgentImageCatalog.all` in
   `Sources/LuminaBootable/AgentImageCatalog.swift` so the built
   image is discoverable via `lumina images catalog` once you
   publish a tarball to a GitHub Release.
4. Send a PR.

## v0.7.1 scope

This ships as **schema + sample recipes** in v0.7.1. The
`build-recipe` command is a thin wrapper around the already-existing
`Lumina.createImage` path — no new build infrastructure. The recipes
directory is checked into the repo so agents / CI / fork-forks can
reference stable paths.
