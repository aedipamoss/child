#!/usr/bin/env bash
set -euo pipefail

if command -v lsb_release >/dev/null 2>&1; then
  codename="$(lsb_release -cs)"
elif [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
else
  codename=""
fi

if [ -z "${codename}" ]; then
  echo "Unable to determine Debian codename" >&2
  exit 1
fi

apt-get update
apt-get install -y --no-install-recommends curl gnupg ca-certificates

install -d -m 0755 /etc/apt/keyrings

curl -sS https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
  gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt/ ${codename}-pgdg main" | \
  tee /etc/apt/sources.list.d/pgdg.list >/dev/null

curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
  gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_18.x nodistro main" | \
  tee /etc/apt/sources.list.d/nodesource.list >/dev/null

curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | \
  gpg --dearmor -o /etc/apt/keyrings/yarn.gpg
echo "deb [signed-by=/etc/apt/keyrings/yarn.gpg] http://dl.yarnpkg.com/debian/ stable main" | \
  tee /etc/apt/sources.list.d/yarn.list >/dev/null

apt-get update

build_deps=(
  autoconf
  automake
  bzip2
  dpkg-dev
  file
  g++
  gcc
  imagemagick
  libbz2-dev
  libc6-dev
  libcurl4-openssl-dev
  libdb-dev
  libevent-dev
  libffi-dev
  libgdbm-dev
  libgeoip-dev
  libglib2.0-dev
  libjpeg-dev
  libkrb5-dev
  liblzma-dev
  libmagickcore-dev
  libmagickwand-dev
  libncurses5-dev
  libncursesw5-dev
  libpng-dev
  libpq-dev
  libreadline-dev
  libsqlite3-dev
  libssl-dev
  libtool
  libvips
  libvips-dev
  libwebp-dev
  libxml2-dev
  libxslt-dev
  libyaml-dev
  make
  patch
  unzip
  xz-utils
  zlib1g-dev
)

if apt-cache show default-libmysqlclient-dev 2>/dev/null | grep -q '^Version:'; then
  build_deps+=(default-libmysqlclient-dev)
else
  build_deps+=(libmysqlclient-dev)
fi

if apt-cache show tzdata-legacy 2>/dev/null | grep -q '^Version:'; then
  build_deps+=(tzdata-legacy)
fi

app_deps=(
  postgresql-client default-mysql-client sqlite3 git
  nodejs=18.19.0-1nodesource1 yarn lsof ffmpeg mupdf mupdf-tools poppler-utils
)

apt-get install -y --no-install-recommends "${build_deps[@]}" "${app_deps[@]}"
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/*
