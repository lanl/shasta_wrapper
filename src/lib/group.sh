## group library
# Contains all commands for `shasta group`
# largely commands for getting information and performing actions against the ansible groups

# © 2023. Triad National Security, LLC. All rights reserved.
# This program was produced under U.S. Government contract 89233218CNA000001 for Los Alamos
# National Laboratory (LANL), which is operated by Triad National Security, LLC for the U.S.
# Department of Energy/National Nuclear Security Administration. All rights in the program are
# reserved by Triad National Security, LLC, and the U.S. Department of Energy/National Nuclear
# Security Administration. The Government is granted for itself and others acting on its behalf a
# nonexclusive, paid-up, irrevocable worldwide license in this material to reproduce, prepare
# derivative works, distribute copies to the public, perform publicly and display publicly, and to permit
# others to do so.

declare -A NODE2GROUP GROUP2NODES BUILD_GROUPS

function group {
    case "$1" in
        build_images)
            shift
            group_build_images "$@"
            ;;
        boot)
            shift
            group_action boot "$@"
            ;;
        conf*)
            shift
            group_action configure "$@"
            ;;
        clear_errors)
            shift
            group_action clear_errors "$@"
            ;;
        li*)
            shift
            group_list "$@"
            ;;
        des*)
            shift
            group_describe "$@"
            ;;
        power_on)
            shift
            group_action power_on "$@"
            ;;
        poweron)
            shift
            group_action power_on "$@"
            ;;
        power_off)
            shift
            group_action power_off "$@"
            ;;
        poweroff)
            shift
            group_action power_off "$@"
            ;;
        power_reset)
            shift
            group_action power_reset "$@"
            ;;
        power_status)
            shift
            group_action power_status "$@"
            ;;
        reboot)
            shift
            group_action reboot "$@"
            ;;
        sho*)
            shift
            group_describe "$@"
            ;;
        sum*)
            shift
            group_summary "$@"
            ;;
        shutdown)
            shift
            group_action shutdown "$@"
            ;;
        *)
            group_help
            ;;
    esac
}

function group_help {
    echo    "USAGE: $0 group [action]"
    echo    "DESC: shows the node groups information and what configurations, bos sessiontemplates, and images are used for each(details)"
    echo    "ACTIONS:"
    echo -e "\tboot [group list] : Boots the nodes in the given group with the group's default bos template."
    echo -e "\tconfig [group list] : Configures the nodes in the given group with the group's default cfs config."
    echo -e "\tclear_errors [group list] : Resets the node error counters to 0."
    echo -e "\tbuild_images <--map> <group>: cluster node group information"
    echo -e "\tdescribe : (same as show)"
    echo -e "\tlist : list all available node groups"
    echo -e "\tpower_off <options> [group]: Powers the given nodes off"
    echo -e "\tpower_on <options> [group]: Powers the given nodes on"
    echo -e "\tpower_reset [group]: Powers the given nodes off then on again"
    echo -e "\tpower_status <options> [group]: Provides the power state of the given group of nodes"
    echo -e "\treboot [group list] : Reboots the given group into it's default bos template."
    echo -e "\tshow : show details on a specific node group"
    echo -e "\tsummary <-v> : show all groups and their general configs"
    echo -e "\tshutdown [group list] : shutdown all nodes in the group"

    exit 1
}

## group_list
# List out the ansible groups that have defaults set
function group_list {
    local group
    cluster_defaults_config
    for group in "${!CONFIG_DEFAULT[@]}"; do
        echo $group
    done | sort
    for group in "${!BOS_DEFAULT[@]}"; do
        echo $group
    done | sort
}

## group_action
# Perform an action against all nodes in a given group (ie reboot them)
function group_action {
    local ACTION="$1"
    shift
    local ARGS HELP
    ARGS=""
    OPTIND=1
    while getopts "yfr" OPTION ; do
        case "$OPTION" in
            y) ARGS+=" -y" ;;
            f) [[ "$ACTION" == "power_off" ]] && ARGS+=" -f" ;;
            :) echo "-$OPTARG must have an arument"; exit 1 ;;
            \?) HELP=1
                return 1
            ;;
        esac
    done
    shift $((OPTIND-1))
    local GROUP_LIST=( "$@" )
    local NODES GROUP
    if [[ -z "${GROUP_LIST[@]}" || -n "$HELP" ]]; then
        echo "USAGE: $0 group $ACTION <options> [group]" 1>&2
        exit 1
    fi
    refresh_ansible_groups
    NODES_CONVERTED=1
    for GROUP in "${GROUP_LIST[@]}"; do
        if [[ -z "${GROUP2NODES[$GROUP]}" ]]; then
            die "Group '$GROUP' is not a valid group" 1>&2
        fi
    done
    for GROUP in "${GROUP_LIST[@]}"; do
        NODES="${GROUP2NODES[$GROUP]}"
        if [[ "$ACTION" == "configure" ]]; then
            node_config $NODES
        elif [[ "$ACTION" == "clear_errors" ]]; then
            node_clear_errors $NODES
        elif [[ "$ACTION" == "power_on" ]]; then
            power_action on $ARGS $NODES
        elif [[ "$ACTION" == "power_off" ]]; then
            power_action off $ARGS $NODES
        elif [[ "$ACTION" == "power_reset" ]]; then
            power_reset $ARGS $NODES
        elif [[ "$ACTION" == "power_status" ]]; then
            power_status $NODES
        else
            node_action $ARGS "$ACTION" $NODES
        fi
    done
}

## refresh_ansible_groups
# Get the ansible groups from /etc/ansible/hosts
function refresh_ansible_groups {
    local ANSIBLE_LINES LINE SPLIT GROUP NODE_GROUPS
    cluster_defaults_config
    hsm_get_node_state

    if [[ -n "${!GROUP2NODES[@]}" ]]; then
        return
    fi

    #IFS=$'\n'
    #ANSIBLE_LINES=( $(cat /etc/ansible/hosts | grep -v 'hosts:$' | grep -v 'children:$' | grep -v 'all:$' | sed 's/: {}//g' | sed 's/ //g') )
    #IFS=$' \t\n'


    GROUP=""
    for XNAME in "${!HSM_NODE_GROUP[@]}"; do
	NODE_GROUPS=( $(echo "${HSM_NODE_GROUP[$XNAME]}" ) )

	for GROUP in "${NODE_GROUPS[@]}"; do
            GROUP2NODES[$GROUP]+="$XNAME "
	done
    done
}

## group_describe
# Show the group information
function group_describe {
    local NO_NODES=0
    if [[ "$1" == "-q" ]]; then
        NO_NODES=1
        shift
    fi
    local GROUP="$1"
    local CONFIG IMAGE_ETAG IMAGE_NAME IMAGE_ID

    if [[ -z "$GROUP" ]]; then
        echo "USAGE: $0 group show [group]"
        exit 1
    fi

    cluster_defaults_config
    image_defaults
    refresh_ansible_groups

    local CONFIG IMAGE_ETAG BOS_RAW IMAGE
    if [[ -n "${BOS_DEFAULT[$GROUP]}" ]]; then


        CONFIG="${CONFIG_DEFAULT[$GROUP]}"
        IMG_CONFIG="${CONFIG_IMAGE_DEFAULT[$GROUP]}"
        IMAGE_ETAG="${CUR_IMAGE_ETAG[$GROUP]}"

        IMAGE_NAME="${CUR_IMAGE_NAME[$GROUP]}"
        IMAGE_ID="${CUR_IMAGE_ID[$GROUP]}"

         echo "[$GROUP]"
         echo "bos_sessiontemplate: ${BOS_DEFAULT[$GROUP]}"
         echo "recipe_id:           ${RECIPE_DEFAULT[$GROUP]}"
         echo "image_name:          $IMAGE_NAME"
         echo "image_id:            $IMAGE_ID"
         echo "config:              $CONFIG"
         echo "config img:          $CONFIG_IMG"
         if [[ "$NO_NODES" -eq "0" ]]; then
             echo "nodes:               ${GROUP2NODES[$GROUP]}"
         fi
    elif [[ -n "${CONFIG_DEFAULT[$GROUP]}" ]]; then
         echo "[$GROUP]"
         echo "config:              ${CONFIG_DEFAULT[$GROUP]}"
         if [[ "$NO_NODES" -eq "0" ]]; then
             echo "nodes:               ${GROUP2NODES[$GROUP]}"
         fi
    else
        die "'$GROUP' is not a valid group."
    fi
}

## group_build_images
# build images for a given group or all the ones with defaults defined
function group_build_images {
    local MAP="1" ARG BUILD_GROUP="Default"
    for ARG in "$@"; do
        if [[ "$1" == "--map" ]]; then
            MAP="0"
            shift
	elif [[ "$1" == "--cache" ]]; then
            CONFIG_ENABLE_IMAGE_CACHE="1"
            shift
	elif [[ "$1" == "--build_group" ]]; then
            if [[ -z "$2" ]]; then
	        echo "Option --build_group requires an argument"
		exit 1
	    fi
            BUILD_GROUP="$2"
            shift
            shift
	elif [[ "$1" = -* ]]; then
	    echo "$0 group build_images <OPTIONS> <group list>"
	    echo "OPTIONS:"
	    echo "\t--map : update the bos templates with the new image(s) that are built"
	    echo "\t--cache : Grab bare images from the cache(WARNING: Cache info is stored locally only)"
	    return 1
	fi
    done

    local GROUP_LIST=( "$@" )
    local MAP_TARGET IMAGE_GROUP
    cluster_defaults_config

    if [[ -n "$BUILD_GROUP" && "$BUILD_GROUP" != "Default" ]]; then
        if [[ -z "${BUILD_GROUPS[$BUILD_GROUP]}" ]]; then
	    echo "BUILD_GROUPS[$BUILD_GROUP] is not defined in /etc/shasta_wrapper/cluster_defaults.conf"
	    exit 1
	fi
    fi
    
    if [[ -z "${GROUP_LIST[@]}" ]]; then
        if [[ -n "${BUILD_GROUPS[$BUILD_GROUP]}" ]]; then
		GROUP_LIST=( ${BUILD_GROUPS[$BUILD_GROUP]} )
	else
            GROUP_LIST=( $(echo "${!BOS_DEFAULT[@]}" "${!IMAGE_DEFAULT[@]}" | sort -u ) )
	fi
    fi

    echo "## Validating current setup before trying to build anything... (Should take a few seconds)"
    cluster_validate
    echo "Done"
    echo

    for GROUP in "${GROUP_LIST[@]}"; do
        echo "$GROUP: ${IMAGE_GROUPS[$GROUP]}"
        if [[ -n "${IMAGE_GROUPS[$GROUP]}" ]]; then
            IMAGE_GROUP="${IMAGE_GROUPS[$GROUP]}"
        else
            IMAGE_GROUP="$GROUP"
        fi
        if [[ "$MAP" -eq "0" ]]; then
            MAP_TARGET="${BOS_DEFAULT[$GROUP]}"
        fi
	local TAG="$GROUP"
        if [[ -n "${IMAGE_DEFAULT[$GROUP]}" ]]; then
            image_build \
              -I "${IMAGE_DEFAULT[$GROUP]}" \
              -g "$GROUP" \
              -G "$IMAGE_GROUP" \
              -c "${CONFIG_IMAGE_DEFAULT[$GROUP]}" \
              -m "$MAP_TARGET" \
	      -t "$TAG_SANITIZED" &
        else
            image_build \
              -r "${RECIPE_DEFAULT[$GROUP]}" \
              -g "$GROUP" \
              -G "$IMAGE_GROUP" \
              -c "${CONFIG_IMAGE_DEFAULT[$GROUP]}" \
              -i "${IMAGE_DEFAULT_NAME[$GROUP]}" \
              -m "$MAP_TARGET" \
	      -t "$TAG" &
        fi
    done
    echo "See detailed logs in: $IMAGE_LOGDIR/"
    echo -n "Images started building at: "
    date

    wait $(jobs -p)
    echo -n "Images stopped building at: "
    date
}

## group_summary
# Show all of the groups and the nodes assigned to them. Optionally map them to their default bos config.
function group_summary {
    local ARGS='-q'
    if [[ "$1" == "-v" ]]; then
        ARGS=''
    fi
    local group
    cluster_defaults_config

    for group in "${!CONFIG_DEFAULT[@]}"; do
        group_describe $ARGS "$group"
        echo ""
    done
    for group in "${!BOS_DEFAULT[@]}"; do
        group_describe $ARGS "$group"
        echo ""
    done
}

