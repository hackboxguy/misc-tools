#!/bin/bash
set -e

# Helper function to update sysctl
update_sysctl() {
    local key=$1
    local value=$2
    echo "${key} = ${value}" >> /etc/sysctl.conf
}

# Update sysctl settings
update_sysctl "net.core.rmem_max" "26214400"
update_sysctl "net.core.wmem_max" "26214400"
update_sysctl "net.core.rmem_default" "1310720"
update_sysctl "net.core.wmem_default" "1310720"

# Enable micropanel service if installed
#if [ "$MICROPANEL_INSTALLED" = "true" ]; then
    #systemctl enable /home/pi/micropanel/micropanel.service
    #cp /home/pi/micropanel/configs/config.txt /boot/firmware/
    
    #update-config-path.sh cannot do inplace editing of config.json
    sync
    cp /home/pi/micropanel/etc/micropanel/config.json /home/pi/micropanel/etc/micropanel/config-temp.json
    #resolve $MICROPANEL_HOME
/home/pi/micropanel/usr/bin/update-config-path.sh --path=/home/pi/micropanel --output=/home/pi/micropanel/etc/micropanel/config.json --input=/home/pi/micropanel/etc/micropanel/config-temp.json
    systemctl enable /home/pi/micropanel/lib/systemd/system/micropanel.service
    cp /home/pi/micropanel/usr/share/micropanel/configs/config.txt /boot/firmware/
#fi

# Enable high-speed UART
sed -i 's/^console=serial0,115200 //' /boot/firmware/cmdline.txt

# Enable i2c module
echo 'i2c-dev' > /etc/modules-load.d/i2c.conf

echo "Custom configuration complete!"
