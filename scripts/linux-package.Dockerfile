FROM ubuntu:24.04 AS runtime
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends emacs-nox fonts-dejavu-core fonts-noto-cjk elpa-markdown-mode \
    && test -z "$(find /usr/lib -name 'libpango*.so*' -print -quit)"

FROM ubuntu:22.04 AS build
ENV DEBIAN_FRONTEND=noninteractive
RUN sed -i 's/^# deb-src /deb-src /' /etc/apt/sources.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential emacs-nox python3 pkg-config libpango1.0-dev patchelf ca-certificates
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list && apt-get update
WORKDIR /src
COPY Makefile pele.el LICENSE ./
COPY src/ src/
COPY vendor/ vendor/
COPY scripts/embed.py scripts/package.py scripts/
# Use the supported Emacs API while retaining Ubuntu 22.04's glibc baseline.
COPY --from=runtime /usr/include/emacs-module.h /opt/emacs/include/emacs-module.h
RUN make -j2 TEXT_BACKEND=pango EMACS_INCLUDE=/opt/emacs/include \
    && make package TEXT_BACKEND=pango EMACS_INCLUDE=/opt/emacs/include

# Test the relocated bundle in a newer runtime with neither Pango nor a compiler.
FROM runtime AS verify
WORKDIR /src
COPY . .
COPY --from=build /src/dist/ /src/dist/
RUN mkdir /bundle && tar -xzf $(find dist -name '*.tar.gz' ! -name '*-sources.tar.gz') -C /bundle \
    && rm -rf /etc/fonts \
    && PELE_PACKAGE_DIR=/bundle emacs -Q --batch --module-assertions -L . -L test \
       -l scripts/verify-package.el

FROM scratch AS artifacts
COPY --from=build /src/dist/ /
# Retain the verification stage as a required dependency of the artifact image.
COPY --from=verify /bundle/manifest.json /verified.json
