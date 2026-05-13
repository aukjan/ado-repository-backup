#!/usr/bin/env bash

# strict mode configuration
set -uo pipefail

# enable extended pathname expansion (e.g. $ ls !(*.jpg|*.gif))
shopt -s extglob

################################################################################
### variables and defaults
################################################################################
VERBOSE_MODE=false;
DRY_RUN=false;
COMPRESS=true
PROJECT_WIKI=false;
BACKLOG=false;
SKIP_REPOS=false;

# required options
PAT=""
BACKUP_ROOT_PATH=""
ORGANIZATION=""
RETENTION_DAYS=""

# retry configuration
MAX_RETRIES=3
RETRY_BASE_DELAY=5

BACKUP_SUCCESS=true;

################################################################################
### FUNCTIONS
################################################################################

# check if command is available
function installed {
  command -v "${1}" >/dev/null 2>&1
}

# die and exit with code 1
function die {
  >&2 printf '%s %s\n' "Fatal: " "${@}"
  exit 1
}

# die and exit with code 1 + usage
function die_and_usage {
  >&2 printf '%s %s\n' "Fatal: " "${@}"
  usage
  exit 1
}

# usage function
function usage {
  usage="$(basename "$0") [-h] -p PAT -d backup-dir -o organization -r retention [-v] [-x] [-w] [-n] [-b] [-s]
where:
    -h  show this help text
    -p  personal access token (PAT) for Azure DevOps [REQUIRED]
    -d  backup directory path: the directory where to store the backup archive [REQUIRED]
    -o  Azure DevOps organization URL (e.g. https://dev.azure.com/organization) [REQUIRED]
    -r  retention days for backup files: how many days to keep the backup files [REQUIRED]
        A value of zero is accepted and keeps only the last daily backup
    -v  verbose mode [default is false]
    -x  dry run mode (no actual backup, only simulation) [default is false]
    -w  backup project wiki [default is false]
    -n  do not compress backup folder [default is true]
    -b  backup backlog work items (exports via REST API as JSON) [default is false]
    -s  skip repository cloning (use with -b for backlog-only mode) [default is false]"
  printf '%s\n' "${usage}"
}

# function to delete partial backup directory if some operation fails in the middle
function delete_partial_backup {
  if [[ "${DRY_RUN}" == "false" ]]; then
    if [ -n "${BACKUP_DIRECTORY}" -a "${BACKUP_DIRECTORY}" != "/" ]; then
      echo "=== Deleting partial backup directory [${BACKUP_DIRECTORY}]"
      rm -rf "${BACKUP_DIRECTORY}"
    else
      echo "=== Skip deleting partial backup directory due to invalid backup directory (${BACKUP_DIRECTORY})"
    fi
  else
    echo "=== Simulate deleting partial backup directory [${BACKUP_DIRECTORY}]"
  fi
}

# retry a command with exponential backoff
# usage: retry <description> <command> [args...]
function retry {
  local description="${1}"
  shift
  local attempt=1
  local delay=${RETRY_BASE_DELAY}

  while [[ ${attempt} -le ${MAX_RETRIES} ]]; do
    if "${@}"; then
      return 0
    fi
    if [[ ${attempt} -lt ${MAX_RETRIES} ]]; then
      echo "====> RETRY: ${description} failed (attempt ${attempt}/${MAX_RETRIES}), retrying in ${delay}s..."
      sleep ${delay}
      delay=$(( delay * 2 ))
    else
      echo "====> FAILED: ${description} after ${MAX_RETRIES} attempts"
    fi
    ((attempt++))
  done
  return 1
}

# Safe curl wrapper: fetches URL, writes body to file, returns HTTP status code
# usage: safe_curl <output_file> <curl_args...>
# Returns: 0 if HTTP 200 and valid JSON, 1 otherwise
function safe_curl {
  local out_file="${1}"
  shift
  local http_code=""
  http_code=$(curl -s -o "${out_file}" -w "%{http_code}" "$@") || {
    echo "====> ERROR: curl failed with exit code $?"
    return 1
  }
  if [[ "${http_code}" != "200" ]]; then
    echo "====> ERROR: HTTP ${http_code} from API"
    [[ -f "${out_file}" ]] && head -c 500 "${out_file}" >&2
    return 1
  fi
  if ! jq empty "${out_file}" 2>/dev/null; then
    echo "====> ERROR: response is not valid JSON"
    head -c 500 "${out_file}" >&2
    return 1
  fi
  return 0
}

# export backlog work items for a project via Azure DevOps REST API
# Streams batches to temp files on disk to avoid memory issues on large projects.
# Handles WIQL >20k cap via ID-range pagination.
# usage: export_backlog <normalized_project_name> <project_id> <original_project_name>
function export_backlog {
  local project_dir_name="${1}"
  local project_id="${2}"
  local project_name="${3}"
  local backlog_dir="${BACKUP_DIRECTORY}/${project_dir_name}/backlog"
  local api_base="${ORGANIZATION}"
  local auth_header="Authorization: Basic ${B64_PAT}"
  local workitems_file="${backlog_dir}/workitems.json"

  echo "====> Exporting backlog for project [${project_name}]"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "====> Simulate backlog export for [${project_name}] to ${backlog_dir}"
    return 0
  fi

  mkdir -p "${backlog_dir}"

  # Create temp directory for streaming data; clean up on exit from this function
  local tmp_dir
  tmp_dir=$(mktemp -d "${backlog_dir}/.export_tmp.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp_dir}'" RETURN

  local tmp_response="${tmp_dir}/response.json"
  local ids_file="${tmp_dir}/all_ids.txt"
  local items_file="${tmp_dir}/items.jsonl"
  local comments_file="${tmp_dir}/comments.json"

  # ── Step 1: Collect ALL work item IDs via WIQL ──
  # WIQL returns max 20,000 items. We paginate by ID range to get everything.
  local last_seen_id=0
  local page=0
  > "${ids_file}"

  while true; do
    ((page++))
    local wiql_body
    wiql_body=$(jq -n --arg pname "${project_name}" --argjson minid "${last_seen_id}" \
      '{"query": ("SELECT [System.Id] FROM workitems WHERE [System.TeamProject] = \u0027" + $pname + "\u0027 AND [System.Id] > " + ($minid|tostring) + " ORDER BY [System.Id]")}')

    fetch_wiql_page() {
      safe_curl "${tmp_response}" \
        -X POST \
        -H "${auth_header}" \
        -H "Content-Type: application/json" \
        -d "${wiql_body}" \
        "${api_base}/${project_id}/_apis/wit/wiql?\$top=20000&api-version=7.1"
    }

    if ! retry "WIQL query page ${page} for [${project_name}]" fetch_wiql_page; then
      echo "====> WARNING: failed to query work items for [${project_name}] (page ${page}), skipping backlog export"
      return 1
    fi

    local page_count
    page_count=$(jq '.workItems | length' "${tmp_response}")

    if [[ "${page_count}" -eq 0 ]]; then
      break
    fi

    # Append IDs to file
    jq -r '.workItems[].id' "${tmp_response}" >> "${ids_file}"
    last_seen_id=$(jq -r '.workItems[-1].id' "${tmp_response}")

    echo "====> WIQL page ${page}: got ${page_count} IDs (last ID: ${last_seen_id})"

    # If fewer than 20,000, we've got them all
    if [[ "${page_count}" -lt 20000 ]]; then
      break
    fi
  done

  local id_count
  id_count=$(wc -l < "${ids_file}" | tr -d ' ')

  if [[ ${id_count} -eq 0 ]]; then
    echo "====> No work items found for [${project_name}]"
    jq -n --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg org "${ORGANIZATION}" --arg proj "${project_name}" \
      '{"exportDate":$date,"organization":$org,"project":$proj,"workItemCount":0,"workItems":[]}' \
      > "${workitems_file}"
    return 0
  fi

  echo "====> Found ${id_count} total work items for [${project_name}]"

  # ── Step 2: Batch-fetch work items (200 per request), stream to disk ──
  > "${items_file}"
  local batch_ids=()
  local batch_num=0
  local fetched_total=0
  local failed_batches=0

  _flush_batch() {
    ((batch_num++))
    local ids_json
    ids_json=$(printf '%s\n' "${batch_ids[@]}" | jq -R 'tonumber' | jq -s '.')
    local batch_body
    batch_body=$(jq -n --argjson ids "${ids_json}" '{"ids": $ids, "$expand": "All"}')

    fetch_batch() {
      safe_curl "${tmp_response}" \
        -X POST \
        -H "${auth_header}" \
        -H "Content-Type: application/json" \
        -d "${batch_body}" \
        "${api_base}/${project_id}/_apis/wit/workitemsbatch?api-version=7.1"
    }

    if retry "work items batch ${batch_num} for [${project_name}]" fetch_batch; then
      # Append each item as one JSON line (jsonl format)
      local batch_count
      batch_count=$(jq '.value | length' "${tmp_response}")
      jq -c '.value[]' "${tmp_response}" >> "${items_file}"
      fetched_total=$(( fetched_total + batch_count ))
      echo "====> Batch ${batch_num}: fetched ${batch_count} items (total: ${fetched_total}/${id_count})"
    else
      echo "====> WARNING: failed batch ${batch_num} (${#batch_ids[@]} items) for [${project_name}]"
      ((failed_batches++))
    fi
  }

  while IFS= read -r wid; do
    [[ -z "${wid}" ]] && continue
    batch_ids+=("${wid}")
    if [[ ${#batch_ids[@]} -ge 200 ]]; then
      _flush_batch
      batch_ids=()
    fi
  done < "${ids_file}"

  # Flush remaining
  if [[ ${#batch_ids[@]} -gt 0 ]]; then
    _flush_batch
    batch_ids=()
  fi

  echo "====> Fetched ${fetched_total} work items for [${project_name}] (${failed_batches} failed batches)"

  # ── Step 3: Fetch comments for work items that have them ──
  # Scan the jsonl to find IDs with comments > 0
  local comment_ids_file="${tmp_dir}/comment_ids.txt"
  jq -r 'select(.fields["System.CommentCount"] != null and .fields["System.CommentCount"] > 0) | .id' "${items_file}" \
    > "${comment_ids_file}" 2>/dev/null || true

  local comment_count
  comment_count=$(wc -l < "${comment_ids_file}" | tr -d ' ')

  # Start comment map as empty JSON object on disk
  echo '{}' > "${comments_file}"

  if [[ ${comment_count} -gt 0 ]]; then
    echo "====> Fetching comments for ${comment_count} work items..."
    local comment_num=0

    while IFS= read -r wid; do
      [[ -z "${wid}" ]] && continue
      ((comment_num++))

      fetch_comments() {
        safe_curl "${tmp_response}" \
          -H "${auth_header}" \
          "${api_base}/${project_id}/_apis/wit/workitems/${wid}/comments?api-version=7.1-preview.4"
      }

      if retry "comments for work item ${wid}" fetch_comments; then
        # Extract comments and merge into the comments map file
        jq -r --argjson wid "${wid}" \
          '[.comments[] | {id: .id, text: .text, createdBy: .createdBy.displayName, createdDate: .createdDate, modifiedBy: .modifiedBy.displayName, modifiedDate: .modifiedDate}]' \
          "${tmp_response}" > "${tmp_dir}/wi_comments.json" 2>/dev/null

        if [[ -s "${tmp_dir}/wi_comments.json" ]]; then
          jq --argjson wid "${wid}" --slurpfile c "${tmp_dir}/wi_comments.json" \
            '. + {($wid | tostring): $c[0]}' "${comments_file}" > "${tmp_dir}/comments_new.json" \
            && mv "${tmp_dir}/comments_new.json" "${comments_file}"
        fi
      else
        echo "====> WARNING: failed to fetch comments for work item ${wid}"
      fi

      # Progress every 50 items
      if (( comment_num % 50 == 0 )); then
        echo "====> Comments progress: ${comment_num}/${comment_count}"
      fi

      # Rate limit avoidance
      sleep 0.2
    done < "${comment_ids_file}"

    echo "====> Comments fetched: ${comment_num}/${comment_count}"
  fi

  # ── Step 4: Assemble final output JSON ──
  # Merge work items (jsonl) with comments map, stream to output file
  echo "====> Assembling final export file..."

  jq -n --slurpfile cm "${comments_file}" \
    --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg org "${ORGANIZATION}" \
    --arg proj "${project_name}" '
    {
      "exportDate": $date,
      "organization": $org,
      "project": $proj,
      "workItemCount": 0,
      "workItems": []
    }
  ' > "${workitems_file}"

  # Build the full workItems array: slurp jsonl items, merge comments, write final file
  jq -s --slurpfile cm "${comments_file}" '
    . as $items |
    $cm[0] as $comments |
    [ $items[] | . + {"comments": ($comments[(.id | tostring)] // [])} ]
  ' "${items_file}" > "${tmp_dir}/merged_items.json"

  jq -n \
    --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg org "${ORGANIZATION}" \
    --arg proj "${project_name}" \
    --slurpfile items "${tmp_dir}/merged_items.json" '
    {
      "exportDate": $date,
      "organization": $org,
      "project": $proj,
      "workItemCount": ($items[0] | length),
      "workItems": $items[0]
    }
  ' > "${workitems_file}"

  local file_size
  file_size=$(du -hs "${workitems_file}" | cut -f1)
  local final_count
  final_count=$(jq '.workItemCount' "${workitems_file}")
  echo "====> Backlog export complete for [${project_name}]: ${final_count} work items (${file_size})"
  return 0
}


################################################################################
### MAIN
################################################################################

# min bash 4 version
[[ "${BASH_VERSINFO[0]}" -lt 4 ]] && die "Bash >=4 required"

# check for required commands
deps=(jq base64 git az tar curl)
for dep in "${deps[@]}"; do
  installed "${dep}" || die "Missing '${dep}'"
done

# parse options
while getopts ':p:d:o:r:vxwhnbs' option; do
  case "$option" in
    p) PAT=$OPTARG
       ;;
    d) BACKUP_ROOT_PATH=$OPTARG
       ;;
    o) ORGANIZATION=$OPTARG
       ;;
    r) RETENTION_DAYS=$OPTARG
       ;;
    v) VERBOSE_MODE=true
       ;;
    x) DRY_RUN=true
       ;;
    w) PROJECT_WIKI=true
       ;;
    n) COMPRESS=false
       ;;
    b) BACKLOG=true
       ;;
    s) SKIP_REPOS=true
       ;;
    h) usage
       exit 0
       ;;
    :) printf 'missing argument for -%s\n' "$OPTARG" >&2
       usage
       exit 1
       ;;
   \?) printf 'illegal option: -%s\n' "$OPTARG" >&2
       usage
       exit 1
       ;;
  esac
done
shift $((OPTIND - 1))

# deal with required options
# die if PAT is empty
[[ -z "${PAT}" ]] && die_and_usage "PAT is required (-p option)"
# die if directory argument is empty
[[ -z "${BACKUP_ROOT_PATH}" ]] && die_and_usage "Backup directory is required (-d option)"
# die if organization argument is empty
[[ -z "${ORGANIZATION}" ]] && die_and_usage "Organization URL is required (-o option)"
# die if retention argument is empty
[[ -z "${RETENTION_DAYS}" ]] && die_and_usage "Retention days is required (-r option)"
# die if retention argument is not a number
[[ ! "${RETENTION_DAYS}" =~ ^[0-9]+$ ]] && die_and_usage "Retention days must be a number"
# die if retention argument is less than 0
[[ "${RETENTION_DAYS}" -lt 0 ]] && die_and_usage "Retention days must be greater or equal to 0"
# die if retention argument is greater than 365
[[ "${RETENTION_DAYS}" -gt 365 ]] && die_and_usage "Retention days must be less than or equal to 365"
# die if directory does not exist
[[ ! -d "${BACKUP_ROOT_PATH}" ]] && die "Backup directory does not exist"
# die if directory is not writable
[[ ! -w "${BACKUP_ROOT_PATH}" ]] && die "Backup directory is not writable"
# die if directory is not a directory
[[ ! -d "${BACKUP_ROOT_PATH}" ]] && die "Backup directory is not a directory"
# die if directory is root (/)
[[ "${BACKUP_ROOT_PATH}" == "/" ]] && die "Backup directory should not be root dir /"
# die if skip repos is set without backlog
[[ "${SKIP_REPOS}" == "true" && "${BACKLOG}" == "false" ]] && die_and_usage "Skip repos (-s) requires backlog (-b) to be enabled"
# warn if skip repos and wiki are both set
[[ "${SKIP_REPOS}" == "true" && "${PROJECT_WIKI}" == "true" ]] && echo "WARNING: -s (skip repos) and -w (wiki) are both set; wiki backup requires repo data and will be skipped"

echo "=== Azure DevOps Repository Backup Script ==="

# Initialize POSITIONAL array
POSITIONAL=()

set -- "${POSITIONAL[@]}" # restore positional parameters

echo "=== Script parameters"
#echo "PAT               = ${PAT}"
echo "ORGANIZATION_URL  = ${ORGANIZATION}"
echo "BACKUP_ROOT_PATH  = ${BACKUP_ROOT_PATH}"
echo "RETENTION_DAYS    = ${RETENTION_DAYS}"
echo "DRY_RUN           = ${DRY_RUN}"
echo "PROJECT_WIKI      = ${PROJECT_WIKI}"
echo "VERBOSE_MODE      = ${VERBOSE_MODE}"
echo "COMPRESS          = ${COMPRESS}"
echo "BACKLOG           = ${BACKLOG}"
echo "SKIP_REPOS        = ${SKIP_REPOS}"

#Store script start time
start_time=$(date +%s)

# git tuning
git config --global http.postBuffer 524288000
git config --global core.compression 0
git config --global http.version HTTP/1.1
if [[ "${VERBOSE_MODE}" == "true" ]]; then
  echo "=== Show git config (git config --list):"
  git config --list --show-scope
fi


#Install the Devops extension
echo "=== Install DevOps Extension"
az extension add --name 'azure-devops'

#Set this environment variable with a PAT will 'auto login' when using 'az devops' commands
echo "=== Set AZURE_DEVOPS_EXT_PAT env variable"
export AZURE_DEVOPS_EXT_PAT=${PAT} 
#Store PAT in Base64
B64_PAT=$(printf "%s"":${PAT}" | base64 -w 0)

echo "=== Get project list"
fetch_project_list() {
  ProjectList=$(az devops project list --organization "${ORGANIZATION}" --query 'value[]')
  [[ -n "${ProjectList}" ]]
}
if ! retry "fetch project list" fetch_project_list; then
  die "ERROR: empty project list after ${MAX_RETRIES} attempts, wrong azure cli parameters?"
fi

#Create backup folder with current time as name
BACKUP_FOLDER=$(date +"%Y%m%d%H%M")
BACKUP_DIRECTORY="${BACKUP_ROOT_PATH}/${BACKUP_FOLDER}"
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "=== Simulate Backup folder creation [${BACKUP_DIRECTORY}]"
else
  mkdir -p "${BACKUP_DIRECTORY}"
  if [[ $? -ne 0 ]]; then
    die "=== Backup folder creation failed [${BACKUP_DIRECTORY}]"
  else
    echo "=== Backup folder created [${BACKUP_DIRECTORY}]"
  fi
fi

# Show project list
PROJECT_COUNTER=0
for project in $(echo "${ProjectList}" | jq -r '.[] | @base64'); do
  _jq() {
    echo ${project} | base64 -d | jq -r ${1}
  }
  echo "==> Found project [${PROJECT_COUNTER}] [$(_jq '.name')]"
  ((PROJECT_COUNTER++))
done

#Initialize counters
PROJECT_COUNTER=0
REPO_COUNTER=0

# start process projects
for project in $(echo "${ProjectList}" | jq -r '.[] | @base64'); do

  WIKI_COUNTER=0

  _jq() {
    echo ${project} | base64 -d | jq -r ${1}
  }
  echo "==> Backup project [${PROJECT_COUNTER}] [$(_jq '.name')] [$(_jq '.id')]"

  #Get current project name and normalize it to create folder
  CURRENT_PROJECT_NAME=$(_jq '.name')
  CURRENT_WIKI_PROJECT_NAME=$(echo $CURRENT_PROJECT_NAME | sed -e 's/[^A-Za-z0-9._\(\)-]/-/g')    
  CURRENT_PROJECT_NAME=$(echo $CURRENT_PROJECT_NAME | sed -e 's/[^A-Za-z0-9._\(\)-]/_/g')
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "=== Simulate Backup folder created [${BACKUP_DIRECTORY}/${CURRENT_PROJECT_NAME}]"
  else
    mkdir -p "${BACKUP_DIRECTORY}/${CURRENT_PROJECT_NAME}"
    if [[ $? -ne 0 ]]; then
      die "=== Backup folder creation failed [${BACKUP_DIRECTORY}/${CURRENT_PROJECT_NAME}]"
    else
      echo "=== Backup folder created [${BACKUP_DIRECTORY}/${CURRENT_PROJECT_NAME}]"
    fi
  fi
  
  if [[ "${SKIP_REPOS}" == "false" ]]; then
    #Get Repository list for current project id.
    fetch_repo_list() {
      REPO_LIST=$(az repos list --organization "${ORGANIZATION}" --project "$(_jq '.id')")
      [[ -n "${REPO_LIST}" ]]
    }
    if ! retry "fetch repo list for [$(_jq '.name')]" fetch_repo_list; then
      echo "====> WARNING: failed to fetch repo list for [$(_jq '.name')], skipping project"
      ((PROJECT_COUNTER++))
      continue
    fi

    for repo in $(echo "${REPO_LIST}" | jq -r '.[] | @base64'); do
      _jqR() {
          echo ${repo} | base64 -d | jq -r ${1}           
      }
      
      # There must always be at least one repository per Team Project.
      if [[ ${WIKI_COUNTER} -eq 0 ]]; then
        CURRENT_BASE_WIKI_URL=$(_jqR '.webUrl')  
        ((WIKI_COUNTER++))        
      fi

      echo "====> Backup repo [${REPO_COUNTER}][$(_jqR '.name')] [$(_jqR '.id')] [$(_jqR '.webUrl')]"
              
      #Get current repo name and normalize it to create folder
      CURRENT_REPO_NAME=$(_jqR '.name')
      CURRENT_REPO_NAME=$(echo $CURRENT_REPO_NAME | sed -e 's/[^A-Za-z0-9._\(\)-]/_/g')
      CURRENT_REPO_DIRECTORY="${BACKUP_DIRECTORY}/${CURRENT_PROJECT_NAME}/repo/${CURRENT_REPO_NAME}"

      if [[ "${DRY_RUN}" == "true" ]]; then
          echo "Simulate git clone ${CURRENT_REPO_NAME}"
      else
          # check if repo is disabled and skip it
          # disabled repos cannot be accessed
          if [[ "$(_jqR '.isDisabled')" == "false" ]]; then
            # Use Base64 PAT in header to authenticate on Git Repository
            # Wrap clone in a function for retry (clean up partial clone between attempts)
            clone_repo() {
              rm -rf "${CURRENT_REPO_DIRECTORY}" 2>/dev/null
              git -c http.extraHeader="Authorization: Basic ${B64_PAT}" clone "$(_jqR '.webUrl')" "${CURRENT_REPO_DIRECTORY}"
            }
            if ! retry "clone repo [${CURRENT_REPO_NAME}]" clone_repo; then
              echo "====> Backup failed for repo [${CURRENT_REPO_NAME}]"
              delete_partial_backup
              die "=== Backup failed for repo [${CURRENT_REPO_NAME}], exiting"
            fi
          else
            echo "====> Skipping disabled repo: [${CURRENT_REPO_NAME}]"
          fi
      fi        
      ((REPO_COUNTER++))
    done
  fi

  if [[ "${BACKLOG}" == "true" ]]; then
    export_backlog "${CURRENT_PROJECT_NAME}" "$(_jq '.id')" "$(_jq '.name')" || \
      echo "====> WARNING: backlog export failed for [$(_jq '.name')], continuing"
  fi

  if [[ "${PROJECT_WIKI}" == "true" && "${SKIP_REPOS}" == "false" ]]; then
      CURRENT_WIKI_DIRECTORY="${BACKUP_DIRECTORY}/${CURRENT_PROJECT_NAME}/wiki/${CURRENT_WIKI_PROJECT_NAME}"             
      CURRENT_BASE_WIKI_URL=$(echo $CURRENT_BASE_WIKI_URL | sed -E 's/(https:\/\/dev.azure.com\/.+\/_git\/)(.+)$/\1/g')
      CURRENT_WIKI_URL="${CURRENT_BASE_WIKI_URL}${CURRENT_WIKI_PROJECT_NAME}.wiki"
      if [[ "${DRY_RUN}" == "true" ]]; then
          echo "Simulate WIKI git clone ${CURRENT_WIKI_PROJECT_NAME}"
      else
        echo "====> Backup Wiki repo ${CURRENT_WIKI_URL}"
        clone_wiki() {
          rm -rf "${CURRENT_WIKI_DIRECTORY}" 2>/dev/null
          git -c http.extraHeader="Authorization: Basic ${B64_PAT}" clone "${CURRENT_WIKI_URL}" "${CURRENT_WIKI_DIRECTORY}"
        }
        if ! retry "clone wiki [${CURRENT_WIKI_PROJECT_NAME}]" clone_wiki; then
          # if wiki fails give only a warning and continue (maybe is not defined)
          echo "====> WARNING: backup failed for repo [${CURRENT_WIKI_URL}]"
          echo "====> WARNING: wiki not defined?"
        fi
      fi
  fi
  ((PROJECT_COUNTER++))
done

# if DRYRUN true skip useless steps
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "=== Skip compress and retention in DRYRUN mode ==="
  echo "=== Backup completed ==="
  exit 0
fi

if [[ "${VERBOSE_MODE}" == "true" ]]; then
  echo "=== Backup structure ==="
  find ${BACKUP_DIRECTORY} -maxdepth 2 -ls
fi

backup_size_uncompressed=$(du -hs ${BACKUP_DIRECTORY})

echo "=== Backup completed ==="
echo  "Projects : ${PROJECT_COUNTER}"
echo  "Repositories : ${REPO_COUNTER}"

cd ${BACKUP_ROOT_PATH}

if [[ "$COMPRESS" == "true" ]]; then
  echo "=== Compress folder"
  tar czf ${BACKUP_FOLDER}.tar.gz --checkpoint=50000 --checkpoint-action=echo="#%u: %T" ${BACKUP_FOLDER}
  if [[ $? -lt 2 ]]; then
    backup_size_compressed=$(du -hs ${BACKUP_FOLDER}.tar.gz)
    echo "Size : ${backup_size_uncompressed} (uncompressed) - ${backup_size_compressed} (compressed)"
    echo "=== Remove raw data in folder"
    rm -rf ${BACKUP_FOLDER}
  else
    BACKUP_SUCCESS=false
    echo "=== ERROR: tar command exited with fatal error!"
    rm -rf ${BACKUP_FOLDER}
    rm -f ${BACKUP_FOLDER}.tar.gz
  fi
else
  echo "Size : ${backup_size_uncompressed} (uncompressed)"
fi

# apply retention policy according to options
if [[ "${BACKUP_SUCCESS}" == "true" ]]; then
  if [[ "${COMPRESS}" == "true" ]]; then
    # doublecheck for BACKUP_ROOT_PATH
    if [ -n "${BACKUP_ROOT_PATH}" -a "${BACKUP_ROOT_PATH}" != "/" ]; then
      echo "=== Apply retention policy (${RETENTION_DAYS} days):"
      echo "=== i'm going to delete following files:"
      find ${BACKUP_ROOT_PATH} -mindepth 1 -maxdepth 1 \
        -type f -regextype posix-extended -regex ".*/[0-9]{12}\\.tar\\.gz$" \
        -daystart -mtime +${RETENTION_DAYS} \
        -print
      find ${BACKUP_ROOT_PATH} -mindepth 1 -maxdepth 1 \
        -type f -regextype posix-extended -regex ".*/[0-9]{12}\\.tar\\.gz$" \
        -daystart -mtime +${RETENTION_DAYS} \
        -delete
      echo "=== Done."
    else
      echo "=== Skip deletion due to invalid backup directory (${BACKUP_ROOT_PATH})"
    fi
  else
    # doublecheck for BACKUP_ROOT_PATH
    if [ -n "${BACKUP_ROOT_PATH}" -a "${BACKUP_ROOT_PATH}" != "/" ]; then
      echo "=== Apply retention policy (${RETENTION_DAYS} days):"
      echo "=== i'm going to delete following backup directories:"
      find ${BACKUP_ROOT_PATH} -mindepth 1 -maxdepth 1 \
        -type d -regextype posix-extended -regex ".*/[0-9]{12}$" \
        -daystart -mtime +${RETENTION_DAYS} \
        -print
      find ${BACKUP_ROOT_PATH} -mindepth 1 -maxdepth 1 \
        -type d -regextype posix-extended -regex ".*/[0-9]{12}$" \
        -daystart -mtime +${RETENTION_DAYS} \
        -print0 | xargs -0 -r -- rm -rf
      echo "=== Done."
    else
      echo "=== Skip deletion due to invalid backup directory (${BACKUP_ROOT_PATH})"
    fi
  fi
  # calculate and print elapsed time since start
  end_time=$(date +%s)
  elapsed=$(( end_time - start_time ))
  eval "echo Elapsed time : $(date -ud "@$elapsed" +'$((%s/3600/24)) days %H hr %M min %S sec')"
else
  die "=== Backup failed, retention policy not applied, exiting"
fi
