# PingIDM 8.1.x image built from the vendor zip.
# Follows the vendor's openidm/bin/Custom.Dockerfile (Java 21, uid 11111, port 8080,
# bin/docker-entrypoint.sh) but uses public eclipse-temurin instead of gcr.io/forgerock-io.
# Build (from project root):
#   docker build --build-context apps=assets/apps --build-arg IDM_ZIP=IDM-8.1.2.zip \
#                -t ping-local/idm:8.1.2 src/docker/idm

# --- unpack + patch ----------------------------------------------------------
FROM alpine:3.22 AS unpack
ARG IDM_ZIP=IDM-8.1.2.zip
COPY --from=apps ${IDM_ZIP} /tmp/idm.zip
RUN unzip -q /tmp/idm.zip -d /opt && rm /tmp/idm.zip
# External DS repo: replace hard-coded localhost:31389 / uid=admin / password with
# property placeholders, resolved from env (OPENIDM_REPO_HOST, ...) or boot.properties.
RUN f=/opt/openidm/conf/repo.ds.json \
 && sed -i \
      -e 's|"hostname" : "localhost"|"hostname" : "\&{openidm.repo.host\|localhost}"|' \
      -e 's|"port" : 31389|"port" : { "$int" : "\&{openidm.repo.port\|1389}" }|' \
      -e 's|"bindDn" : "uid=admin"|"bindDn" : "\&{openidm.repo.binddn\|uid=admin}"|' \
      -e 's|"bindPassword" : "str0ngAdm1nPa55word"|"bindPassword" : "\&{openidm.repo.password}"|' \
      "$f" \
 && grep -q 'openidm.repo.host' "$f" && grep -q 'openidm.repo.port' "$f" \
 && grep -q 'openidm.repo.binddn' "$f" && grep -q 'openidm.repo.password' "$f"
# Platform integration (shared identity store, rsFilter, platformSettings) — see platform/patch-conf.sh
RUN apk add --no-cache jq
COPY platform /tmp/platform
RUN sh /tmp/platform/patch-conf.sh

# --- runtime -----------------------------------------------------------------
FROM eclipse-temurin:21-jre

# fonts-dejavu: needed by the Flowable workflow engine (vendor Dockerfile)
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends fonts-dejavu tini curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 11111 --gid 0 --home-dir /opt/openidm --no-create-home forgerock

COPY --from=unpack --chown=11111:0 /opt/openidm /opt/openidm
COPY --chown=11111:0 --chmod=0755 entrypoint.sh /opt/entrypoint.sh
RUN chmod -R g=u /opt/openidm

USER 11111
WORKDIR /opt/openidm
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/entrypoint.sh"]
CMD ["openidm"]
