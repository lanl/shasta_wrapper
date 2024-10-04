## cfs library
# Contains all commands for `shasta cfs`
# Used for managing what configurations to apply to images/nodes.

# © 2023. Triad National Security, LLC. All rights reserved.
# This program was produced under U.S. Government contract 89233218CNA000001 for Los Alamos
# National Laboratory (LANL), which is operated by Triad National Security, LLC for the U.S.
# Department of Energy/National Nuclear Security Administration. All rights in the program are
# reserved by Triad National Security, LLC, and the U.S. Department of Energy/National Nuclear
# Security Administration. The Government is granted for itself and others acting on its behalf a
# nonexclusive, paid-up, irrevocable worldwide license in this material to reproduce, prepare
# derivative works, distribute copies to the public, perform publicly and display publicly, and to permit
# others to do so.

declare -A CFS_BRANCH CFS_URL CFS_BRANCH_DEFAULT
CONFIG_DIR="/root/templates/cfs_configurations/"
GIT_USER=""
GIT_PASSWD=""
mkdir -p $CONFIG_DIR

function cfs {
    case "$1" in
        ap*)
            shift
            cfs_apply "$@"
            ;;
        cl*)
            shift
            cfs_clone "$@"
            ;;
        des*)
            shift
            cfs_describe "$@"
            ;;
        ed*)
            shift
            cfs_edit "$@"
            ;;
        delete)
            shift
            cfs_delete "$@"
            ;;
        job*)
            shift
            cfs_job "$@"
            ;;
        li*)
            shift
            cfs_list "$@"
            ;;
        sh*)
            shift
            cfs_describe "$@"
            ;;
        unconf*)
            shift
            cfs_unconfigured "$@"
            ;;
        update*)
            shift
            cfs_update "$@"
            ;;
        *)
            cfs_help
            ;;
    esac
}

function cfs_help {
    echo    "USAGE: $0 cfs [action]"
    echo    "DESC: Each cfs config is a declaration of the git ansible repos to checkout and run against each image groups defined in the bos templates. A cfs is defined in a bos sessiontemplate to be used to configure a node group at boot or an image after creation. Direct access via cray commands can be done via 'cray cfs configurations'"
    echo    "ACTIONS:"
    echo -e "\tapply <options> [cfs] [node] : Runs the given cfs against it's confgured nodes"
    echo -e "\tclone [src] [dest] : Clone an existing cfs"
    echo -e "\tedit [cfs config] : Edit a given cfs."
    echo -e "\tdelete [cfs config] : delete the cfs"
    echo -e "\tdescribe [cfs config] : (same as show)"
    echo -e "\tjob [action]: Manage cfs jobs"
    echo -e "\tlist : list all ansible configurations"
    echo -e "\tshow [cfs config] : shows all info on a given cfs"
    echo -e "\tupdate <options> [cfs configs] : update the git repos for the given cfs configuration with the latest based on the branches defined in /etc/shasta_wrapper/cfs_defaults.conf"

    exit 1
}

## cfs_list
# List out the given cfs job configurations
function cfs_list {
    local CONFIG CONFIGS RAW_CONFIGS group
    cluster_defaults_config

    # Get all config data
    RAW_CONFIGS=$(rest_api_query "cfs/v2/configurations")
    if [[ -z "$RAW_CONFIGS" || "$?" -ne 0 ]]; then
        error "Failed to get cfs information: $RAW_CONFIGS"
	return 1
    fi
    CONFIGS=( $(echo "$RAW_CONFIGS" | jq -r '.[].name') )
    echo "${COLOR_BOLD}NAME(default cfs for)${COLOR_RESET}"

    # Any cfs configs that are set as a default for an ansible group should
    # have the ansible group name in paretheses and bolded.
    for CONFIG in "${CONFIGS[@]}"; do
        echo -n "$CONFIG"
        for group in "${!CONFIG_IMAGE_DEFAULT[@]}"; do
            if [[ "${CONFIG_IMAGE_DEFAULT[$group]}" == "$CONFIG" ]]; then
                echo -n "$COLOR_BOLD(img:$group)$COLOR_RESET"
            fi
        done
        for group in "${!CONFIG_DEFAULT[@]}"; do
            if [[ "${CONFIG_DEFAULT[$group]}" == "$CONFIG" ]]; then
                echo -n "$COLOR_BOLD($group)$COLOR_RESET"
            fi
        done
        echo
    done | sort
}

## cfs_describe
# Show the given cfs configuration
function cfs_describe {
    if [[ -z "$1" ]]; then
        echo "USAGE: $0 cfs describe [cfs config]"
	return 1
    fi
    rest_api_query "cfs/v2/configurations/$1"
    return $?
}

## cfs_delete
# Delete the given cfs configuration
function cfs_delete {
    if [[ -z "$1" ]]; then
        echo "USAGE: $0 cfs delete [cfs config]"
	return 1
    fi
    echo cray cfs configurations delete --format json "$1"
    rest_api_delete "cfs/v2/configurations/$1"
    return $?
}

## cfs_exit_if_not_valid
# exit if the given cfs config is not valid (doesn't exist)
function cfs_exit_if_not_valid {
    cfs_describe "$1" > /dev/null 2> /dev/null
    if [[ $? -ne 0 ]]; then
        die "Error! $SRC is not a valid configuration."
    fi
}

## cfs_exit_if_exists
# exit if the given cfs config exists
function cfs_exit_if_exists {
    cfs_describe "$1" > /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo "'$1' already exists. If you really want to overwrite it, you need to delete it first"
        exit 1
    fi
}

## cfs_clone
# Clones the given ffs config to the new name. Doesn't replace any existing config
function cfs_clone {
    local SRC="$1"
    local DEST="$2"
    local TEMPFILE
    setup_craycli

    if [[ -z "$SRC" || -z "$DEST" ]]; then
        echo "USAGE: $0 cfs clone [src cfs] [dest cfs]" 1>&2
        exit 1
    fi
    cfs_exit_if_not_valid "$SRC"
    cfs_exit_if_exists "$DEST"

    set -e
    tmpdir
    TMPFILE="$TMPDIR/cfs_config.json"

    cfs_describe $SRC | jq 'del(.name)' | jq 'del(.lastUpdated)' > "$TMPFILE"

    cray cfs configurations update $DEST --file "$TMPFILE" --format json > /dev/null 2>&1
    set +e
}

## cfs_edit
# Edit the given cfs config with an editor
function cfs_edit {
    local CONFIG="$1"
    if [[ -z "$CONFIG" ]]; then
        echo "USAGE: $0 cfs edit [cfs]" 1>&2
        exit 1
    fi

    cfs_exit_if_not_valid "$CONFIG"
    setup_craycli

    (
        set -e
        flock -x 42
        cfs_describe $CONFIG | jq 'del(.name)' | jq 'del(.lastUpdated)' > "$CONFIG_DIR/$CONFIG.json" 2> /dev/null

        if [[ ! -s "$CONFIG_DIR/$CONFIG.json" ]]; then
            rm -f "$CONFIG_DIR/$CONFIG.json"
            die "Error! Config '$CONFIG' does not exist!"
        fi



        set +e
        edit_file "$CONFIG_DIR/$CONFIG.json" 'json'
        if [[ "$?" == 0 ]]; then
            echo -n "Updating '$CONFIG' with new data..."
            verbose_cmd cray cfs configurations update $CONFIG --file ""$CONFIG_DIR/$CONFIG.json"" --format json > /dev/null 2>&1
            echo 'done'
        else
            echo "No modifications made. Not pushing changes up"
        fi
    ) 42>/tmp/lock
}

## cfs_apply
# Run the given cfs config against the given host
function cfs_apply {
    local NAME JOB POD TRIED MAX_TRIES RET NODE_STRING ARGS OPTIND
    OPTIND=1
    while getopts "n:" OPTION ; do
        case "$OPTION" in
            n) NAME="$OPTARG"
            ;;
            \?) echo "USAGE: $0 cfs apply <options> [configuration name] [nodes|groups]"
                echo "OPTIONS: "
                echo -e "\t-n [name] - specify a name to give the cfs job"
                return 1
            ;;
        esac
    done
    setup_craycli

    shift $((OPTIND-1))
    echo "$@"
    local CONFIG=$1
    shift

    convert2xname "$@"
    local NODES=( $RETURN )

    if [[ -z "$CONFIG" ]]; then
        echo "USAGE: $0 cfs apply <options> [configuration name] [nodes|groups]"
        echo "OPTIONS:"
        echo -e "\t-n - specify a name to give the cfs job"
        exit 1
    fi

    if [[ -z "$NAME" ]]; then
        NAME=cfs`date +%s`
    fi
    cfs_exit_if_not_valid "$CONFIG"

    NODE_STRING=$(echo "${NODES[@]}" | sed 's/ /,/g')
    refresh_ansible_groups

    cfs_clear_node_counters "${NODES[@]}"

    if [[ -n "${NODES[*]}" ]]; then
        cray cfs sessions create --name "$NAME" --configuration-name $CONFIG --ansible-limit "$NODE_STRING" --format json
    else
        cray cfs sessions create --name "$NAME" --configuration-name $CONFIG --format json
    fi
    sleep 1
    cfs_job_log "$NAME"


    cfs_job_delete "$NAME"
}

## cfs_clear_node_counters
# Clear the error counters on the given node and ensure it's enabled
function cfs_clear_node_counters {
    local NODES=( "$@" )
    local NODE i COUNT JOBS

    disown -a
    for NODE in "${NODES[@]}"; do
        rest_api_patch "cfs/v2/components/$NODE" '{ "errorCount": 0, "enabled": true }' > /dev/null 2>&1 &
    done

    wait_for_background_tasks "Updating node CFS state" "${#NODES[@]}"
}

## cfs_disable_nodes
# Clear the error counters on the given node and ensure it's enabled
function cfs_enable_nodes {
    local STATE="$1"
    shift
    local NODES=( "$@" )
    local NODE i COUNT JOBS

    disown -a
    for NODE in "${NODES[@]}"; do
        rest_api_patch "cfs/v2/components/$NODE" "{ \"enabled\": $STATE }" > /dev/null 2>&1 &
    done

    wait_for_background_tasks "Updating node CFS state" "${#NODES[@]}"
}

## cfs_clear_node_state
# Clear the node state forcing it to rerun cfs
function cfs_clear_node_state {
    local NODES=( "$@" )
    local NODE i COUNT JOBS

    disown -a
    for NODE in "${NODES[@]}"; do
        rest_api_patch "cfs/v2/components/$NODE" '{ "state": [], "errorCount": 0 }' > /dev/null 2>&1 &
    done

    wait_for_background_tasks "Resetting node CFS state" "${#NODES[@]}"
    echo
    echo "All nodes have had their cfs state reset. This should cause new cfs jobs to spawn shortly."
    echo "If you have had a lot of failed cfs runs you may need to restart the cfs batcher, as it backs off of launching when a lot have failed"
    echo
}

## cfs_unconfigured
# Get a list of the nodes that cfs has not configured, and the group that node is a member of
function cfs_unconfigured {
    refresh_ansible_groups
    #local NODES
    NODES=( $(rest_api_query "cfs/v2/components" | jq '.[] | select(.configurationStatus != "configured")' | jq '. | select(.enabled == true)'  | jq '.id' | sed 's/"//g') )

    echo -e "${COLOR_BOLD}XNAME\t\tGROUP$COLOR_RESET"
    for node in "${NODES[@]}"; do
        echo -e "$node\t${NODE2GROUP[$node]}"
    done
}

# Reads /etc/shasta_wrapper/cfs_defaults.conf to get what git repos we can update with new conig ids
function read_git_config {
    local REPO

    source /etc/shasta_wrapper/cfs_defaults.conf

    for REPO in "${!CFS_URL[@]}"; do
        if [[ -z "${CFS_BRANCH[$REPO]}" ]]; then
            die "$REPO is not defined for 'CFS_BRANCH'"
        fi
        CFS_BRANCH_DEFAULT["${CFS_URL[$REPO]}"]="${CFS_BRANCH[$REPO]}"
    done
    for REPO in "${!CFS_BRANCH[@]}"; do
        if [[ -z "${CFS_URL[$REPO]}" ]]; then
            die "$REPO is not defined for 'CFS_URL'"
        fi
    done
}

## cfs_update
# Update the commit ids for the given cfs configurations based on what urls and branches are defined in /etc/shasta_wrapper/cfs_defaults.conf. Asks user before making any changes.
function cfs_update {
    local LAYER LAYER_URL FLOCK CONFIG GIT_TARGET=''

    OPTIND=1
    while getopts "t:" OPTION ; do
        case "$OPTION" in
            t) GIT_TARGET="$OPTARG"
            ;;
            \?) echo "USAGE: $0 cfs update <OPTIONS> [config list]"
                echo "OPTIONS: "
                echo -e "\t-t [target] specify an alternate git tag/branch to point update to"
                return 1
            ;;
        esac
    done
    shift $((OPTIND-1))
    local CONFIGS=( "$@" )

    if [[ -z "${CONFIGS[@]}" ]]; then
        prompt_yn "No arguments given, update all default cfs configs?" || exit 0
        cluster_defaults_config
        CONFIGS=( )
        for group in "${!CONFIG_IMAGE_DEFAULT[@]}" "${!CONFIG_DEFAULT[@]}"; do
             CONFIGS+=( "${CONFIG_IMAGE_DEFAULT[$group]}" )
             CONFIGS+=( "${CONFIG_DEFAULT[$group]}" )
        done
        # dedup
        CONFIGS=( $(echo "${CONFIGS[@]}" | sed 's/ /\n/g' | sort -u) )
    fi

    for CONFIG in "${CONFIGS[@]}"; do
        local FILE="$CONFIG_DIR/$CONFIG.json"
        if [[ -z "$CONFIG" ]]; then
            echo "USAGE: $0 cfs update [cfs]" 1>&2
            exit 1
        fi
	echo "#### $CONFIG"

        cfs_exit_if_not_valid "$CONFIG"

        read_git_config
        (
            flock -x 42

            cfs_describe $CONFIG | jq 'del(.name)' | jq 'del(.lastUpdated)' > "$FILE" 2> /dev/null

            if [[ ! -s "$FILE" ]]; then
                rm -f "$FILE"
                die "Error! Config '$CONFIG' does not exist!"
            fi
            tmpdir

            GIT_REPO_COUNT=$(cat "$FILE" | jq '.layers[].commit' | wc -l)
            GIT_REPO_COUNT=$(($GIT_REPO_COUNT - 1))
            for LAYER in $(seq 0 $GIT_REPO_COUNT); do
                cfs_update_git "$FILE" "$LAYER" "$CONFIG" "$GIT_TARGET" || error "Failed to check repo for updates...\n"
            done
            HAS_ADDITIONAL_INVENTORY=$(cat "$FILE" | jq '.additional_inventory')
            if [[ "$HAS_ADDITIONAL_INVENTORY" != "null" ]]; then
                cfs_update_git "$FILE" "i" "$CONFIG" "$GIT_TARGET" || error "Failed to check repo for updates...\n"
            fi
            rmdir "$TMPDIR" > /dev/null 2>&1
        ) 42>/tmp/lock

	echo
	echo
    done
}

## get_git_password
# Pull the git password out of kubernetes
function get_git_password {
    if [[ -n "$GIT_PASSWD" ]]; then
        return
    fi
    GIT_USER=crayvcs
    GIT_PASSWD=$(kubectl get secret -n services vcs-user-credentials --template={{.data.vcs_password}} | base64 --decode)
    if [[ -z "$GIT_PASSWD" ]]; then
        die "Failed to get git password"
    fi
}

## cfs_update_git
# Given the cfs configuration, update it's commit ids with the commit ids of the beanch specified in /etc/shasta_wrapper/cfs_defaults.conf.
function cfs_update_git {
    local FILE="$1"
    local LAYER="$2"
    local CONFIG="$3"
    local GIT_TARGET="$4"
    setup_craycli

    local JQ_BASE_QUERY=""
    if [[ "$LAYER" == 'i' ]]; then
        JQ_BASE_QUERY=".additional_inventory"
    else
        JQ_BASE_QUERY=".layers[$LAYER]"
    fi

    get_git_password

    LAYER_URL=$(cat "$FILE" | jq "${JQ_BASE_QUERY}.cloneUrl" | sed 's/"//g')
    LAYER_CUR_COMMIT=$(cat "$FILE" | jq "${JQ_BASE_QUERY}.commit" | sed 's/"//g')
    URL=$(echo "$LAYER_URL" | sed "s|https://|https://$GIT_USER:$GIT_PASSWD@|g"| sed "s|http://|http://$GIT_USER:$GIT_PASSWD@|g")
    if [[ -z "$GIT_TARGET" ]]; then
        if [[ -n "${CFS_BRANCH_DEFAULT[$LAYER_URL]}" ]]; then
            GIT_TARGET="${CFS_BRANCH_DEFAULT[$LAYER_URL]}"
        else
            echo "$LAYER_URL is not defined in /etc/shasta_wrapper/cfs_defaults.conf... skipping"
            return 1
        fi
    fi

    echo "cloning $LAYER_URL"
    cd "$TMPDIR"
    git clone --quiet "$URL" "$TMPDIR/$LAYER" || return 1
    cd "$TMPDIR/$LAYER"
    git -c advice.detachedHead=false checkout "$GIT_TARGET" || return 1

    NEW_COMMIT=$(git rev-parse HEAD)
    if [[ "$LAYER_CUR_COMMIT" != "$NEW_COMMIT" ]]; then
        echo "old commit: $LAYER_CUR_COMMIT"
        echo "new commit: $NEW_COMMIT"
        prompt_yn "Would you like to apply the new commit '$NEW_COMMIT' for '$LAYER_URL'?" || return 0
        json_set_field "$FILE" "${JQ_BASE_QUERY}.commit" "$NEW_COMMIT"
        verbose_cmd cray cfs configurations update $CONFIG --file "$CONFIG_DIR/$CONFIG.json" --format json > /dev/null 2>&1
    else
        echo "No updates. commit: '$NEW_COMMIT', old commit: '$LAYER_CUR_COMMIT'"
    fi
    rm -rf "$TMPDIR/$LAYER"
}
