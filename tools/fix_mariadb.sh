#!/bin/bash
echo "Stopping MariaDB..."
systemctl stop mariadb 2>/dev/null || true

echo "1. Completely purging MariaDB packages..."
apt-get purge -y mariadb-server mariadb-client mariadb-common mysql-common libmariadb-dev >/dev/null
apt-get autoremove -y >/dev/null

echo "2. Deleting leftover data and config directories..."
rm -rf /var/lib/mysql /etc/mysql /var/lib/mariadb

echo "3. Reinstalling MariaDB cleanly..."
# A fresh install (not --reinstall) after a purge will automatically restore
# /etc/mysql and automatically initialize /var/lib/mysql with the correct
# AppArmor security contexts, completely bypassing the permission errors.
apt-get install -y mariadb-server mariadb-client mariadb-common mysql-common libmariadb-dev

echo "4. Ensuring service is started..."
systemctl enable mariadb
systemctl start mariadb

echo "Done! The database is fully reset and running."
