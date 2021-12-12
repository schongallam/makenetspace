#!/bin/sh
#
# Copyright 2021 Malcolm Schongalla, released under the MIT License (see end of file)
#
# malcolm.schongalla@gmail.com
#
# A script to set up a network namespace and move an adapter into it
# 
# usage:
# $ makespace [-f] NETNS DEVICE [ESSID] [PASSWORD]
#
# -f                    option to force execution without a proper resolv.conf in place.
#                       otherwise, script will exit.
# NETNS                 the name of the namespace you wish to create
# DEVICE                the network interface that you want to assign to the namespace NETNS
# ESSID and PASSWORD    used for wireless interfaces. Attempts to join network
#                       with wpa_supplicant only.
#
# makespace will create the namespace NETNS, move the physical interface DEVICE to that space,
# attempt to join the wireless network ESSID using password PASSWORD, then finally launch
# a root shell in that namespace.
#
# when you exit the shell, the script will attempt to kill dhclient and wpa_supplicant
# within that namespace, revert the device to the default namespace, and remove the namespace.
#
# Note: this script must be run as the superuser.
#
# Note: before using this script, you should have a custom resolv.conf file that already
# exists in the folder /etc/netns/$NETNS, the purpose is to have this file bind to
# /etc/resolv.conf within the new namespace.  Without this you will have to manually set up
# DNS  (see -f option).
#
#
# Other internal variables:
#  NO_CHECK             1 if skipping check for /etc/netns/$NETNS/resolv.conf
#                       otherwise, 0
#  INTERFACE_TYPE       1 for wired DEVICE, 2 for wireless DEVICE
#  EXIT_CODE            captures and preserves an abnormal exit code from a command in the
#                       event that we need to exit the script with it
#  PHY                  physical interface name for given wifi interface DEVICE
#  PHY_FALLBACK         (UNUSED) 1 if unable to confirm PHY, and using DEVICE instead.
#                       Otherwise, undefined
#  UNCONFIRMED_MOVE     (UNUSED) 1 if grep can't find DEVICE listed in the new namespace after
#                       attempting to move it
#
# OTHER EXIT CODES:
NORMAL=0                # normal exit
HELP=0                  # help/description shown
NO_ROOT=1               # not run as root
NO_RESOLV_CONF=2        # unable to find appropriate resolv.conf file
BAD_NAMESPACE=3         # namespace is bad or already exists

# HELP TEXT:
show_help() {

    echo "usage:"
    echo "$ makespace NETNS DEVICE [ESSID] [PASSWORD]"
    echo
    echo "Argments:"
    echo " NETNS                The name of the namespace you wish"
    echo "                      to create"
    echo
    echo " DEVICE               The network interface that you want"
    echo "                      to assign to the namespace NETNS"
    echo
    echo " ESSID and PASSWORD   Used for wireless interfaces."
    echo "                      Attempts to join network with"
    echo "                      wpa_supplicant only."
    echo
    echo "makespace will create the namespace NETNS, move the"
    echo "physical interface DEVICE to that space, attempt to join"
    echo "the wireless network ESSID using password PASSWORD, then"
    echo "finally launch a root shell in that namespace."
    echo
    echo "when you exit the shell, the script will attempt to kill"
    echo "dhclient and wpa_supplicant within that namespace,"
    echo "revert the device to the default namespace, and remove"
    echo "the namespace."
    echo
    echo "Note: this script must be run as the superuser."
    echo
    echo "Note: before using this script, you should have a custom"
    echo "resolv.conf file that already exists in the folder"
    echo "/etc/netns/$NETNS, the purpose is to have this file bind"
    echo "to /etc/resolv.conf within the new namespace.  Without"
    echo "this you will have to manually set up DNS."
    echo

}

#
# SCRIPT ENTRY POINT
#

if [ "$1" = "-f" ]; then
    NO_CHECK=1
    shift
else
    NO_CHECK=0
fi

if [ $# -eq 2 ]; then
    echo "Assuming WIRED interface..."
    INTERFACE_TYPE=1 # 1 for wired, we'll need this later
    NETNS=$1
    DEVICE=$2
elif [ $# -eq 4 ]; then
    echo "Assuming WIRELESS interface..."
    INTERFACE_TYPE=2 # 2 for wireless
    NETNS=$1
    DEVICE=$2
    ESSID=$3
    PASSWORD=$4
else
    show_help
    exit $HELP
fi

if [ "$(whoami)" != root ]; then
  echo "Only root can run this script. Exiting ($NO_ROOT)"
  exit $NO_ROOT
fi

if [ $NO_CHECK -eq 1 ]; then
    echo "Forcing execution without checking for /etc/netns/$NETNS/resolv.conf"
else
    if [ -f "/etc/netns/$NETNS/resolv.conf" ]; then
        echo "... /etc/netns/$NETNS/resolv.conf exists.  Hopefully it's correct!"
    else
        echo "/etc/netns/$NETNS/resolv.conf missing.  Please create this or"
        echo "run script with the -f option, and expect to set up DNS manually."
        echo "Exiting ($NO_RESOLV_CONF)"
        exit $NO_RESOLV_CONF
    fi

fi

# check for pre-existing network namespace
ip netns | grep -w -o $NETNS > /dev/null
if [ $? -ne 1 ]; then
    echo "That namespace won't work.  Please try a different one."
    echo "Check '$ ip netns' to make sure it's not already in use."
    echo "Exiting ($BAD_NAMESPACE)"
    exit $BAD_NAMESPACE
fi

# create the namespace
ip netns add "$NETNS"
if [ $? -ne 0 ]; then
    echo "Unable to create namespace $NETNS. Exiting ($BAD_NAMESPACE)"
    exit $BAD_NAMESPACE
fi

# not technically required
ip link set dev "$DEVICE" down

# Wired or wireless?  If wireless, we need to reference the physical device
if [ $INTERFACE_TYPE -eq 1 ]; then
    ip link set dev "$DEVICE" netns "$NETNS"
    if [ $? -ne 0 ]; then
        EXIT_CODE=$?
        echo "Unable to move $DEVICE to $NETNS, exiting $EXIT_CODE"
        exit $EXIT_CODE
    fi
else
    PHY="$(basename "$(cd "/sys/class/net/$DEVICE/phy80211" && pwd -P)")"
    if [ -z $PHY ]; then
        PHY=$DEVICE # try this as a fallback but it may not work
        PHY_FALLBACK=1
        echo "Unable to confirm physical device name for wireless interface $DEVICE"
        echo "Falling back on $PHY, may not work. Proceeding..."
    fi
    iw phy "$PHY" set netns name "$NETNS"
    if [ $? -ne 0 ]; then
        EXIT_CODE=$?
        echo "Unable to move $PHY to $NETNS, exiting $EXIT_CODE"
        exit $EXIT_CODE
    fi
fi

# Check for success
ip netns exec $NETNS ip link show | grep $DEVICE > /dev/null # may yield false positive result for success if DEVICE is abnormally too simple of a string
if [ $? -ne 0 ]; then
    echo "Unable to confirm $DEVICE in $NETNS, will attempt to continue..."
    UNCONFIRMED_MOVE=1
fi

# Bring up the devices
ip netns exec "$NETNS" ip link set dev lo up
if [ $? -ne 0 ]; then
    echo "Could not bring up lo in $NETNS, something else may be wrong. Proceeding..."
fi

ip netns exec "$NETNS" ip link set dev "$DEVICE" up
if [ $? -ne 0 ]; then
    echo "Could not bring up $DEVICE in $NETNS, something probably went wrong. Proceeding..."
fi

# Connect to wifi, if required
if [ $INTERFACE_TYPE -eq 2 ]; then
    echo "Attempting to connect to wifi network $ESSID... (may see initialization failures, that's usually OK)"
    wpa_passphrase $ESSID $PASSWORD | ip netns exec "$NETNS" wpa_supplicant -i "$DEVICE" -c /dev/stdin -B

    if [ $? -ne 0 ]; then
        echo "Unconfirmed attempt to join $ESSID with error $?. Proceeding..."
    fi

    echo "(DEBUG) displaying output of iwconfig in namespace $NETNS:"
    ip netns exec "$NETNS" iwconfig
fi

echo
echo "Starting dhclient..."
ip netns exec "$NETNS" dhclient "$DEVICE"
echo "(DEBUG) dhclient returns status $?..."

# Spawn a shell in the new namespace

echo "Spawning root shell in $NETNS..."
echo "... try runuser -u UserName BrowserName &"
echo "... and exit to kill the shell and netns, when done"
ip netns exec "$NETNS" su

# Stop dhclient
ip netns exec "$NETNS" dhclient -r
echo "Stopped dhclient in $NETNS with status $?"

# Move the device back into the default namespace
if [ $INTERFACE_TYPE -eq 1 ]; then
    ip netns exec "$NETNS" ip link set dev "$DEVICE" netns 1
    echo "Closing wired interface status $?"
else
    ip netns exec "$NETNS" iw phy "$PHY" set netns 1
    echo "Closing wireless interface status $?"
fi

# Remove the namespace
ip netns del "$NETNS"
echo "Deleted $NETNS"

# ... and just for good measure
echo "Restarting Network Manager"
service network-manager restart

echo
echo "exiting... status $?"

# RESCUE:
# if script fails and deletes the namespace without first removing the interface from the netns, try:
# sudo find /proc/ -name wlp7s0 # or interface name as appropriate
# sudo kill [process_id]
#
#
# LICENSE
# Copyright 2021, by Malcolm Schongalla
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
