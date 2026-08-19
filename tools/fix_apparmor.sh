#!/bin/bash
echo "Disabling broken AppArmor profile for MariaDB..."
if [[ -f "/etc/apparmor.d/usr.sbin.mysqld" ]]; then
  ln -s /etc/apparmor.d/usr.sbin.mysqld /etc/apparmor.d/disable/ 2>/dev/null
  apparmor_parser -R /etc/apparmor.d/usr.sbin.mysqld 2>/dev/null || true
elif [[ -f "/etc/apparmor.d/usr.sbin.mariadbd" ]]; then
  ln -s /etc/apparmor.d/usr.sbin.mariadbd /etc/apparmor.d/disable/ 2>/dev/null
  apparmor_parser -R /etc/apparmor.d/usr.sbin.mariadbd 2>/dev/null || true
fi

echo "Initializing database tables..."
mkdir -p /var/lib/mysql
chown -R mysql:mysql /var/lib/mysql
chmod 700 /var/lib/mysql
mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql

echo "Starting MariaDB..."
systemctl start mariadb

echo "Done! The database is now running."
