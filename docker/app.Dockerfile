# syntax=docker/dockerfile:1
# Generic browser build of one Craft App, served by nginx.
#
# Build context  = a checkout of the app's repo (storytold/<app>).
# Named context  = `--build-context cfg=<this repo>/docker` (nginx.conf).
#
#   docker buildx build -f docker/app.Dockerfile --build-context cfg=docker \
#     --build-arg APP=photocraft --build-arg VERSION=0.8.2 --build-arg BUILD_SHA=$(git -C src rev-parse HEAD) \
#     -t photocraft-web src
#
# Every app repo ships `packaging/web/package.sh`, the script its own release CI runs: it builds
# the site (trunk for most apps; `cargo xtask web` + wasm-bindgen for lightcraft, effectcraft and
# filmcraft) with relative URLs and zips it as dist/release/<APP>-web-<VERSION>.zip containing
# <APP>-web-<VERSION>/. That zip is the one contract this image relies on, so the apps' differing
# layouts (Trunk.toml or not, apps/<app>-web/web/, xtask) never matter here.
#
# Derived from storytold/photocraft's Dockerfile. The wasm is built once on the build host
# (--platform=$BUILDPLATFORM) and copied into a runtime image per target platform.

ARG RUST_VERSION=1
ARG NGINX_VERSION=1.28-alpine

FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-slim-bookworm AS builder
# Keep in sync with `trunk-version` in storytold/craft-common-actions release.yml.
ARG TRUNK_VERSION=0.21.14
# wasm-opt for the xtask-built apps (trunk downloads its own).
ARG BINARYEN_VERSION=133
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git zip unzip \
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
    trunk --version; \
    asset="binaryen-version_${BINARYEN_VERSION}-${arch}-linux.tar.gz"; \
    curl -fsSL --retry 3 -A craft-apps-web "https://github.com/WebAssembly/binaryen/releases/download/version_${BINARYEN_VERSION}/$asset" -o "$asset"; \
    tar -xzf "$asset" --strip-components=2 -C /usr/local/bin "binaryen-version_${BINARYEN_VERSION}/bin/wasm-opt"; \
    tar -xzf "$asset" --strip-components=1 -C /usr/local "binaryen-version_${BINARYEN_VERSION}/lib"; \
    rm "$asset"; \
    wasm-opt --version

ARG APP
ARG VERSION=0.0.0
ARG BUILD_SHA=
ARG BUILD_DATE=
# Thin LTO needs less memory than the release zip's fat LTO; ignored by apps without a
# `wasm-release` profile.
ARG CARGO_PROFILE_WASM_RELEASE_LTO=thin
ENV CARGO_TERM_COLOR=always CARGO_INCREMENTAL=0

WORKDIR /src
COPY . .
# `cargo xtask web` (lightcraft, effectcraft, filmcraft) needs the wasm-bindgen CLI at exactly the
# version in the repo's Cargo.lock; installed only for repos that use it.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    set -eu; \
    if grep -q 'cargo xtask web' packaging/web/package.sh; then \
        v="$(awk '/^name = "wasm-bindgen"$/ { getline; gsub(/[" ]/, "", $3); print $3; exit }' Cargo.lock)"; \
        test -n "$v"; \
        cargo install wasm-bindgen-cli --version "$v" --locked; \
    fi
# Build provenance, read by each app's build.rs via packaging/env.sh as <APP>_VERSION /
# <APP>_BUILD_SHA / <APP>_BUILD_DATE (.git isn't in the context, so the sha is passed in).
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/src/target,id=target-${APP} \
    --mount=type=cache,target=/root/.cache/trunk,id=trunk-${APP} \
    set -eu; \
    test -n "$APP" || { echo 'build-arg APP is required' >&2; exit 1; }; \
    test -f packaging/web/package.sh || { echo 'packaging/web/package.sh not found' >&2; exit 1; }; \
    prefix="$(printf '%s' "$APP" | tr 'a-z-' 'A-Z_')"; \
    [ "$APP" = craft-launcher ] && prefix=ARTCRAFT_LAUNCHER; \
    export "${prefix}_VERSION=$VERSION" "${prefix}_BUILD_SHA=$BUILD_SHA" "${prefix}_BUILD_DATE=$BUILD_DATE"; \
    bash packaging/web/package.sh; \
    zipfile="$(ls dist/release/*-web-"$VERSION".zip)"; \
    rm -rf /site && mkdir /site && unzip -q "$zipfile" -d /site; \
    mv /site/*-web-"$VERSION" /site/web; \
    test -s /site/web/index.html; \
    printf '{"app":"%s","version":"%s","sha":"%s","date":"%s"}\n' "$APP" "$VERSION" "$BUILD_SHA" "$BUILD_DATE" > /site/web/version.json; \
    rm -f /site/web/.htaccess /site/web/_headers; \
    gzip -9 -k /site/web/*.wasm /site/web/*.js /site/web/index.html

FROM nginx:${NGINX_VERSION} AS runtime
COPY --from=cfg nginx.conf /etc/nginx/nginx.conf
COPY --from=builder /site/web/ /usr/share/nginx/html/
# Bypass the stock entrypoint: this configuration needs no runtime rewriting.
USER nginx
EXPOSE 8080
ENTRYPOINT []
CMD ["nginx", "-g", "daemon off;"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
