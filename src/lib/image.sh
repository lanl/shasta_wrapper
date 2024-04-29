## image library
# Contains all commands for `shasta image`
# Commands for listing and building images

# © 2023. Triad National Security, LLC. All rights reserved.
# This program was produced under U.S. Government contract 89233218CNA000001 for Los Alamos
# National Laboratory (LANL), which is operated by Triad National Security, LLC for the U.S.
# Department of Energy/National Nuclear Security Administration. All rights in the program are
# reserved by Triad National Security, LLC, and the U.S. Department of Energy/National Nuclear
# Security Administration. The Government is granted for itself and others acting on its behalf a
# nonexclusive, paid-up, irrevocable worldwide license in this material to reproduce, prepare
# derivative works, distribute copies to the public, perform publicly and display publicly, and to permit
# others to do so.

declare -A IMAGE_ID2NAME
declare -A IMAGE_ID2CREATED

IMAGE_LOGDIR="/var/log/image/"`date '+%Y%m%d-%H%M%S'`

function image {
    case "$1" in
        build)
            shift
            image_build "$@"
            ;;
        build_bare)
            shift
            image_build_bare "$@"
            ;;
        co*)
            shift
            image_configure "$@"
            ;;
        job*)
            shift
            image_job "$@"
            ;;
        li*)
            shift
            image_list "$@"
            ;;
        des*)
            shift
            image_describe "$@"
            ;;
        delete)
            shift
            image_delete "$@"
            ;;
        map)
            shift
            image_map "$@"
            ;;
        sh*)
            shift
            image_describe "$@"
            ;;
        *)
            image_help
            ;;
    esac
}

function image_help {
    echo    "USAGE: $0 image [action]"
    echo    "DESC: The images used by the system to boot nodes. To set an image to be used at boot,  See 'cray cfs configurations' for more detailed options."
    echo    "ACTIONS:"
    echo -e "\tbuild [recipe id] [group] [config] <image name>: build a new bare image from the given recipe"
    echo -e "\tbuild_bare [recipe id] [image name]: build a new bare image from the given recipe"
    echo -e "\tconfigure [image id] [group name] [config name] : build a new image configuring it"
    echo -e "\tdelete [image id] : delete a image"
    echo -e "\tdescribe [image id] : show image information"
    echo -e "\tjob [action]: Manage image jobs"
    echo -e "\tlist : list all images"
    echo -e "\tmap [bos template] [image id] : show image information"

    exit 1
}

## refresh_images
# Get the image data from ims
function refresh_images {
    local RAW LIST image

    RAW=$(rest_api_query "ims/images")
    if [[ $? -ne 0 ]]; then
	 error "Error getting image information: $RAW"
	 return 1
    fi
    IFS=$'\n'
    LIST=( $(echo "$RAW" | jq -r '.[] | "\(.id) \(.created) \(.name)"') )
    IFS=$' \t\n'

    for image in "${LIST[@]}"; do
        SPLIT=( $image )
        id="${SPLIT[0]}"
        created="${SPLIT[1]}"
        name="${SPLIT[*]:2}"
        IMAGE_ID2NAME[$id]=$name
        IMAGE_ID2CREATED[$id]=$created
    done
}

## image_list
# List out the images
function image_list {
    local id name created group
    image_defaults
    refresh_images
    echo "CREATED                            ID                                     NAME(Mapped image for)"
    for id in "${!IMAGE_ID2NAME[@]}"; do
        name="${IMAGE_ID2NAME[$id]}"
        created="${IMAGE_ID2CREATED[$id]}"
        for group in "${!CUR_IMAGE_ID[@]}"; do
            if [[ "${CUR_IMAGE_ID[$group]}" == "$id" ]]; then
                name="$name$COLOR_BOLD($group)$COLOR_RESET"
            fi
        done
        echo "$created   $id   $name"
    done | sort
}

## image_describe
# show inormation on the given image
function image_describe {
    local OUTPUT RET
    OUTPUT=$(rest_api_query "ims/images/$1")
    RET=$?
    echo "$OUTPUT" | jq
    return $RET
}

## image_delete
# delete the given image
function image_delete {
    if [[ -z "$1" ]]; then
        echo "USAGE: $0 image delete [image1] <images...>" 1>&2
        exit 1
    fi
    for image in "$@"; do
        if [[ -z "$image" ]]; then
            continue
        fi
        echo cray ims images delete --format json "$image" | grep -P '\S'
        rest_api_delete "ims/images/$image"
    done
    echo "Cleaning up image artifacts..."
    image_clean_deleted_artifacts
}

## image_build
# Build a bare image from recipe, and configure it via cfs.
function image_build {
    local EX_HOST BARE_IMAGE_ID CONFIG_IMAGE_ID CONFIG_JOB_NAME RECIPE_ID GROUP_NAME CONFIG_NAME NEW_IMAGE_NAME BOS_TEMPLATE FROM_IMAGE BSS_MAP IMAGE_GROUPS
    OPTIND=1
    while getopts "bc:g:G:i:m:r:t:I:" OPTION ; do
        case "$OPTION" in
            b) BSS_MAP=1 ;;
            c) CONFIG_NAME="$OPTARG" ;;
            g) GROUP_NAME="$OPTARG" ;;
            G) IMAGE_GROUPS="$OPTARG" ;;
            i) NEW_IMAGE_NAME="$OPTARG" ;;
            I) FROM_IMAGE="$OPTARG" ;;
            m) BOS_TEMPLATE="$OPTARG" ;;
            r) RECIPE_ID="$OPTARG" ;;
            t) CONFIG_TAG="$OPTARG" ;;
            \?) die 1 "cfs_apply:  Invalid option:  -$OPTARG" ; return 1 ;;
            :) die 1 "option:  -$OPTARG requires an argument" ; return 1 ;;
        esac
    done
    shift $((OPTIND-1))

    if [[ -z "$RECIPE_ID" && -z "$FROM_IMAGE" ]]; then
        RECIPE_ID="$1"
        shift
    fi
    if [[ -z "$GROUP_NAME" ]]; then
        GROUP_NAME="$1"
        shift
    fi
    if [[ -z "$CONFIG_NAME" ]]; then
        CONFIG_NAME="$1"
        shift
    fi
    if [[ -z "$NEW_IMAGE_NAME" && -z "$FROM_IMAGE" ]]; then
        NEW_IMAGE_NAME="$1"
        shift
    fi
    if [[ -z "$BOS_TEMPLATE" ]]; then
        BOS_TEMPLATE="$1"
        shift
    fi
    if [[ -z "$IMAGE_GROUPS" ]]; then
        IMAGE_GROUPS="$GROUP_NAME"
    fi

    if [[ -z "$GROUP_NAME" || -z "$CONFIG_NAME" || -z "$FROM_IMAGE" && -z "$RECIPE_ID" ]]; then
        echo "USAGE: $0 image build <OPTIONS> [recipe id] [group] [config] <image name> <bos template to map to>" 1>&2
        echo "OPTIONS:"
        echo -e "\t -c <cfs config> - Configure the image with this cfs configuration"
        echo -e "\t -i <image name> - Base name to use for the created image"
        echo -e "\t -I <image id> - Image to start with instead of making a new one"
        echo -e "\t -m <bos template> - Map the final built image to this bos template"
        echo -e "\t -r <recipe id> - Recipe id to build the image from"
        echo -e "\t -t <config tag> - name to use for the applied configuration. This will show on the end of the configured image name"
        exit 1
    fi
    cluster_defaults_config

    refresh_ansible_groups
    if [[ -z "${GROUP2NODES[$GROUP_NAME]}" ]]; then
        error "WARNING: '$GROUP_NAME' doesn't appear to be a valid group name."
    fi

    cfs_describe "$CONFIG_NAME" > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        die "'$CONFIG_NAME' is not a valid configuration."
    fi
    if [[ -z "$NEW_IMAGE_NAME" ]]; then
        NEW_IMAGE_NAME="img_$GROUP_NAME"
    fi
    if [[ -n "$BOS_TEMPLATE" ]]; then
        echo "[$GROUP_NAME] Image will be mapped to '$BOS_TEMPLATE' if build/configure succeed."
    fi

   # quick sleep here to help consolidate the map and build messages
   sleep 1


    mkdir -p "$IMAGE_LOGDIR"
    if [[ -z "$FROM_IMAGE" ]]; then
        echo "[$GROUP_NAME] Bare image build started. Full logs at: '$IMAGE_LOGDIR/bare-${NEW_IMAGE_NAME}.log'"
        image_build_bare "$RECIPE_ID" "$NEW_IMAGE_NAME" "$GROUP_NAME" > "$IMAGE_LOGDIR/bare-${NEW_IMAGE_NAME}.log"
        if [[ $? -ne 0 ]]; then
            die "[$GROUP_NAME] bare image build failed... Not continuing"
        fi
        BARE_IMAGE_ID="$RETURN"
    else
        echo "[$GROUP_NAME] Useing prebuilt bare image: $FROM_IMAGE"
        BARE_IMAGE_ID="$FROM_IMAGE"
    fi


    echo "[$GROUP_NAME] Configure image started. Full logs at: '$IMAGE_LOGDIR/config-${NEW_IMAGE_NAME}.log'"
    if [[ -n "$CONFIG_TAG" ]]; then
        image_configure -n "$CONFIG_TAG" "$BARE_IMAGE_ID" "$IMAGE_GROUPS" "$CONFIG_NAME" > "$IMAGE_LOGDIR/config-${NEW_IMAGE_NAME}.log"
    else
        image_configure "$BARE_IMAGE_ID" "$IMAGE_GROUPS" "$CONFIG_NAME" > "$IMAGE_LOGDIR/config-${NEW_IMAGE_NAME}.log"
    fi
    if [[ $? -ne 0 ]]; then
        die "[$GROUP_NAME] configure image failed... Not continuing"
    fi
    CONFIG_IMAGE_ID="$RETURN"

    if [[ -z "$FROM_IMAGE" ]]; then
        echo "[$GROUP_NAME] Deleting bare image, as it's no longer needed."
        image_delete "$BARE_IMAGE_ID" > /dev/null 2>&1
    fi


    if [[ -n "$BOS_TEMPLATE" ]]; then
        image_map "$BOS_TEMPLATE" "$CONFIG_IMAGE_ID" "$GROUP_NAME"
    fi

    if [[ -n "$BSS_MAP" ]]; then
        bss_map "$CONFIG_IMAGE_ID" "${GROUP2NODES[$GROUP]}"
    fi
}

## image_map
# Set the given image to be used in the bos template
function image_map {
    local BOS_TEMPLATE="$1"
    local IMAGE_ID="$2"
    local GROUP="$3"

    if [[ -z "$BOS_TEMPLATE" || -z "$IMAGE_ID" ]]; then
        echo "USAGE: $0 image map [bos template] [image id]" 1>&2
        exit 1
    fi
    IMAGE_RAW=$(rest_api_query "ims/images" | jq ".[] | select(.id == \"$IMAGE_ID\")")

    IMAGE_ETAG=$(echo "$IMAGE_RAW" | jq '.link.etag' | sed 's/"//g')
    IMAGE_PATH=$(echo "$IMAGE_RAW" | jq '.link.path' | sed 's/"//g')
    if [[ -z "$IMAGE_ETAG" ]]; then
        die "etag could not be found for image: '$IMAGE_ID'. Did you provide a valid image id?"
    fi

    bos_update_template "$BOS_TEMPLATE" ".boot_sets[].etag" "$IMAGE_ETAG"
    if [[ $? -ne 0 ]]; then
        die "Failed to map image id '$IMAGE_ID' to bos template '$BOS_TEMPLATE'" 1>&2
    fi
    bos_update_template "$BOS_TEMPLATE" ".boot_sets[].path" "$IMAGE_PATH"
    if [[ $? -ne 0 ]]; then
        die "Failed to map image id '$IMAGE_ID' to bos template '$BOS_TEMPLATE'" 1>&2
    fi
    if [[ -n "$GROUP" ]]; then
        echo "[$GROUP] Successfully mapped '$BOS_TEMPLATE' to '$IMAGE_ID'"
    else
        echo "Successfully mapped '$BOS_TEMPLATE' to '$IMAGE_ID'"
    fi
    return 0
}

## image_build_bare
# build a bare image from a recipe
function image_build_bare {
    local RECIPE_ID=$1
    local NEW_IMAGE_NAME=$2
    local GROUP_NAME=$3
    local JOB_RAW JOB_ID IMS_JOB_ID POD IMAGE_ID

    if [[ -z "$RECIPE_ID" ]]; then
        echo "usage: $0 image build_bare [recipe id] [image name]"
        exit 1
    fi

    if [[ -z "$RECIPE_ID" ]]; then
        echo "[$GROUP_NAME] Error. recipe id must be provided!"
        die "[$GROUP_NAME] Error. recipe id must be provided!"
    fi
    refresh_recipes
    if [[ -n "${RECIPE_ID2NAME[$RECIPE_ID]}" ]]; then
    	local RECIPE_NAME="${RECIPE_ID2NAME[$RECIPE_ID]}"
    else
        echo "[$GROUP_NAME] Error! RECIPE ID '$RECIPE_ID' doesn't exist."
        die "[$GROUP_NAME] Error! RECIPE ID '$RECIPE_ID' doesn't exist."
    fi
    if [[ -z "$NEW_IMAGE_NAME" ]]; then
        NEW_IMAGE_NAME="img_$RECIPE_NAME"
    fi
    setup_craycli

    cluster_defaults_config
    if [[ -z "$IMS_PUBLIC_KEY_ID" ]]; then
	    die "[$GROUP_NAME] Error! IMS_PUBLIC_KEY_ID is not defined in '/etc/shasta_wrapper/cluster_defaults.conf'"
    fi

    set -e
    echo "cray ims jobs create \
      --job-type create \
      --image-root-archive-name $NEW_IMAGE_NAME \
      --artifact-id $RECIPE_ID \
      --public-key-id $IMS_PUBLIC_KEY_ID \
      --enable-debug False \
      --format json"
    JOB_RAW=$(cray ims jobs create \
      --job-type create \
      --image-root-archive-name $NEW_IMAGE_NAME \
      --artifact-id $RECIPE_ID \
      --public-key-id $IMS_PUBLIC_KEY_ID \
      --enable-debug False \
      --format json)

    JOB_ID=$(echo "$JOB_RAW" | jq '.kubernetes_job' | sed 's/"//g')
    echo "  Grabbing kubernetes_job = '$JOB_ID' from output..."
    IMS_JOB_ID=$(echo "$JOB_RAW" | jq '.id' | sed 's/"//g')
    echo "  Grabbing id = '$IMS_JOB_ID' from output..."

    image_logwatch "$JOB_ID"

    cmd_wait_output "success|error" image_job_describe "$IMS_JOB_ID"

    image_job_describe "$IMS_JOB_ID" | grep "status" | grep -q 'success'
    if [[ "$?" -ne 0 ]]; then
        echo "[$GROUP_NAME] Error image build failed! See logs for details"
        die "[$GROUP_NAME] Error image build failed! See logs for details"
    fi

    IMAGE_ID=$(image_job_describe "$IMS_JOB_ID" | jq .resultant_image_id | sed 's/"//g' )
    echo "  Grabbing image_id = '$IMAGE_ID' from output..."

    set +e
    verbose_cmd image_describe "$IMAGE_ID" > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo "[$GROUP_NAME] Error image build failed! See logs for details"
        die "[$GROUP_NAME] Error image build failed! See logs for details"
    fi
    echo "  Ok, image does appear to exist. Cleaning up the job..."

    verbose_cmd image_job_delete $IMS_JOB_ID

    echo "[$GROUP_NAME] Bare image Created: $IMAGE_ID" 1>&2
    echo "[$GROUP_NAME] Bare image Created: $IMAGE_ID"
    RETURN="$IMAGE_ID"
    return 0
}

## image_logwatch
# Watch logs for building image kube job
function image_logwatch {
    KUBE_JOB="$1"

    sleep 3
    cmd_wait_output "READY" kubectl get pods -l job-name=$KUBE_JOB -n ims 2>&1
    POD_ID=$(kubectl get pods -l job-name=$KUBE_JOB -n ims| tail -n 1 | awk '{print $1}')

    verbose_cmd kubectl describe job -n ims $JOB_ID | grep -q 'Pods Statuses:  0 Running / 1 Succeeded'
    RET=$?
    if [[ $RET -eq 0 ]]; then
        echo "[$GROUP_NAME] IMAGE BUILD FAILED: job id '$JOB_ID'"
        die "[$GROUP_NAME] IMAGE BUILD FAILED: job id '$JOB_ID'"
    fi

    echo "################################################"
    echo "#### INFO"
    echo "################################################"
    echo "KUBERNETES JOB: $KUBE_JOB"
    echo "KUBERNETES POD: $POD_ID"
    echo "################################################"
    echo "#### END INFO"
    echo "################################################"

    # Get list of init containers
    INIT_CONTAIN=( $(kubectl get pods "$POD_ID" -n ims -o json |\
        jq -r .spec.initContainers[].name) )

    # Get list of regular containers
    CONTAIN=( $(kubectl get pods $POD_ID -n ims -o json |\
	jq -r .spec.containers[].name) )

    # init container logs
    for cont in fetch-recipe wait-for-repos build-ca-rpm; do
        if [[ "$cont" != "build-image" && "$cont" != 'buildenv-sidecar' ]]; then
            echo
            echo
            echo "#################################################"
            echo "### init container: $cont"
            echo "#################################################"
            cmd_wait kubectl logs -n ims -f "$POD_ID" -c $cont
            verbose_cmd kubectl logs -n ims -f "$POD_ID" -c $cont 2>&1
        fi
    done

    # Because the kiwi logs are far more usefull to debugging image builds than
    # the actual container logs, we go into the container and read from that instead
    echo
    echo
    echo "#################################################"
    echo "### kiwi logs"
    echo "#################################################"
    cmd_wait kubectl exec -ti "$POD_ID" -n ims -c build-image -- ls /mnt/image/kiwi.log 2>&1
    verbose_cmd kubectl exec -ti "$POD_ID" -n ims -c build-image -- tail -f /mnt/image/kiwi.log 2>&1
    echo "#################################################"
    echo "you may get more info from \`kubectl logs -n ims -f $POD -c build-image\`"
    echo "#################################################"
    echo
    echo

}

## image_configure
# Configure an image with cfs
function image_configure {
    local SESSION_NAME EX_HOST JOB_ID POD_ID NEW_IMAGE_ID IMAGE_GROUP OPTIND ARGS GROUP_NAME
    OPTIND=1
    while getopts "n:" OPTION ; do
        case "$OPTION" in
            n) SESSION_NAME="$OPTARG"
            ;;
            \?) die 1 "cfs_apply:  Invalid option:  -$OPTARG" ; return 1 ;;
        esac
    done
    shift $((OPTIND-1))

    local IMAGE_ID=$1
    local GROUP_NAMES_RAW=$2
    local CONFIG_NAME=$3
    declare -a GROUP_NAMES
    cluster_defaults_config

    if [[ -z "$IMAGE_ID" || -z "$GROUP_NAMES_RAW" || -z "$CONFIG_NAME" ]]; then
        echo "USAGE: $0 image config <OPTIONS> [image id] [group name] [config name]"
        echo "OPTIONS:"
        echo -e "\t-n [name] - set a name for the cfs run instead of the default name"
        exit 1
    fi
    setup_craycli
    refresh_ansible_groups


    IFS=$',\t\n'
    GROUP_NAMES=( $GROUP_NAMES_RAW )
    IFS=$' \t\n'

    ## Validate group name
    for GROUP_NAME in "${GROUP_NAMES[@]}"; do
        if [[ -z "${GROUP2NODES[$GROUP_NAME]}" ]]; then
            echo "WARNING: '$GROUP_NAME' doesn't appear to be a valid group name."
            error "WARNING: '$GROUP_NAME' doesn't appear to be a valid group name."
        fi
    done

    ## Setup cfs job id
    # We need a group that's lowercase and only containers certain characters
    # that cfs accepts to use it as the cfs job id
    SESSION_NAME="$GROUP"`date +%M`
    # Sanitize session name
    local SESSION_NAME_SANITIZED=$(echo "$SESSION_NAME" | awk '{print tolower($0)}' | sed 's/[^a-z0-9]//g')

    # Delete any existing cfs session that has the same
    # name to ensure we don't screw things up
    cfs_job_delete "$SESSION_NAME_SANITIZED" > /dev/null 2>&1

    ARGS=""
    for GROUP_NAME in "${GROUP_NAMES[@]}"; do
        ARGS="$ARGS --target-group '$GROUP_NAME' '$IMAGE_ID'"
    done

    ## Launch the cfs configuration job.
    # We try multiple times as sometimes cfs is in a bad state and won't
    # respond (usually responds eventually)
    RETRIES=20
    RET=1
    TRIES=0
    while [[ $RET -ne 0 && $RETRIES -gt $TRIES ]]; do
        if [[ $TRIES -ne 0 ]]; then
            echo
            echo "failed... trying again($TRIES/$RETRIES)"
        fi
    	verbose_cmd cray cfs sessions create \
	    --format json \
    	    --name "$SESSION_NAME_SANITIZED" \
    	    --configuration-name "$CONFIG_NAME" \
    	    --target-definition image \
    	    $ARGS 2>&1
        RET=$?
	sleep 2
        TRIES=$(($TRIES + 1))
    done

    if [[ $RET -ne 0 ]]; then
        echo "[$SESSION_NAME] cfs session creation failed! See logs for details"
        die "[$SESSION_NAME] cfs session creation failed! See logs for details"
    fi

    ## Show the logs for the cfs configure job
    #
    cmd_wait_output "job" cfs_job_describe "$SESSION_NAME_SANITIZED"

    JOB_ID=$(cfs_job_describe $SESSION_NAME_SANITIZED  | jq '.status.session.job' | sed 's/"//g')
    cfs_job_log "$SESSION_NAME_SANITIZED"

    cmd_wait_output 'complete' cfs_job_describe "$SESSION_NAME_SANITIZED"

    cfs_job_describe "$SESSION_NAME_SANITIZED" | jq '.status.session.succeeded' | grep -q 'true'
    if [[ $? -ne 0 ]]; then
        echo "[$SESSION_NAME] image configuation failed"
        die "[$SESSION_NAME] image configuation failed"
    fi

    ## Validate that we got an image and set that as the RETURN so that if
    # parent function wants it it can use it

    NEW_IMAGE_ID=$(cfs_job_describe "$SESSION_NAME_SANITIZED" | jq '.status.artifacts[0].result_id' | sed 's/"//g')

    if [[ -z "$NEW_IMAGE_ID" ]]; then
        echo "[$SESSION_NAME] Could not determine image id for configured image."
        die "[$SESSION_NAME] Could not determine image id for configured image."
    fi
    verbose_cmd image_describe "$NEW_IMAGE_ID"
    if [[ $? -ne 0 ]]; then
        echo "[$SESSION_NAME] Error Image Configuration Failed! See logs for details"
        die "[$SESSION_NAME] Error Image Configuration Failed! See logs for details"
    fi

    echo "Image successfully configured"
    echo "[$SESSION_NAME] Configured image created: '$NEW_IMAGE_ID'" 1>&2
    echo "[$SESSION_NAME] Configured image created: '$NEW_IMAGE_ID'"
    RETURN="$NEW_IMAGE_ID"
    return 0
}

## image_clean_deleted_artifacts
# when telling ims to delete an image, it just marks the artifact as deleted instead of actually deleting it. Thus this goes and deletes any boot-image artifacts marked as deleted.
function image_clean_deleted_artifacts {
    local ARTIFACTS=()
    local artifact
    setup_craycli

    ARTIFACTS=( $(cray artifacts list boot-images --format json | jq '.artifacts' | jq '.[].Key' | sed 's/"//g' | grep ^deleted/) )
    for artifact in "${ARTIFACTS[@]}"; do
        cray artifacts delete boot-images --format json "$artifact" | grep -P '\S'
    done
}

## image_defaults
# Get and set the currently used images for each group and set that in the CUR_IMAGE_NAME and CUR_IMAGE_ID variables.
function image_defaults {
    local IMAGE_RAW BOS
    if [[ -n "${!CUR_IMAGE_NAME[@]}" ]]; then
        return 0
    fi
    cluster_defaults_config
    for group in "${!BOS_DEFAULT[@]}"; do
        BOS=$(echo "$BOS_RAW" | jq ".[] | select(.name == \"${BOS_DEFAULT[$group]}\")")

        if [[ -z "$BOS" && -n "$BOS_RAW" ]]; then
            echo "Warning: default BOS_DEFAULT '${BOS_DEFAULT[$group]}' set for group '$group' is not a valid  bos sessiontemplate. Check /etc/shasta_wrapper/cluster_defaults.conf" 1>&2
        fi

        IMAGE_RAW=$(rest_api_query "ims/images" | jq ".[] | select(.link.etag == \"${CUR_IMAGE_ETAG[$group]}\")")
        if [[ -z "$IMAGE_RAW" && $? -eq 0 ]]; then
            echo "Warning: Image etag '${CUR_IMAGE_ETAG[$group]}' for bos sessiontemplate '${BOS_DEFAULT[$group]}' does not exist." 1>&2
            CUR_IMAGE_NAME[$group]="Invalid"
            CUR_IMAGE_ID[$group]="Invalid"
        else
            CUR_IMAGE_NAME[$group]=$(echo "$IMAGE_RAW" | jq ". | \"\(.name)\"" | sed 's/"//g')
            CUR_IMAGE_ID[$group]=$(echo "$IMAGE_RAW" | jq ". | \"\(.id)\"" | sed 's/"//g')
        fi
    done
}
