#!/bin/bash
# Add Intel QSV GPU passthrough to LXC 121
CONF="/etc/pve/lxc/121.conf"

# Check if already configured
if grep -q "dev0" "$CONF"; then
    echo "GPU passthrough already configured:"
    grep "dev" "$CONF"
    exit 0
fi

# Add /dev/dri passthrough for Intel QSV
echo "" >> "$CONF"
echo "# Intel QSV GPU passthrough" >> "$CONF"
echo "dev0: /dev/dri/card0,gid=44" >> "$CONF"
echo "dev1: /dev/dri/renderD128,gid=104" >> "$CONF"

echo "Added GPU passthrough. New config:"
cat "$CONF"
echo ""
echo "NOTE: LXC 121 needs a restart for this to take effect"
