# Ping Platform UI 8.1.2 (admin /platform, end user /enduser, login /login) from the vendor zip,
# served by one unprivileged nginx (port 8080). URLs/client IDs are injected into the
# JS bundles at container start by the vendor variable_replacement.sh (envsubst).
# Build (from project root):
#   docker build --build-context apps=assets/apps --build-arg UI_ZIP=PlatformUI-8.1.2.0813.zip \
#                -t ping-local/platform-ui:8.1.2.0813 src/docker/platform-ui

FROM alpine:3.22 AS unpack
ARG UI_ZIP=PlatformUI-8.1.2.0813.zip
COPY --from=apps ${UI_ZIP} /tmp/ui.zip
RUN unzip -q /tmp/ui.zip -d /tmp \
 && mkdir -p /out \
 && mv /tmp/PlatformUI/www /out/html \
 && mv /tmp/PlatformUI/variable_replacement.sh /out/variable_replacement.sh \
 && find /out/html -name '*.map' -delete \
 && rm -rf /tmp/ui.zip /tmp/PlatformUI

# nginx-unprivileged: runs as uid 101, listens on 8080; envsubst is included (gettext).
FROM nginxinc/nginx-unprivileged:1.29-alpine

USER root
COPY --from=unpack --chown=101:0 /out/html /usr/share/nginx/html
COPY --from=unpack --chown=101:0 --chmod=0755 /out/variable_replacement.sh /opt/variable_replacement.sh
COPY --chown=101:0 --chmod=0755 entrypoint.sh /opt/entrypoint.sh
COPY --chown=101:0 nginx.conf /etc/nginx/conf.d/default.conf
RUN chmod -R g=u /usr/share/nginx/html && command -v envsubst
USER 101

EXPOSE 8080
ENTRYPOINT ["/opt/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
