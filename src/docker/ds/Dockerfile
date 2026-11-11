# PingDS 8.1.x image built from the vendor zip.
# Build (from project root):
#   docker build --build-context apps=assets/apps --build-arg DS_ZIP=DS-8.1.2.zip \
#                -t ping-local/ds:8.1.2 src/docker/ds
#
# Binaries in /opt/opendj (image). Volume /opt/opendj/data holds instance/ + deployment-id + setup marker.
# First start runs `setup` with the AM + IDM profiles; later starts just start DS.

# --- unpack ------------------------------------------------------------------
FROM alpine:3.22 AS unpack
ARG DS_ZIP=DS-8.1.2.zip
COPY --from=apps ${DS_ZIP} /tmp/ds.zip
RUN unzip -q /tmp/ds.zip -d /opt && rm /tmp/ds.zip

# --- runtime -----------------------------------------------------------------
# DS 8.1 requires Java 25+ (verified: fails on Java 21).
FROM eclipse-temurin:25-jre

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tini \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 11111 --gid 0 --home-dir /opt/opendj --no-create-home forgerock

COPY --from=unpack --chown=11111:0 /opt/opendj /opt/opendj
COPY --chown=11111:0 --chmod=0755 entrypoint.sh /opt/entrypoint.sh
RUN mkdir -p /opt/opendj/data && chown 11111:0 /opt/opendj/data && chmod -R g=u /opt/opendj

ENV DS_HOME=/opt/opendj \
    DS_DATA=/opt/opendj/data \
    DS_JAVA_ARGS="-XX:MaxRAMPercentage=60 -XX:+ExitOnOutOfMemoryError"

USER 11111
WORKDIR /opt/opendj
VOLUME /opt/opendj/data

# 1389 LDAP, 1636 LDAPS, 4444 admin, 8080 HTTP (health: /alive /healthy)
EXPOSE 1389 1636 4444 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/entrypoint.sh"]
CMD ["start"]
