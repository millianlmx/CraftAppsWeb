# syntax=docker/dockerfile:1
# Generic browser build of one Craft App, served by nginx.
#
# Build context  = a checkout of the app's repo (storytold/<app>).
# Named context  = `--build-context cfg=<this repo>/docker` (nginx.conf).
#
#   docker buildx build -f docker/app.Dockerfile --build-context cfg=docker \
#     --build-arg APP=photocraft --build-arg WEB_DIR=apps/photocraft-web \
#     --build-arg VERSION=0.8.2 --build-arg BUILD_SHA=$(git -C src rev-parse HEAD) \
#     -t photocraft-web src
#
# Every app repo has the same shape (packaging/web/package.sh upstream): a Trunk app in
# `apps/<app>-web` whose Trunk.toml writes `../../dist/web` with relative URLs, so the site works
# under any path prefix (the hub serves it at /<app>/).
#
# Derived from storytold/photocraft's Dockerfile. The wasm is built once on the build host
# (--platform=$BUILDPLATFORM) and copied into a runtime image per target platform.

ARG RUST_VERSION=1
ARG NGINX_VERSION=1.28-alpine

FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-slim-bookworm AS builder
# Keep in sync with `trunk-version` in storytold/craft-common-actions release.yml.
ARG TRUNK_VERSION=0.21.14
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && rustup target add wasm32-unknown-unknown
RUN set -eu; \
    case "$(uname -m)" in \
        x86_64) arch=x86_64 ;; \
        aarch64) arch=aarch64 ;; \
        *) echo 'The web builder supports amd64 and arm64' >&2; exit 1 ;; \
    esac; \
    asset="trunk-${arch}-unknown-linux-musl.tar.gz"; \
    url="https://github.com/trunk-rs/trunk/releases/download/v${TRUNK_VERSION}"; \
    cd /tmp; \
    curl -fsSL --retry 3 -A craft-apps-web "$url/$asset" -o "$asset"; \
    curl -fsSL --retry 3 -A craft-apps-web "$url/$asset.sha256" -o "$asset.sha256"; \
    printf '%s  %s\n' "$(cat "$asset.sha256")" "$asset" | sha256sum -c -; \
    tar -xzf "$asset" -C /usr/local/bin trunk; \
    rm "$asset" "$asset.sha256"; \
    trunk --version

ARG APP
ARG WEB_DIR=apps/${APP}-web
ARG VERSION=0.0.0
ARG BUILD_SHA=
ARG BUILD_DATE=
# Thin LTO needs less memory than the release zip's fat LTO; ignored by apps without a
# `wasm-release` profile.
ARG CARGO_PROFILE_WASM_RELEASE_LTO=thin
ENV CARGO_TERM_COLOR=always CARGO_INCREMENTAL=0

WORKDIR /src
COPY . .
# Build provenance, read by each app's build.rs as <APP>_BUILD_SHA / <APP>_BUILD_DATE (About
# dialog and --version). Cargo args stay neutral: trunk reads the profile/features from index.html.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/src/target,id=target-${APP} \
    --mount=type=cache,target=/root/.cache/trunk,id=trunk-${APP} \
    set -eu; \
    test -n "$APP" || { echo 'build-arg APP is required' >&2; exit 1; }; \
    test -f "$WEB_DIR/index.html" || { echo "$WEB_DIR/index.html not found" >&2; exit 1; }; \
    prefix="$(printf '%s' "$APP" | tr 'a-z-' 'A-Z_')"; \
    [ "$APP" = craft-launcher ] && prefix=ARTCRAFT_LAUNCHER; \
    export "${prefix}_VERSION=$VERSION" "${prefix}_BUILD_SHA=$BUILD_SHA" "${prefix}_BUILD_DATE=$BUILD_DATE" \
           "VERSION=$VERSION" "BUILD_SHA=$BUILD_SHA" "BUILD_DATE=$BUILD_DATE"; \
    (cd "$WEB_DIR" && trunk build --release --locked); \
    test -s dist/web/index.html; \
    if grep -Eq '(src|href)="/[^/]' dist/web/index.html; then \
        echo 'dist/web/index.html has root-absolute URLs; it would break under /<app>/' >&2; exit 1; fi; \
    printf '{"app":"%s","version":"%s","sha":"%s","date":"%s"}\n' "$APP" "$VERSION" "$BUILD_SHA" "$BUILD_DATE" > dist/web/version.json; \
    mkdir -p dist/web/licenses; \
    for f in LICENSE-MIT LICENSE-APACHE NOTICE ATTRIBUTION.md; do [ -f "$f" ] && cp "$f" dist/web/licenses/ || true; done; \
    gzip -9 -k dist/web/*.wasm dist/web/*.js dist/web/index.html

FROM nginx:${NGINX_VERSION} AS runtime
COPY --from=cfg nginx.conf /etc/nginx/nginx.conf
COPY --from=builder /src/dist/web/ /usr/share/nginx/html/
# Bypass the stock entrypoint: this configuration needs no runtime rewriting.
USER nginx
EXPOSE 8080
ENTRYPOINT []
CMD ["nginx", "-g", "daemon off;"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
