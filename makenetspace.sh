#!/bin/sh
#
# makenetspace v 0.2.0-alpha
# Copyright 2021, 2022 Malcolm Schongalla, released under the MIT License (see end of file)
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

### INTERNAL VARIABLES ###

# Debug levels for stdout messages, used like constants
#  MSG_FATAL            Something programatically went wrong. Will always print.
MSG_FATAL=0

#  MSG_NORM             'Normal' information that would be good to display in most cases. Production default.
#                       Examples: user errors that force script to exit, and important notifications.
MSG_NORM=1

#  MSG_VERBOSE          Something deviated from the expected, but script will attempt to proceed. Testing default.
#                       Examples: 
MSG_VERBOSE=2

#  MSG_DEBUG            'Debug'-level info, for instance printing a variable, or tracing the
#                       programmatic flow of the script.
MSG_DEBUG=5

#
# Option-determined variables:
#  NETNS                User-specified name of the namespace to create, populate, and/or cleanup
#
#  DEVICE               User-specified identified of the network device
#
#  FORCE                defaults to 0.  1 if skipping check for /etc/netns/$NETNS/resolv.conf ;
#                       determined by --force
FORCE=0

#  INTERFACE_TYPE       defaults to 0-> wired; 1->wifi, no PW; 2->PW without wifi (invalid); 3->wifi+PW
#                       determined by presence of --essid and --passwd options
INTERFACE_TYPE=0

#  SET_WIFI             1 if -essid is invoked.  Used only for explicit parameter auditing
SET_WIFI=0

#  ESSID                ESSID of wireless network, undefined unless explicitly set
#
#  SET_PWD              1 if --passwd is invoked.  Used only for explicit parameter auditing,
#                       this should never be 1 if SET_WIFI is 0
SET_PWD=0

#  GET_PWD              1 if --getpw, -g is invoked
GET_PWD=0

#  WIFI_PASSWORD        Password of wireless network, undefined unless explicitly set

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

#  MANUAL_IP_CONFIG     defaults to 0.  Set to 1 by --static option, which collects STATIC_IP and
#                       GATEWAY.  Set to 2 by --noconfig, -o option, to indicate skipping host
#                       IP configuration entirely.
MANUAL_IP_CONFIG=0
SET_STATIC=0            # 1 if --static option is invoked
SET_NOCONFIG=0          # 1 if --noconfig is invoked

#  STATIC_IP            set by --static option.  XXX.XXX.XXX.XXX/YY format expected.  No input checking yet.
#
#  GATEWAY              set by --static option.  XXX.XXX.XXX.XXX format expected.  No input checking yet.
#
#  DEBUG_LEVEL          Triggers or suppresses output based on debug relevancy. Default depends on
#                       production vs testing status. (production->MSG_NORM; testing->MSG_VERBOSE)
DEBUG_LEVEL=$MSG_VERBOSE    #TODO: set to MSG_NORMAL in production release
SET_QUIET=0             # 1 if --quiet option is invoked
SET_VERBOSE=0           # 1 if --verbose option is invoked
SET_DEBUG=0             # 1 if --debug option is invoked

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

#
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


### SUBROUTINES ###

# Printing to stdout based on DEBUG_LEVEL
d_echo() {
    if [ $1 -le $DEBUG_LEVEL ]; then echo "$2"; fi
}

#debug output
var_dump() {
    echo "FORCE = $FORCE"
    echo "INTERFACE_TYPE = $INTERFACE_TYPE"
    echo "SET_WIFI = $SET_WIFI"
    echo "ESSID = $ESSID"
    echo "SET_PWD = $SET_PWD"
    echo "WIFI_PASSWORD = $WIFI_PASSWORD"
    echo "SPAWN_SHELL = $SPAWN_SHELL"
    echo "CLEANUP_ONLY = $CLEANUP_ONLY"
    echo "VIRTUAL = $VIRTUAL"
    echo "STRICT = $STRICT"
    echo "STRICTKILL = $STRICTKILL"
    echo "NMIGNORE = $NMIGNORE"
    echo "MANUAL_IP_CONFIG = $MANUAL_IP_CONFIG"
    echo "SET_STATIC = $SET_STATIC"
    echo "STATIC_IP = $STATIC_IP"
    echo "GATEWAY = $GATEWAY"
    echo "SET_NOCONFIG = $SET_NOCONFIG"
    echo "DEBUG_LEVEL = $DEBUG_LEVEL"
    echo "SET_QUIET = $SET_QUIET"
    echo "SET_VERBOSE = $SET_VERBOSE"
    echo "SET_DEBUG = $SET_DEBUG"
    echo "NETNS = $NETNS"
    echo "DEVICE = $DEVICE"
}

# HELP TEXT: (ignore debug level for stdout messages, always print)
usage() {

    #TODO: UPDATE WHEN COMPLETE
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

    # d_echo $MSG_NORM "get_arguments: zero is $0, one is $1" 
    # d_echo $MSG_NORM "Get options first... count is $#"
    #not MSG_DEBUG because that option hasnt been set yet

    INTERFACE_TYPE=0

    while [ $# -gt 0 ]; do
        d_echo $MSG_DEBUG " testing $1..."
        case $1 in
            --essid|-e)
                if [ $# -lt 2 ]; then
                    d_echo $MSG_NORM "Argument missing after ESSID. Try $0 --help or $0 -h"
                    exit $BAD_ARGUMENT
                fi
                ESSID=$2
                INTERFACE_TYPE=$((INTERFACE_TYPE+1))
                VIRTUAL=1
                SET_WIFI=1 # used only for explicit parameter auditing
                shift
                shift
                ;;
            --passwd|-p)
                if [ $# -lt 2 ]; then
                    d_echo $MSG_NORM "Argument missing after password."
                    exit $BAD_ARGUMENT
                fi
                WIFI_PASSWORD=$2
                SET_PWD=1 # used for explicit parameter auditing and warning if --getpw is also used
                shift
                shift
                ;;
            --getpw|-g)
                if [ $SET_PWD -ne 1 -a $GET_PWD -ne 1 ]; then
                    INTERFACE_TYPE=$((INTERFACE_TYPE+2)) # if no ESSID specified, this value will stay at 2 and get flagged
                fi
                GET_PWD=1
                shift
                ;;
            --static)
                if [ $# -lt 3 ]; then
                    d_echo $MSG_NORM "Arguments missing for --static <STATIC_IP> <GATEWAY>"
                    exit $BAD_ARGUMENT
                fi
                MANUAL_IP_CONFIG=$((MANUAL_IP_CONFIG+1))
                STATIC_IP=$2
                GATEWAY=$3
                SET_STATIC=1
                shift
                shift
                shift
                ;;               
            --noconfig|-o)
                MANUAL_IP_CONFIG=$((MANUAL_IP_CONFIG+2))
                SET_NOCONFIG=1
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
            --nmignore|-i)
                NMIGNORE=1
                shift
                ;;
            --quiet|-q)
                SET_QUIET=1
                shift
                ;;
            --verbose|-r)
                SET_VERBOSE=1
                shift
                ;;
            --debug|-d)
                SET_DEBUG=1
                shift
                ;;
            --help|-h)
                usage
                exit $HELP
                ;;
            --*)
                d_echo $MSG_NORM "Unrecognized option, $1."
                d_echo $MSG_NORM "try $0 --help or $0 -h"
                exit $BAD_ARGUMENT
                ;;
            -*)
                d_echo $MSG_NORM "Unrecognized option, $1.  Sorry, flag stacking is not supported yet."
                d_echo $MSG_NORM "try $0 --help or $0 -h"
                exit $BAD_ARGUMENT
                ;;
            *)
                break # assume we are at positional arguments now
                ;;
        esac
    done

    # Now check for certain conflicting options
    #  in certain cases, implicit parameter auditing was implemented initially, but this could be subject to
    #  abuse or undocumented behavior if someone uses the same argument multiple times.  To account for this,
    #  explicit checking was later implemented

    # Currently using discrete options to set debug output level.
    # Considered using an integer option in the future, but that would make the parameter less intuitive.
    if [ $SET_QUIET -eq 1 ]; then # lowest priority option
        DEBUG_LEVEL=$MSG_FATAL
    fi

    if [ $SET_VERBOSE -eq 1 ]; then # next priority
        DEBUG_LEVEL=$MSG_VERBOSE
    fi

    if [ $SET_DEBUG -eq 1 ]; then # top priority
        DEBUG_LEVEL=$MSG_DEBUG
    fi

    if [ $SET_PWD -eq 1 -a $GET_PWD -eq 1 ]; then
        d_echo $MSG_VERBOSE "Ignoring --passwd option."
    fi

    if [ $SPAWN_SHELL -eq 0 -a $CLEANUP_ONLY -eq 1 ]; then
        d_echo $MSG_NORM "--noshell and --cleanup options are incompatible.  Exiting."
        exit $BAD_ARGUMENT
    fi

    if [ $STRICT -eq 1 -a $STRICTKILL -eq 1 ]; then
        d_echo $MSG_NORM "--strict and --strictkill are incompatible.  Exiting."
        exit $BAD_ARGUMENT
    fi

    if [ $MANUAL_IP_CONFIG -gt 2 ] || 
       [ $SET_STATIC -eq 1 -a $SET_NOCONFIG -eq 1 ]; then # Uses both implicit and explicit parameter deconfliction
        d_echo $MSG_DEBUG "MANUAL_IP_CONFIG = $MANUAL_IP_CONFIG"
        d_echo $MSG_DEBUG "SET_STATIC = $SET_STATIC"
        d_echo $MSG_DEBUG "SET_NOCONFIG = $SET_NOCONFIG"
        d_echo $MSG_NORM "--static and --noconfig are incompatible.  Exiting."
        exit $BAD_ARGUMENT
    fi

    if [ $INTERFACE_TYPE -eq 2 ] ||
       [ $SET_WIFI -eq 0 -a $SET_PWD -eq 1 ]; then # Uses both explicit and implicit parameter deconfliction
        d_echo $MSG_DEBUG "INTERFACE_TYPE = $INTERFACE_TYPE"
        d_echo $MSG_DEBUG "SET_WIFI = $SET_WIFI"
        d_echo $MSG_DEBUG "SET_PWD = $SET_PWD"
        d_echo $MSG_NORM "Password specified without ESSID, ignoring.  Assuming wired device."
        INTERFACE_TYPE=0
    fi

    d_echo $MSG_DEBUG "Proceeding with INTERFACE_TYPE = $INTERFACE_TYPE"
    d_echo $MSG_DEBUG "0 for eth; 1 for wifi; 3 for wifi with pw"

    d_echo $MSG_DEBUG "options complete"
    d_echo $MSG_DEBUG "Remaining parameters: $#"

    if [ $# -eq 2 ]; then
        d_echo $MSG_DEBUG "two mandatory positional arguments..."
        NETNS=$1
        DEVICE=$2
    else
        d_echo $MSG_NORM "$0 --help for usage"
        d_echo $MSG_VERBOSE "Ambiguous, $# positional argument(s).  Exiting."
        exit $BAD_ARGUMENT
    fi

    # everything checks good so far, so collect the wifi password from STDIN if indicated
    if [ $GET_PWD -eq 1 -a $SET_WIFI -eq 1 ]; then
        if [ $DEBUG_LEVEL -gt $MSG_NORM ]; then
            echo -n "Enter WIFI password: "
        fi

        trap 'stty echo' EXIT
        stty -echo
        read WIFI_PASSWORD
        stty echo
        trap - EXIT

        if [ $DEBUG_LEVEL -gt $MSG_NORM ]; then echo; fi
    fi

}

#
### SCRIPT ENTRY POINT ###
#

get_arguments $@

#debug
if [ $DEBUG_LEVEL -eq $MSG_DEBUG ]; then
    var_dump
fi

# confirm root now, because the subsequent commands will need it
if [ "$(whoami)" != root ]; then
  d_echo $MSG_NORM "Only root can run this script. Exiting ($NO_ROOT)" # MSG_FATAL? not necessarily because exit code
  exit $NO_ROOT
fi

if [ $CLEANUP_ONLY -eq 0 ]; then

    if [ $FORCE -eq 1 ]; then
        d_echo $MSG_VERBOSE "Forcing execution without checking for /etc/netns/$NETNS/resolv.conf"
    else
        if [ -f "/etc/netns/$NETNS/resolv.conf" ]; then
            d_echo $MSG_VERBOSE "... /etc/netns/$NETNS/resolv.conf exists.  Hopefully it's correct!"
        else
            d_echo $MSG_NORM "/etc/netns/$NETNS/resolv.conf missing.  Please create this or"
            d_echo $MSG_NORM "run script with the -f option, and expect to set up DNS manually."
            d_echo $MSG_NORM "Exiting ($NO_RESOLV_CONF)"
            exit $NO_RESOLV_CONF
        fi
    fi

    # check for pre-existing network namespace
    ip netns | grep -w -o $NETNS > /dev/null
    if [ $? -ne 1 ]; then
        d_echo $MSG_VERBOSE "That namespace won't work.  Please try a different one."
        d_echo $MSG_VERBOSE "Check '$ ip netns' to make sure it's not already in use."
        d_echo $MSG_NORM "Exiting ($BAD_NAMESPACE)"
        exit $BAD_NAMESPACE
    fi

    # create the namespace
    ip netns add "$NETNS"
    if [ $? -ne 0 ]; then
        d_echo $MSG_NORM "Unable to create namespace $NETNS. Exiting ($BAD_NAMESPACE)"
        exit $BAD_NAMESPACE
    fi

    # not technically required... or is it?
    ip link set dev "$DEVICE" down

    # Wired or wireless?  If wireless, we need to reference the physical device
    if [ $VIRTUAL -eq 0 ]; then # wired or physical device
        ip link set dev "$DEVICE" netns "$NETNS"
        if [ $? -ne 0 ]; then
            EXIT_CODE=$?
            d_echo $MSG_NORM "Unable to move $DEVICE to $NETNS, exiting $EXIT_CODE"
            exit $EXIT_CODE
        fi
    else # wireless or virtual device
        PHY="$(basename "$(cd "/sys/class/net/$DEVICE/phy80211" && pwd -P)")"
        if [ -z $PHY ]; then
            PHY=$DEVICE # try this as a fallback but it may not work
            PHY_FALLBACK=1
            d_echo $MSG_VERBOSE "Unable to confirm physical device name for wireless interface $DEVICE"
            d_echo $MSG_VERBOSE "Falling back on $PHY, may not work. Proceeding..."
        fi
        iw phy "$PHY" set netns name "$NETNS"
        if [ $? -ne 0 ]; then
            EXIT_CODE=$?
            d_echo $MSG_NORM "Unable to move $PHY to $NETNS, exiting $EXIT_CODE"
            exit $EXIT_CODE
        fi
    fi

    # Check for success
    ip netns exec $NETNS ip link show | grep $DEVICE > /dev/null # WARNING: may yield false positive result for success if DEVICE is abnormally too simple of a string
    
    if [ $? -ne 0 ]; then
        if [ $STRICTKILL -eq 1 ]; then
            d_echo $MSG_NORM "Unable to confirm $DEVICE in $NETNS, enforcing --strictkill, exiting."
            exit $EXIT_STRICT_KILL
        fi
        if [ $STRICT -eq 1 ]; then
            d_echo $MSG_VERBOSE "Unable to confirm $DEVICE in $NETNS, enforcing --strict option and proceeding to cleanup..."
            STRICT=2 # failure
        else
            d_echo $MSG_VERBOSE "Unable to confirm $DEVICE in $NETNS, will attempt to continue..."
        fi
        UNCONFIRMED_MOVE=1
    fi

    # Skip the next steps if STRICT option enforced

    # Bring up lo and $DEVICE
    if [ $STRICT -ne 2 ]; then
        ip netns exec "$NETNS" ip link set dev lo up
        if [ $? -ne 0 ]; then
            if [ $STRICTKILL -eq 1 ]; then
                d_echo $MSG_NORM "Could not bring up lo in $NETNS, enforcing --strictkill, exiting."
                exit $EXIT_STRICT_KILL
            fi
            if [ $STRICT -eq 1 ]; then
                d_echo $MSG_NORM "Could not bring up lo in $NETNS, enforcing --strict option and proceeding to cleanup..."
                STRICT=2
            else
                d_echo $MSG_VERBOSE "Could not bring up lo in $NETNS, something else may be wrong. Proceeding..."
            fi
        fi
        LO_FAIL=1
    fi

    if [ $STRICT -ne 2 ]; then
        ip netns exec "$NETNS" ip link set dev "$DEVICE" up
        if [ $? -ne 0 ]; then
            if [ $STRICTKILL -eq 1 ]; then
                d_echo $MSG_NORM "Could not bring up $DEVICE in $NETNS, enforcing --strictkill, exiting."
                exit $EXIT_STRICT_KILL
            fi        
            if [ $STRICT -eq 1 ]; then
                d_echo $MSG_NORM "Could not bring up $DEVICE in $NETNS, enforcing --strict option and proceeding to cleanup..."
                STRICT=2
            else
                d_echo $MSG_VERBOSE "Could not bring up $DEVICE in $NETNS, something probably went wrong. Proceeding..."
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
            d_echo $MSG_FATAL "Should never encounter this, exiting."
            exit $DEBUG_EXIT
        fi

        # connect to open network with iwconfig, or, with WPA supplicant if password is provided
        if [ $INTERFACE_TYPE -eq 1 ]; then
            d_echo $MSG_NORM "Attempting to connect to open wifi network $ESSID..."
            ip netns exec "$NETNS" iwconfig "$DEVICE" essid "$ESSID"
        elif [ $INTERFACE_TYPE -eq 3 ]; then
            d_echo $MSG_NORM "Attempting to connect to secure wifi network $ESSID... (may see initialization failures, that's usually OK)"
            wpa_passphrase $ESSID $PASSWORD | ip netns exec "$NETNS" wpa_supplicant -i "$DEVICE" -c /dev/stdin -B
        fi

        if [ $? -ne 0 ]; then
            if [ $STRICTKILL -eq 1 ]; then
                d_echo $MSG_NORM "Error $? attempting to join $ESSID, enforcing --strictkill, exiting."
                exit $EXIT_STRICT_KILL
            fi            
            if [ $STRICT -eq 1 ]; then
                d_echo $MSG_NORM "Error $? attempting to join $ESSID.  Enforcing --strict option, proceeding to cleanup..."
                STRICT=2
            else
                d_echo $MSG_VERBOSE "Unconfirmed attempt to join $ESSID with error $?. Proceeding..."
            fi
        fi

            d_echo $MSG_DEBUG "Displaying output of iwconfig in namespace $NETNS:"
            if [ $DEBUG_LEVEL -ge $MSG_DEBUG ]; then
                ip netns exec "$NETNS" iwconfig
            fi
        fi
    fi

    # TODO: enable timeout limits or other failover parameters for dhclient call

    if [ $STRICT -ne 2 ]; then

        # intentional blank line
        d_echo $MSG_NORM ""

        # start dhclient, or, assign given STATIC_IP and GATEWAY, or, do nothing
        if [ $MANUAL_IP_CONFIG -eq 0 ]; then
            d_echo $MSG_NORM "Starting dhclient..."
            ip netns exec "$NETNS" dhclient "$DEVICE"
            d_echo $MSG_DEBUG "dhclient returns status $?..." # Note, dhclient abnormality is not subject to --strict enforcement
        elif [ $MANUAL_IP_CONFIG -eq 1]; then
            d_echo $MSG_NORM "Attempting to manually configure STATIC_IP and GATEWAY.  Exit status verification not implemented yet."
            ip netns exec "$NETNS" ip addr add "$STATIC_IP" dev "$DEVICE" #https://www.tecmint.com/ip-command-examples/
            #ip netns exec "$NETNS" ip address add dev "$DEVICE" local "$STATIC_IP" #https://linux.die.net/man/8/ip
            ip netns exec "$NETNS" ip route add default via "$GATEWAY"
        else
            d_echo $MSG_NORM "No IP host configuration set up.  Do not expect usual network access until you address this."
        fi

        if [ $SPAWN_SHELL -eq 0 ]; then # we are done
            exit $NORMAL
        fi

        # Spawn a shell in the new namespace
        d_echo $MSG_NORM "Spawning root shell in $NETNS..."
        d_echo $MSG_VERBOSE "... try runuser -u UserName BrowserName &"
        d_echo $MSG_VERBOSE "... and exit to kill the shell and netns, when done"
        ip netns exec "$NETNS" su

    fi
    # end of setup and shell. Only cleanup remains.

else # --cleanup option enabled.  Still may need to set $PHY
    d_echo $MSG_NORM "Cleanup only"
    if [ $VIRTUAL -eq 1 ]; then
        d_echo $MSG_VERBOSE "Detecting physical name of virtual device"
        PHY="$(basename "$(cd "/sys/class/net/$DEVICE/phy80211" && pwd -P)")"
        if [ -z $PHY ]; then
            PHY=$DEVICE # try this as a fallback but it may not work
            PHY_FALLBACK=1
            d_echo $MSG_VERBOSE "Unable to confirm physical device name for wireless interface $DEVICE"
            d_echo $MSG_VERBOSE "Falling back on $PHY, may not work. Proceeding..."
        fi
    fi
fi

# Stop dhclient
# TODO: figure out how this is affected, if using --static option
# In the meantime, just stop dhclient regardless and ignore any manually set IP config
# which should go away when we kill the namespace anyway... right?
ip netns exec "$NETNS" dhclient -r
d_echo $MSG_NORM "Stopped dhclient in $NETNS with status $?"

# Move the device back into the default namespace
if [ $VIRTUAL -eq 0 ]; then
    ip netns exec "$NETNS" ip link set dev "$DEVICE" netns 1
    d_echo $MSG_NORM "Closing wired interface status $?.  If this fails, try again with the --virtual option."
else
    ip netns exec "$NETNS" iw phy "$PHY" set netns 1
    d_echo $MSG_NORM "Closing wireless/virtual interface status $?"
fi

# Remove the namespace
ip netns del "$NETNS"
d_echo $MSG_NORM "Deleted $NETNS"

# ... and just for good measure
if [ $NMIGNORE -eq 0 ]; then
    d_echo $MSG_NORM "Restarting Network Manager"
    service network-manager restart
else
    d_echo $MSG_NORM "Ignoring Network Manager reset"
fi

d_echo $MSG_VERBOSE ""
d_echo $MSG_VERBOSE "exiting, status $?"

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
