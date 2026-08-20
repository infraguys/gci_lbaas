#!/usr/bin/env bash

# Copyright 2025 Genesis Corporation
#
# All Rights Reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

set -eu
set -x
set -o pipefail

SDK_MIN_VER=3.0.5


# Kernel package hooks run while the full load-balancer stack is active after
# deployment. Keep compression memory deterministic so a package upgrade cannot
# leave a truncated initramfs that fails only on the next boot.
sudo install -d -m 0755 \
    /etc/dracut.conf.d \
    /etc/initramfs/post-update.d \
    /etc/kernel/postinst.d \
    /usr/local/libexec \
    /usr/local/sbin
sudo install -m 0644 \
    /opt/gci_lbaas/etc/dracut.conf.d/20-low-memory.conf \
    /etc/dracut.conf.d/20-low-memory.conf
sudo install -m 0755 \
    /opt/gci_lbaas/usr/local/libexec/exordos-validate-initramfs \
    /usr/local/libexec/exordos-validate-initramfs
sudo install -m 0755 \
    /opt/gci_lbaas/usr/local/sbin/dracut \
    /usr/local/sbin/dracut
sudo install -m 0755 \
    /opt/gci_lbaas/etc/initramfs/post-update.d/00-exordos-validate-initramfs \
    /etc/initramfs/post-update.d/00-exordos-validate-initramfs
sudo install -m 0755 \
    /opt/gci_lbaas/etc/kernel/postinst.d/zz-exordos-validate-initramfs \
    /etc/kernel/postinst.d/zz-exordos-validate-initramfs


# Install packages
sudo apt update
sudo apt dist-upgrade -y
sudo apt install -y \
    crudini \
    nginx-full

sudo systemctl enable nginx

sudo mkdir -p /etc/nginx/ssl
sudo chown www-data:www-data /etc/nginx/ssl
sudo mkdir -p /etc/nginx/exordos/

# Cert to restrict default_server
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -subj "/C=PE/ST=Exordos/L=Exordos/O=Exordos core dummy cert. /OU=IT Department/CN=exordos.core" -keyout /etc/nginx/ssl/nginx.key -out /etc/nginx/ssl/nginx.crt

# Block any connections not explicitly set
cat <<EOF | sudo tee /etc/nginx/sites-enabled/default
server {
    listen 80 default_server reuseport;
    listen 443 ssl default_server reuseport;
    listen [::]:80 default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;

    location / {
        return 444;
    }
}
EOF

cat <<EOF | sudo tee -a /etc/nginx/nginx.conf
include /etc/nginx/exordos/*.conf;
EOF

# enable driver
UA_CONF=/etc/exordos_universal_agent/exordos_universal_agent.conf
DRIVERS="$(crudini --get "$UA_CONF" universal_agent caps_drivers)"
crudini --set "$UA_CONF" universal_agent caps_drivers "${DRIVERS},LBCapabilityDriver"

# Use fresh sdk
/opt/universal_agent/.venv/bin/pip install --upgrade "gcl_sdk>=${SDK_MIN_VER}"

cat >>/etc/systemd/system.conf <<EOF

DefaultLimitNOFILE=524288
DefaultLimitNPROC=65000
DefaultTasksMax=65000
EOF

rsync -a /opt/gci_lbaas/etc/sysctl.d/* /etc/sysctl.d/

# The build must never publish a kernel whose initramfs is already damaged.
for initramfs in /boot/initrd.img-*; do
    [ -e "$initramfs" ] || continue
    version=${initramfs##*/initrd.img-}
    /etc/kernel/postinst.d/zz-exordos-validate-initramfs \
        "$version" "/boot/vmlinuz-${version}"
done
