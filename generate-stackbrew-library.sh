#!/usr/bin/env bash
set -Eeuo pipefail

# ----- config -----
SOURCE_REPO="https://github.com/DDVTECH/mistserver.git"
DOCKER_REPO="https://github.com/DDVTECH/mistserver-docker-builder.git"
FILE="Dockerfile.mistserver"
ARCHES="amd64 arm64v8"
MIN_VERSION="3.9.2"
MAX_VERSIONS=10

# ----- collect numeric tags -----
mapfile -t versions_all < <(
	git ls-remote --tags --refs "$SOURCE_REPO" \
	| awk '{print $2}' \
	| sed 's#refs/tags/##' \
	| grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
	| sort -Vr
)

# ----- shallow clone for file checks + extraction -----
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git clone --quiet --filter=blob:none --no-checkout "$SOURCE_REPO" "$TMP"

# ----- version compare -----
ver_ge() {
	local a b IFS=.
	read -r -a a <<<"$1"
	read -r -a b <<<"$2"
	for i in 0 1 2; do
		if (( ${a[i]:-0} > ${b[i]:-0} )); then return 0; fi
		if (( ${a[i]:-0} < ${b[i]:-0} )); then return 1; fi
	done
	return 0
}

# ----- filter valid versions -----
versions=()

for v in "${versions_all[@]}"; do
	if ver_ge "$v" "$MIN_VERSION" \
	&& git -C "$TMP" cat-file -e "refs/tags/$v:$FILE" 2>/dev/null; then
		versions+=( "$v" )
	fi
	(( ${#versions[@]} >= MAX_VERSIONS )) && break
done

if ((${#versions[@]} == 0)); then
	echo "ERROR: no tags >= $MIN_VERSION with Dockerfile found" >&2
	exit 1
fi

latest="${versions[0]}"

# ----- resolve commits -----
declare -A versionCommits
for v in "${versions[@]}"; do
	versionCommits[$v]="$(
		git ls-remote --tags --refs "$SOURCE_REPO" "refs/tags/$v" | awk '{print $1}'
	)"
done

# ----- generate dockerfiles into version folders -----
for v in "${versions[@]}"; do
	mkdir -p "$v"
	cat > "$v/$FILE" <<EOF
FROM alpine AS mist_build

# Pull in build requirements
RUN apk add --no-cache git patch meson ninja gcc g++ linux-headers pigz curl cjson pkgconfig

# Fetch MistServer from version-pinned source
RUN curl -fsSL -o /tmp/src.tar.gz "https://github.com/DDVTECH/mistserver/archive/refs/tags/${v}.tar.gz" && mkdir /src && tar -xzf /tmp/src.tar.gz --strip-components=1 -C /src && rm -f /tmp/src.tar.gz

# Install mbedtls
RUN mkdir -p /deps/build/mbedtls && curl -fsSL -o /tmp/mbedtls-3.6.5.tar.bz2 "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.5/mbedtls-3.6.5.tar.bz2" && tar -xjf /tmp/mbedtls-3.6.5.tar.bz2 -C /deps && rm -f /tmp/mbedtls-3.6.5.tar.bz2
RUN cp /src/subprojects/packagefiles/mbedtls/meson.build /deps/mbedtls-3.6.5/ && cp /src/subprojects/packagefiles/mbedtls/include/mbedtls/mbedtls_config.h /deps/mbedtls-3.6.5/include/mbedtls/ && cd /deps/build/mbedtls/ && meson setup /deps/mbedtls-3.6.5 -Dstrip=true && meson install

# Build MistServer
ARG MIST_OPTS
ARG DEBUG=3
ARG VERSION=${v}
ARG TARGETPLATFORM
ARG RELEASE=Docker_\${TARGETPLATFORM}
RUN mkdir /build/ && cd /build && meson setup /src -DDOCKERRUN=true -DNOUPDATE=true -DDEBUG=\${DEBUG} -DVERSION=\${VERSION} -DRELEASE=\${RELEASE} -Dstrip=true \${MIST_OPTS} && ninja install

# Expose MistServer
FROM alpine
RUN apk add --no-cache libstdc++ cjson
COPY --from=mist_build /usr/local/ /usr/local/
LABEL org.opencontainers.image.authors="Jaron Viëtor <jaron.vietor@ddvtech.com>"
EXPOSE 4242 8080 1935 5554 8889/udp 18203/udp
ENTRYPOINT ["MistController"]
HEALTHCHECK CMD ["MistUtilHealth"]
EOF
done

# ----- get the latest commit -----
DOCKER_COMMIT="$(
	git ls-remote "$DOCKER_REPO" refs/heads/main | awk '{print $1}'
)"

# ----- manifest header -----
cat <<-HEADER
Maintainers: Jaron Viëtor <jaron.vietor@ddvtech.com> (@Thulinma),
             Marco van Dijk <marco.van.dijk@ddvtech.com> (@stronk-dev),
             Carina van der Meer <carina.van.der.meer@ddvtech.com> (@thoronwen),
             Balder Viëtor <balder.vietor@ddvtech.com> (@Rokamun),
             Ramkoemar Bhoera <ramkoemar.bhoera@ddvtech.com> (@ramkoemar),
             Juno Jense <unit-stamp-sled@duck.com> (@junojense)
GitRepo: $DOCKER_REPO
GitFetch: refs/heads/main
GitCommit: $DOCKER_COMMIT
Builder: buildkit
HEADER

# ----- image entries -----
for v in "${versions[@]}"; do
	if [[ "$v" == "$latest" ]]; then
		tags="latest, $v"
	else
		tags="$v"
	fi

	cat <<-METADATA

Tags: $tags
Architectures: ${ARCHES// /, }
Directory: $v
File: $FILE

METADATA
done
