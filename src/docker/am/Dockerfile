# PingAM 8.1.x image built from the vendor zip: Tomcat 10.1 (Jakarta EE / Servlet 5+) on JDK 21.
# AM 8.1.1 classes are Java 17 bytecode (class version 61) — verified.
# Build (from project root):
#   docker build --build-context apps=assets/apps --build-arg AM_ZIP=AM-8.1.1.zip \
#                -t ping-local/am:8.1.1 src/docker/am
#
# Webapp:  /usr/local/tomcat/webapps/am  (exploded war, context path /am)
# Volume:  /home/forgerock  (AM_HOME) — holds the AM config dir (openam/) and the
#          bootstrap pointer (.openamcfg/). Without it AM shows the setup wizard after restart.

# --- unpack ------------------------------------------------------------------
FROM alpine:3.22 AS unpack
ARG AM_ZIP=AM-8.1.1.zip
COPY --from=apps ${AM_ZIP} /tmp/am.zip
RUN unzip -q /tmp/am.zip 'openam/AM-*.war' -d /tmp \
 && mkdir -p /out/am \
 && unzip -q /tmp/openam/AM-*.war -d /out/am \
 && rm -rf /tmp/am.zip /tmp/openam

# --- runtime -----------------------------------------------------------------
FROM tomcat:10.1-jdk21-temurin

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tini curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 11111 --gid 0 --home-dir /home/forgerock --create-home forgerock \
 && rm -rf /usr/local/tomcat/webapps/* /usr/local/tomcat/webapps.dist

# Behind ingress-nginx (TLS terminated there): trust X-Forwarded-Proto/Port so AM sees https.
RUN sed -i 's|</Host>|  <Valve className="org.apache.catalina.valves.RemoteIpValve" internalProxies=".*" remoteIpHeader="x-forwarded-for" protocolHeader="x-forwarded-proto" portHeader="x-forwarded-port"/>\n      </Host>|' \
      /usr/local/tomcat/conf/server.xml \
 && grep -q RemoteIpValve /usr/local/tomcat/conf/server.xml

COPY --from=unpack --chown=11111:0 /out/am /usr/local/tomcat/webapps/am
COPY --chown=11111:0 --chmod=0755 entrypoint.sh /opt/entrypoint.sh
RUN chown -R 11111:0 /usr/local/tomcat /home/forgerock && chmod -R g=u /usr/local/tomcat /home/forgerock

ENV AM_HOME=/home/forgerock \
    CATALINA_OPTS="-XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError -Dcom.sun.identity.util.debug.provider=default"

USER 11111
WORKDIR /home/forgerock
VOLUME /home/forgerock
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/entrypoint.sh"]
CMD ["run"]
