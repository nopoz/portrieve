#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Portrieve: back up, restore, and migrate Portainer stacks.
# Run with --help, or see README.md.

readonly DEFAULT_CONFIG_FILE=".portainer_config"
readonly DEFAULT_BACKUP_DIR="portainer_backups"
readonly STACK_TYPE_SWARM=1
readonly STACK_TYPE_COMPOSE=2

# Mutable globals, set by config loading and argument parsing.
# BACKUP_DIR honours PORTAINER_BACKUP_DIR; the --out flag overrides both.
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
BACKUP_DIR="${PORTAINER_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
LOG_FILE=""
api_key=""
portainer_url=""

readonly COLOR_RESET='\033[0m'
readonly COLOR_INFO='\033[1;34m'
readonly COLOR_SUCCESS='\033[1;32m'
readonly COLOR_WARNING='\033[1;33m'
readonly COLOR_ERROR='\033[1;31m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'

function timestamp() {
	date '+%Y-%m-%d %H:%M:%S'
}

function log() {
	local level=$1
	local message=$2
	# No file logging until a command sets LOG_FILE (only export does).
	if [[ -n "$LOG_FILE" ]]; then
		echo -e "$(timestamp) ${level} ${message}" >> "${LOG_FILE}"
	fi
}

# Console helpers prefix a dim timestamp so `docker logs` (notably scheduled
# cron runs) shows when each line ran; the file log timestamps separately.
function info() {
	local message=$1
	echo -e "${DIM}$(timestamp)${COLOR_RESET} ${COLOR_INFO}[INFO]${COLOR_RESET} $message"
	log "INFO" "$message"
}

function success() {
	local message=$1
	echo -e "${DIM}$(timestamp)${COLOR_RESET} ${COLOR_SUCCESS}[SUCCESS]${COLOR_RESET} $message"
	log "SUCCESS" "$message"
}

function warning() {
	local message=$1
	echo -e "${DIM}$(timestamp)${COLOR_RESET} ${COLOR_WARNING}[WARNING]${COLOR_RESET} $message" >&2
	log "WARNING" "$message"
}

function error_msg() {
	local message=$1
	echo -e "${DIM}$(timestamp)${COLOR_RESET} ${COLOR_ERROR}[ERROR]${COLOR_RESET} $message" >&2
	log "ERROR" "$message"
}

function print_separator() {
	echo -e "${DIM}----------------------------------------------------------${COLOR_RESET}"
	log "INFO" "----------------------------------------------------------"
}

function cleanup() {
	local code=$?
	# Success, Ctrl-C (130), or a closed pipe like `| head` (141): stay quiet.
	[[ $code -eq 0 || $code -eq 130 || $code -eq 141 ]] && return
	# Only the export run keeps a log worth pointing at; other commands already
	# print their own specific error before exiting non-zero.
	if [[ -n "$LOG_FILE" ]]; then
		error_msg "Script failed! Check ${LOG_FILE} for details."
	fi
}

function check_dependencies() {
	local missing_deps=()

	for cmd in curl jq; do
		if ! command -v "$cmd" &> /dev/null; then
			missing_deps+=("$cmd")
		fi
	done

	if [[ ${#missing_deps[@]} -gt 0 ]]; then
		error_msg "Missing required dependencies: ${missing_deps[*]}"
		exit 1
	fi
}

# Classify the installed yq. The script needs mikefarah/yq v4+ (Go); the
# unrelated Python "yq" (kislyuk) uses different syntax and is NOT compatible.
# Echoes one of: ok | missing | wrong | old  (and returns 0 only for "ok").
function yq_check() {
	if ! command -v yq &> /dev/null; then
		echo "missing"; return 1
	fi
	local ver
	ver=$(yq --version 2>/dev/null || true)
	if [[ "$ver" != *mikefarah* ]]; then
		echo "wrong"; return 1   # likely the Python (kislyuk) yq
	fi
	if [[ "$ver" =~ version[[:space:]]+v?([0-9]+) ]] && (( BASH_REMATCH[1] >= 4 )); then
		echo "ok"; return 0
	fi
	echo "old"; return 1
}

# True only when a compatible yq (mikefarah v4+) is available.
function has_yq() {
	[[ "$(yq_check 2>/dev/null)" == "ok" ]]
}

# Emit a precise warning explaining why yq is unusable (for the given reason).
function warn_yq() {
	local reason=$1
	case "$reason" in
		missing) warning "yq not found: external-network recreation will be skipped. Install mikefarah/yq v4+ (see README)." ;;
		wrong)   warning "Found an incompatible 'yq' (not mikefarah/yq); external-network recreation skipped. Install mikefarah/yq v4+ (see README)." ;;
		old)     warning "Found mikefarah/yq older than v4; needs v4+ syntax. External-network recreation skipped." ;;
	esac
}

function validate_url() {
	local url=$1
	if ! [[ $url =~ ^https?://[^[:space:]/]+(/.*)?$ ]]; then
		error_msg "Invalid Portainer URL format: $url"
		exit 1
	fi
}

# Load api_key / portainer_url. Precedence (highest first): environment variables
# (PORTAINER_API_KEY, PORTAINER_URL), then the config file. The file is optional
# when the environment already supplies both credentials.
function load_config() {
	if [[ -f $CONFIG_FILE ]]; then
		# shellcheck disable=SC1090
		source "$CONFIG_FILE"
	fi

	api_key="${PORTAINER_API_KEY:-${api_key:-}}"
	portainer_url="${PORTAINER_URL:-${portainer_url:-}}"

	if [[ -z "$api_key" ]]; then
		error_msg "API key not set. Set PORTAINER_API_KEY, or api_key in $CONFIG_FILE."
		exit 1
	fi

	if [[ -z "$portainer_url" ]]; then
		error_msg "Portainer URL not set. Set PORTAINER_URL, or portainer_url in $CONFIG_FILE."
		exit 1
	fi

	validate_url "$portainer_url"

	# Opt-in TLS skip for Portainer behind a self-signed/private cert. Off by
	# default; any value other than true/1/yes keeps verification on.
	INSECURE_CURL=()
	case "${PORTAINER_INSECURE:-}" in
		true|1|yes) INSECURE_CURL=(--insecure) ;;
	esac
}

# make_api_request <endpoint> [method] [body]
#
# Performs a Portainer API request with retries and exponential backoff.
# GET (no body) callers can omit method/body. When a body is supplied the
# request is sent with the given method and a JSON Content-Type header.
# Echoes the response body on success; returns non-zero after exhausting retries.
function make_api_request() {
	local endpoint=$1
	local method=${2:-GET}
	local body=${3:-}
	local retries=3
	local wait_time=5
	local attempt=1

	local -a curl_args
	while [[ $attempt -le $retries ]]; do
		curl_args=(-s --fail --location -X "$method"
			--connect-timeout 10
			"${INSECURE_CURL[@]}"
			--header "X-API-Key: $api_key"
			--header 'Accept: application/json')
		if [[ -n "$body" ]]; then
			curl_args+=(--header 'Content-Type: application/json' --data "$body")
		fi
		curl_args+=("$endpoint")

		local response
		if response=$(curl "${curl_args[@]}"); then
			echo "$response"
			return 0
		fi
		if [[ $attempt -eq $retries ]]; then
			error_msg "Failed ${method} request to $endpoint after $retries attempts"
			return 1
		fi
		warning "Attempt $attempt failed. Retrying in $wait_time seconds..."
		sleep $wait_time
		((attempt++))
		((wait_time*=2))
	done
}

#######################################
# Export
#######################################

# Inspect the Docker networks for an endpoint and save the user-defined ones to
# networks.json. Predefined networks (bridge/host/none) are dropped. Failure to
# reach the Docker proxy is non-fatal (some endpoints may be unreachable).
function export_networks() {
	local eid=$1
	local endpoint_dir=$2
	local networks_json

	if ! networks_json=$(make_api_request "$portainer_url/endpoints/$eid/docker/networks"); then
		warning "Could not retrieve networks for endpoint ID $eid; skipping networks.json"
		return 0
	fi

	echo "$networks_json" \
		| jq '[.[] | select(.Name != "bridge" and .Name != "host" and .Name != "none")]' \
		> "$endpoint_dir/networks.json"
	success "Saved networks to $endpoint_dir/networks.json"
}

function cmd_export() {
	# Exports hold secrets (.env, metadata), so keep them owner-only by default.
	# PORTAINER_BACKUP_UMASK overrides (e.g. 027 for group read). umask alone is
	# not enough: some filesystems (e.g. Synology shared folders) stamp an
	# inherited ACL on new files that overrides it, and `>` truncation preserves
	# an existing file's mode, so the tree is chmod'd to the matching modes at the
	# end of the run as well.
	local backup_umask="${PORTAINER_BACKUP_UMASK:-077}"
	# A umask is 3-4 octal digits. Reject anything else and fall back to a safe
	# default: an unquoted `077` in YAML is read as octal and reaches the
	# container as `63`, which would otherwise compute a world-readable 0604.
	if [[ ! "$backup_umask" =~ ^[0-7]{3,4}$ ]]; then
		warning "Ignoring invalid PORTAINER_BACKUP_UMASK='$backup_umask' (want 3-4 octal digits like 077; quote it in YAML). Using 077."
		backup_umask="077"
	fi
	local file_mode dir_mode
	printf -v file_mode '%03o' "$(( 0666 & ~0"$backup_umask" ))"
	printf -v dir_mode '%03o' "$(( 0777 & ~0"$backup_umask" ))"
	umask "$backup_umask"
	mkdir -p "$BACKUP_DIR"
	LOG_FILE="${BACKUP_DIR}/export.log"
	: > "${LOG_FILE}"  # truncate

	check_dependencies
	load_config

	print_separator
	info "Starting Portainer stack export"
	info "Backup directory: $BACKUP_DIR"
	info "Log file: $LOG_FILE"

	print_separator
	info "Retrieving endpoints from Portainer at: $portainer_url"

	local endpoints_json
	endpoints_json=$(make_api_request "$portainer_url/endpoints") || exit 1

	if [[ -z "$endpoints_json" ]]; then
		warning "No endpoints returned from Portainer."
		exit 0
	fi

	local endpoint_ids
	endpoint_ids=$(echo "$endpoints_json" | jq -r '.[].Id')

	if [[ -z "$endpoint_ids" ]]; then
		warning "No endpoints found."
		exit 0
	fi

	info "Found endpoints: $(echo "$endpoint_ids" | tr '\n' ' ')"
	print_separator

	# Names seen this run; anything in the backup dir not listed gets pruned.
	declare -A current_endpoints

	local eid endpoint_obj endpoint_name endpoint_dir
	for eid in $endpoint_ids; do
		endpoint_obj=$(echo "$endpoints_json" | jq --arg eid "$eid" '.[] | select(.Id == ($eid|tonumber))')
		endpoint_name=$(echo "$endpoint_obj" | jq -r '.Name')

		endpoint_dir="${BACKUP_DIR}/${endpoint_name}-${eid}"
		mkdir -p "$endpoint_dir"
		current_endpoints["${endpoint_name}-${eid}"]=1

		info "Processing endpoint: ${BOLD}${endpoint_name}${COLOR_RESET} (ID: $eid)"

		local filters filter_uri stacks_url stacks_json
		filters=$(jq -n --argjson id "$eid" '{"EndpointID": $id}')
		filter_uri=$(echo "$filters" | jq -sRr @uri)
		stacks_url="$portainer_url/stacks?filters=${filter_uri}"

		stacks_json=$(make_api_request "$stacks_url") || continue

		# Always export networks for the endpoint, even when it has no stacks.
		export_networks "$eid" "$endpoint_dir"

		if [[ -z "$stacks_json" || "$stacks_json" == "[]" ]]; then
			info "No stacks found for endpoint: $endpoint_name (ID: $eid)."
			print_separator
			continue
		fi

		local stack_ids
		stack_ids=$(echo "$stacks_json" | jq -r '.[].Id')
		info "Found stacks for $endpoint_name (ID: $eid): $(echo "$stack_ids" | tr '\n' ' ')"

		declare -A current_stacks

		local sid stack_obj stack_name env_data stack_type stack_dir stack_file_json stack_file_content
		for sid in $stack_ids; do
			stack_obj=$(echo "$stacks_json" | jq --arg sid "$sid" '.[] | select(.Id == ($sid|tonumber))')
			stack_name=$(echo "$stack_obj" | jq -r '.Name')
			current_stacks["$stack_name"]=1
			env_data=$(echo "$stack_obj" | jq '.Env')
			stack_type=$(echo "$stack_obj" | jq -r '.Type')

			echo
			info "Processing stack: ${BOLD}${stack_name}${COLOR_RESET} (ID: $sid, Type: $stack_type)"

			stack_dir="$endpoint_dir/$stack_name"
			mkdir -p "$stack_dir"

			echo "$stack_obj" | jq '.' > "$stack_dir/stack_metadata.json"
			success "Saved stack metadata to $stack_dir/stack_metadata.json"

			stack_file_json=$(make_api_request "$portainer_url/stacks/$sid/file") || continue
			stack_file_content=$(echo "$stack_file_json" | jq -r '.StackFileContent')

			echo "$stack_file_content" > "$stack_dir/docker-compose.yml"
			success "Saved $stack_dir/docker-compose.yml"

			if [[ $(echo "$env_data" | jq length) -gt 0 ]]; then
				echo "$env_data" | jq -r '.[] | "\(.name)=\(.value)"' > "$stack_dir/.env"
				success "Saved environment variables to $stack_dir/.env"
			else
				info "No environment variables found for stack: $stack_name"
			fi
		done

		# Remove directories for stacks that no longer exist. networks.json is a
		# file (not a dir) so the -type d find naturally skips it.
		local sdir sname
		while IFS= read -r -d '' sdir; do
			sname=$(basename "$sdir")
			if [[ -z "${current_stacks[$sname]:-}" ]]; then
				info "Removing directory for deleted stack: $sdir"
				rm -rf "$sdir"
			fi
		done < <(find "$endpoint_dir" -mindepth 1 -maxdepth 1 -type d -print0)

		unset current_stacks
		print_separator
	done

	# Remove directories for endpoints that no longer exist
	local edir ebasename
	while IFS= read -r -d '' edir; do
		ebasename=$(basename "$edir")
		if [[ "$ebasename" != "$(basename "$BACKUP_DIR")" && -z "${current_endpoints[$ebasename]:-}" ]]; then
			info "Removing directory for deleted endpoint: $edir"
			rm -rf "$edir"
		fi
	done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

	# Enforce secure modes on the whole tree. chmod is what actually sticks: umask
	# is unreliable where inherited ACLs apply (e.g. Synology shared folders) and
	# truncating writes keep an existing file's mode.
	find "$BACKUP_DIR" -type d -exec chmod "$dir_mode" {} +
	find "$BACKUP_DIR" -type f -exec chmod "$file_mode" {} +

	success "All endpoints and stacks have been processed."
	info "Backup location: $BACKUP_DIR"
}

#######################################
# Import
#######################################

# Resolve a target endpoint id from a user-supplied id-or-name against the live
# endpoint list. Echoes the numeric id on success.
function resolve_endpoint_id() {
	local wanted=$1
	local endpoints_json=$2
	local id

	if [[ "$wanted" =~ ^[0-9]+$ ]]; then
		id=$(echo "$endpoints_json" | jq -r --argjson id "$wanted" '.[] | select(.Id == $id) | .Id')
	else
		id=$(echo "$endpoints_json" | jq -r --arg n "$wanted" '.[] | select(.Name == $n) | .Id' | head -n1)
	fi

	if [[ -z "$id" ]]; then
		return 1
	fi
	echo "$id"
}

# Parse a .env file into a JSON array of {name,value} pairs. Blank lines and
# comments are skipped; only the first '=' on each line splits name/value.
function env_file_to_json() {
	local env_file=$1
	if [[ ! -f "$env_file" ]]; then
		echo "[]"
		return 0
	fi
	jq -Rn '
		[ inputs
		  | select(length > 0 and (startswith("#") | not))
		  | capture("^(?<name>[^=]+)=(?<value>.*)$")
		]
	' "$env_file"
}

# Detect networks declared "external: true" in a compose file. Uses yq when
# available; otherwise falls back to a coarse grep and warns about reliability.
# Echoes one network name per line.
function external_networks_from_compose() {
	local compose=$1
	if has_yq; then
		yq -r '
			.networks // {} | to_entries[]
			| select(.value.external == true or (.value.external.name != null))
			| (.value.external.name // .value.name // .key)
		' "$compose" 2>/dev/null || true
	else
		# Fallback: cannot reliably parse YAML without a compatible yq.
		warning "Compatible yq unavailable; skipping external-network detection for $compose"
	fi
}

# Build the Docker network-create payload for a network. When the network is
# present in the saved networks.json, carry over its driver, labels, options and
# IPAM (subnet/gateway) so stacks that pin static IPs keep working. Falls back to
# a plain bridge network when there is no saved entry.
function build_network_payload() {
	local net=$1 networks_json_file=$2 fallback
	fallback=$(jq -n --arg n "$net" '{Name: $n, Driver: "bridge", CheckDuplicate: true, Labels: {}}')

	if [[ ! -f "$networks_json_file" ]]; then
		printf '%s' "$fallback"
		return
	fi

	jq --arg n "$net" --argjson fb "$fallback" '
		([.[] | select(.Name == $n)][0]) as $src
		| if $src == null then $fb
		  else
		    {
		      Name: $n,
		      CheckDuplicate: true,
		      Driver: ($src.Driver // "bridge"),
		      Labels: ($src.Labels // {}),
		      Options: ($src.Options // {}),
		      Attachable: ($src.Attachable // false),
		      Internal: ($src.Internal // false),
		      EnableIPv6: ($src.EnableIPv6 // false)
		    }
		    + (if (($src.IPAM.Config // []) | length) > 0
		       then {IPAM: {Driver: ($src.IPAM.Driver // "default"),
		                    Config: $src.IPAM.Config,
		                    Options: ($src.IPAM.Options // {})}}
		       else {} end)
		  end
	' "$networks_json_file"
}

# Ensure the named external networks exist on the endpoint, creating any that are
# missing. Attributes are taken from a saved networks.json when one is provided.
function ensure_networks() {
	local eid=$1
	local networks_json_file=$2
	shift 2
	local -a wanted=("$@")
	[[ ${#wanted[@]} -eq 0 ]] && return 0

	local existing_json existing
	if ! existing_json=$(make_api_request "$portainer_url/endpoints/$eid/docker/networks"); then
		warning "Could not list networks on endpoint $eid; skipping network creation"
		return 0
	fi
	existing=$(echo "$existing_json" | jq -r '.[].Name')

	local net body driver subnet detail
	for net in "${wanted[@]}"; do
		[[ -z "$net" ]] && continue
		if grep -qxF "$net" <<< "$existing"; then
			info "Network already exists: $net"
			continue
		fi

		body=$(build_network_payload "$net" "$networks_json_file")
		driver=$(jq -r '.Driver' <<< "$body")
		subnet=$(jq -r '.IPAM.Config[0].Subnet // empty' <<< "$body")
		detail="driver: $driver${subnet:+, subnet: $subnet}"

		if [[ "$DRY_RUN" == true ]]; then
			info "[dry-run] Would create network: $net ($detail)"
			continue
		fi

		if make_api_request "$portainer_url/endpoints/$eid/docker/networks/create" POST "$body" > /dev/null; then
			success "Created network: $net ($detail)"
		else
			warning "Failed to create network: $net"
		fi
	done
}

# Import a single stack from a directory (containing a compose file and
# optionally .env / stack_metadata.json) or explicit compose file.
# Args: <compose_file> <name> <type> <swarm_id_hint> <metadata_endpoint_id> <networks_json_file> <env_file>
function import_one_stack() {
	local compose_file=$1
	local stack_name=$2
	local stack_type=$3
	local meta_endpoint_id=$4
	local networks_json_file=$5
	local env_file=$6

	echo
	info "Importing stack: ${BOLD}${stack_name}${COLOR_RESET}"

	if [[ ! -f "$compose_file" ]]; then
		error_msg "Compose file not found: $compose_file"
		return 1
	fi

	# Resolve target endpoint: --endpoint override wins, else metadata EndpointId.
	# The endpoint list is fetched once per run by cmd_import (see ENDPOINTS_CACHE).
	local endpoints_json=$ENDPOINTS_CACHE
	local target_eid

	local wanted_endpoint="${ENDPOINT_OVERRIDE:-$meta_endpoint_id}"
	if [[ -z "$wanted_endpoint" ]]; then
		error_msg "No target endpoint for stack '$stack_name' (no --endpoint and no EndpointId in metadata)"
		return 1
	fi
	if ! target_eid=$(resolve_endpoint_id "$wanted_endpoint" "$endpoints_json"); then
		error_msg "Endpoint '$wanted_endpoint' not found on target Portainer"
		return 1
	fi
	info "Target endpoint resolved to ID: $target_eid"

	local -a ext_nets=()
	local n
	while IFS= read -r n; do
		[[ -n "$n" ]] && ext_nets+=("$n")
	done < <(external_networks_from_compose "$compose_file")
	if [[ ${#ext_nets[@]} -gt 0 ]]; then
		info "External networks required: ${ext_nets[*]}"
		ensure_networks "$target_eid" "$networks_json_file" "${ext_nets[@]}"
	fi

	# jq --arg JSON-escapes the compose body when building request payloads below.
	local env_json
	env_json=$(env_file_to_json "$env_file")

	local kind="standalone"
	if [[ "$stack_type" == "$STACK_TYPE_SWARM" ]]; then
		kind="swarm"
	fi

	# Skip or update if a stack with this name already exists on the endpoint.
	local existing_json existing_id filter_uri
	filter_uri=$(jq -n --argjson id "$target_eid" '{EndpointID:$id}' | jq -sRr @uri)
	existing_json=$(make_api_request "$portainer_url/stacks?filters=${filter_uri}") || existing_json="[]"
	existing_id=$(echo "$existing_json" | jq -r --arg n "$stack_name" '.[] | select(.Name == $n) | .Id' | head -n1)

	if [[ -n "$existing_id" ]]; then
		if [[ "$UPDATE_EXISTING" != true ]]; then
			warning "Stack '$stack_name' already exists (ID $existing_id) on endpoint $target_eid; skipping. Use --update to overwrite."
			return 0
		fi
		local put_body
		put_body=$(jq -n --argjson env "$env_json" --arg content "$(cat "$compose_file")" \
			--argjson prune "$PRUNE" \
			'{StackFileContent: $content, Env: $env, Prune: $prune}')
		if [[ "$DRY_RUN" == true ]]; then
			info "[dry-run] Would UPDATE stack '$stack_name' (ID $existing_id) on endpoint $target_eid"
			return 0
		fi
		if make_api_request "$portainer_url/stacks/$existing_id?endpointId=$target_eid" PUT "$put_body" > /dev/null; then
			success "Updated stack '$stack_name' (ID $existing_id)"
		else
			error_msg "Failed to update stack '$stack_name'"
			return 1
		fi
		return 0
	fi

	local create_url create_body swarm_id
	create_url="$portainer_url/stacks/create/$kind/string?endpointId=$target_eid"
	if [[ "$kind" == "swarm" ]]; then
		swarm_id=$(echo "$endpoints_json" | jq -r --argjson id "$target_eid" \
			'.[] | select(.Id == $id) | .Snapshots[0].DockerSnapshotRaw.Info.Swarm.Cluster.ID // ""' 2>/dev/null || echo "")
		create_body=$(jq -n --arg name "$stack_name" --arg content "$(cat "$compose_file")" \
			--argjson env "$env_json" --arg swarm "$swarm_id" \
			'{Name: $name, StackFileContent: $content, Env: $env, SwarmID: $swarm}')
	else
		create_body=$(jq -n --arg name "$stack_name" --arg content "$(cat "$compose_file")" \
			--argjson env "$env_json" \
			'{Name: $name, StackFileContent: $content, Env: $env}')
	fi

	if [[ "$DRY_RUN" == true ]]; then
		info "[dry-run] Would CREATE $kind stack '$stack_name' on endpoint $target_eid"
		return 0
	fi
	if make_api_request "$create_url" POST "$create_body" > /dev/null; then
		success "Created $kind stack '$stack_name' on endpoint $target_eid"
	else
		error_msg "Failed to create stack '$stack_name'"
		return 1
	fi
}

# Compose filenames portrieve recognizes, in Docker's precedence order.
readonly COMPOSE_FILENAMES=(compose.yaml compose.yml docker-compose.yaml docker-compose.yml)

# Echo the canonical compose file inside a directory (honoring the precedence
# above), or return non-zero when the directory holds none.
function compose_file_in() {
	local dir=$1 name
	for name in "${COMPOSE_FILENAMES[@]}"; do
		if [[ -f "$dir/$name" ]]; then
			printf '%s' "$dir/$name"
			return 0
		fi
	done
	return 1
}

# Import every stack found under a source backup tree
# (source/<endpoint>/<stack>/<compose file>). Any recognized compose filename is
# matched; if a stack dir holds more than one, the precedence above decides.
function import_from_tree() {
	local source_dir=$1
	local found=0
	local compose stack_dir endpoint_dir stack_name networks_file meta type eid env_file
	local -A seen_dirs

	while IFS= read -r -d '' compose; do
		stack_dir=$(dirname "$compose")
		# One stack per directory, even if it contains several compose filenames.
		[[ -n "${seen_dirs[$stack_dir]:-}" ]] && continue
		seen_dirs[$stack_dir]=1
		found=1
		compose=$(compose_file_in "$stack_dir") || continue
		endpoint_dir=$(dirname "$stack_dir")
		stack_name=$(basename "$stack_dir")
		networks_file="$endpoint_dir/networks.json"
		env_file="$stack_dir/.env"
		meta="$stack_dir/stack_metadata.json"

		type="$STACK_TYPE_COMPOSE"
		eid=""
		if [[ -f "$meta" ]]; then
			type=$(jq -r '.Type // 2' "$meta")
			eid=$(jq -r '.EndpointId // ""' "$meta")
		fi

		import_one_stack "$compose" "$stack_name" "$type" "$eid" "$networks_file" "$env_file" || true
	done < <(find "$source_dir" -mindepth 1 -type f \
		\( -name compose.yaml -o -name compose.yml -o -name docker-compose.yaml -o -name docker-compose.yml \) -print0)

	if [[ "$found" -eq 0 ]]; then
		warning "No compose files found under: $source_dir"
	fi
}

function cmd_import() {
	check_dependencies
	load_config
	LOG_FILE=""  # import does not write the export log

	local yq_state
	yq_state=$(yq_check) || warn_yq "$yq_state"

	print_separator
	info "Starting Portainer stack import"
	[[ "$DRY_RUN" == true ]] && info "DRY RUN: no changes will be made"

	# Fetch the endpoint list once; import_one_stack reuses it per stack.
	if ! ENDPOINTS_CACHE=$(make_api_request "$portainer_url/endpoints"); then
		error_msg "Could not retrieve endpoints from Portainer at $portainer_url"
		exit 1
	fi

	# Mode selection: --compose (single explicit file) > --stack (single dir) > --source tree.
	if [[ -n "$IMPORT_COMPOSE" ]]; then
		if [[ -z "$IMPORT_NAME" ]]; then
			error_msg "--compose requires --name"
			exit 1
		fi
		local env_guess
		env_guess="$(dirname "$IMPORT_COMPOSE")/.env"
		import_one_stack "$IMPORT_COMPOSE" "$IMPORT_NAME" "$STACK_TYPE_COMPOSE" "" "" "$env_guess"
	elif [[ -n "$IMPORT_STACK_DIR" ]]; then
		local stack_dir="$IMPORT_STACK_DIR"
		local stack_name networks_file meta type eid compose_file
		stack_name=$(basename "$stack_dir")
		networks_file="$(dirname "$stack_dir")/networks.json"
		meta="$stack_dir/stack_metadata.json"
		type="$STACK_TYPE_COMPOSE"; eid=""
		if [[ -f "$meta" ]]; then
			type=$(jq -r '.Type // 2' "$meta")
			eid=$(jq -r '.EndpointId // ""' "$meta")
		fi
		if ! compose_file=$(compose_file_in "$stack_dir"); then
			error_msg "No compose file found in $stack_dir"
			exit 1
		fi
		import_one_stack "$compose_file" "$stack_name" "$type" "$eid" "$networks_file" "$stack_dir/.env"
	else
		info "Importing from backup tree: $IMPORT_SOURCE"
		import_from_tree "$IMPORT_SOURCE"
	fi

	print_separator
	success "Import complete."
}

#######################################
# Discovery / helper commands
#######################################

# Human-readable name for a Portainer endpoint Type code.
function endpoint_type_name() {
	case "$1" in
		1) echo "Docker" ;;
		2) echo "Docker-Agent" ;;
		3) echo "Azure-ACI" ;;
		4) echo "Edge-Docker" ;;
		5) echo "Kubernetes" ;;
		6) echo "K8s-Agent" ;;
		7) echo "K8s-Edge" ;;
		*) echo "Type-$1" ;;
	esac
}

# Human-readable name for a Portainer stack Type code.
function stack_type_name() {
	case "$1" in
		1) echo "Swarm" ;;
		2) echo "Compose" ;;
		3) echo "Kubernetes" ;;
		*) echo "Type-$1" ;;
	esac
}

# portrieve.sh endpoints [--json]
# List environments with their ID, name, platform type and online status.
function cmd_endpoints() {
	check_dependencies
	load_config
	LOG_FILE=""

	local endpoints_json
	endpoints_json=$(make_api_request "$portainer_url/endpoints") || exit 1

	if [[ "$OUTPUT_JSON" == true ]]; then
		echo "$endpoints_json" | jq '[.[] | {Id, Name, Type, Status}]'
		return 0
	fi

	printf "${BOLD}%-5s %-28s %-13s %-8s${COLOR_RESET}\n" "ID" "NAME" "TYPE" "STATUS"
	echo "$endpoints_json" | jq -r '.[] | "\(.Id)\t\(.Name)\t\(.Type)\t\(.Status)"' \
		| while IFS=$'\t' read -r id name type status; do
			local stat="down"
			[[ "$status" == "1" ]] && stat="up"
			printf "%-5s %-28s %-13s %-8s\n" "$id" "$name" "$(endpoint_type_name "$type")" "$stat"
		done
}

# portrieve.sh stacks [--endpoint ID|NAME] [--json]
# List stacks (optionally for one endpoint) with id, name, type and endpoint.
function cmd_stacks() {
	check_dependencies
	load_config
	LOG_FILE=""

	local endpoints_json stacks_url stacks_json target_eid
	endpoints_json=$(make_api_request "$portainer_url/endpoints") || exit 1

	stacks_url="$portainer_url/stacks"
	if [[ -n "$ENDPOINT_OVERRIDE" ]]; then
		if ! target_eid=$(resolve_endpoint_id "$ENDPOINT_OVERRIDE" "$endpoints_json"); then
			error_msg "Endpoint '$ENDPOINT_OVERRIDE' not found"
			exit 1
		fi
		local filter_uri
		filter_uri=$(jq -n --argjson id "$target_eid" '{EndpointID:$id}' | jq -sRr @uri)
		stacks_url="$portainer_url/stacks?filters=${filter_uri}"
	fi

	stacks_json=$(make_api_request "$stacks_url") || exit 1

	if [[ "$OUTPUT_JSON" == true ]]; then
		echo "$stacks_json" | jq '[.[] | {Id, Name, Type, EndpointId, Status}]'
		return 0
	fi

	if [[ -z "$stacks_json" || "$stacks_json" == "[]" ]]; then
		info "No stacks found."
		return 0
	fi

	printf "${BOLD}%-5s %-26s %-10s %-9s %-8s${COLOR_RESET}\n" "ID" "NAME" "TYPE" "ENDPOINT" "STATUS"
	echo "$stacks_json" | jq -r '.[] | "\(.Id)\t\(.Name)\t\(.Type)\t\(.EndpointId)\t\(.Status)"' \
		| while IFS=$'\t' read -r id name type eid status; do
			local stat="inactive"
			[[ "$status" == "1" ]] && stat="active"
			printf "%-5s %-26s %-10s %-9s %-8s\n" "$id" "$name" "$(stack_type_name "$type")" "$eid" "$stat"
		done
}

# portrieve.sh test [--json]
# Validate config + connectivity + auth in one quick, single-attempt check.
function cmd_test() {
	check_dependencies
	load_config
	LOG_FILE=""

	[[ "$OUTPUT_JSON" != true ]] && info "Testing connection to $portainer_url"

	# Single attempt (no retry/backoff) so a bad key/URL fails fast.
	local body http curl_rc=0
	body=$(curl -s --max-time 10 -w $'\n%{http_code}' "${INSECURE_CURL[@]}" \
		-H "X-API-Key: $api_key" -H 'Accept: application/json' \
		"$portainer_url/endpoints" 2>/dev/null) || curl_rc=$?
	http=$(printf '%s' "$body" | tail -n1)
	body=$(printf '%s' "$body" | sed '$d')

	local ep_count="-" stack_count="-" ok=false reason=""
	case "$http" in
		200)
			ok=true
			ep_count=$(printf '%s' "$body" | jq 'length' 2>/dev/null || echo "?")
			local stacks_json
			stacks_json=$(curl -s --max-time 10 "${INSECURE_CURL[@]}" -H "X-API-Key: $api_key" -H 'Accept: application/json' "$portainer_url/stacks" 2>/dev/null || echo "[]")
			stack_count=$(printf '%s' "$stacks_json" | jq 'length' 2>/dev/null || echo "?")
			;;
		401|403) reason="authentication failed (HTTP $http); check api_key" ;;
		000|"")
			# curl exit 60 = TLS cert verification failed. Point at the opt-out.
			if [[ $curl_rc -eq 60 ]]; then
				reason="TLS certificate verification failed for $portainer_url; set PORTAINER_INSECURE=true to skip verification (self-signed/private cert)"
			else
				reason="could not reach $portainer_url; check URL/network"
			fi
			;;
		*)       reason="unexpected response (HTTP $http)" ;;
	esac

	if [[ "$OUTPUT_JSON" == true ]]; then
		jq -n --argjson ok "$ok" --arg url "$portainer_url" --arg http "$http" \
			--arg endpoints "$ep_count" --arg stacks "$stack_count" --arg reason "$reason" \
			'{connected: $ok, url: $url, http: ($http|tonumber? // $http), endpoints: ($endpoints|tonumber? // null), stacks: ($stacks|tonumber? // null), reason: (if $reason == "" then null else $reason end)}'
		[[ "$ok" == true ]] && return 0 || return 1
	fi

	if [[ "$ok" == true ]]; then
		success "Connected and authenticated (HTTP 200)"
		info "Endpoints visible: $ep_count"
		info "Stacks visible: $stack_count"
		return 0
	fi
	error_msg "Connection test failed: $reason"
	return 1
}

#######################################
# Usage / argument parsing
#######################################

function usage() {
	cat <<'EOF'
portrieve.sh - export and import Portainer stacks via the API

USAGE:
  portrieve.sh export [options]
  portrieve.sh import [options]
  portrieve.sh endpoints [--json]
  portrieve.sh stacks [--endpoint ID|NAME] [--json]
  portrieve.sh test [--json]
  portrieve.sh --help

COMMON OPTIONS:
  --config FILE     Path to config file (default: .portainer_config)

DISCOVERY COMMANDS:
  endpoints         List environments (ID, name, type, status). Useful for
                    picking an --endpoint value for import.
  stacks            List stacks (ID, name, type, endpoint, status). Filter with
                    --endpoint ID|NAME.
  test              Validate config, connectivity and the API key, and report
                    how many endpoints/stacks are visible.

  All three accept --json to emit raw JSON instead of a table.

EXPORT OPTIONS:
  --out DIR         Backup output directory (default: portainer_backups)

  Exports every stack from every endpoint as docker-compose.yml, .env and
  stack_metadata.json, plus a per-endpoint networks.json. The output tree is
  synced: stacks/endpoints removed in Portainer are pruned from the backup.

IMPORT OPTIONS:
  --source DIR      Import all stacks under a backup tree (default: portainer_backups)
  --stack DIR       Import a single stack directory (contains a compose file:
                    compose.yaml or docker-compose.yml)
  --compose FILE    Import a single explicit compose file (requires --name)
  --name NAME       Stack name (used with --compose)
  --endpoint ID|NAME  Target endpoint override (else uses metadata EndpointId)
  --update          Update stacks that already exist (default: skip them)
  --prune           With --update, prune orphaned services (PUT Prune=true)
  --dry-run         Show planned actions without calling write endpoints

  Importing recreates any "external: true" networks a stack depends on (needs
  the optional `yq` tool) before deploying. Existing stacks are skipped unless
  --update is given.

CONFIG FILE (.portainer_config):
  api_key="YOUR_API_KEY"
  portainer_url="http://YOUR_HOST:9000/api"
EOF
}

# Import-mode option state (referenced by import functions).
IMPORT_SOURCE="$BACKUP_DIR"
IMPORT_STACK_DIR=""
IMPORT_COMPOSE=""
IMPORT_NAME=""
ENDPOINT_OVERRIDE=""
UPDATE_EXISTING=false
PRUNE=false
DRY_RUN=false
OUTPUT_JSON=false
ENDPOINTS_CACHE=""

function main() {
	trap cleanup EXIT

	local command="${1:-}"
	if [[ $# -gt 0 ]]; then
		shift
	fi

	case "$command" in
		-h|--help|help|"")
			usage
			exit 0
			;;
		export)
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--config) CONFIG_FILE="$2"; shift 2 ;;
					--out)    BACKUP_DIR="$2"; shift 2 ;;
					-h|--help) usage; exit 0 ;;
					*) error_msg "Unknown export option: $1"; exit 1 ;;
				esac
			done
			cmd_export
			;;
		import)
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--config)   CONFIG_FILE="$2"; shift 2 ;;
					--source)   IMPORT_SOURCE="$2"; shift 2 ;;
					--stack)    IMPORT_STACK_DIR="$2"; shift 2 ;;
					--compose)  IMPORT_COMPOSE="$2"; shift 2 ;;
					--name)     IMPORT_NAME="$2"; shift 2 ;;
					--endpoint) ENDPOINT_OVERRIDE="$2"; shift 2 ;;
					--update)   UPDATE_EXISTING=true; shift ;;
					--prune)    PRUNE=true; shift ;;
					--dry-run)  DRY_RUN=true; shift ;;
					-h|--help)  usage; exit 0 ;;
					*) error_msg "Unknown import option: $1"; exit 1 ;;
				esac
			done
			cmd_import
			;;
		endpoints)
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--config) CONFIG_FILE="$2"; shift 2 ;;
					--json)   OUTPUT_JSON=true; shift ;;
					-h|--help) usage; exit 0 ;;
					*) error_msg "Unknown endpoints option: $1"; exit 1 ;;
				esac
			done
			cmd_endpoints
			;;
		stacks)
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--config)   CONFIG_FILE="$2"; shift 2 ;;
					--endpoint) ENDPOINT_OVERRIDE="$2"; shift 2 ;;
					--json)     OUTPUT_JSON=true; shift ;;
					-h|--help)  usage; exit 0 ;;
					*) error_msg "Unknown stacks option: $1"; exit 1 ;;
				esac
			done
			cmd_stacks
			;;
		test)
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--config) CONFIG_FILE="$2"; shift 2 ;;
					--json)   OUTPUT_JSON=true; shift ;;
					-h|--help) usage; exit 0 ;;
					*) error_msg "Unknown test option: $1"; exit 1 ;;
				esac
			done
			cmd_test
			;;
		*)
			error_msg "Unknown command: $command"
			usage
			exit 1
			;;
	esac
}

main "$@"
