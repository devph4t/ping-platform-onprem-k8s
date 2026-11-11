# Platform configuration runner (k8s Job): bash + curl + jq + envsubst, the config scripts
# and payloads from src/config, and the vendor sample journeys from the AM zip.
# Build (from project root):
#   docker build --build-context apps=assets/apps --build-context config=src/config \
#                --build-arg AM_ZIP=AM-8.1.1.zip -t ping-local/platform-config:1 src/docker/platform-config

FROM alpine:3.22 AS trees
ARG AM_ZIP=AM-8.1.1.zip
COPY --from=apps ${AM_ZIP} /tmp/am.zip
RUN unzip -q /tmp/am.zip 'openam/sample-trees-*.zip' -d /tmp \
 && mkdir -p /out && unzip -q /tmp/openam/sample-trees-*.zip -d /out/sample-trees \
 && test -d /out/sample-trees/root/AuthTree

FROM alpine:3.22
RUN apk add --no-cache bash curl jq gettext \
 && adduser -D -u 11111 -G root config
COPY --from=trees --chown=11111:0 /out/sample-trees /opt/platform-config/sample-trees
COPY --from=config --chown=11111:0 . /opt/platform-config/
RUN chmod 0755 /opt/platform-config/*.sh
USER 11111
WORKDIR /opt/platform-config
ENTRYPOINT ["/opt/platform-config/configure.sh"]
