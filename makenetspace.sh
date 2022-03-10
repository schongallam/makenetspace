#!/bin/sh
#
# makenetspace v 0.1.1-alpha
# Copyright 2021 Malcolm Schongalla, released under the MIT License (see end of file)
#
# malcolm.schongalla@gmail.com
#
# A script to set up a network namespace and move an adapter into it, and clean up after
# 
# usage:
# $ makenetspace [OPTIONS] NETNS DEVICE
#
# see USAGE for argument details.
#
#
# Script flow:
# - Set global variables
# - Interpret command line arguments
# - Confirm root
# - (If --cleanup option is used, skip setup and shell)
# - Conditionally check for /etc/$NETNS/resolv.conf (can be overridden)
# - Make sure network namespace doesn't already exist, then try to create it
# - Bring down the device before moving it
# - If it's a virtual or wireless device, detect the corresponding physical device name
# - Make the namespace, and move the device into it
# - Bring up both the loopback interface and the device
# - Connect to wifi network using provided ESSID and password, if applicable
# - Start dhclient, unless opted against
# - At this point, exit, if no shell is desired
# - (--cleanup option redirects to here)
# - 
#
# Option-determined variables:
#  ESSID                ESSID of wireless network
#  WIFI_PASSWORD        Password of wireless network
#  FORCE                defaults to 0.  1 if skipping check for /etc/netns/$NETNS/resolv.conf ;
#                       determined by --force
FORCE=0

#  INTERFACE_TYPE       defaults to 0-> wired; 1->wifi, no PW; 2->PW without wifi (invalid); 3->wifi+PW
#                       determined by presence of --essid and -passwd options
INTERFACE_TYPE=0

#  SPAWN_SHELL          defaults to true (1).  False with --noshell, -n option
SPAWN_SHELL=1

#  CLEANUP_ONLY         defaults to false (0). To cleanup a wireless interface, use this with --virtual
#                       or --essid <ESSID>.  Incompatible with --noshell, -n
CLEANUP_ONLY=0

#  VIRTUAL              defaults to false (0). Set to 1 if a wireless interface is implied by
#                       providing an ESSID, or if forced by the --virtual, -v option.  This option
#                       is useful when using --cleanup on a wireless interface
VIRTUAL=0

#  STRICT               defaults to false (0). If set true, will enforce successful assignment of the
#                       DEVICE into NETNS and subsequent commands.  Failure of assignment means
#                       skipping ahead to the cleanup portions of the script.  Set to true (1) by the
#                       --strict, -s option.
STRICT=0

#  STRICTKILL           defaults to false (0). If set true, failure of STRICT enforced commands result
#                       immediately exiting the script.  This option can cause problems.  Set to true
#                       (1) by --strictkill, -k
STRICTKILL=0

#  NMIGNORE             defaults to false (0). If set true, don't reset network manager on cleanup.
#                       set to true (1) by --nmignore, -i
NMIGNORE=0

# MANUAL_IP_CONFIG      defaults to 0.  Set to 1 by --static option, which collects STATIC_IP and
#                       GATEWAY.  Set to 2 by --noconfig, -o option, to indicate skipping host
#                       IP configuration entirely.
MANUAL_IP_CONFIG=0

#
# Other internal variables:
#  EXIT_CODE            captures and preserves an abnormal exit code from a command in the
#                       event that we need to exit the script with it
#  PHY                  physical interface name for given wifi interface DEVICE
#  PHY_FALLBACK         (UNUSED) 1 if unable to confirm PHY, and using DEVICE instead.
#                       Otherwise, undefined
#  UNCONFIRMED_MOVE     (UNUSED) 1 if grep can't find DEVICE listed in the new namespace after
#                       attempting to move it
#  LO_FAIL              (UNUSED) 1 if unable to raise lo interface in NETNS
#  DEVICE_FAIL          (UNUSED) 1 if unable to raise DEVICE in NETNS

# OTHER EXIT CODES:
NORMAL=0                # normal exit
HELP=0                  # help/description shown
BAD_ARGUMENT=1          # Problem parsing arguments
NO_ROOT=2               # not run as root
NO_RESOLV_CONF=3        # unable to find appropriate resolv.conf file
BAD_NAMESPACE=4         # namespace is bad or already exists
STRICT_WITH_CLEANUP=5   # could not verify that DEVICE was moved into NETNS.  NETNS removed.
EXIT_STRICT_KILL=6      # could not verify that DEVICE was moved into NETNS.  Exited immediately.
DEBUG_EXIT=10           # used for debugging purposes

# HELP TEXT:
usage() {

    echo "usage:"
    echo "$ makenetspace [-f] NETNS DEVICE [ESSID] [PASSWORD]"
    echo    
    echo "Options:"
    echo " --essid, -e <ESSID>   Attempt to join wireless network ESSID after creating namespace."
    echo "                      Ignored if using --cleanup."
    echo " --passwd, -p <PASSWORD>   Password to use with ESSID.  Ignored if --essid not used."
    echo " --force, -f          Option to force execution without"
    echo "                      a proper resolv.conf in place."
    echo "                      Otherwise, script will exit."
    echo " --help, -h           Show this information"
    echo
    echo "Arguments:"
    echo " NETNS                The name of the namespace you wish"
    echo "                      to create"
    echo
    echo " DEVICE               The network interface that you want"
    echo "                      to assign to the namespace NETNS"
    echo
    echo " ignore: ESSID and PASSWORD   Used for wireless interfaces."
    echo "                      Attempts to join network with"
    echo "                      wpa_supplicant only."
    echo
    echo "makenetspace will create the namespace NETNS, move the"
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
    echo "this you'll have to manually set up DNS (see -f option)."
    echo

}

# Process options and positional arguments
get_arguments() {

    echo "get_arguments: zero is $0, one is $1"
    echo "Get options first... count is $#"

    INTERFACE_TYPE=0

    while [ $# -gt 0 ]; do
        echo " testing $1..."
        case $1 in
            --essid|-e)
                if [ $# -lt 2 ]; then
                    echo "Argument missing after ESSID. Try $0 --help or $0 -h"
                    exit $BAD_ARGUMENT
                fi
                ESSID=$2
                INTERFACE_TYPE=$((INTERFACE_TYPE+1))
                VIRTUAL=1
                shift
                shift
            ;;
            --passwd|-p)
                if [ $# -lt 2 ]; then
                    echo "Argument missing after password."
                    exit $BAD_ARGUMENT
                fi
                WIFI_PASSWORD=$2
                INTERFACE_TYPE=$((INTERFACE_TYPE+2)) # if no ESSID specified, this value will stay at 2 and get flagged
                shift
                shift
            ;;
            --static)
                if [ $# -lt 3 ]; then
                    echo "Arguments missing for --static <STATIC_IP> <GATEWAY>"
                    exit $BAD_ARGUMENT
                fi
                MANUAL_IP_CONFIG=$((MANUAL_IP_CONFIG+1))
                STATIC_IP=$2
                GATEWAY=$3
                shift
                shift
                shift
                ;;               
            --noconfig|-o)
                MANUAL_IP_CONFIG=$((MANUAL_IP_CONFIG+2))
                shift
                ;;            
            --force|-f)
                FORCE=1
                shift
                ;;
            --virtual|-v)
                VIRTUAL=1
                shift
            ;;
            --noshell|-n)
                SPAWN_SHELL=0
                shift
                ;;
            --cleanup|-c)
                CLEANUP_ONLY=1
                shift
                ;;
            --strict|-s)
                STRICT=1
                shift
                ;;
            --strictkill|-k)
                STRICTKILL=1
                shift
                ;;
            --nmingore|-i)
                NMIGNORE=1
                shift
                ;;
            --help|-h)
                usage
                exit $HELP
                ;;
            --*|-*)
                echo "Unrecognized $1.  Sorry, flag stacking is not supported yet."
                echo "try $0 --help or $0 -h"
                exit $BAD_ARGUMENT
                ;;
            *)
                break # assume we are at positional arguments now
                ;;
        esac
    done

    #check for certain conflicting options
    if [ $SPAWN_SHELL -eq 0 -a $CLEANUP_ONLY -eq 1 ]; then
        echo "--noshell and --cleanup options are incompatible.  Exiting."
        exit $BAD_ARGUMENT
    fi

    if [ $STRICT -eq 1 -a $STRICTKILL -eq 1 ]; then
        echo "--strict and --strictkill are incompatible.  Exiting."
        exit $BAD_ARGUMENT
    fi

    if [ $MANUAL_IP_CONFIG -gt 2 ]; then
        echo "--static and --noconfig are incompatible.  Exiting."
        exit $BAD_ARGUMENT
    fi

    if [ $INTERFACE_TYPE -eq 2 ]; then
        echo "Password specified without ESSID, ignoring.  Assuming wired device."
        INTERFACE_TYPE=0
    fi

    echo "Proceeding with INTERFACE_TYPE = $INTERFACE_TYPE"
    echo "0 for eth; 1 for wifi; 3 for wifi/pw"

    echo "options complete"
    echo "Remaining parameters: $#"

    if [ $# -eq 2 ]; then
        echo "two mandatory positional arguments..."
        NETNS=$1
        DEVICE=$2
    else
        echo "Ambiguous, $# positional argument(s).  Exiting."
        exit $BAD_ARGUMENT
    fi

}

#
# SCRIPT ENTRY POINT
#

get_arguments $@

#debug
if [ $INTERFACE_TYPE -gt 0 ]; then
    echo "ESSID = $ESSID (if = $INTERFACE_TYPE)"
fi

#debug
if [ $INTERFACE_TYPE -eq 3 ]; then
    echo "Wifi password = $WIFI_PASSWORD"
fi

#debug
echo "Will set up $DEVICE inside $NETNS"

#debug
echo "VIRTUAL flag set to $VIRTUAL"

#debug
echo "SPAWN SHELL = $SPAWN_SHELL"


# confirm root now, because the subsequent commands will need it
if [ "$(whoami)" != root ]; then
  echo "Only root can run this script. Exiting ($NO_ROOT)"
  exit $NO_ROOT
fi

if [ $CLEANUP_ONLY -eq 0 ]; then

    if [ $FORCE -eq 1 ]; then
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

    # not technically required... or is it?
    ip link set dev "$DEVICE" down

    # Wired or wireless?  If wireless, we need to reference the physical device
    if [ $VIRTUAL -eq 0 ]; then # wired or physical device
        ip link set dev "$DEVICE" netns "$NETNS"
        if [ $? -ne 0 ]; then
            EXIT_CODE=$?
            echo "Unable to move $DEVICE to $NETNS, exiting $EXIT_CODE"
            exit $EXIT_CODE
        fi
    else # wireless or virtual device
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
    ip netns exec $NETNS ip link show | grep $DEVICE > /dev/null # WARNING: may yield false positive result for success if DEVICE is abnormally too simple of a string
    
    if [ $? -ne 0 ]; then
        if [ $STRICTKILL -eq 1 ]; then
            echo "Unable to confirm $DEVICE in $NETNS, enforcing --strictkill, exiting."
            exit $EXIT_STRICT_KILL
        fi
        if [ $STRICT -eq 1 ]; then
            echo "Unable to confirm $DEVICE in $NETNS, enforcing --strict option and proceeding to cleanup..."
            STRICT=2 # failure
        else
            echo "Unable to confirm $DEVICE in $NETNS, will attempt to continue..."
        fi
        UNCONFIRMED_MOVE=1
    fi

    # Skip the next steps if STRICT option enforced

    # Bring up lo and $DEVICE
    if [ $STRICT -ne 2 ]; then
        ip netns exec "$NETNS" ip link set dev lo up
        if [ $? -ne 0 ]; then
            if [ $STRICTKILL -eq 1 ]; then
                echo "Could not bring up lo in $NETNS, enforcing --strictkill, exiting."
                exit $EXIT_STRICT_KILL
            fi
            if [ $STRICT -eq 1 ]; then
                echo "Could not bring up lo in $NETNS, enforcing --strict option and proceeding to cleanup..."
                STRICT=2
            else
                echo "Could not bring up lo in $NETNS, something else may be wrong. Proceeding..."
            fi
        fi
        LO_FAIL=1
    fi

    if [ $STRICT -ne 2 ]; then
        ip netns exec "$NETNS" ip link set dev "$DEVICE" up
        if [ $? -ne 0 ]; then
            if [ $STRICTKILL -eq 1 ]; then
                echo "Could not bring up $DEVICE in $NETNS, enforcing --strictkill, exiting."
                exit $EXIT_STRICT_KILL
            fi        
            if [ $STRICT -eq 1 ]; then
                echo "Could not bring up $DEVICE in $NETNS, enforcing --strict option and proceeding to cleanup..."
                STRICT=2
            else
                echo "Could not bring up $DEVICE in $NETNS, something probably went wrong. Proceeding..."
            fi
        fi
        DEVICE_FAIL=1
    fi


    # Connect to wifi, if required.
    # TODO: testing of the no-password method, using iwconfig

    if [ $STRICT -ne 2 ]; then
    
        #dirty hack to ensure the exit status variable ($?) is reset to zero
        #someone please educate me if there is a better way to do this
        cat /dev/null
        if [ $? -ne 0 ]; then
            echo "Should never encounter this, exiting."
            exit $DEBUG_EXIT
        fi

        # connect to open network with iwconfig, or, with WPA supplicant if password is provided
        if [ $INTERFACE_TYPE -eq 1 ]; then
            echo "Attempting to connect to open wifi network $ESSID..."
            ip netns exec "$NETNS" iwconfig "$DEVICE" essid "$ESSID"
        elif [ $INTERFACE_TYPE -eq 3 ]; then
            echo "Attempting to connect to secure wifi network $ESSID... (may see initialization failures, that's usually OK)"
            wpa_passphrase $ESSID $PASSWORD | ip netns exec "$NETNS" wpa_supplicant -i "$DEVICE" -c /dev/stdin -B
        fi

        if [ $? -ne 0 ]; then
            if [ $STRICTKILL -eq 1 ]; then
                echo "Error $? attempting to join $ESSID, enforcing --strictkill, exiting."
                exit $EXIT_STRICT_KILL
            fi            
            if [ $STRICT -eq 1 ]; then
                echo "Error $? attempting to join $ESSID.  Enforcing --strict option, proceeding to cleanup..."
                STRICT=2
            else
                echo "Unconfirmed attempt to join $ESSID with error $?. Proceeding..."
            fi
        fi

            echo "(DEBUG) displaying output of iwconfig in namespace $NETNS:"
            ip netns exec "$NETNS" iwconfig
        fi
    fi

    # TODO: distinguish between intent to use dhclient vs. static config
    # TODO: enable timeout limits or other failover parameters for dhclient call

    if [ $STRICT -ne 2 ]; then

        # intentional blank line
        echo

        # start dhclient, or, assign given STATIC_IP and GATEWAY, or, do nothing
        if [ $MANUAL_IP_CONFIG -eq 0 ]; then
            echo "Starting dhclient..."
            ip netns exec "$NETNS" dhclient "$DEVICE"
            echo "(DEBUG) dhclient returns status $?..." # Note, dhclient abnormality is not subject to --strict enforcement
        elif [ $MANUAL_IP_CONFIG -eq 1]; then
            echo "Attempting to manually configure STATIC_IP and GATEWAY.  Exit status verification not implemented yet."
            ip netns exec "$NETNS" ip addr add "$STATIC_IP" dev "$DEVICE" #https://www.tecmint.com/ip-command-examples/
            #ip netns exec "$NETNS" ip address add dev "$DEVICE" local "$STATIC_IP" #https://linux.die.net/man/8/ip
            ip netns exec "$NETNS" ip route add default via "$GATEWAY"
        else
            echo "No IP host configuration set up.  Do not expect usual IP access until you address this."
        fi

        if [ $SPAWN_SHELL -eq 0 ]; then # we are done
            exit $NORMAL
        fi

        # Spawn a shell in the new namespace
        echo "Spawning root shell in $NETNS..."
        echo "... try runuser -u UserName BrowserName &"
        echo "... and exit to kill the shell and netns, when done"
        ip netns exec "$NETNS" su

    fi
    # end of setup and shell. Only cleanup remains.

else # --cleanup option enabled.  Still may need to set $PHY
    echo "Cleanup only"
    if [ $VIRTUAL -eq 1 ]; then
        echo "Detecting physical name of virtual device"
        PHY="$(basename "$(cd "/sys/class/net/$DEVICE/phy80211" && pwd -P)")"
        if [ -z $PHY ]; then
            PHY=$DEVICE # try this as a fallback but it may not work
            PHY_FALLBACK=1
            echo "Unable to confirm physical device name for wireless interface $DEVICE"
            echo "Falling back on $PHY, may not work. Proceeding..."
        fi
    fi
fi

# Stop dhclient
# TODO: figure out how this is affected, if using --static option
# In the meantime, just stop dhclient regardless and ignore any manually set IP config
# which should go away when we kill the namespace anyway... right?
ip netns exec "$NETNS" dhclient -r
echo "Stopped dhclient in $NETNS with status $?"

# Move the device back into the default namespace
if [ $VIRTUAL -eq 0 ]; then
    ip netns exec "$NETNS" ip link set dev "$DEVICE" netns 1
    echo "Closing wired interface status $?.  If this fails, try again with the --virtual option."
else
    ip netns exec "$NETNS" iw phy "$PHY" set netns 1
    echo "Closing wireless/virtual interface status $?"
fi

# Remove the namespace
ip netns del "$NETNS"
echo "Deleted $NETNS"

# ... and just for good measure
if [ $NMIGNORE -eq 0 ]; then
    echo "Restarting Network Manager"
    service network-manager restart
else
    echo "Ignoring Network Manager reset"
fi

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
