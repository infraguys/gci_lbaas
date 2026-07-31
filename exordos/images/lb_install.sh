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

# Block unmatched HTTP connections. HTTPS listeners are created only for
# load-balancer virtual hosts that have certificates configured.
cat <<EOF | sudo tee /etc/nginx/sites-enabled/default
server {
    listen 80 default_server reuseport;
    listen [::]:80 default_server;
    server_name _;

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
