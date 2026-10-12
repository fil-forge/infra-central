# strongSwan and a psql client for scripts/check-pandora-vpn-host.sh and
# scripts/check-pandora-vpn-laptop.sh. Built where it runs.
FROM ubuntu:24.04

# libstrongswan-standard-plugins carries the openssl and gcm plugins, without
# which charon has neither DH groups 20 and 21 nor AES-GCM. It is only a
# recommended package, so it is named here.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates charon-systemd iproute2 libstrongswan-standard-plugins nftables \
      postgresql-client strongswan-swanctl \
 && rm -rf /var/lib/apt/lists/*

COPY strongswan-logging.conf /etc/strongswan.d/zz-pandora-vpn-check.conf
COPY strongswan-entrypoint.sh client-entrypoint.sh /usr/local/bin/
