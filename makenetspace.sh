#!/bin/sh
#
# makenetspace v 0.3.0-alpha
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
# - If --cleanup option is used, skip below past spawning the shell
# - Conditionally check for /etc/$NETNS/resolv.conf (can be overridden)
# - Make sure network namespace doesn't already exist, then try to create it
# - Bring down the device before moving it
# - If it's a virtual or wireless device, detect the corresponding physical device name
# - Make the namespace, and move the device into it
# - Bring up both the loopback interface and the device
# - Connect to wifi network using provided ESSID and password, if applicable
# - Start dhclient, by default.  Or, can statically configure IPv4 or leave unconfigured.
# - Spawn shell by default, otherwise exit here
# - Stop dhclient, if running
# - move the device out of the namespace
# - delete the namespace
# - restart NetworkManager (by default)

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

#  STRICT               value corresponds to status of STRICT operations.  Set to 1 by --strict.
#                       0 (default) - normal operations (tolerate errors)
#                       1 - errors cause script to skip ahead to namespace cleanup
#                       2 - an error was detected, script will skip remaining setup steps.
#                       Note, will still exit with code 0, reason being the script functioned as intented
#                       in response to an error.  Can use --debug for more information.
#                       In future versions, consider carrying through the error code if there is interest.
STRICT=0

#  STRICTKILL           defaults to false (0). If set true (1), failure of STRICT enforced commands result
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
DEBUG_LEVEL=$MSG_NORM
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
BAD_DEVICE=5
STRICT_WITH_CLEANUP=6   # could not verify that DEVICE was moved into NETNS.  NETNS removed.
EXIT_STRICT_KILL=7      # could not verify that DEVICE was moved into NETNS.  Exited immediately.
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
    echo "GET_PWD = $GET_PWD"
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

    echo "usage:"
    echo "# makenetspace.sh [OPTIONS] NETNS DEVICE"
    echo
    echo " OPTIONS  See included USAGE file for detailed options information."
    echo " NETNS    The name of the namespace you wish to create"
    echo " DEVICE   The network interface that you want to assign to the namespace NETNS"
    echo
    echo "OPTIONS:"
    echo "--essid, -e <ESSID>       Connect wifi interface to ESSID"
    echo "--passwd, -p <PASSWORD>   WPA2 only"
    echo "--getpw, -g       Get wifi password from STDIN"
    echo "--force, -f       Proceed even if resolv.conf is not found"
    echo "--virtual -v      Use iw instead if ip to move the interface around"
    echo "--noshell, -n     Don't spawn a shell in the new network namespace"
    echo "--cleanup, -c     Skip setup and configuration, and go straight to cleanup"
    echo "--strict, -s      Treat all errors as fatal, but try to cleanup before exiting"
    echo "--strictkill -k   Treat all errors as fatal and exit immediately (no cleanup)"
    echo "--nmignore, -i    Don't reset NetworkManager upon cleanup"
    echo "--static <STATIC_IP> <GATEWAY>    Static IP in lieu of dhclient"
    echo "--noconfig, -o    Don't apply IP configuration with dhclient or --static option"
    echo "--physical <WIFI> Tto print the physical name of the WIFI interface, then exit"
    echo "--quiet, -q       Suppress unnecessary output (ignored if --debug flag used)"
    echo "--verbose, -r     (overrides --quiet)"
    echo "--debug, -d       (overrides --quiet and --verbose)"
    echo
    echo
    echo "Note 1: this script must be run as the superuser."
    echo
    echo "Note 2: before using this script, you should have a custom resolv.conf file"
    echo "that already exists in the folder /etc/netns/\$NETNS, the purpose is to have"
    echo "this file bind to /etc/resolv.conf within the new namespace.  Without this you"
    echo "will have to manually set up DNS (see --force option)."
    echo
}

# Process options and positional arguments
get_arguments() {

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
            --physical)
                if [ $# -lt 2 ]; then
                    d_echo $MSG_NORM "Argument missing after --physical. Try $0 --help or $0 -h"
                    exit $BAD_ARGUMENT
                fi
                echo "$(basename "$(cd "/sys/class/net/$2/phy80211" && pwd -P)")"
                exit $NORMAL
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
    # read -s is not POSIX compliant, this employs an alternate technique
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
  d_echo $MSG_NORM "Fatal error: only root can run this script. Exiting ($NO_ROOT)" # MSG_FATAL? not necessarily because exit code
  exit $NO_ROOT
fi

d_echo $MSG_DEBUG "CLEANUP_ONLY = $CLEANUP_ONLY"

if [ $CLEANUP_ONLY -eq 0 ]; then

    d_echo $MSG_DEBUG "Checking for resolv.conf..."

    if [ $FORCE -eq 1 ]; then
        d_echo $MSG_VERBOSE "Forcing execution without checking for /etc/netns/$NETNS/resolv.conf"
    else
        if [ -f "/etc/netns/$NETNS/resolv.conf" ]; then
            d_echo $MSG_VERBOSE "... /etc/netns/$NETNS/resolv.conf exists."
        else
            d_echo $MSG_NORM "Fatal error: /etc/netns/$NETNS/resolv.conf missing.  Please create this or"
            d_echo $MSG_NORM "run script with the -f option, and expect to set up DNS manually."
            d_echo $MSG_NORM "Exiting ($NO_RESOLV_CONF)"
            exit $NO_RESOLV_CONF
        fi
    fi

    d_echo $MSG_DEBUG "Checking for pre-existing netns $NETNS..."
    # check for pre-existing network namespace
    ip netns | grep -w -o $NETNS > /dev/null
    if [ $? -ne 1 ]; then
        d_echo $MSG_VERBOSE "Fatal error: that namespace won't work.  Please try a different one."
        d_echo $MSG_VERBOSE "Check '$ ip netns' to make sure it's not already in use."
        d_echo $MSG_NORM "Exiting ($BAD_NAMESPACE)"
        exit $BAD_NAMESPACE
    fi

    d_echo $MSG_DEBUG "Creating netns $NETNS..."
    # create the namespace
    ip netns add "$NETNS"
    if [ $? -ne 0 ]; then
        d_echo $MSG_NORM "Fatal error: unable to create namespace $NETNS, exiting ($BAD_NAMESPACE)"
        exit $BAD_NAMESPACE
    fi

    ### After this point, the network namespace has been created, so it will need cleanup according to --strict or --strictkill for any future errors

    # technically, we don't need to lower DEVICE to move it into a namespace.  But if this fails, a common
    # reason is that DEVICE doesn't exist and we should find this out sooner rather than later.
    d_echo $MSG_DEBUG "Setting $DEVICE down..."
    ip link set dev "$DEVICE" down
    EXIT_CODE=$?
    d_echo $MSG_DEBUG "ip link set dev $DEVICE down -> $EXIT_CODE"
    if [ $EXIT_CODE -ne 0 ]; then
        if [ $STRICTKILL -eq 1 ]; then
            d_echo $MSG_NORM "Unable to set $DEVICE down, enforcing --strictkill"
            exit $BAD_DEVICE
        fi
        if [ $STRICT -eq 1 ]; then
            d_echo $MSG_NORM "Unable to set $DEVICE down, enforcing --strict, proceeding to cleanup"
            STRICT=2 # First location of flagging --strict violation
        else
            d_echo $MSG_NORM "Unable to set $DEVICE down with code $EXIT_CODE, but will attempt to proceed..."
        fi
    fi

    # From this point on, STRICT could potentially be set to 2, and we need to check between each step.

    # Wired or wireless?  If wireless, we need to reference the physical device
    if [ $STRICT -ne 2 ]; then
        if [ $VIRTUAL -eq 0 ]; then # wired or physical device
            d_echo $MSG_DEBUG "...physical device..."
            ip link set dev "$DEVICE" netns "$NETNS"
            if [ $? -ne 0 ]; then
                EXIT_CODE=$?
                if [ $STRICTKILL -eq 1 ]; then
                    d_echo $MSG_NORM "Unable to move physical $DEVICE into $NETNS, enforcing --strictkill, exiting $EXIT_CODE"
                    exit $EXIT_CODE
                fi
                d_echo $MSG_NORM "Fatal error: unable to move $DEVICE into $NETNS, proceeding to cleanup..."
                STRICT=2
            fi
        else # wireless or virtual device
            d_echo $MSG_DEBUG "...virtual or wifi device..."
            PHY="$(basename "$(cd "/sys/class/net/$DEVICE/phy80211" && pwd -P)")"
            d_echo $MSG_DEBUG "...attempted to identify PHY = $PHY..."
            if [ -z $PHY ]; then
                PHY=$DEVICE # try this as a fallback but it may not work
                PHY_FALLBACK=1
                d_echo $MSG_VERBOSE "Unable to confirm physical device name for wireless interface $DEVICE"
                d_echo $MSG_VERBOSE "Falling back on $PHY, may not work. Proceeding..."
            fi
            iw phy "$PHY" set netns name "$NETNS"
            if [ $? -ne 0 ]; then
                EXIT_CODE=$?
                if [ $STRICTKILL -eq 1 ]; then
                    d_echo $MSG_NORM "Unable to move virtual interface $PHY into $NETNS, enforcing --strictkill, exiting $EXIT_CODE"
                    exit $EXIT_CODE
                fi
                d_echo $MSG_NORM "Fatal error: unable to move $DEVICE into $NETNS, proceeding to cleanup..."
                STRICT=2
                d_echo $MSG_VERBOSE "(Try --virtual option to indicate a wifi device without a given ESSID)"
            fi
        fi #endif determine wired/wireless/virtual

    fi # endif enforce --strict before attempting to move DEVICE into NETNS

    # From this point forward, failures are not necessarily fatal unless --strict[kill] is enforced
    if [ $STRICT -ne 2 ]; then

        if [ $DEBUG_LEVEL -eq $MSG_DEBUG ]; then
            echo "Checking for success moving device $DEVICE to netns $NETNS, running ip link show..."
            ip netns exec $NETNS ip link show | grep $DEVICE # WARNING: may yield false positive result for success if DEVICE is abnormally too simple of a string
        else
            ip netns exec $NETNS ip link show | grep $DEVICE > /dev/null # WARNING: may yield false positive result for success if DEVICE is abnormally too simple of a string
        fi
        
        EXIT_CODE=$?

        d_echo $MSG_DEBUG "Evaluating strict/kill citeria for having moved $DEVICE into $NETNS..."
        if [ $EXIT_CODE -ne 0 ]; then
            if [ $STRICTKILL -eq 1 ]; then
                d_echo $MSG_NORM "Unable to confirm $DEVICE in $NETNS, enforcing --strictkill, exiting."
                exit $EXIT_STRICT_KILL
            fi
            if [ $STRICT -eq 1 ]; then
                d_echo $MSG_VERBOSE "Unable to confirm $DEVICE in $NETNS, enforcing --strict, proceeding to cleanup..."
                STRICT=2
            else
                d_echo $MSG_VERBOSE "Unable to confirm $DEVICE in $NETNS, will attempt to continue..."
            fi
            UNCONFIRMED_MOVE=1
        fi
    fi # endif enforcing --strict before checking for success moving DEVICE into NETNS

    # Bring up lo and $DEVICE
    if [ $STRICT -ne 2 ]; then
        d_echo $MSG_DEBUG "Bring up lo..."
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
    fi # endif bring up lo

    if [ $STRICT -ne 2 ]; then
        d_echo $MSG_DEBUG "Bring up $DEVICE..."
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
    fi #endif bring up DEVICE


    # Connect to wifi, if required.

    if [ $STRICT -ne 2 ]; then

        # This d_echo call serves double duty.  Besides conditionally displaying a message, it also
        # resets $? to 0.  If you remove it later, do something empty like `cat /dev/null` to reset $?.
        d_echo $MSG_DEBUG "Will connect to Wifi if required..."
        #cat /dev/null

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

    fi #endif connect to wifi

    # TODO: consider enabling timeout limits or other failover parameters for dhclient call

    if [ $STRICT -ne 2 ]; then
        d_echo $MSG_DEBUG "IP configuring step (unless --noconfig)"
        # intentional blank line
        d_echo $MSG_NORM ""

        # start dhclient, or, assign given STATIC_IP and GATEWAY, or, do nothing
        if [ $MANUAL_IP_CONFIG -eq 0 ]; then
            d_echo $MSG_NORM "Starting dhclient..."
            ip netns exec "$NETNS" dhclient "$DEVICE"
            d_echo $MSG_DEBUG "dhclient returns status $?..." # Note, dhclient abnormality is not subject to --strict enforcement
        elif [ $MANUAL_IP_CONFIG -eq 1 ]; then
            d_echo $MSG_NORM "Attempting to manually configure STATIC_IP and GATEWAY.  Exit status verification not implemented yet."
            ip netns exec "$NETNS" ip addr add "$STATIC_IP" brd + dev "$DEVICE" #https://www.tecmint.com/ip-command-examples/
            EXIT_CODE=$?
            d_echo $MSG_DEBUG "ip addr add: returns $EXIT_CODE..."
            if [ $EXIT_CODE -ne 0 ]; then
                if [ $STRICTKILL -eq 1 ]; then
                    d_echo $MSG_NORM "Could not add static IP and netmask, enforcing --strictkill, exiting."
                    exit $EXIT_STRICT_KILL
                fi        
                if [ $STRICT -eq 1 ]; then
                    d_echo $MSG_NORM "Could not add static IP and netmask, enforcing --strict option and proceeding to cleanup..."
                    STRICT=2
                else
                    d_echo $MSG_VERBOSE "...Could not add static IP and netmask..."
                fi
            fi


            ip netns exec "$NETNS" ip route add default via "$GATEWAY"
            EXIT_CODE=$?            
            d_echo $MSG_DEBUG "ip route add: returns $EXIT_CODE..."
            if [ $EXIT_CODE -ne 0 ]; then
                if [ $STRICTKILL -eq 1 ]; then
                    d_echo $MSG_NORM "Could not add default gateway, enforcing --strictkill, exiting."
                    exit $EXIT_STRICT_KILL
                fi        
                if [ $STRICT -eq 1 ]; then
                    d_echo $MSG_NORM "Could not add default gateway, enforcing --strict option and proceeding to cleanup..."
                    STRICT=2
                else
                    d_echo $MSG_VERBOSE "...Could not add default gateway..."
                fi
            fi
        else
            d_echo $MSG_NORM "No IP host configuration set up.  Do not expect usual network access until you address this."
        fi #endif configure IP

        if [ $STRICT -ne 2 ]; then # if STRICT is enforced, script should cleanup instead of shelling or terminating here
            if [ $SPAWN_SHELL -eq 0 ]; then # we are done
                exit $NORMAL
            fi
 
            # Spawn a shell in the new namespace
            d_echo $MSG_NORM "Spawning root shell in $NETNS..."
            d_echo $MSG_VERBOSE "... try runuser -u UserName BrowserName &"
            d_echo $MSG_VERBOSE "... and exit to kill the shell and netns, when done"
            ip netns exec "$NETNS" sh
        fi

 
    fi # endif of namespace setup and shell. Only cleanup remains.

else # --cleanup option enabled.  Still may need to set $PHY
    d_echo $MSG_NORM "Cleanup only"
    if [ $VIRTUAL -eq 1 ]; then
        d_echo $MSG_VERBOSE "Detecting physical name of virtual device for cleanup only"
        PHY="$(basename "$(cd "/sys/class/net/$DEVICE/phy80211" && pwd -P)")"
        if [ -z $PHY ]; then
            PHY=$DEVICE # try this as a fallback but it may not work
            PHY_FALLBACK=1
            d_echo $MSG_VERBOSE "Unable to confirm physical device name for wireless interface $DEVICE"
            d_echo $MSG_VERBOSE "Falling back on $PHY, may not work. Proceeding..."
        fi
    fi
fi # endif determining cleanup only or not


### Cleanup phase ###

# Stop dhclient
# likely no effect if we employed --static, but the user may have started it separately so kill it just in case
ip netns exec "$NETNS" dhclient -r
d_echo $MSG_NORM "Stopped dhclient in $NETNS with status $?"

# Move the device back into the default namespace
if [ $VIRTUAL -eq 0 ]; then
    ip netns exec "$NETNS" ip link set dev "$DEVICE" netns 1
    d_echo $MSG_NORM "Closing wired interface status $?.  If this fails, try again with --virtual"
else
    ip netns exec "$NETNS" iw phy "$PHY" set netns 1
    TEMP_EXIT=$?
    d_echo $MSG_NORM "Closing wireless/virtual interface status $TEMP_EXIT"
    if [ $TEMP_EXIT -ne 0 ]; then
        d_echo $MSG_VERBOSE "(Try using --virtual and providing physical device name next time)"
    fi
fi

# Remove the namespace
ip netns del "$NETNS"
d_echo $MSG_NORM "Deleted $NETNS"

# ... and just for good measure
if [ $NMIGNORE -eq 0 ]; then
    #make sure network-manager is running first
    service network-manager status > /dev/null
    $TEMP_EXIT=$?
    if [ $TEMP_EXIT -eq 0 ]; then
        d_echo $MSG_NORM "Restarting network-manager"
        service network-manager restart
#    elseif [ $TEMP_EXIT -eq 3 ]; then
#        d_echo $MSG_NORM "Starting network-manager"
#        service network-manager start
    else
        d_echo $MSG_VERBOSE "Network-manager not running, skipping restart"
    fi
else
    d_echo $MSG_NORM "Ignoring network-manager reset"
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
