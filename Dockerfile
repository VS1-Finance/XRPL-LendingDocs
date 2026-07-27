# Build the Retype static site from source, then serve it from nginx.
#
# This builds entirely from the repo — no pre-built .retype/ is required — so it works on any
# platform that builds from a git checkout (EasyPanel, CI, `docker build`).
#
# The build stage must be a glibc image (Debian slim), not Alpine/musl: retype ships a glibc-linked
# .NET binary that cannot execute under musl. The serve stage stays on nginx-alpine.
#
#   docker build -t xrpl-lending-docs .
#   docker run --rm -p 8080:80 xrpl-lending-docs   # http://localhost:8080

# --- Build stage: render docs/ into a static site ---
FROM node:20-bookworm-slim AS build
WORKDIR /docs
COPY package.json ./
RUN npm install
COPY retype.yml ./
COPY docs ./docs
RUN npx retypeapp build

# --- Serve stage: a tiny nginx image serving the built output ---
FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /docs/.retype /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost/ >/dev/null 2>&1 || exit 1
