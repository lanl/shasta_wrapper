## Bos Job library
# Contains all commands for `shasta bos job`
# This includes all bos job actions. Each bos job is an action that bos attempts to perform such as rebooting or confuguring a node. Largely used for rebooting nodes, often via the group or node libraries.

# © 2023. Triad National Security, LLC. All rights reserved.
# This program was produced under U.S. Government contract 89233218CNA000001 for Los Alamos
# National Laboratory (LANL), which is operated by Triad National Security, LLC for the U.S.
# Department of Energy/National Nuclear Security Administration. All rights in the program are
# reserved by Triad National Security, LLC, and the U.S. Department of Energy/National Nuclear
# Security Administration. The Government is granted for itself and others acting on its behalf a
# nonexclusive, paid-up, irrevocable worldwide license in this material to reproduce, prepare
# derivative works, distribute copies to the public, perform publicly and display publicly, and to permit
# others to do so.


BOS_JOBS=( )
BOS_JOBS_RAW=""

function bos_job {
    case "$1" in
        des*)
            shift
            bos_job_describe "$@"
            ;;
        delete)
            shift
            bos_job_delete "$@"
            ;;
        li*)
            shift
            bos_job_list "$@"
            ;;
        log*)
            shift
            bos_job_log "$@"
            ;;
        sh*)
            shift
            bos_job_describe "$@"
            ;;
        st*)
            shift
            bos_job_status "$@"
            ;;
        *)
            bos_job_help
            ;;
    esac
}

function bos_job_help {
    echo    "USAGE: $0 bos job [action]"
    echo    "DESC: control jobs launched by bos"
    echo    "ACTIONS:"
    echo -e "\tdelete <--all|--complete> [job] : delete all, completed or specified bos jobs"
    echo -e "\tdescribe [job] : (same as show)"
    echo -e "\tlist <-s> : list bos jobs"
    echo -e "\tshow [job] : shows all info on a given bos"

    exit 1
}

## refresh_bos_jobs
# Refresh current job info from bos
function refresh_bos_jobs {
    if [[ -n "$BOS_JOBS_RAW" && "$1" != "--force" ]]; then
        return
    fi
    local RET=1
    BOS_JOBS_RAW=$(rest_api_query "bos/v2/sessions")
    if [[ -z "$BOS_JOBS_RAW" || $? -ne 0 ]]; then
       error "Error retrieving bos data: $BOS_JOBS_RAW"
       return 1
    fi
}

## bos_job_list
# List out the bos jobs. This gets the list of all bos jobs, then gets information on them one at a time, so this can be very expensive. Thus the -s option is also prodived to just get the list of bos job ids as it's just one query.
function bos_job_list {
    local JOB
    refresh_bos_jobs
    printf "${COLOR_BOLD}%19s   %36s   %17s   %10s$COLOR_RESET\n" Started ID Template Complete
    echo "$BOS_JOBS_RAW" | jq -r '.[] | "\(.status.start_time)   \(.name)   \(.template_name)   \(.status.status)"' | sort
}

## bos_job_describe
# describe the bos job
function bos_job_describe {
    if [[ -z "$1" ]]; then
        echo "USAGE: $0 bos job show [jobid]"
	return 1
    fi
    OUTPUT=$(rest_api_query "bos/v2/sessions/$1")
    local RET="$?"

    if [[ "$RET" -ne 0 ]]; then
        echo "Bos job '$1' does not exist"
    else
        echo "$OUTPUT"
    fi
    return $RET
}

## bos_job_delete
# Delete the given bos jobs
function bos_job_delete {
    local JOBS=( "$@" )
    local job comp

    # Handle options
    if [[ "$1" == "--"* ]]; then
        if [[ "${JOBS[0]}" == "--all" ]]; then
            refresh_bos_jobs
            JOBS=( $(echo "$BOS_JOBS_RAW" | jq '.[].name' | sed 's/"//g') )
            prompt_yn "Would you really like to delete all ${#JOBS[@]} jobs?" || exit 0
        elif [[ "${JOBS[0]}" == "--complete" ]]; then
            refresh_bos_jobs
            JOBS=( $(echo "$BOS_JOBS_RAW" | jq '.[] | select(.status.status == "complete")' | jq '.name' | sed 's/"//g') )
            prompt_yn "Would you really like to delete all completed jobs(${#JOBS[@]})?" || exit 0
        else
            echo "Invalid argument '$1'"
            JOBS=( )
        fi
    fi

    # Display help if no options given
    if [[ -z "${JOBS[@]}" ]]; then
        echo -e "USAGE: shasta bos job delete <OPTIONS> <Job list>"
	echo -e "OPTIONS:"
	echo -e "\t--all: delete all bos jobs"
	echo -e "\t--complete: delete all complete bos jobs (Can take some time to run)"
	return 1
    fi

    # Delete the jobs
    for job in "${JOBS[@]}"; do
        if [[ -z "$job" ]]; then
            continue
        fi
        echo cray bos session delete $job --format json
        rest_api_delete "bos/v2/sessions/$job"
    done
}
## bos_job_exit_if_not_valid
# Exit if the given bos template isn't valid (most likely it doesn't exist)
function bos_job_exit_if_not_valid {
    bos_job_describe "$1" > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        die "Error! $1 is not a valid bos job."
    fi
}

## bos_job_status
# show the status of the bos job
function bos_job_status {
    local JOB="$1"
    if [[ -z "$JOB" ]]; then
        echo "USAGE: $0 bos job status [jobid]"
	return 1
    fi
    bos_job_exit_if_not_valid "$JOB" || return $?

    cray bos sessions status list --format json "$JOB"
    return $?
}
