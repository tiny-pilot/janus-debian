# syntax=docker/dockerfile:1.4
# Enable here-documents:
# https://github.com/moby/buildkit/blob/master/frontend/dockerfile/docs/syntax.md#here-documents

FROM debian:bullseye-20220328-slim AS build

ARG DEBIAN_FRONTEND='noninteractive'

# Install Debian packaging packages.
RUN apt-get update && \
    apt-get install --yes \
      debhelper \
      dpkg-dev \
      devscripts \
      equivs

# Install general-purpose packages.
RUN apt-get install --yes --no-install-recommends \
      git \
      wget \
      python3-pip \
      cmake \
      pkg-config

# Install additional libnice dependency packages.
RUN apt-get install --yes --no-install-recommends \
      libglib2.0-dev \
      libssl-dev \
      ninja-build

RUN pip3 install meson

# Install additional Janus dependency packages.
RUN apt-get install --yes --no-install-recommends \
      automake \
      libtool \
      libjansson-dev \
      libconfig-dev \
      gengetopt

# libince is recommended to be installed from source because the version
# installed via apt is too low.
ARG LIBNICE_VERSION='0.1.18'
RUN git clone https://gitlab.freedesktop.org/libnice/libnice \
      --branch "${LIBNICE_VERSION}" \
      --single-branch && \
    cd libnice && \
    meson --prefix=/usr build && \
    ninja -C build && \
    ninja -C build install

ARG LIBSRTP_VERSION='2.2.0'
RUN wget "https://github.com/cisco/libsrtp/archive/v${LIBSRTP_VERSION}.tar.gz" && \
    tar xfv "v${LIBSRTP_VERSION}.tar.gz" && \
    cd "libsrtp-${LIBSRTP_VERSION}" && \
    ./configure \
      --prefix=/usr \
      --enable-openssl && \
    make shared_library && \
    make install

ARG LIBWEBSOCKETS_VERSION='v3.2-stable'
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
      -DCMAKE_C_FLAGS='-fpic' \
      .. && \
    make && \
    make install

# Docker populates this value from the --platform argument. See
# https://docs.docker.com/build/building/multi-platform/
ARG TARGETPLATFORM

ARG PKG_NAME='janus'
ARG PKG_VERSION='1.3.2'

# This should be a timestamp, formatted `YYYYMMDDhhmmss`. That way the package
# manager always installs the most recently built package.
ARG PKG_BUILD_NUMBER

# Docker's platform names don't match Debian's platform names, so we translate
# the platform name from the Docker version to the Debian version and save the
# result to a file so we can re-use it in later stages.
RUN cat | bash <<'EOF'
set -eux
case "${TARGETPLATFORM}" in
  'linux/amd64')
    PKG_ARCH='amd64'
    ;;
  'linux/arm/v7')
    PKG_ARCH='armhf'
    ;;
  *)
    echo "Unrecognized target platform: ${TARGETPLATFORM}" >&2
    exit 1
esac
echo "${PKG_ARCH}" > /tmp/pkg-arch
echo "${PKG_NAME}_${PKG_VERSION}-${PKG_BUILD_NUMBER}_${PKG_ARCH}" > /tmp/pkg-id
EOF

# We ultimately need the directory name to be the package ID, but there's no
# way to specify a dynamic value in Docker's WORKDIR command, so we use a
# placeholder directory name to assemble the Debian package and then rename the
# directory to its package ID name in the final stages of packaging.
WORKDIR /build/placeholder-pkg-id

ARG JANUS_VERSION="v${PKG_VERSION}"
RUN git clone https://github.com/meetecho/janus-gateway.git \
      --branch "${JANUS_VERSION}" \
      --single-branch \
      .

# Include locally compiled shared library dependencies in the package.
# Note: Ensure that /usr/lib/janus is set as the RPATH during buildtime so that
# Janus can find these libraries at runtime.
RUN mkdir --parent usr/lib/janus && \
    cp --no-dereference \
      /usr/lib/arm-linux-gnueabihf/libnice.so* \
      /usr/lib/libsrtp2.so* \
      /usr/lib/libwebsockets.so* \
      usr/lib/janus

COPY ./debian-pkg ./

WORKDIR debian

RUN set -ux && \
    PKG_ARCH="$(cat /tmp/pkg-arch)" && \
    cat >control <<EOF
Source: ${PKG_NAME}
Section: comm
Priority: optional
Maintainer: TinyPilot Support <support@tinypilotkvm.com>
Build-Depends:
 debhelper (>= 11),
 libconfig-dev,
 libglib2.0-dev,
 libjansson-dev,
 libssl-dev

Package: ${PKG_NAME}
Architecture: ${PKG_ARCH}
Pre-Depends:
 \${misc:Pre-Depends}
Depends:
 \${misc:Depends},
 \${shlibs:Depends}
Homepage: https://janus.conf.meetecho.com/
Description: An open source, general purpose, WebRTC server
EOF

# Install build dependencies based on Debian control file.
RUN mk-build-deps \
      --tool 'apt-get --option Debug::pkgProblemResolver=yes --no-install-recommends -qqy' \
      --install \
      --remove \
      control

RUN cat >changelog <<EOF
${PKG_NAME} (${PKG_VERSION}-${PKG_BUILD_NUMBER}) bullseye; urgency=medium

  * Janus ${PKG_VERSION} release.

 -- TinyPilot Support <support@tinypilotkvm.com>  $(date '+%a, %d %b %Y %H:%M:%S %z')
EOF

# Rename the placeholder build directory to the final package ID.
WORKDIR /build
RUN set -ux && \
    PKG_ID="$(cat /tmp/pkg-id)" && \
    mv placeholder-pkg-id "${PKG_ID}" && \
    cd "${PKG_ID}" && \
    DH_VERBOSE=1 dpkg-buildpackage --build=binary

# Print build directory contents.
RUN apt-get install --yes tree && \
    tree

FROM scratch as artifact

COPY --from=build "/build/*.deb" ./
