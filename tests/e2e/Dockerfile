# A fresh Ubuntu/Debian machine with systemd as PID 1, for end-to-end runs of
# install-frappe.sh. Only what any real server has is pre-installed: systemd,
# sudo, and a regular user with sudo rights. Everything else must be brought
# in by the installer itself.
ARG BASE=ubuntu:24.04
FROM ${BASE}

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus sudo \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash frappe \
 && echo 'frappe ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/frappe \
 && chmod 440 /etc/sudoers.d/frappe

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
