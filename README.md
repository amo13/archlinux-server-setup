# archlinux-server-setup
Interactive Arch Linux post-install script for server setup. Nginx, php-fpm, redis, mariadb, smartmontools, netdata, ...

This script is meant to be run **after** the installation of Arch Linux. It also requires a working internet connection.

On your fresh Arch Linux installation, call:

`bash <(curl -sSL https://raw.githubusercontent.com/amo13/archlinux-server-setup/main/setup.sh)`


## What to expect
### Reflector
Reflector is installed and its systemd timer is enabled and started to periodically update the pacman mirrorlist.

### Default unprivileged user
A default unprivileged user is created (if none is found) for default access to the server and for unprivileged tasks like building AUR packages. This user gets added to the wheel group for sudo commands. 

### Sudo
Allow all users in the wheel group to use sudo. (For convenience reasons, this is first set to allow sudo without entering the password so that the script is not interrupted by password prompts. At the end of the script, this is modified again to allow sudo only with the password.)

### yay AUR helper
Install the yay AUR helper for easier installation and update of packages from the AUR.

### SSH
Configure SSH access on the default port 22 and do not allow to log in as the root user.

### Pacman clean cache hook
Add a pacman hook to clean the cached packages potentially freeing a lot of disk space automatically. You can choose how many package versions to keep in the cache (maybe for downgrading in case something breaks). Default is 2: keep the current version and the one before.

### fstrim
Activate periodic fstrim of drives supporting the feature using the systemd timer and service files provided by the system. Trim daily instead of weekly though.

### Gotify
Install, enable and start the gotify server. It will listen on port 8057. You can specify the default admin user name. You should change its password using the web UI after the script finished.

### Systemd service failure notification with gotify
Create a systemd toplevel override file adding `OnFailure=failure-notification@%n` to all systemd services. Also add the `failure-notification@` service that is to be started if another service somehow fails. This, in turn, will send information about the unit that has failed and its status to the gotify server using the gotify-cli command (also gets installed and configured to use your gotify server). You can receive and view all messages on the web UI or using the android application.
If you want to change how and where the notifications are delivered, you should modify the contents of the failure-notification.sh script in the scripts folder of your default user accordingly.

### fail2ban
Install, activate and start fail2ban. It will monitor the ssh and nginx logs.