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


### Script needs to be started as root
if [ ! "$(whoami)" == "root" ]; then
	echo "Please start this script as root or with sudo."
	exit
fi


### Define some variables
hostname=$(uname -n | tr -d '\n')
root_fs_type=$(mount | grep "^/dev" | grep -oP "(?<=on / type )[^ ]+" | tr -d '\n')


### Update system and install packages
pacman -Syu --noconfirm base base-devel pacman-contrib reflector nano sudo htop git


### Enable and start reflector timer
systemctl enable --now reflector.timer


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


### Sudo (part 1)
read -p "Install and setup sudo for your user? [Y,n]: " setup_sudo
if [ "$setup_sudo" != "n" ]; then
	# Install sudo
	pacman -S --noconfirm sudo
	# Modify sudoers file to allow members of the wheel group
	sed '/%wheel ALL=(ALL) NOPASSWD: ALL/s/^# //g' /etc/sudoers | EDITOR='tee' visudo
fi


### yay AUR helper
read -p "Install yay AUR helper? [Y,n]: " setup_yay
if [ "$setup_yay" != "n" ]; then
	runuser -u "$default_user" -- git clone https://aur.archlinux.org/yay.git 
	runuser -u "$default_user" -- sh -c 'cd yay && makepkg -rsi --noconfirm'
fi


### SSH
read -p "Install and setup SSH? [Y,n]: " setup_ssh
if [ "$setup_ssh" != "n" ]; then
	# Install openssh
	pacman -S --noconfirm openssh
	# Prohibit ssh login as root
	sed -i 's/.*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
	# Enable and start the ssh daemon
	systemctl enable --now sshd
fi


### Pacman clean cache hook
read -p "Setup a pacman hook to clean up its cache? [Y,n]: " pacman_cleanup_hook
if [ "$pacman_cleanup_hook" != "n" ]; then
	read -p "Enter how many versions of each package to keep [default: 2]: " pacman_cleanup_hook_keep
	# Set to default if nothing has been entered
	[ -z "$pacman_cleanup_hook_keep" ] && pacman_cleanup_hook_keep=2
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
fi


### fstrim
read -p "Activate daily filesystem trim? [Y,n]: " activate_fstrim
if [ "$activate_fstrim" != "n" ]; then
	# Create parent folder
	mkdir -p /etc/systemd/system/fstrim.timer.d
	# Create a drop-in configuration file to run fstrim daily instead of weekly
	echo "[Timer]" >> /etc/systemd/system/fstrim.timer.d/override.conf
	echo "OnCalendar=daily" >> /etc/systemd/system/fstrim.timer.d/override.conf
	# Enable and start the timer
	systemctl enable --now fstrim.timer
fi


### Gotify
read -p "Install and setup gotify server? [Y,n]: " gotifyserver
if [ "$gotifyserver" != "n" ]; then
	# Install the gotify server
	runuser -u "$default_user" -- sh -c 'yay -S --noconfirm gotify-server-bin'
	# Set admin user name
	read -p "Enter admin user name for gotify [default: $default_user]: " gotify_admin_user
	# Set to default if nothing has been entered
	[ -z "$gotify_admin_user" ] && gotify_admin_user="$default_user"
	sed -i -e "s/name: admin/name: $gotify_admin_user/g" /etc/gotify/config.yml
	# Set the listening port to 8057
	sed -i -e "s/port: 80/port: 8057/g" /etc/gotify/config.yml
	# Enable and start the gotify server
	systemctl enable --now gotify-server
fi


### Systemd service failure notification with gotify
read -p "Send systemd service failure notifications to gotify? [Y,n]: " systemd_failure_notifications
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
read -p "Install and setup fail2ban? [Y,n]: " setup_fail2ban
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
read -p "Install and setup smartmontools? [Y,n]: " setup_smartmontools
if [ "$setup_smartmontools" != "n" ]; then
	# Install smartmontools
	pacman -S --noconfirm smartmontools
	# Dump smartd logs for potential parsing by netdata
	# Create parent folder
	mkdir -p "/var/log/smartd"
	# Write the environment file
	echo 'SMARTD_ARGS="-A /var/log/smartd/ -i 600"' > /etc/conf.d/smartd
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



### Sudo (part 2)
if [ "$setup_sudo" != "n" ]; then
	# Remove temporary passwordless sudo for wheel group
	sed '/%wheel ALL=(ALL) NOPASSWD: ALL/s/^/# /g' /etc/sudoers | EDITOR='tee' visudo
	# Modify sudoers file to allow members of the wheel group
	sed '/%wheel ALL=(ALL) ALL/s/^# //g' /etc/sudoers | EDITOR='tee' visudo
	# Restore sudo lecture for the default user
	rm /var/db/sudo/lectured/"$default_user" 2> /dev/null
fi