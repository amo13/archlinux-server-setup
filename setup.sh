#!/bin/bash

### Interactive Arch Linux post-install script for server setup

### Presumptions:
###		- Running on a freshly installed archlinux system
###		- Working internet connection (networking already set up)
###
### Notice:
###		- Change passwords only after completion of this script

# shellcheck disable=SC2162
# shellcheck disable=SC2012

### Parse command line arguments
while [ ! -z "$1" ];do
   case "$1" in
        --stfu|--all)
          stfu="y"
          ;;
        *)
       echo "Incorrect input provided"
       exit
   esac
shift
done


### Script needs to be started as root
if [ ! "$(whoami)" == "root" ]; then
	echo "Please start this script as root or with sudo."
	exit
fi


### Define some variables
repo_raw_url='https://raw.githubusercontent.com/amo13/archlinux-server-setup/main/'
hostname=$(uname -n | tr -d '\n')
root_fs_type=$(mount | grep "^/dev" | grep -oP "(?<=on / type )[^ ]+" | tr -d '\n')


### Default unprivileged user
create_default_user() {
	useradd -m -G ftp,http,mail,wheel "$1"
	echo "Set a password for the new user:"
	passwd "$1"
}
users_count=$(ls -x /home | wc -l)
if [ "$users_count" -eq 0 ]; then
	echo "No default unprivileged user found. Creating one..."
	read -p "Enter new user name: " default_user
	create_default_user "$default_user"
elif [ "$users_count" -eq 1 ]; then
	default_user="$(ls -x /home | tr -d '\n')"
	echo "Setting default unprivileged user to $default_user"
	useradd -m -G ftp,http,mail,wheel "$default_user"
else
	read -p "Enter the name of your default unprivileged user: " default_user
	while [ -z "$default_user" ] || [ ! -d /home/"$default_user" ]; do
		echo "Either you left the user name empty or the user you entered has no home directory."
		read -p "Enter the name of your default unprivileged user: " default_user
	done
	create_default_user "$default_user"
fi


### Set the home folder of the default user as working directory
cd /home/"$default_user" || exit


### Ask all inevitable questions right at the beginning
# Ask for the domain to use
read -p "Enter your domain or leave empty if you do not have one: " user_domain
if [ -z "$user_domain" ]; then
	user_domain="domain.tld"
fi
# Ask for gotify admin user name now if --stfu argument has been given
[ "$stfu" == "y" ] && read -p "Enter admin user name for gotify [default: $default_user]: " gotify_admin_user
# Set to default if nothing has been entered
[ "$stfu" == "y" ] && [ -z "$gotify_admin_user" ] && gotify_admin_user="$default_user"
# Ask for nextcloud tarball download url now if --stfu argument has been given
[ "$stfu" == "y" ] && read -p "Please paste the url to the latest nextcloud release tarball: " nextcloud_latest


### Namecheap dynamic DNS update
read -p "Is your domain registered with namecheap? [Y,n]: " namecheap_domain
if [ "$namecheap_domain" != "n" ]; then
	read -p "Setup a DNS update timer? [Y,n]: " namecheap_domain_update
	if [ "$namecheap_domain_update" != "n" ]; then
		# Ask for the dynamic DNS password from the Namecheap dashboard
		read -p "Enter your Namecheap dynamic DNS password for $user_domain: " namecheap_dns_password
		# Make sure the parent folder of the following script exists and is owned by the default user
		mkdir -p /home/"$default_user"/scripts
		chown -R $default_user:$default_user /home/"$default_user"/scripts
		# Create a script to update your IP at Namecheap using curl
		{
			echo '#!/bin/bash';
			echo;
			echo "curl \"https://dynamicdns.park-your-domain.com/update?host=@&domain=$user_domain&password=$namecheap_dns_password\" > /dev/null"
		} > /home/"$default_user"/scripts/dns-update.sh
		# Make the script executable and owned by the default user
		chmod +x /home/"$default_user"/scripts/dns-update.sh
		chown "$default_user":"$default_user" /home/"$default_user"/scripts/dns-update.sh
		# Create systemd unit and timer to call the script every 5 minutes
		cat > /etc/systemd/system/dns-update.service <<EOF
[Unit]
Description=Update DNS

[Service]
User=$default_user
ExecStart=/home/$default_user/scripts/dns-update.sh

[Install]
WantedBy=basic.target
EOF
		cat > /etc/systemd/system/dns-update.timer <<EOF
[Unit]
Description=Update DNS

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
		# Enable and start the timer
		systemctl daemon-reload
		systemctl enable --now dns-update.timer
	fi
fi


### Update system and install packages
pacman -Syu --noconfirm base base-devel pacman-contrib reflector nano sudo htop git


### Enable and start reflector timer
systemctl enable --now reflector.timer


### Sudo (part 1)
# Install sudo
pacman -S --noconfirm sudo
# Modify sudoers file to allow members of the wheel group
sed '/%wheel ALL=(ALL) NOPASSWD: ALL/s/^# //g' /etc/sudoers | EDITOR='tee' visudo


### yay AUR helper
runuser -u "$default_user" -- git clone https://aur.archlinux.org/yay.git 
runuser -u "$default_user" -- sh -c 'cd yay && makepkg -rsi --noconfirm'


### SSH
# Install openssh
pacman -S --noconfirm openssh
# Prohibit ssh login as root
sed -i 's/.*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
# Enable and start the ssh daemon
systemctl enable --now sshd


### Pacman clean cache hook
[ "$stfu" == "y" ] || read -p "Enter how many versions of each package to keep [default: 2]: " pacman_cleanup_hook_keep
# Set how many packages to keep in pacman's cache
[ -z $pacman_cleanup_hook_keep ] && pacman_cleanup_hook_keep=2
# Create the parent folder
mkdir -p /etc/pacman.d/hooks
# Write the hook (Do not indent the following lines!)
cat > /etc/pacman.d/hooks/clean-cache.hook <<EOF
[Trigger]
Operation = Remove
Operation = Install
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Keep the last cache and the currently installed.
When = PostTransaction
Exec = /usr/bin/paccache -rk$pacman_cleanup_hook_keep
EOF


### fstrim
[ "$stfu" == "y" ] && activate_fstrim="y" || read -p "Activate daily filesystem trim? [Y,n]: " activate_fstrim
if [ "$activate_fstrim" != "n" ]; then
	# Create parent folder
	mkdir -p /etc/systemd/system/fstrim.timer.d
	# Create a drop-in configuration file to run fstrim daily instead of weekly
	echo "[Timer]" >> /etc/systemd/system/fstrim.timer.d/override.conf
	echo "OnCalendar=daily" >> /etc/systemd/system/fstrim.timer.d/override.conf
	# Enable and start the timer
	systemctl enable --now fstrim.timer
fi


### BTRFS health check
if [ "$root_fs_type" == "btrfs" ]; then
	cat > /etc/systemd/system/btrfs-check@.service <<EOF
[Unit]
Description=BTRFS health check on %f

[Service]
ExecStart=/usr/bin/btrfs device stats -c %f

[Install]
WantedBy=basic.target
EOF
	cat > /etc/systemd/system/btrfs-check@.timer <<EOF
[Unit]
Description=Check BTRFS health on %f twice a day

[Timer]
OnBootSec=3min
OnUnitActiveSec=12h

[Install]
WantedBy=timers.target
EOF
	# Enable and start the BTRFS check timer
	systemctl daemon-reload
	systemctl enable --now btrfs-check@-.timer
fi


### Nginx
[ "$stfu" == "y" ] && setup_nginx="y" || read -p "Install and setup nginx? [Y,n]: " setup_nginx
if [ "$setup_nginx" != "n" ]; then
	# Install nginx
	pacman -S --noconfirm nginx
	# Set the number of worker processes to auto
	sed -i 's/worker_processes  1;/worker_processes auto;/g' /etc/nginx/nginx.conf
	# Delete the last line of the nginx config (should be only a "}")
	sed -i '$d' /etc/nginx/nginx.conf
	# Add "include sites-enabled/*;" to the config file
	echo 'include sites-enabled/*;' >> /etc/nginx/nginx.conf
	# Add the previously deleted last line "}"
	echo '}' >> /etc/nginx/nginx.conf
	# Create the sites-available and sites-enabled folders
	mkdir -p /etc/nginx/sites-available
	mkdir -p /etc/nginx/sites-enabled
	# Create a template virtual host config file for static content
	cat > /etc/nginx/sites-available/template <<EOF
server {

	server_name sub.$user_domain;

    listen 80;
    listen [::]:80;

    location / {
        root /srv/sub.$user_domain;
    }

}
EOF
	# Fix the warning: Could not build optimal types_hash
	sed -i -e '/http {/a\' -e '    server_names_hash_bucket_size 128;' /etc/nginx/nginx.conf
	sed -i -e '/http {/a\' -e '    types_hash_max_size 4096;' /etc/nginx/nginx.conf
	# Raise fastcgi_read_timeout
	sed -i -e '/http {/a\' -e '    fastcgi_read_timeout 600s;' /etc/nginx/nginx.conf
	# Enable and start nginx
	systemctl enable --now nginx
fi


### PHP
[ "$stfu" == "y" ] && setup_php="y" || read -p "Setup PHP? [Y,n]: " setup_php
if [ "$setup_php" != "n" ]; then
	# Install php and additional modules
	pacman -S --noconfirm php php-fpm php-gd php-igbinary php-imagick php-intl php-imap php-sqlite php-pgsql php-tidy php-apcu composer
	runuser -u "$default_user" -- sh -c 'yay -S --noconfirm php-smbclient'
	# Enable widely used extensions
	sed -i '/extension=bcmath/s/^;//g' /etc/php/php.ini
	sed -i '/extension=bz2/s/^;//g' /etc/php/php.ini
	sed -i '/extension=exif/s/^;//g' /etc/php/php.ini
	sed -i '/extension=ftp/s/^;//g' /etc/php/php.ini
	sed -i '/extension=gd/s/^;//g' /etc/php/php.ini
	sed -i '/extension=gettext/s/^;//g' /etc/php/php.ini
	sed -i '/extension=gmp/s/^;//g' /etc/php/php.ini
	sed -i '/extension=iconv/s/^;//g' /etc/php/php.ini
	sed -i '/extension=imap/s/^;//g' /etc/php/php.ini
	sed -i '/extension=intl/s/^;//g' /etc/php/php.ini
	sed -i '/extension=ldap/s/^;//g' /etc/php/php.ini
	sed -i '/zend_extension=opcache/s/^;//g' /etc/php/php.ini
	sed -i '/extension=pdo_sqlite/s/^;//g' /etc/php/php.ini
	sed -i '/extension=tidy/s/^;//g' /etc/php/php.ini
	sed -i '/extension=igbinary/s/^;//g' /etc/php/conf.d/igbinary.ini
	sed -i '/extension=imagick/s/^;//g' /etc/php/conf.d/imagick.ini
	sed -i '/extension=smbclient/s/^;//g' /etc/php/conf.d/smbclient.ini
	sed -i '/extension=apcu/s/^;//g' /etc/php/conf.d/apcu.ini
	# Adjust settings of php and php-fpm according to nextcloud recommendations
	sed -i 's/pm.max_children.*/pm.max_children = 120/g' /etc/php/php-fpm.d/www.conf
	sed -i 's/pm.start_servers.*/pm.start_servers = 12/g' /etc/php/php-fpm.d/www.conf
	sed -i 's/pm.min_spare_servers.*/pm.min_spare_servers = 6/g' /etc/php/php-fpm.d/www.conf
	sed -i 's/pm.max_spare_servers.*/pm.max_spare_servers = 18/g' /etc/php/php-fpm.d/www.conf
	sed -i '/env\[HOSTNAME\]/s/^;//g' /etc/php/php-fpm.d/www.conf
	sed -i '/env\[PATH\]/s/^;//g' /etc/php/php-fpm.d/www.conf
	sed -i '/env\[TMP\]/s/^;//g' /etc/php/php-fpm.d/www.conf
	sed -i '/env\[TMPDIR\]/s/^;//g' /etc/php/php-fpm.d/www.conf
	sed -i '/env\[TEMP\]/s/^;//g' /etc/php/php-fpm.d/www.conf
	sed -i '/opcache.enable/s/^;//g' /etc/php/php.ini
	sed -i '/opcache.interned_strings_buffer/s/^;//g' /etc/php/php.ini
	sed -i '/opcache.max_accelerated_files/s/^;//g' /etc/php/php.ini
	sed -i '/opcache.memory_consumption/s/^;//g' /etc/php/php.ini
	sed -i '/opcache.save_comments/s/^;//g' /etc/php/php.ini
	sed -i '/opcache.revalidate_freq/s/^;//g' /etc/php/php.ini
	sed -i 's/memory_limit.*/memory_limit = 512M/g' /etc/php/php.ini
	sed -i 's/upload_max_filesize.*/upload_max_filesize = 16G/g' /etc/php/php.ini
	sed -i 's/post_max_size.*/post_max_size = 16G/g' /etc/php/php.ini
	sed -i 's/max_input_time =.*/max_input_time = 3600/g' /etc/php/php.ini
	sed -i 's/max_execution_time.*/max_execution_time = 3600/g' /etc/php/php.ini
	sed -i 's/default_socket_timeout.*/default_socket_timeout = 600/g' /etc/php/php.ini
	# Configure php-fpm to allow read and write to /usr/share/webapps
	mkdir -p /etc/systemd/system/php-fpm.service.d
	echo '[Service]' >> /etc/systemd/system/php-fpm.service.d/override.conf
	echo 'ReadWritePaths = /usr/share/webapps' >> /etc/systemd/system/php-fpm.service.d/override.conf
	# Enable and start php-fpm
	systemctl daemon-reload
	systemctl enable --now php-fpm
fi


### MariaDB
[ "$stfu" == "y" ] && setup_mariadb="y" || read -p "Setup mariadb? [Y,n]: " setup_mariadb
if [ "$setup_mariadb" != "n" ]; then
	# Install mariadb and client-side packages
	pacman -S --noconfirm mariadb mysql-python
	# Disable Copy-On-Write for /var/lib/mysql if it resides on BTRFS
	if [ "$root_fs_type" == "btrfs" ]; then
		chattr +C /var/lib/mysql
	fi
	# Initialize the MariaDB data directory
	mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
	# Enable and start mariadb
	systemctl enable --now mariadb
	# Enable the pdo_mysql extension for php if php has been installed
	if [ "$setup_php" != "n" ]; then
		sed -i '/extension=pdo_mysql/s/^;//g' /etc/php/php.ini
		sed -i '/extension=mysqli/s/^;//g' /etc/php/php.ini
	fi
fi


### PostgreSQL
[ "$stfu" == "y" ] && setup_postgres="y" || read -p "Setup PostgreSQL? [Y,n]: " setup_postgres
if [ "$setup_postgres" != "n" ]; then
	# Install PostgreSQL
	pacman -S --noconfirm postgresql
	# Disable Copy-On-Write for /var/lib/postgres if it resides on BTRFS
	if [ "$root_fs_type" == "btrfs" ]; then
		chattr +C /var/lib/postgres
		chattr +C /var/lib/postgres/data
	fi
	# Initialize the database
	runuser -u postgres -- sh -c 'initdb -D /var/lib/postgres/data'
	# Enable and start the database service
	systemctl enable --now postgresql
	# Enable the pdo_pgsql extension for php if php has been installed
	if [ "$setup_php" != "n" ]; then
		sed -i '/extension=pdo_pgsql/s/^;//g' /etc/php/php.ini
		sed -i '/extension=pgsql/s/^;//g' /etc/php/php.ini
	fi
	# Restricts access rights to the database superuser by default
	sed -i 's/local   all             all                                     trust/local   all             postgres                                peer/g' /var/lib/postgres/data/pg_hba.conf
fi


### Redis
[ "$stfu" == "y" ] && setup_redis="y" || read -p "Install and setup redis? [Y,n]: " setup_redis
if [ "$setup_redis" != "n" ]; then
	# Install redis and client-side packages
	pacman -S --noconfirm redis python-redis
	# Change the configuration file to enable the unix socket
	sed -i 's/# unixsocket \/tmp\/redis.sock/unixsocket \/run\/redis\/redis.sock/g' /etc/redis.conf
	sed -i 's/# unixsocketperm 700/unixsocketperm 770/g' /etc/redis.conf
	# Add the default user and the http user to the redis group to allow socket access
	gpasswd -a http,"$default_user" redis
	# Prevent some smaller issues and warnings as per Archwiki
	echo 'w /sys/kernel/mm/transparent_hugepage/enabled - - - - never' >> /etc/tmpfiles.d/redis.conf
	echo 'w /sys/kernel/mm/transparent_hugepage/defrag - - - - never' >> /etc/tmpfiles.d/redis.conf
	echo 'net.core.somaxconn=512' >> /etc/sysctl.d/99-sysctl.conf
	echo 'vm.overcommit_memory=1' >> /etc/sysctl.d/99-sysctl.conf
	# Enable and start redis
	systemctl enable --now redis
	if [ "$setup_php" != "n" ]; then
		# Install redis extension for php
		pacman -S --noconfirm php-redis
		# Enable php-redis
		sed -i '/extension=redis/s/^;//g' /etc/php/conf.d/redis.ini
	fi
fi


### Gotify
[ "$stfu" == "y" ] && gotifyserver="y" || read -p "Install and setup gotify server? [Y,n]: " gotifyserver
if [ "$gotifyserver" != "n" ]; then
	# Install the gotify server
	runuser -u "$default_user" -- sh -c 'yay -S --noconfirm gotify-server-bin'
	# Set admin user name
	[ -z $gotify_admin_user ] && read -p "Enter admin user name for gotify [default: $default_user]: " gotify_admin_user
	# Set to default if nothing has been entered
	[ -z "$gotify_admin_user" ] && gotify_admin_user="$default_user"
	sed -i -e "s/name: admin/name: $gotify_admin_user/g" /etc/gotify/config.yml
	# Set the listening port to 8057
	sed -i -e "s/port: 80/port: 8057/g" /etc/gotify/config.yml
	# Enable and start the gotify server
	systemctl enable --now gotify-server
	# Add nginx virtual host if nginx has been set up
	if [ "$setup_nginx" != "n" ]; then
		{
			echo 'upstream gotify {';
			echo '  # Set the port to the one you are using in gotify';
			echo '  server 127.0.0.1:8057;';
			echo '}';
			echo;
			echo 'server {';
			echo '  # Here goes your domain / subdomain';
			echo "  server_name gotify.$user_domain;";
			echo '  listen 80;';
			echo;
			echo '  location / {';
			echo '    # We set up the reverse proxy';
			echo '    proxy_pass         http://gotify;';
			echo '    proxy_http_version 1.1;';
			echo;
			echo '    # Ensuring it can use websockets';
			echo '    proxy_set_header   Upgrade $http_upgrade;';
			echo '    proxy_set_header   Connection "upgrade";';
			echo '    proxy_set_header   X-Real-IP $remote_addr;';
			echo '    proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;';
			echo '    proxy_set_header   X-Forwarded-Proto http;';
			echo '    proxy_redirect     http:// $scheme://;';
			echo;
			echo '    # The proxy must preserve the host because gotify verifies the host with the origin';
			echo '    # for WebSocket connections';
			echo '    proxy_set_header   Host $http_host;';
			echo;
			echo '    # These sets the timeout so that the websocket can stay alive';
			echo '    proxy_connect_timeout   7m;';
			echo '    proxy_send_timeout      7m;';
			echo '    proxy_read_timeout      7m;';
			echo '  }';
			echo '}';
		} > /etc/nginx/sites-available/gotify."$user_domain"
		# Actually activate the gotify virtual host
		ln -s /etc/nginx/sites-available/gotify."$user_domain" /etc/nginx/sites-enabled/gotify."$user_domain"
		# Reload the nginx service to make gotify reachable under the "gotify" subdomain
		systemctl reload nginx
	fi
fi


### Systemd service failure notification with gotify
[ "$stfu" == "y" ] && systemd_failure_notifications="y" || read -p "Send systemd service failure notifications to gotify? [Y,n]: " systemd_failure_notifications
if [ "$systemd_failure_notifications" != "n" ]; then
	# Create parent folder
	mkdir -p /etc/systemd/system/service.d
	# Create a systemd toplevel override for services
	echo "[Unit]" >> /etc/systemd/system/service.d/toplevel-override.conf
	echo "OnFailure=failure-notification@%n" >> /etc/systemd/system/service.d/toplevel-override.conf
	# Create the unit file notifying of failed units (Do not indent the following lines!)
	cat > /etc/systemd/system/failure-notification@.service <<EOF
[Unit]
Description=Send a notification about a failed systemd unit
After=network.target

[Service]
Type=simple
ExecStart=/home/$default_user/scripts/failure-notification.sh %i
EOF
	# Prevent regression/recursion
	mkdir -p /etc/systemd/system/failure-notification@.service.d
	touch /etc/systemd/system/failure-notification@.service.d/toplevel-override.conf
	# Create the script file to be called on service failures
	# Create parent folder
	mkdir -p /home/"$default_user"/scripts
	# Create script
	{
		echo '#!/bin/bash';
		echo;
		echo 'UNIT=$1';
		echo 'UNITFILE=$(systemctl cat $UNIT)';
		echo 'UNITSTATUS=$(systemctl status $UNIT)';
		echo;
		echo 'gotify-cli push -t "$UNIT failed" << EOF';
		echo 'Systemd unit $UNIT has failed.';
		echo;
		echo 'The current status is:';
		echo;
		echo '$UNITSTATUS';
		echo;
		echo 'The unit file is:';
		echo;
		echo '$UNITFILE';
		echo 'EOF'
	} > /home/"$default_user"/scripts/failure-notification.sh
	# Make it executable and owned by the default user
	chmod +x /home/"$default_user"/scripts/failure-notification.sh
	chown "$default_user":"$default_user" /home/"$default_user"/scripts/failure-notification.sh
	# Install gotify-cli
	runuser -u "$default_user" -- sh -c 'yay -S --noconfirm gotify-cli-bin'
	# Create application on the gotify server
	app_creation_response=$(curl -u "$gotify_admin_user":admin http://127.0.0.1:8057/application -F "name=$hostname" -F "description=Arch Linux Server")
	# Install jq to parse the json response
	pacman -S --noconfirm jq
	# Extract the application token
	gotify_app_token=$(echo "$app_creation_response" | jq -r '.token' | tr -d '\n')
	# Configure gotify-cli
	jq -n --arg token "$gotify_app_token" '{"token": $token,"url": "http://127.0.0.1:8057","defaultPriority": 10}' > /etc/gotify/cli.json
	# Remove jq and its no longer required dependencies
	pacman -Rs --noconfirm jq
fi


### Fail2ban
[ "$stfu" == "y" ] && setup_fail2ban="y" || read -p "Install and setup fail2ban? [Y,n]: " setup_fail2ban
if [ "$setup_fail2ban" != "n" ]; then
	# Install fail2ban
	pacman -S --noconfirm fail2ban
	# Enable and start iptables and ip6tables services
	systemctl enable --now iptables ip6tables
	# Create the fail2ban jail configuration file
	cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
ignoreip = 127.0.0.1/8

[sshd]
enabled  = true
filter   = sshd
action   = iptables[name=SSH, port=ssh, protocol=tcp]
backend  = systemd
maxretry = 5

[nginx-http-auth]
enabled  = true
filter   = nginx-http-auth
action   = iptables-multiport[name=nginx, port="http,https"]
port     = http,https
logpath  = /var/log/nginx/*access.log*
           /var/log/nginx/*error.log*
maxretry = 5
EOF
	# Enable and start fail2ban
	systemctl enable --now fail2ban
fi


### Smartmontools
[ "$stfu" == "y" ] && setup_smartmontools="y" || read -p "Install and setup smartmontools? [Y,n]: " setup_smartmontools
if [ "$setup_smartmontools" != "n" ]; then
	# Install smartmontools
	pacman -S --noconfirm smartmontools
	# Dump smartd logs for potential parsing by netdata
	# Create parent folder
	#mkdir -p "/var/log/smartd"
	# Disable copy-on-write on BTRFS
	#[ "$root_fs_type" == "btrfs" ] && chattr +C /var/log/smartd
	# Write the environment file
	#echo 'SMARTD_ARGS="-A /var/log/smartd/ -i 600"' > /etc/conf.d/smartd
	# Notify about potential problems using gotify
	{
		echo '#!/bin/bash';
		echo;
		echo 'gotify-cli push -t "SMART warning" "$SMARTD_FULLMESSAGE"'
	} > /usr/share/smartmontools/smartd_warning.d/smartd-warning.sh
	# Make the notification script executable
	chmod +x /usr/share/smartmontools/smartd_warning.d/smartd-warning.sh
	# Comment out the default DEVICESCAN directive
	sed -i '/DEVICESCAN$/s/^/#/g' /etc/smartd.conf
	# Configure smartd to monitor all drives and to notify on potential problems
	echo 'DEVICESCAN -a -I 194 -W 4,45,55 -R 1! -R 5! -R 10! -R 184! -R 187! -R 188! -R 196! -R 197! -R 198! -R 201! -n standby,q -m @smartd-warning.sh -M test' >> /etc/smartd.conf
	# Enable and start smartd
	systemctl enable --now smartd
fi


### Nextcloud
[ "$stfu" == "y" ] && setup_nextcloud="y" || read -p "Install and setup Nextcloud? [Y,n]: " setup_nextcloud
if [ "$setup_nextcloud" != "n" ]; then
	# Install ffmpeg for preview generation and nextcloud-systemd-timers as alternative to cron
	pacman -S --noconfirm ffmpeg
	runuser -u "$default_user" -- sh -c 'yay -S --noconfirm nextcloud-systemd-timers'
	# Setup database using MariaDB
	echo 'Creating database "nextcloud" with user "nextcloud" and password "nextcloud"...'
	mysql -u root -e "CREATE DATABASE nextcloud DEFAULT CHARACTER SET 'utf8mb4' COLLATE 'utf8mb4_general_ci';"
	mysql -u root -e "GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost' IDENTIFIED BY 'nextcloud';"
	mysql -u root -e "FLUSH PRIVILEGES;"
	# Make sure /usr/share/webapps exists
	mkdir -p /usr/share/webapps
	# Change working directory to /usr/share/webapps
	cd /usr/share/webapps || exit
	# Ask for link to latest nextcloud release tarball and download it
	[ -z $nextcloud_latest ] && read -p "Please paste the url to the latest nextcloud release tarball: " nextcloud_latest
	curl -L "$nextcloud_latest" -o nextcloud-latest.tar.bz2
	# Unpack and remove the tarball
	tar -xf nextcloud-latest.tar.bz2
	rm nextcloud-latest.tar.bz2
	# Set the nextcloud directory to be owned by http
	chown -R http:http /usr/share/webapps/nextcloud
	# Change working directory back to home
	cd /home/"$default_user" || exit
	# Download the nginx config and add nginx virtual host if nginx has been set up
	if [ "$setup_nginx" != "n" ]; then
		curl -L "${repo_raw_url}files/nextcloud.conf" -o /etc/nginx/sites-available/nextcloud.conf
		# Set the nextcloud config to use redis
		{
			echo 'upstream php-handler {';
			echo '  server unix:/run/php-fpm/php-fpm.sock;';
			echo '}';
			echo;
			echo 'server {';
			echo "  server_name nextcloud.$user_domain;";
			echo '  listen 80;';
			echo '  listen [::]:80;';
			echo '  include sites-available/nextcloud.conf;';
			echo '}';
		} > /etc/nginx/sites-available/nextcloud."$user_domain"
		# Actually activate the nextcloud virtual host
		ln -s /etc/nginx/sites-available/nextcloud."$user_domain" /etc/nginx/sites-enabled/nextcloud."$user_domain"
		# Reload the nginx service to make gotify reachable under the "gotify" subdomain
		systemctl reload nginx
	fi
fi


### Finalize

### MariaDB (part 2)
if [ "$setup_mariadb" != "n" ]; then
	# Improve initial security for MariaDB
	echo "Improve initial security for MariaDB: running mysql_secure_installation script..."
	mysql_secure_installation
fi

### Sudo (part 2)
# Remove temporary passwordless sudo for wheel group
sed '/%wheel ALL=(ALL) NOPASSWD: ALL/s/^/# /g' /etc/sudoers | EDITOR='tee' visudo
# Modify sudoers file to allow members of the wheel group
sed '/%wheel ALL=(ALL) ALL/s/^# //g' /etc/sudoers | EDITOR='tee' visudo
# Restore sudo lecture for the default user
rm /var/db/sudo/lectured/"$default_user" 2> /dev/null