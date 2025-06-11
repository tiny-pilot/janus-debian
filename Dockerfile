# syntax=docker/dockerfile:1.4
# Enable here-documents:
# https://github.com/moby/buildkit/blob/master/frontend/dockerfile/docs/syntax.md#here-documents

FROM debian:buster-20220418-slim AS build

RUN set -x && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      dpkg-dev

# Install general-purpose packages.
RUN apt-get install -y --no-install-recommends \
    git \
    wget \
    python3-pip \
    cmake \
    pkg-config

# Install additional libnice dependency packages.
RUN apt-get install -y --no-install-recommends \
    libglib2.0-dev \
    libssl-dev \
    ninja-build

RUN pip3 install meson

# Install additional Janus dependency packages.
RUN apt-get install -y --no-install-recommends \
    automake \
    libtool \
    libjansson-dev \
    libconfig-dev \
    gengetopt

# libince is recommended to be installed from source because the version
# installed via apt is too low.
ARG LIBNICE_VERSION="0.1.18"
RUN git clone https://gitlab.freedesktop.org/libnice/libnice \
        --branch "${LIBNICE_VERSION}" \
        --single-branch && \
    cd libnice && \
    meson --prefix=/usr build && \
    ninja -C build && \
    ninja -C build install

ARG LIBSRTP_VERSION="2.2.0"
RUN wget "https://github.com/cisco/libsrtp/archive/v${LIBSRTP_VERSION}.tar.gz" && \
    tar xfv "v${LIBSRTP_VERSION}.tar.gz" && \
    cd "libsrtp-${LIBSRTP_VERSION}" && \
    ./configure --prefix=/usr \
        --enable-openssl && \
    make shared_library && \
    make install

ARG LIBWEBSOCKETS_VERSION="v3.2-stable"
RUN git clone https://libwebsockets.org/repo/libwebsockets \
        --branch "${LIBWEBSOCKETS_VERSION}" \
        --single-branch && \
    cd libwebsockets && \
    mkdir build && \
    cd build && \
    cmake \
        # https://github.com/meetecho/janus-gateway/issues/732
        -DLWS_MAX_SMP=1 \
        # https://github.com/meetecho/janus-gateway/issues/2476
        -DLWS_WITHOUT_EXTENSIONS=0 \
        -DCMAKE_INSTALL_PREFIX:PATH=/usr \
        -DCMAKE_C_FLAGS="-fpic" \
        .. && \
    make && \
    make install

# Compile Janus.
ARG JANUS_VERSION="1.3.1"
ARG INSTALL_DIR="/opt/janus"
RUN git clone https://github.com/meetecho/janus-gateway.git \
        --branch "v${JANUS_VERSION}" \
        --single-branch && \
    cd janus-gateway && \
    sh autogen.sh && \
    ./configure --prefix="${INSTALL_DIR}" \
        --disable-all-plugins \
        --disable-all-transports \
        --disable-all-handlers \
        --disable-all-loggers \
        --enable-websockets && \
    make && \
    make install

# Allow Janus C header files to be included when compiling third-party plugins.
# Issue: https://github.com/tiny-pilot/ansible-role-tinypilot/issues/192
RUN sed -i -e 's|^#include "refcount.h"$|#include "../refcount.h"|g' \
    "${INSTALL_DIR}/include/janus/plugins/plugin.h" && \
    ln -s "${INSTALL_DIR}/include/janus" /usr/include/ || true

# Ensure Janus default library directories exist.
RUN mkdir --parents "${INSTALL_DIR}/lib/janus/plugins" \
    "${INSTALL_DIR}/lib/janus/transports" \
    "${INSTALL_DIR}/lib/janus/loggers"

# Use Janus sample config.
RUN mv "${INSTALL_DIR}/etc/janus/janus.jcfg.sample" \
        "${INSTALL_DIR}/etc/janus/janus.jcfg" && \
    mv "${INSTALL_DIR}/etc/janus/janus.transport.websockets.jcfg.sample" \
        "${INSTALL_DIR}/etc/janus/janus.transport.websockets.jcfg"

# Overwrite Janus WebSocket config.
RUN cat > "${INSTALL_DIR}/etc/janus/janus.transport.websockets.jcfg" <<EOF
general: {
    ws = true
    ws_ip = "127.0.0.1"
    ws_port = 8002
}
EOF

RUN cat > "/lib/systemd/system/janus.service" <<EOF
[Unit]
Description=Janus WebRTC gateway
After=network.target
Documentation=https://janus.conf.meetecho.com/docs/index.html

[Service]
Type=forking
ExecStart=${INSTALL_DIR}/bin/janus --disable-colors --daemon --log-stdout
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

ARG PKG_NAME="janus"
ARG PKG_VERSION="0.0.0"
ARG PKG_BUILD_NUMBER="1"
ARG PKG_ARCH="armhf"
ARG PKG_ID="${PKG_NAME}_${PKG_VERSION}-${PKG_BUILD_NUMBER}_${PKG_ARCH}"
ARG PKG_DIR="/releases/${PKG_ID}"
RUN mkdir --parents "${PKG_DIR}"

COPY ./debian-pkg "${PKG_DIR}"

# Add Janus files to the Debian package.
RUN cp --parents --recursive --no-dereference "${INSTALL_DIR}/etc/janus" \
    "${INSTALL_DIR}/bin/janus" \
    "${INSTALL_DIR}/bin/janus-cfgconv" \
    "${INSTALL_DIR}/lib/janus" \
    "${INSTALL_DIR}/include/janus" \
    /usr/include/janus \
    "${INSTALL_DIR}/share/janus" \
    "${INSTALL_DIR}/share/doc/janus-gateway" \
    "${INSTALL_DIR}/share/man/man1/janus.1" \
    "${INSTALL_DIR}/share/man/man1/janus-cfgconv.1" \
    /lib/systemd/system/janus.service \
    "${PKG_DIR}/"

# Add Janus compiled shared library dependencies to the Debian package.
RUN cp --parents --no-dereference /usr/lib/arm-linux-gnueabihf/libnice.so* \
    /usr/lib/libsrtp2.so* \
    /usr/lib/libwebsockets.so* \
    "${PKG_DIR}/"

WORKDIR "${PKG_DIR}/DEBIAN"

RUN cat > control <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Maintainer: TinyPilot Support <support@tinypilotkvm.com>
Depends: libconfig9, libglib2.0-0, libjansson4, libssl1.1, libc6, libsystemd0
Conflicts: libnice10, libsrtp2-1, libwebsockets16
Architecture: ${PKG_ARCH}
Homepage: https://janus.conf.meetecho.com/
Description: An open source, general purpose, WebRTC server
EOF

RUN dpkg --build "${PKG_DIR}"

FROM scratch as artifact

COPY --from=build "/releases/*.deb" ./
