# Serve the pre-built Retype static site from nginx.
#
# The site is built on the host with `npx retypeapp build` (output in .retype/), then this image
# just serves it. Building here keeps the image tiny and avoids shipping the retype toolchain — the
# retype binary is glibc/.NET and network-dependent, so the build belongs on the host or in CI, not
# in the container. Rebuild the site before building the image:
#
#   npx retypeapp build && docker build -t xrpl-lending-docs .
#   docker run --rm -p 8080:80 xrpl-lending-docs   # http://localhost:8080

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY .retype /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost/ >/dev/null 2>&1 || exit 1
