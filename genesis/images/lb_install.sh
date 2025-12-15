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

SDK_MIN_VER=0.11.1


# Install packages
sudo apt update
sudo apt dist-upgrade -y
sudo apt install -y \
    nginx-full

sudo systemctl enable nginx

sudo mkdir -p /etc/nginx/ssl
sudo chown www-data:www-data /etc/nginx/ssl
sudo mkdir -p /etc/nginx/genesis/

# Cert to restrict default_server
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -subj "/C=PE/ST=Genesis/L=Genesis/O=Genesis core dummy cert. /OU=IT Department/CN=genesis.core" -keyout /etc/nginx/ssl/nginx.key -out /etc/nginx/ssl/nginx.crt

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
include /etc/nginx/genesis/*.conf;
EOF

# enable driver
sudo sed -i '/caps_drivers/ s/$/,LBCapabilityDriver/' /etc/genesis_universal_agent/genesis_universal_agent.conf

# Use fresh sdk
source /opt/universal_agent/.venv/bin/activate
pip install --upgrade gcl_sdk>=$SDK_MIN_VER

cat >>/etc/systemd/system.conf <<EOF

DefaultLimitNOFILE=524288
DefaultLimitNPROC=65000
DefaultTasksMax=65000
EOF

rsync -a /opt/gci_lbaas/etc/sysctl.d/* /etc/sysctl.d/
