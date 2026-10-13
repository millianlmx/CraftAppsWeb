# Craft Apps Web

Docker images of every [storytold](https://github.com/storytold) Craft App's browser build, with the
ArtCraft Launcher (web build, hub mode) as the front page, deployable as one Portainer stack behind
an external Traefik.

```
apps.json                 the suite: id, name, repo, Trunk app dir, …  (source of truth)
docker/app.Dockerfile     generic image: trunk build of apps/<id>-web → nginx on :8080
docker/nginx.conf         nginx config baked into every app image
hub/                      hub image: nginx, / → the launcher, /<id>/ → each app
scripts/generate.py       writes docker-compose.yml and hub/nginx.conf from apps.json
docker-compose.yml        the Portainer stack (generated)
.github/workflows/build.yml
```

## The launcher as hub

The front page is storytold's own egui launcher, web build, from the fork
[millianlmx/craft-launcher@web-hub](https://github.com/millianlmx/craft-launcher/tree/web-hub)
(one commit on top of upstream, see its message). Its `index.html` carries
`<meta name="craft-web-apps" content="./">`: the launcher then probes `./<id>/version.json` for
each app, shows **Open** (new tab, the app's browser build) where one is deployed, **Not
available** where none answers, and keeps the desktop download in the card's `…` menu. Upstream's
release checks (GitHub API, from the visitor's browser) are unchanged.

To follow upstream: rebase `web-hub` on `storytold/craft-launcher` main; CI pins that branch via
`"ref": "web-hub"` in `apps.json`.

## Images

`<REGISTRY>/<NAMESPACE>/<id>-web:{latest, <version>, sha-<commit>}` for each app and
`…/craft-apps-hub:{latest, sha-<commit>}`. Default registry: GHCR under this repo's owner.

The workflow runs on push to `main`, weekly, and by hand (`workflow_dispatch`: pick apps, build the
latest release or the default branch, push or not). Each app job checks out `storytold/<id>` at its
latest release tag, reads `[workspace.package] version` from its `Cargo.toml`, and builds
`docker/app.Dockerfile` for linux/amd64 + linux/arm64 (the wasm is built once; only the nginx
layer is per-platform).

Repository settings:

| Kind     | Name                                   | Purpose                                             |
|----------|----------------------------------------|-----------------------------------------------------|
| variable | `REGISTRY`                             | default `ghcr.io`                                   |
| variable | `IMAGE_NAMESPACE`                      | default: repo owner                                 |
| secret   | `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` | only for non-GHCR registries (GHCR uses `GITHUB_TOKEN`) |

## Deploy (Portainer + external Traefik)

Create a stack from this repo's `docker-compose.yml` and set:

| Variable       | Default                | Meaning                                |
|----------------|------------------------|----------------------------------------|
| `HUB_HOST`     | `craft.1000co.fr`      | hostname Traefik routes to the hub     |
| `IMAGE_PREFIX` | `ghcr.io/millianlmx`   | registry/namespace of the images       |
| `TAG`          | `latest`               | tag used for every image               |

Traefik labels follow the other stacks on this host: entrypoint `websecure`, certresolver
`myresolver`, network `traefik-network`.

Only `hub` joins the Traefik network. The apps sit on an internal network; the hub proxies
`https://HUB_HOST/` to the launcher and `https://HUB_HOST/<id>/` to each app. An app that is
stopped or removed from the stack shows as not available in the launcher; nothing else breaks.

To serve a subset, delete the unwanted services from the stack: the hub tolerates missing
upstreams. Private GHCR images need a registry credential in Portainer.

## Adding or changing an app

Edit `apps.json`, run `scripts/generate.py`, commit the result. CI fails if the generated files are
stale.

## Local build

```sh
git clone --depth 1 https://github.com/storytold/photocraft src
docker buildx build -f docker/app.Dockerfile --build-context cfg=docker \
  --build-arg APP=photocraft --build-arg VERSION=dev -t photocraft-web src
docker build -f hub/Dockerfile -t craft-apps-hub .
```
