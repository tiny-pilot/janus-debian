# Janus Debian Package

[![License](http://img.shields.io/:license-mit-blue.svg?style=flat-square)](LICENSE)
[![CircleCI](https://circleci.com/gh/tiny-pilot/janus-debian/tree/master.svg?style=svg)](https://circleci.com/gh/tiny-pilot/janus-debian/tree/master)

Use CircleCI to build an ARM64 Debian package for the Janus WebRTC server.

## Overview

We use Docker as a build context for creating an ARM64 Debian package, with precompiled Janus binaries (see the [Dockerfile](Dockerfile) for the complete build procedure). The resulting artifact is emitted to the `build/` folder. For example:

```bash
build/janus_1.0.1-20220513_arm64.deb
```

## Pre-requisites

* Raspberry Pi OS Trixie (64-bit)
* Docker
* Git

## Build

On the device, run the following commands:

```bash
# Build Debian package.
pushd "$(mktemp -d)" && \
  git clone https://github.com/tiny-pilot/janus-debian.git . && \
  ./dev-scripts/build-debian-pkg 'linux/arm64'
```

## Install

On the device, run the following command:

```bash
# Install Debian package.
sudo apt-get install --yes ./build/janus_*.deb
```

You can confirm that the Janus systemd service is running, by executing the following command:

```bash
sudo systemctl status janus.service
```

## Uninstall

On the device, run the following command:

```bash
sudo apt-get purge --yes janus
```
