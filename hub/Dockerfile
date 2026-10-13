# syntax=docker/dockerfile:1
# The hub: nginx in front of the suite. `/` is the launcher (hub mode), `/<id>/` each app.
# Build context = repo root:  docker build -f hub/Dockerfile -t craft-apps-hub .
ARG NGINX_VERSION=1.28-alpine
FROM nginx:${NGINX_VERSION}
COPY hub/nginx.conf /etc/nginx/nginx.conf
COPY hub/proxy.conf /etc/nginx/proxy.conf
USER nginx
EXPOSE 8080
ENTRYPOINT []
CMD ["nginx", "-g", "daemon off;"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
