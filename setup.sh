#!/bin/bash

### Interactive Arch Linux post-install script for server setup

### Presumptions:
###		- Running on a freshly installed archlinux system
###		- Working internet connection (networking already set up)


### Script needs to be started as root
if [ ! "$(whoami)" == "root" ]; then
	echo "Please start this script as root or with sudo."
	exit
fi


### Update system and install packages
pacman -Syu --noconfirm base base-devel nano sudo htop git


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
else
	read -p "Enter the name of your default unprivileged user: " default_user
	while [ -z "$default_user" ] || [ ! -d /home/"$default_user" ]; do
		echo "Either you left the user name empty or the user you entered has no home directory."
		read -p "Enter the name of your default unprivileged user: " default_user
	done
	create_default_user "$default_user"
fi


### Set the home folder of the default user as working directory
cd /home/"$default_user"


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






### Sudo (part 2)
if [ "$setup_sudo" != "n" ]; then
	# Remove temporary passwordless sudo for wheel group
	sed '/%wheel ALL=(ALL) NOPASSWD: ALL/s/^/# /g' /etc/sudoers | EDITOR='tee' visudo
	# Modify sudoers file to allow members of the wheel group
	sed '/%wheel ALL=(ALL) ALL/s/^# //g' /etc/sudoers | EDITOR='tee' visudo
	# Restore sudo lecture for the default user
	rm /var/db/sudo/lectured/"$default_user" 2> /dev/null
fi