# Build the Retype static site from source, then serve it from nginx.
#
# Builds entirely from the repo — no pre-built output required — so any platform that builds from a
# git checkout (EasyPanel, CI, `docker build`) can deploy it directly.
#
#   docker build -t xrpl-lending-docs .
#   docker run --rm -p 8080:80 xrpl-lending-docs   # http://localhost:8080

# --- Build stage: render docs/ into a static site ---
# Install retype as a dotnet tool (Retype is a .NET app; the SDK image gives it the correct runtime —
# no manual libicu/glibc fixes, no Node needed to build). Retype 4.6.0's tool targets net10.0, so the
# SDK image MUST be 10.0 — an older SDK (e.g. 9.0) fails with "DotnetToolSettings.xml not found".
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /build
RUN dotnet tool install retypeapp --version 4.6.0 --tool-path /usr/local/bin
COPY retype.yml ./
COPY docs ./docs
# Build to an explicit output dir, then fail loudly if retype emitted nothing.
RUN retype build --output .site \
    && test -f .site/index.html \
    || (echo "ERROR: retype build produced no .site/index.html" && ls -la .site 2>/dev/null; exit 1)

# --- Serve stage: a tiny nginx image serving the built output ---
FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /build/.site /usr/share/nginx/html
EXPOSE 80
# No container-level HEALTHCHECK: the platform's reverse proxy does its own health probing, and a
# flaky in-container check can leave the container marked "unhealthy" so the proxy won't route to it
# (surfacing as a 502 even though nginx is serving fine).
