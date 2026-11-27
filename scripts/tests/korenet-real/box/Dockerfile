# A Linux box for scripts/tests/korenet-real: systemd as PID 1 (user units, linger, boot order),
# real sshd, real tailscaled (kernel mode, tailscale0) built from the tailscale.com module the
# kore-tailnet helper uses. kore-host and kore-tailnet are never baked in: Kore's Set up puts them
# there over SSH, as on a real box.
FROM debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus dbus-user-session libpam-systemd openssh-server sudo iptables \
      socat procps iproute2 xz-utils ca-certificates rsync \
    && rm -rf /var/lib/apt/lists/* /usr/share/doc /usr/share/man
COPY tailscaled /usr/sbin/tailscaled
COPY tailscale /usr/bin/tailscale
COPY derper /usr/local/bin/derper
COPY tailscaled.service rig-forward.service /etc/systemd/system/
RUN systemctl enable ssh rig-forward.service \
    && systemctl mask getty@.service console-getty.service systemd-firstboot.service systemd-logind-varlink.socket 2>/dev/null; \
    useradd -m -s /bin/bash kore && useradd -m -s /bin/bash nosudo \
    && echo 'kore ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/kore && chmod 440 /etc/sudoers.d/kore \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
    && mkdir -p /etc/environment.d
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
