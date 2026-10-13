# Craft Apps Web

Docker images of every [storytold](https://github.com/storytold) Craft App's browser build, plus a
hub page that links to them, deployable as one Portainer stack behind an external Traefik.

```
apps.json                 the suite: id, name, tagline, colour, Trunk app dir  (source of truth)
docker/app.Dockerfile     generic image: trunk build of apps/<id>-web → nginx on :8080
docker/nginx.conf         nginx config baked into every app image
hub/                      hub image: static page + reverse proxy /<id>/ → <id>:8080
scripts/generate.py       writes docker-compose.yml and hub/nginx.conf from apps.json
docker-compose.yml        the Portainer stack (generated)
.github/workflows/build.yml
```

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

| Variable             | Default                | Meaning                                  |
|----------------------|------------------------|------------------------------------------|
| `HUB_HOST`           | *(required)*           | hostname Traefik routes to the hub       |
| `IMAGE_PREFIX`       | `ghcr.io/millianlmx`   | registry/namespace of the images         |
| `TAG`                | `latest`               | tag used for every image                 |
| `TRAEFIK_NETWORK`    | `traefik-network`      | the external Traefik network             |
| `TRAEFIK_ENTRYPOINT` | `websecure`            | Traefik entrypoint                       |
| `TRAEFIK_RESOLVER`   | `letsencrypt`          | Traefik certificate resolver             |

Only `hub` joins the Traefik network. The apps sit on an internal network; the hub proxies
`https://HUB_HOST/<id>/` to each one and shows on its front page which apps are up and which
version they run (from `/<id>/version.json`, written at build time). An app that is stopped or
removed from the stack is shown offline; nothing else breaks.

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
