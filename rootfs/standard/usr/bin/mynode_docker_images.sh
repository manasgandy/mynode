#!/bin/bash

# set -e # Stop on error (skip for now with new logic to allow an attempt to install each container)
set -x

source /usr/share/mynode/mynode_config.sh
source /usr/share/mynode/mynode_functions.sh
source /usr/share/mynode/mynode_app_versions.sh

echo "Starting mynode_docker_images.sh ..."
touch /tmp/installing_docker_images

# Drive should be mounted, let's still wait a bit
sleep 10s

echo "Waiting on bitcoin to sync so drive usage is lower..."
/usr/bin/wait_on_bitcoin.sh

while true; do
    echo "Checking for building new docker images..."
    touch /tmp/installing_docker_images

    # Check if we happened to change architectures (move from 32-bit to 64-bit Raspi4 image)
    CURRENT_ARCH=$(uname -m)
    SAVED_ARCH="unknown"
    if [ ! -f $DEVICE_ARCHITECTURE_FILE ]; then
        echo $CURRENT_ARCH > $DEVICE_ARCHITECTURE_FILE
    fi
    if [ -f $DEVICE_ARCHITECTURE_FILE ]; then
        SAVED_ARCH=$(cat $DEVICE_ARCHITECTURE_FILE)
    fi
    if [ "$CURRENT_ARCH" != "$SAVED_ARCH" ]; then
        # Reset docker stuff
        docker system prune --all --force

        # Remove containers known to cause problems if cached
        docker rmi debian:buster-slim

        # Mark mempool and dojo for re-install
        #  Must reset version for Dojo or it will fully re-install and break rather than 'upgrade'
        echo "reset" > $WEBSSH2_VERSION_FILE
        echo "reset" > $NETDATA_VERSION_FILE
        echo "reset" > $MEMPOOL_VERSION_FILE
        echo "reset" > $DOJO_VERSION_FILE
    fi
    echo $CURRENT_ARCH > $DEVICE_ARCHITECTURE_FILE

    # Pull images that don't need to be built
    # ???

    # Upgrade Netdata
    echo "Checking for new netdata..."
    CURRENT=""
    if [ -f $NETDATA_VERSION_FILE ]; then
        CURRENT=$(cat $NETDATA_VERSION_FILE)
    fi
    if [ "$CURRENT" != "$NETDATA_VERSION" ]; then
        docker rmi $(docker images --format '{{.Repository}}:{{.Tag}}' | grep 'netdata') || true

        docker pull netdata/netdata:${NETDATA_VERSION}

        echo $NETDATA_VERSION > $NETDATA_VERSION_FILE
    fi
    touch /tmp/need_application_refresh
    

    # Upgrade WebSSH2
    echo "Checking for new webssh2..."
    WEBSSH2_UPGRADE_URL=https://github.com/billchurch/webssh2/archive/${WEBSSH2_VERSION}.tar.gz
    CURRENT=""
    if [ -f $WEBSSH2_VERSION_FILE ]; then
        CURRENT=$(cat $WEBSSH2_VERSION_FILE)
    fi
    if [ "$CURRENT" != "$WEBSSH2_VERSION" ]; then
        docker rmi webssh2 || true

        cd /tmp/
        rm -rf webssh2
        wget $WEBSSH2_UPGRADE_URL -O webssh2.tar.gz
        tar -xvf webssh2.tar.gz
        rm webssh2.tar.gz
        mv webssh2-* webssh2
        cd webssh2
        docker build -t webssh2 .
        if [ $? == 0 ]; then
            echo $WEBSSH2_VERSION > $WEBSSH2_VERSION_FILE
        fi
    fi
    touch /tmp/need_application_refresh


    # Upgrade mempool
    MEMPOOL_UPGRADE_URL=https://github.com/mempool/mempool/archive/${MEMPOOL_VERSION}.tar.gz
    echo "Checking for new mempool..."
    if should_install_app "mempool" ; then
        CURRENT=""
        if [ -f $MEMPOOL_VERSION_FILE ]; then
            CURRENT=$(cat $MEMPOOL_VERSION_FILE)
        fi
        if [ "$CURRENT" != "$MEMPOOL_VERSION" ]; then
            docker rmi mempoolspace || true     # Remove old v1 image
            docker rmi $(docker images --format '{{.Repository}}:{{.Tag}}' | grep 'mempool') || true # Remove v2 images

            cd /mnt/hdd/mynode/mempool
            rm -rf data
            rm -rf mysql
            mkdir -p data mysql/data mysql/db-scripts
            cp -f /usr/share/mynode/mempool-docker-compose.yml /mnt/hdd/mynode/docker-compose.yml

            rm -rf /opt/download/mempool
            mkdir -p /opt/download/mempool
            cd /opt/download/mempool
            wget $MEMPOOL_UPGRADE_URL -O mempool.tar.gz
            tar -xvf mempool.tar.gz
            rm mempool.tar.gz
            mv mempool-* mempool
            cp -f mempool/mariadb-structure.sql /mnt/hdd/mynode/mempool/mysql/db-scripts/mariadb-structure.sql

            # Update env variable to use latest version
            sed -i "s/VERSION=.*/VERSION=$MEMPOOL_VERSION/g" /mnt/hdd/mynode/mempool/.env

            docker pull mempool/frontend:${MEMPOOL_VERSION}
            docker pull mempool/backend:${MEMPOOL_VERSION}

            enabled=$(systemctl is-enabled mempool)
            if [ "$enabled" = "enabled" ]; then
                systemctl restart mempool &
            fi

            echo $MEMPOOL_VERSION > $MEMPOOL_VERSION_FILE
        fi
    fi
    touch /tmp/need_application_refresh


    # Upgrade BTCPay Server (docker compose does install, just need version file update)
    if should_install_app "btcpayserver" ; then
        CURRENT=""
        if [ -f $BTCPAYSERVER_VERSION_FILE ]; then
            CURRENT=$(cat $BTCPAYSERVER_VERSION_FILE)
        fi
        if [ "$CURRENT" != "$BTCPAYSERVER_VERSION" ]; then
            echo $BTCPAYSERVER_VERSION > $BTCPAYSERVER_VERSION_FILE
        fi
    fi
    touch /tmp/need_application_refresh


    # Install Dojo
    DOJO_UPGRADE_URL=https://code.samourai.io/dojo/samourai-dojo/-/archive/$DOJO_VERSION/samourai-dojo-$DOJO_VERSION.tar.gz
    DOJO_UPGRADE_URL_FILE=/mnt/hdd/mynode/settings/dojo_url
    CURRENT=""
    INSTALL=true
    # If Upgrade file existed, mark "install" choice for legacy devices
    if [ -f /mnt/hdd/mynode/settings/dojo_url ] || [ -f /mnt/hdd/mynode/settings/mynode_dojo_install ]; then
        touch /mnt/hdd/mynode/settings/install_dojo
        sync
        sleep 3s
    fi
    # Only install Dojo if marked for installation and testnet not enabled
    if should_install_app "dojo" ; then
        if [ ! -f $IS_TESTNET_ENABLED_FILE ]; then
            if [ -f $DOJO_UPGRADE_URL_FILE ] && [ ! -f $DOJO_VERSION_FILE ]; then
                echo $DOJO_VERSION > $DOJO_VERSION_FILE
                sync
            fi
            if [ -f $DOJO_VERSION_FILE ]; then
                INSTALL=false
                CURRENT=$(cat $DOJO_VERSION_FILE)
            fi
            if [ "$CURRENT" != "$DOJO_VERSION" ]; then
                MARK_DOJO_COMPLETE=1
                sudo mkdir -p /opt/download/dojo
                sudo mkdir -p /mnt/hdd/mynode/dojo
                sudo rm -rf /opt/download/dojo/*
                cd /opt/download/dojo
                sudo wget -O dojo.tar.gz $DOJO_UPGRADE_URL

                # verify tar file
                echo "$DOJO_TAR_HASH  dojo.tar.gz" > /tmp/dojo_hash
                sha256sum --check /tmp/dojo_hash

                sudo tar -zxvf dojo.tar.gz
                sudo cp -r samourai-dojo*/* /mnt/hdd/mynode/dojo
                sudo rm -rf /opt/download/dojo/*

                # Configure Dojo for MyNode
                sudo /usr/bin/mynode_gen_dojo_config.sh || MARK_DOJO_COMPLETE=0

                # Fix for v1.12.1 (may need to remove later)
                sed -i "s/node:14-alpine.*/node:14-alpine3.12/g" /mnt/hdd/mynode/dojo/docker/my-dojo/node/Dockerfile

                # Run Dojo Install or Upgrade
                cd /mnt/hdd/mynode/dojo/docker/my-dojo
                INSTALL_PID=0
                if [ "$INSTALL" = "true" ]; then
                    yes | sudo ./dojo.sh install &
                    INSTALL_PID=$!
                else
                    yes | sudo ./dojo.sh upgrade &
                    INSTALL_PID=$!
                fi

                #Check for install/upgrade to finish to initialize Dojo mysql db
                sudo /usr/bin/mynode_post_dojo.sh

                # Wait for install script to finish
                wait $INSTALL_PID || MARK_DOJO_COMPLETE=0


                # Try and start dojo (if upgraded and already enabled)
                systemctl enable dojo &
                systemctl restart dojo &

                # Mark dojo install complete
                if [ $MARK_DOJO_COMPLETE = 1 ]; then
                    echo $DOJO_VERSION > $DOJO_VERSION_FILE
                fi
            fi
        fi
    fi
    touch /tmp/need_application_refresh

    rm -f /tmp/installing_docker_images
    touch /tmp/installing_docker_images_completed_once

    # Wait a day
    sleep 1d
done

# We should not exit
exit 1
