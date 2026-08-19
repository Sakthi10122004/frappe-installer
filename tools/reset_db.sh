#!/bin/bash
echo "================================================================="
echo "WARNING: This will completely DESTROY all databases in MariaDB!"
echo "Only proceed if this is a fresh setup with NO DATA you care about."
echo "================================================================="
read -p "Type YES to completely wipe MariaDB and start fresh: " confirm
if [ "$confirm" != "YES" ]; then
  echo "Aborting."
  exit 1
fi

echo "Stopping MariaDB..."
systemctl stop mariadb 2>/dev/null || true

echo "Purging MariaDB packages..."
apt-get purge -y mariadb-server mariadb-client mariadb-common mysql-common libmariadb-dev >/dev/null

echo "Deleting all database files and configurations..."
rm -rf /var/lib/mysql /etc/mysql /var/lib/mariadb

echo "Done! MariaDB has been completely wiped. The installer will now install it fresh."
