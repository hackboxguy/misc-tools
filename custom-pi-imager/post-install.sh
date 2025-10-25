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
if [ "$MICROPANEL_INSTALLED" = "true" ]; then
    systemctl enable /home/pi/micropanel/micropanel.service
    cp /home/pi/micropanel/configs/config.txt /boot/firmware/
fi

# Enable high-speed UART
sed -i 's/^console=serial0,115200 //' /boot/firmware/cmdline.txt

# Enable i2c module
echo 'i2c-dev' > /etc/modules-load.d/i2c.conf

echo "Custom configuration complete!"
