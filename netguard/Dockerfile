ARG NETGUARD_BASE_IMAGE
FROM ${NETGUARD_BASE_IMAGE}

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         ca-certificates iptables tinyproxy procps util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 proxyguard \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin proxyguard

COPY --chmod=0755 netguard/entrypoint.sh /usr/local/sbin/netguard-entrypoint
COPY --chmod=0755 netguard/healthcheck.sh /usr/local/sbin/netguard-healthcheck
COPY --chmod=0644 netguard/tinyproxy.conf /etc/tinyproxy/secure.conf

ENTRYPOINT ["/usr/local/sbin/netguard-entrypoint"]
