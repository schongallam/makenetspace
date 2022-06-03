#!/bin/sh
#
# makenetspace
version="0.3.3b"
# Copyright 2021, 2022 Malcolm Schongalla, released under the MIT License (see end of file)
#
# malcolm.schongalla@gmail.com
#
# A script to set up a network namespace and move an adapter into it, and clean up after
# 
# general usage:
# $ makenetspace [OPTIONS] netns net_device
#
# see USAGE file or usage() below for argument details.
#
#
# Script flow:
# - Set global variables
# - Interpret command line arguments
# - Confirm root
# - If --cleanup option is used, skip below past spawning the shell
# - Conditionally check for /etc/$netns/resolv.conf (can be overridden)
# - Make sure network namespace doesn't already exist, then try to create it
# - Bring down the device before moving it
# - If it's a virtual or wireless device, detect the corresponding physical device name
# - Make the namespace, and move the device into it
# - Bring up both the loopback interface and the device
# - Connect to wifi network using provided ESSID and password, if applicable
# - Start dhclient, by default.  Or, can statically configure IPv4 or leave unconfigured.
# - Spawn shell by default, execute another specified command, or exit here
# - kill any remaining PIDs in the network namespace
# - move the device out of the namespace
# - delete the namespace

### INTERNAL VARIABLES ###

# Debug levels for stdout messages, used like constants
#  msg_fatal            Something programmatically went wrong.  Will always print.  Used for beta development.
msg_fatal=0             # factor this out for production versions if possible

#  msg_norm             For error messages, user interaction, info about major script steps.  Production default.
msg_norm=1

#  msg_verbose          More detailed info about steps.  Often accompanies a msg_norm echo.  Testing default.
msg_verbose=2

#  msg_debug            Debug-level info, for instance printing a variable, or tracing the
#                       programmatic flow of the script.  i.e. variable contents, exit codes
msg_debug=5

#
# Option-determined variables:
#  netns                User-specified name of the namespace to create, populate, and/or cleanup
#
#  net_device           User-specified identified of the network device
#
#  force_resolv         Defaults to 0.  1 if skipping check for /etc/netns/$netns/resolv.conf ;
#                       determined by --force
force_resolv=0

#  interface_type       defaults to 0-> wired; 1->wifi, no PW; 2->PW without wifi (invalid); 3->wifi+PW
#                       determined by presence of --essid and --passwd options
interface_type=0

#  set_wifi             1 if -essid is invoked.  Used only for explicit parameter auditing
set_wifi=0

#  ESSID                ESSID of wireless network, undefined unless explicitly set. (in caps b/c acronym)
#
#  set_pwd              1 if --passwd is invoked.  Used only for explicit parameter auditing,
#                       this should never be 1 if set_wifi is 0
set_pwd=0

#  get_pwd              1 if --getpw, -g is invoked
get_pwd=0

#  wifi_password        Password of wireless network, undefined unless explicitly set

#  spawn_shell          defaults to true (1).  False with --noshell, -n option
spawn_shell=1

#  exec_flag            1 if intention is to execute an alternate command to su.  Incomaptible with
#                       --cleanup
exec_flag=0

#  exec_cmd             If exec_flag is set to 1, run this command instead of su.
#
#  cleanup_only         defaults to false (0). To cleanup a wireless interface, use this with --virtual
#                       or --essid <ESSID>.  Incompatible with --noshell, -n
cleanup_only=0

#  virtual_dev          defaults to false (0). Set to 1 if a wireless interface is implied by
#                       providing an ESSID, or if forced by the --virtual, -v option.  This option
#                       is useful when using --cleanup on a wireless interface
virtual_dev=0

#  strict_enforce       value corresponds to status of strict_enforce operations.  Set to 1 by --strict.
#                       0 (default) - normal operations (tolerate errors)
#                       1 - errors cause script to skip ahead to namespace cleanup
#                       2 - an error was detected, script will skip remaining setup steps.
#                       Note, will still exit with code 0, reason being the script functioned as intented
#                       in response to an error.  Can use --debug for more information.
#                       In future versions, consider carrying through the error code if there is interest.
strict_enforce=0

#  strict_kill          defaults to false (0). If set true (1), failure of strict_enforce enforced commands result
#                       immediately exiting the script.  This option can cause problems.  Set to true
#                       (1) by --strictkill, -k
strict_kill=0

#  manual_ip_config     defaults to 0.  Set to 1 by --static option, which collects static_ip and
#                       gateway.  Set to 2 by --noconfig, -o option, to indicate skipping host
#                       IP configuration entirely.
manual_ip_config=0
set_static=0            # 1 if --static option is invoked
set_noconfig=0          # 1 if --noconfig is invoked

#  static_ip            set by --static option.  XXX.XXX.XXX.XXX/YY format expected.  No input checking yet.
#
#  gateway              set by --static option.  XXX.XXX.XXX.XXX format expected.  No input checking yet.
#
#  debug_level          Triggers or suppresses output based on debug relevancy. Default depends on
#                       production vs testing status. (production->msg_norm; testing->msg_verbose)
debug_level=$msg_norm
set_quiet=0             # 1 if --quiet option is invoked
set_verbose=0           # 1 if --verbose option is invoked
set_debug=0             # 1 if --debug option is invoked

#
# Other internal variables:
#  exit_code            captures and preserves an abnormal exit code from a command in the
#                       event that we need to exit the script with it
#  phy_dev              physical interface name for given wifi interface net_device
#  phy_fallback         (UNUSED) 1 if unable to confirm phy_dev, and using net_device instead.
#                       Otherwise, undefined
#  unconfirmed_move     (UNUSED) 1 if grep can't find net_device listed in the new namespace after
#                       attempting to move it
#  lo_fail              (UNUSED) 1 if unable to raise lo interface in netns
#  device_fail          (UNUSED) 1 if unable to raise net_device in netns

#
# OTHER EXIT CODES:
exit_normal=0           # normal exit
exit_help=0             # help/description shown
exit_bad_argument=1     # Problem parsing arguments
exit_no_root=2          # not run as root
exit_no_resolv=3        # unable to find appropriate resolv.conf file
exit_bad_namespace=4    # namespace is bad or already exists
exit_bad_device=5       # unable to set device down, something may be wrong with it
exit_strict_enforce=6   # could not verify that net_device was moved into netns.  netns removed.
exit_strict_kill=7      # could not verify that net_device was moved into netns.  Exited immediately.
exit_debug=10           # used for debugging purposes

#
### SUBROUTINES ###
#

# Printing to stdout based on debug_level
d_echo() {
    if [ $1 -le $debug_level ]; then echo "$2"; fi
}

# for debug output
var_dump() {
    echo "force_resolv = $force_resolv"
    echo "interface_type = $interface_type"
    echo "set_wifi = $set_wifi"
    echo "ESSID = $ESSID"
    echo "set_pwd = $set_pwd"
    echo "get_pwd = $get_pwd"
    echo "wifi_password = $wifi_password"
    echo "spawn_shell = $spawn_shell"
    echo "exec_flag = $exec_flag"
    echo "exec_cmd = $exec_cmd"
    echo "cleanup_only = $cleanup_only"
    echo "virtual_dev = $virtual_dev"
    echo "strict_enforce = $strict_enforce"
    echo "strict_kill = $strict_kill"
    echo "manual_ip_config = $manual_ip_config"
    echo "set_static = $set_static"
    echo "static_ip = $static_ip"
    echo "gateway = $gateway"
    echo "set_noconfig = $set_noconfig"
    echo "debug_level = $debug_level"
    echo "set_quiet = $set_quiet"
    echo "set_verbose = $set_verbose"
    echo "set_debug = $set_debug"
    echo "netns = $netns"
    echo "net_device = $net_device"
}

usage() {
    cat <<EOF
usage:
# makenetspace.sh [OPTIONS] netns net_device
Version $version

 OPTIONS        See included USAGE file for detailed options information.
 netns          The name of the namespace you wish to create
 net_device     The network interface that you want to assign to the namespace netns

OPTIONS:
--essid, -e <ESSID>         Connect wifi interface to ESSID
--passwd, -p <PASSWORD>     WPA2 only
--getpw, -g       Get wifi password from STDIN
--force, -f       Proceed even if resolv.conf is not found
--virtual -v      Use iw instead if ip to move the interface around
--noshell, -n     Don't spawn a shell in the new network namespace
--execute, -x <CMD>         Run CMD instead of su in the new namespace
--cleanup, -c     Skip setup and configuration, and go straight to cleanup
--strict, -s      Treat all errors as fatal, but try to cleanup before exiting
--strictkill -k   Treat all errors as fatal and exit immediately (no cleanup)
--static <static_ip/MASK> <gateway>    Static IP in lieu of dhclient
--noconfig, -o    Don't apply IP configuration with dhclient or --static option
--physical <WIFI> Print the physical name of the WIFI interface, then exit
--quiet, -q       Suppress unnecessary output (ignored if --debug flag used)
--verbose, -r     (overrides --quiet)
--debug, -d       (overrides --quiet and --verbose)


Note 1: this script must be run as the superuser.

Note 2: before using this script, you should have a custom resolv.conf file
that already exists in the folder /etc/netns/\$netns, the purpose is to have
this file bind to /etc/resolv.conf within the new namespace.  Without this you
will have to manually set up DNS (see --force option).

EOF
}

get_arguments() {

    interface_type=0

    while [ $# -gt 0 ]; do
        case $1 in
            --essid|-e)
                if [ $# -lt 2 ]; then
                    d_echo $msg_norm "Argument missing after ESSID. Try $0 --help or $0 -h"
                    exit $exit_bad_argument
                fi
                ESSID="$2"
                interface_type=$((interface_type+1))
                virtual_dev=1
                set_wifi=1 # used only for explicit parameter auditing
                shift
                shift
                ;;
            --passwd|-p)
                if [ $# -lt 2 ]; then
                    d_echo $msg_norm "Argument missing after password."
                    exit $exit_bad_argument
                fi
                wifi_password="$2"
                if [ $set_pwd -ne 1 -a $get_pwd -ne 1 ]; then # make sure the variable is only increased once
                    interface_type=$((interface_type+2)) # if no ESSID specified, this value will stay at 2 and get flagged
                fi
                set_pwd=1 # used for explicit parameter auditing and warning if --getpw is also used
                shift
                shift
                ;;
            --getpw|-g)
                if [ $set_pwd -ne 1 -a $get_pwd -ne 1 ]; then # make sure the variable is only increased once
                    interface_type=$((interface_type+2)) # if no ESSID specified, this value will stay at 2 and get flagged
                fi
                get_pwd=1
                shift
                ;;
            --static)
                if [ $# -lt 3 ]; then
                    d_echo $msg_norm "Arguments missing for --static <static_ip> <gateway>"
                    exit $exit_bad_argument
                fi
                manual_ip_config=$((manual_ip_config+1))
                static_ip=$2
                gateway=$3
                set_static=1
                shift
                shift
                shift
                ;;               
            --noconfig|-o)
                manual_ip_config=$((manual_ip_config+2))
                set_noconfig=1
                shift
                ;;            
            --force|-f)
                force_resolv=1
                shift
                ;;
            --virtual|-v)
                virtual_dev=1
                shift
                ;;
            --noshell|-n)
                spawn_shell=0
                shift
                ;;
            --execute|-x)
                if [ $# -lt 2 ]; then
                    d_echo $msg_norm "Argument missing for --execute <CMD>"
                    exit $exit_bad_argument
                fi            
                exec_flag=1
                exec_cmd="$2"
                shift
                shift
                ;;
            --cleanup|-c)
                cleanup_only=1
                shift
                ;;
            --strict|-s)
                strict_enforce=1
                shift
                ;;
            --strictkill|-k)
                strict_kill=1
                shift
                ;;
            --physical)
                if [ $# -lt 2 ]; then
                    d_echo $msg_norm "Argument missing after --physical. Try $0 --help or $0 -h"
                    exit $exit_bad_argument
                fi
                echo "$(basename "$(cd "/sys/class/net/$2/phy80211" && pwd -P)")"
                exit $exit_normal
                ;;                
            --quiet|-q)
                set_quiet=1
                shift
                ;;
            --verbose|-r)
                set_verbose=1
                shift
                ;;
            --debug|-d)
                set_debug=1
                shift
                ;;
            --help|-h)
                usage
                exit $exit_help
                ;;
            --*)
                d_echo $msg_norm "Unrecognized option, $1."
                d_echo $msg_norm "try $0 --help or $0 -h"
                exit $exit_bad_argument
                ;;
            -*)
                d_echo $msg_norm "Unrecognized option, $1.  Sorry, flag stacking is not supported yet."
                d_echo $msg_norm "try $0 --help or $0 -h"
                exit $exit_bad_argument
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

    if [ $set_quiet -eq 1 ]; then # lowest priority option
        debug_level=$msg_fatal
    fi

    if [ $set_verbose -eq 1 ]; then # next priority
        debug_level=$msg_verbose
    fi

    if [ $set_debug -eq 1 ]; then # top priority
        echo "Debug level set"
        debug_level=$msg_debug
    fi

    if [ $set_pwd -eq 1 -a $get_pwd -eq 1 ]; then
        d_echo $msg_verbose "Ignoring --passwd option."
    fi

    if [ $spawn_shell -eq 0 -a $cleanup_only -eq 1 ]; then
        d_echo $msg_norm "--noshell and --cleanup options are incompatible.  Exiting."
        exit $exit_bad_argument
    fi

    if [ $exec_flag -eq 1 -a $cleanup_only -eq 1 ]; then
        d_echo $msg_norm "--execute and --cleanup options are incompatible.  Exiting."
        exit $exit_bad_argument
    fi

    if [ $strict_enforce -eq 1 -a $strict_kill -eq 1 ]; then
        d_echo $msg_norm "--strict and --strictkill are incompatible.  Exiting."
        exit $exit_bad_argument
    fi

    if [ $manual_ip_config -gt 2 ] || 
       [ $set_static -eq 1 -a $set_noconfig -eq 1 ]; then # Uses both implicit and explicit parameter deconfliction
        d_echo $msg_debug "manual_ip_config = $manual_ip_config"
        d_echo $msg_debug "set_static = $set_static"
        d_echo $msg_debug "set_noconfig = $set_noconfig"
        d_echo $msg_norm "--static and --noconfig are incompatible.  Exiting."
        exit $exit_bad_argument
    fi

    if [ $interface_type -eq 2 ] ||
       [ $set_wifi -eq 0 -a $set_pwd -eq 1 ]; then # Uses both explicit and implicit parameter deconfliction
        d_echo $msg_debug "interface_type = $interface_type"
        d_echo $msg_debug "set_wifi = $set_wifi"
        d_echo $msg_debug "set_pwd = $set_pwd"
        d_echo $msg_norm "Password specified without ESSID, ignoring.  Assuming wired device."
        interface_type=0
    fi

    d_echo $msg_debug "Proceeding with interface_type = $interface_type"
    d_echo $msg_debug "0 for eth; 1 for wifi; 3 for wifi with pw"

    d_echo $msg_debug "options complete"
    d_echo $msg_debug "Remaining parameters: $#"

    if [ $# -eq 2 ]; then
        # d_echo $msg_debug "two mandatory positional arguments..."
        netns=$1
        net_device=$2
    else
        if [ $debug_level -eq $msg_debug ]; then
            var_dump
        fi

        d_echo $msg_norm "$0 --help for usage"
        d_echo $msg_verbose "Ambiguous, $# positional argument(s).  Exiting."
        exit $exit_bad_argument
    fi

    # everything checks good so far, so collect the wifi password from STDIN if indicated
    # 'read -s' is not POSIX compliant, this employs an alternate technique
    if [ $get_pwd -eq 1 -a $set_wifi -eq 1 ]; then
        if [ $debug_level -gt $msg_norm ]; then
            echo -n "Enter WIFI password: "
        fi

        trap 'stty echo' EXIT
        stty -echo
        read wifi_password
        stty echo
        trap - EXIT

        if [ $debug_level -gt $msg_norm ]; then echo; fi
    fi

}

#
### SCRIPT ENTRY POINT ###
#

get_arguments "$@"

#debug
if [ $debug_level -eq $msg_debug ]; then
    var_dump
fi

# confirm root now, because the subsequent commands will need it
if [ $(id -u) -ne 0 ]; then
  d_echo $msg_norm "Only root can run this script. Exiting ($exit_no_root)"
  exit $exit_no_root
fi

# Redundant, commented out for now
#d_echo $msg_debug "cleanup_only = $cleanup_only"

if [ $cleanup_only -eq 0 ]; then

    d_echo $msg_debug "Checking for resolv.conf..."

    if [ $force_resolv -eq 1 ]; then
        d_echo $msg_verbose "Forcing execution without checking for /etc/netns/$netns/resolv.conf"
    else
        if [ -f "/etc/netns/$netns/resolv.conf" ]; then
            d_echo $msg_verbose "... /etc/netns/$netns/resolv.conf exists."
        else
            d_echo $msg_norm "Error: /etc/netns/$netns/resolv.conf missing.  Please create this or"
            d_echo $msg_norm "run script with the -f option, and expect to set up DNS manually."
            d_echo $msg_norm "Exiting ($exit_no_resolv)"
            exit $exit_no_resolv
        fi
    fi

    d_echo $msg_debug "Checking for pre-existing netns $netns..."
    # check for pre-existing network namespace
    ip netns | grep -w -o $netns > /dev/null
    if [ $? -ne 1 ]; then
        d_echo $msg_verbose "That namespace won't work.  Please try a different one."
        d_echo $msg_verbose "Check '$ ip netns' to make sure it's not already in use."
        d_echo $msg_norm "Exiting ($exit_bad_namespace)"
        exit $exit_bad_namespace
    fi

    d_echo $msg_debug "Creating netns $netns..."
    # create the namespace
    ip netns add "$netns"
    if [ $? -ne 0 ]; then
        d_echo $msg_norm "Unable to create namespace $netns, exiting ($exit_bad_namespace)"
        exit $exit_bad_namespace
    fi

    ### After this point, the network namespace has been created, so it will need cleanup according to --strict or --strictkill for any future errors

    # technically, we don't need to lower net_device to move it into a namespace.  But if this fails, a common
    # reason is that net_device doesn't exist and we should find this out sooner rather than later.
    d_echo $msg_debug "Setting $net_device down..."
    ip link set dev "$net_device" down
    exit_code=$?
    d_echo $msg_debug "ip link set dev $net_device down -> $exit_code"
    if [ $exit_code -ne 0 ]; then
        if [ $strict_kill -eq 1 ]; then
            d_echo $msg_norm "Unable to set $net_device down, enforcing --strictkill"
            exit $exit_bad_device
        fi
        if [ $strict_enforce -eq 1 ]; then
            d_echo $msg_norm "Unable to set $net_device down, enforcing --strict, proceeding to cleanup"
            strict_enforce=2 # First location of flagging --strict violation
        else
            d_echo $msg_norm "Unable to set $net_device down with code $exit_code, but will attempt to proceed..."
        fi
    fi

    # From this point on, strict_enforce could potentially be set to 2, and we need to check between each step.

    # Wired or wireless?  If wireless, we need to reference the physical device
    if [ $strict_enforce -ne 2 ]; then
        if [ $virtual_dev -eq 0 ]; then # wired or physical device
            d_echo $msg_debug "...physical device..."
            ip link set dev "$net_device" netns "$netns"
            if [ $? -ne 0 ]; then
                exit_code=$?
                if [ $strict_kill -eq 1 ]; then
                    d_echo $msg_norm "Unable to move physical $net_device into $netns, enforcing --strictkill, exiting $exit_code"
                    exit $exit_code
                fi
                d_echo $msg_norm "Fatal error: unable to move $net_device into $netns, proceeding to cleanup... (try --virtual for wifi interfaces)"
                strict_enforce=2
            fi
        else # wireless or virtual device
            d_echo $msg_debug "...virtual or wifi device..."
            phy_dev="$(basename "$(cd "/sys/class/net/$net_device/phy80211" && pwd -P)")"
            d_echo $msg_debug "...attempted to identify phy_dev = $phy_dev..."
            if [ -z $phy_dev ]; then
                phy_dev=$net_device # try this as a fallback but it may not work
                phy_fallback=1
                d_echo $msg_verbose "Unable to confirm physical device name for wireless interface $net_device"
                d_echo $msg_verbose "Falling back on $phy_dev, may not work. Proceeding..."
            fi
            iw phy "$phy_dev" set netns name "$netns"
            if [ $? -ne 0 ]; then
                exit_code=$?
                if [ $strict_kill -eq 1 ]; then
                    d_echo $msg_norm "Unable to move virtual interface $phy_dev into $netns, enforcing --strictkill, exiting $exit_code"
                    exit $exit_code
                fi
                d_echo $msg_norm "Fatal error: unable to move $net_device into $netns, proceeding to cleanup..."
                strict_enforce=2
                d_echo $msg_verbose "(Try --virtual option to indicate a wifi device without a given ESSID)"
            fi
        fi #endif determine wired/wireless/virtual

    fi # endif enforce --strict before attempting to move net_device into netns

    # From this point forward, failures are not necessarily fatal unless --strict[kill] is enforced
    if [ $strict_enforce -ne 2 ]; then

        if [ $debug_level -eq $msg_debug ]; then
            echo "Checking for success moving device $net_device to netns $netns, running ip link show..."
            ip netns exec $netns ip link show | grep $net_device # WARNING: may yield false positive result for success if net_device is abnormally too simple of a string
        else
            ip netns exec $netns ip link show | grep $net_device > /dev/null # WARNING: may yield false positive result for success if net_device is abnormally too simple of a string
        fi
        
        exit_code=$?
        if [ $exit_code -ne 0 ]; then
            if [ $strict_kill -eq 1 ]; then
                d_echo $msg_norm "Unable to confirm $net_device in $netns, enforcing --strictkill, exiting."
                exit $exit_strict_kill
            fi
            if [ $strict_enforce -eq 1 ]; then
                d_echo $msg_verbose "Unable to confirm $net_device in $netns, enforcing --strict, proceeding to cleanup..."
                strict_enforce=2
            else
                d_echo $msg_verbose "Unable to confirm $net_device in $netns, will attempt to continue..."
            fi
            unconfirmed_move=1
        fi
    fi # endif enforcing --strict before checking for success moving net_device into netns

    # Bring up lo and $net_device
    if [ $strict_enforce -ne 2 ]; then
        d_echo $msg_debug "Bring up lo..."
        ip netns exec "$netns" ip link set dev lo up
        if [ $? -ne 0 ]; then
            if [ $strict_kill -eq 1 ]; then
                d_echo $msg_norm "Could not bring up lo in $netns, enforcing --strictkill, exiting."
                exit $exit_strict_kill
            fi

            if [ $strict_enforce -eq 1 ]; then
                d_echo $msg_norm "Could not bring up lo in $netns, enforcing --strict option and proceeding to cleanup..."
                strict_enforce=2
            else
                d_echo $msg_verbose "Could not bring up lo in $netns, something else may be wrong. Proceeding..."
            fi
        fi
        lo_fail=1
    fi # endif bring up lo

    if [ $strict_enforce -ne 2 ]; then
        d_echo $msg_debug "Bring up $net_device..."
        ip netns exec "$netns" ip link set dev "$net_device" up
        if [ $? -ne 0 ]; then
            if [ $strict_kill -eq 1 ]; then
                d_echo $msg_norm "Could not bring up $net_device in $netns, enforcing --strictkill, exiting."
                exit $exit_strict_kill
            fi        
            if [ $strict_enforce -eq 1 ]; then
                d_echo $msg_norm "Could not bring up $net_device in $netns, enforcing --strict option and proceeding to cleanup..."
                strict_enforce=2
            else
                d_echo $msg_verbose "Could not bring up $net_device in $netns, something probably went wrong. Proceeding..."
            fi
        fi
        device_fail=1
    fi #endif bring up net_device

    # Connect to wifi, if required.
    if [ $strict_enforce -ne 2 ]; then
        TEMP_EXIT=0
        # connect to open network with iwconfig, or, with WPA supplicant if password is provided
        if [ $interface_type -eq 1 ]; then
            d_echo $msg_norm "Attempting to connect to open wifi network $ESSID..."
            ip netns exec "$netns" iwconfig "$net_device" essid "$ESSID"
            TEMP_EXIT=$?
        elif [ $interface_type -eq 3 ]; then
            d_echo $msg_norm "Attempting to connect to secure wifi network $ESSID... (may see initialization failures, that's usually OK)"
            wpa_passphrase "$ESSID" "$wifi_password" | ip netns exec "$netns" wpa_supplicant -i "$net_device" -c /dev/stdin -B
            #alternate way in bash, ksh, zsh (but not dash, not POSIX compliant):
            #ip netns exec "$netns" wpa_supplicant -B -i "$net_device" -c <(wpa_passphrase "$ESSID" "$wifi_password")
            TEMP_EXIT=$?
            d_echo $msg_debug "wpa_supplicant exits with code $TEMP_EXIT"
        fi

        # check strict options after attempting to join wifi network
        if [ $TEMP_EXIT -ne 0 ]; then #TODO FIX AND FINE ERROR 
            if [ $strict_kill -eq 1 ]; then
                d_echo $msg_norm "Error $? attempting to join $ESSID, enforcing --strictkill, exiting."
                exit $exit_strict_kill
            fi            
            if [ $strict_enforce -eq 1 ]; then
                d_echo $msg_norm "Error $? attempting to join $ESSID.  Enforcing --strict option, proceeding to cleanup..."
                strict_enforce=2
            else
                d_echo $msg_verbose "Unconfirmed attempt to join $ESSID with error $?. Proceeding..."
            fi
        fi

        if [ $debug_level -ge $msg_debug ]; then
            ### This is can futile if wpa_supplicant needs more time to connect, so delay.
            echo "Displaying output of iwconfig in namespace $netns (slight pause here for device latency):"
            sleep 5
            ip netns exec "$netns" iwconfig
        fi

    fi #endif connect to wifi

    if [ $strict_enforce -ne 2 ]; then
        d_echo $msg_debug "IP configuring step (unless --noconfig)"
        d_echo $msg_norm ""

        # start dhclient, or, assign given static_ip and gateway, or, do nothing
        if [ $manual_ip_config -eq 0 ]; then
            # dhclient can take a long time to try to connect, depending on your timeout setting in /etc/dhcp/dhclient.conf
            d_echo $msg_norm "Starting dhclient..."
            ip netns exec "$netns" dhclient "$net_device" # if you are impatient and expect this to fail, you could add a &
            d_echo $msg_debug "dhclient returns status $?..." # Note, dhclient abnormality is not subject to --strict enforcement
        elif [ $manual_ip_config -eq 1 ]; then
            d_echo $msg_norm "Attempting to manually configure static_ip and gateway..."
            ip netns exec "$netns" ip addr add "$static_ip" brd + dev "$net_device"
            exit_code=$?
            d_echo $msg_debug "ip addr add: returns $exit_code..."
            if [ $exit_code -ne 0 ]; then
                if [ $strict_kill -eq 1 ]; then
                    d_echo $msg_norm "Could not add static IP and netmask, enforcing --strictkill, exiting."
                    exit $exit_strict_kill
                fi        
                if [ $strict_enforce -eq 1 ]; then
                    d_echo $msg_norm "Could not add static IP and netmask, enforcing --strict option and proceeding to cleanup..."
                    strict_enforce=2
                else
                    d_echo $msg_verbose "...Could not add static IP and netmask..."
                fi
            fi # reminder: don't close the if statement checking "$strict_enforce -ne 2" yet, bc the next if statement is dependent on a nested if test

            ip netns exec "$netns" ip route add default via "$gateway"
            exit_code=$?            
            d_echo $msg_debug "ip route add: returns $exit_code..."
            if [ $exit_code -ne 0 ]; then
                if [ $strict_kill -eq 1 ]; then
                    d_echo $msg_norm "Could not add default gateway, enforcing --strictkill, exiting."
                    exit $exit_strict_kill
                fi        
                if [ $strict_enforce -eq 1 ]; then
                    d_echo $msg_norm "Could not add default gateway, enforcing --strict option and proceeding to cleanup..."
                    strict_enforce=2
                else
                    d_echo $msg_verbose "...Could not add default gateway..."
                fi
            fi
        else
            d_echo $msg_norm "No IP host configuration set up.  Do not expect usual network access until you address this."
        fi #endif configure IP
        # could close the if statement checking the last "$strict_enforce -ne 2", but only one more check remains so its functionally the same to just nest the next one.

        if [ $strict_enforce -ne 2 ]; then # if strict_enforce is enforced, script should cleanup instead of shelling or terminating here
            if [ $spawn_shell -eq 0 ]; then # we are done
                d_echo $msg_verbose "Exiting without shell. $net_device successfully moved to $netns."
                exit $exit_normal
            fi
 
            if [ $exec_flag -eq 1 ]; then # special command intended
                d_echo $msg_verbose "Spawning command"
                d_echo $msg_debug "$exec_cmd"
                ip netns exec "$netns" $exec_cmd
            else # Spawn a shell in the new namespace
                d_echo $msg_norm "Spawning root shell in $netns..."
                d_echo $msg_verbose "... try runuser -u UserName BrowserName &"
                d_echo $msg_verbose "... and exit to kill the shell and netns, when done"
                ip netns exec "$netns" su
            fi
        fi
    fi # endif of namespace setup and shell. Only cleanup remains.

else # --cleanup option enabled.  Still may need to set $phy_dev
    d_echo $msg_verbose "Cleanup only"
    if [ $virtual_dev -eq 1 ]; then
        d_echo $msg_verbose "Detecting physical name of virtual device for cleanup only"
        phy_dev="$(basename "$(cd "/sys/class/net/$net_device/phy80211" && pwd -P)")"
        if [ -z $phy_dev ]; then
            phy_dev=$net_device # try this as a fallback but it may not work
            phy_fallback=1
            d_echo $msg_verbose "Unable to confirm physical device name for wireless interface $net_device"
            d_echo $msg_verbose "Falling back on $phy_dev, may not work. Proceeding..."
        fi
    fi
fi # endif determining cleanup only or not

#
### Cleanup phase ###
#

d_echo $msg_verbose "Killing all remaining processes in $netns..."

if [ $debug_level -gt $msg_norm ]; then
    ip netns pids "$netns" | xargs kill
else
    ip netns pids "$netns" | xargs kill 2> /dev/null
fi

# Move the device back into the default namespace
d_echo $msg_verbose "Moving $net_device out of netns $netns..."
if [ $virtual_dev -eq 0 ]; then
    d_echo $msg_verbose "Moving device $net_device out of netns $netns..."
    ip netns exec "$netns" ip link set dev "$net_device" netns 1
    d_echo $msg_norm "Closing wired interface status $?.  If this fails, try again with --virtual"
else
    d_echo $msg_verbose "Moving device $phy_dev (wireless/virtual) out of netns $netns..."
    ip netns exec "$netns" iw phy "$phy_dev" set netns 1
    TEMP_EXIT=$?
    d_echo $msg_norm "Closing wireless/virtual interface status $TEMP_EXIT"
    if [ $TEMP_EXIT -ne 0 ]; then
        d_echo $msg_verbose "(Try using --virtual and providing physical device name next time)"
    fi
fi

# Remove the namespace
d_echo $msg_verbose "Deleting $netns..."
ip netns del "$netns"
d_echo $msg_verbose ""
d_echo $msg_verbose "exiting, status $?"

# RESCUE:
# if script fails and deletes the namespace without first removing the interface from the netns, try:
# $ sudo find /proc/ -name wlp7s0 # or interface name as appropriate, locate the process_id
# $ sudo kill [process_id]
#
# (and if all else fails, try restarting your system)
#
#
# LICENSE
# Copyright 2021,2022 by Malcolm Schongalla
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
