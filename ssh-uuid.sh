#!/usr/bin/env bash

# Copyright 2022 Balena Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e  # Exit immediately on unhandled errors

BALENARC_DATA_DIRECTORY="${BALENARC_DATA_DIRECTORY:-"${HOME}/.balena"}"

function quit {
	echo "ERROR: $1" >/dev/stderr
	exit 1
}

# Check that the version of bash meets the requirements.
# The 'declare -pf' and 'readarray -t' features require bash v4.4 or later.
function check_bash_version {
	local major="${BASH_VERSINFO[0]:-0}"
	local minor="${BASH_VERSINFO[1]:-0}"
	if (( "${major}" < 4 || ("${major}" == 4 && "${minor}" < 4) )); then
		quit "\
bash v${major}.${minor} detected, but this script requires bash v4.4 or later.
On macOS, it can be updated with 'brew install bash' ( https://brew.sh/ )
Sorry for the inconvenience!
"
	fi
}

check_bash_version

# Escape the arguments in a way compatible with the POSIX 'sh'. Alternative to
# bash's printf '%q' (because bash's printf '%q' may produce bash-specific
# escaping, for example using the $'a\nb' syntax that interprets ASCII control
# characters, which is not supported by POSIX 'sh'). Useful with the '--service'
# flag as we do not assume that balenaOS application containers will have 'bash'
# installed. Based on: https://stackoverflow.com/a/29824428
function escape_sh {
	case $# in 0) return 0; esac
	while :
	do
		printf "'"
		printf %s "$1" | sed "s/'/'\\\\''/g"
		shift
		case $# in 0) break; esac
		printf "' "
	done
	printf "'\n"
}

function print_help_and_quit {
	echo "For ssh or scp options, check the manual pages: 'man ssh' or 'man scp'.
For ssh-uuid or scp-uuid usage, see README at:
https://github.com/pdcastro/ssh-uuid/blob/master/README.md
" >/dev/stderr
	exit
}

# Check whether the BALENA_USERNAME and BALENA_TOKEN environment variables are set, for
# the purpose of balenaCloud proxy authentication, and as the username to use for ssh
# public key authentication. If either variable is not set, attempt to obtain the missing
# value from the balena CLI's ~/.balena/cachedUsername JSON file. That file is created
# by running the `balena login` command followed by the `balena whoami` command. If you
# would rather not depend on the balena CLI, set the environment variables manually with
# the values found in the balenaCloud web dashboard, Preferences page, Account Details and
# Access Tokens tabs.
function get_user_and_token {
	if [[ -n "${BALENA_USERNAME}" && -n "${BALENA_TOKEN}" ]]; then
		return
	fi
	local cached_usr_file="${BALENARC_DATA_DIRECTORY}/cachedUsername"
	if [[ ! -r "${cached_usr_file}" ]]; then
		return
	fi
	# jq missing while the cached file exists isn't fatal here — see
	# require_balena_auth, which surfaces the missing tool only when the
	# balena tunnel is actually about to be used.
	if ! command -v jq >/dev/null 2>&1; then
		return
	fi
	local cached_username
	local cached_token
	cached_username="$(jq -r .username "${cached_usr_file}")"
	cached_token="$(jq -r .token "${cached_usr_file}")"
	BALENA_USERNAME="${BALENA_USERNAME:-"${cached_username}"}"
	BALENA_TOKEN="${BALENA_TOKEN:-"${cached_token}"}"
}

# Mandatory-auth check. Called from code paths that actually need to talk to
# balenaCloud (the proxy do_proxy uses, or any cmdline run that will inject
# the ProxyCommand). With --no-balena-tunnel set, the wrapper does not touch
# balenaCloud, so this is skipped.
function require_balena_auth {
	if [[ -n "${BALENA_USERNAME}" && -n "${BALENA_TOKEN}" ]]; then
		return
	fi
	local cached_usr_file="${BALENARC_DATA_DIRECTORY}/cachedUsername"
	if [[ ! -r "${cached_usr_file}" ]]; then
		quit "\
'BALENA_USERNAME' or 'BALENA_TOKEN' env vars not defined, and file
'${cached_usr_file}' not found or not readable.
Set the env vars as per README, or use the balena CLI 'login' and 'whoami'
commands to ensure that file is created.
(If you do not need the balena cloud tunnel — e.g. you reach the device
over zerotier / tailscale / a private network — pass '--no-balena-tunnel'
or '-oBalenaTunnel=no' to skip this requirement.)
"
	fi
	# If we got here, the cached file exists but get_user_and_token couldn't
	# parse it (missing jq, parse error, etc.). Surface the underlying
	# requirement instead of staying silent.
	check_tool jq
	quit "Cached balena credentials at '${cached_usr_file}' could not be read."
}

# This function will execute on the balenaOS host OS
function remote__get_container_name {
	local service="$1"
	local len="${#service}"
	local -a names
	readarray -t names <<< "$(balena-engine ps --format '{{.Names}}')"
	local result=''
	local name
	for name in "${names[@]}"; do
		if [ "${name:0:len+1}" = "${service}_" ]; then
			result="${name}"
			break
		fi
	done
	echo "${result}"
}

# This function will execute on the balenaOS host OS with bash v5
function remote__main {
	local service="$1"
	shift
	local container_name
	container_name="$(remote__get_container_name "${service}")"
	if [ -z "${container_name}" ]; then
		echo "ERROR: Cannot find a running container for service '${service}'" >/dev/stderr
		exit 1
	fi
	local -a args
	if [ "$#" = 0 ]; then
		args=('sh')
	else
		IFS=' ' args=('sh' '-c' "$*")
	fi
	local tty_flags='-i' # without '-i', STDIN is closed
	[[ "$#" = 0 || -t 0 ]] && tty_flags='-it'
	[ -n "${SSUU_DEBUG}" ] && set -x
	balena-engine exec ${tty_flags} "${container_name}" "${args[@]}"
	{ local status="$?"; [ -n "${SSUU_DEBUG}" ] && set +x; } 2>/dev/null
	return "${status}"
}

# Parse a short flag specification like '-N' or '-CNL', the latter being the
# abbreviated form for '-C' '-N' '-L'. For each short flag, set a global
# variable in the format "SSUU_FLAG_${flag}". Examples:
#   parse_short_flag '-N'
#   -> SSUU_FLAG_N='-N'
#
#   parse_short_flag '-CNL'
#   -> SSUU_FLAG_C='-CNL'
#      SSUU_FLAG_N='-CNL'
#      SSUU_FLAG_L='-CNL'
function parse_short_flag {
	local spec="$1" # flag spec like '-N' or '-CNL'
	local i
	for (( i=1; i<${#spec}; i++ )); do
		local flag="${spec:i:1}"
		if [[ "${flag}" =~ [a-zA-Z] ]]; then
			declare -g SSUU_FLAG_"${flag}"="${spec}"
		else
			break
		fi
	done
}

# Decide whether a short-flag spec like '-p' or '-vt' or '-p22222' consumes
# the next CLI token as its value (returns 0) or not (returns 1). The first
# argument is the spec, the second is a string of option-taking flag letters.
# Walks letters left-to-right: when an option-taking letter is found, any
# letters that follow within the same spec are the (inline) value — so the
# next token is NOT consumed; if the option-taking letter is the last one,
# the value comes from the next token. Only consulted when an explicit
# --balena-device-uuid was given (the default flow keeps the prior, simpler
# parsing that relies on the UUID.balena regex to identify the hostname).
function short_flag_consumes_next {
	local spec="$1"
	local arg_flags="$2"
	local letters="${spec:1}"
	local i
	for (( i=0; i<${#letters}; i++ )); do
		local c="${letters:i:1}"
		if [[ "${arg_flags}" == *"${c}"* ]]; then
			[ $((i+1)) -lt "${#letters}" ] && return 1
			return 0
		fi
	done
	return 1
}

# Parse the arguments and split them between option arguments and positional
# arguments.
# Note: the split happens at the first UUID.balena occurrence which is always
# correct for `ssh`, but not always correct for `scp`. For the purposes of
# `scp-uuid` however, this potential incorrectness is not important.
function parse_args {
	local args=("$@")
	local nargs=${#args[@]}
	local i
	SSUU_USER=''
	SSUU_OPT_ARGS=()
	SSUU_POS_ARGS=()

	# Pre-scan: extract every ssh-uuid-specific ("fake") option no matter
	# where it appears on the command line, and drop those tokens from
	# `args` so the main loop only deals with real ssh/scp options and
	# positionals. This is what makes the fake options order-independent
	# relative to the hostname — important because the explicit-UUID path
	# accepts the first non-flag arg as the connection target, so any fake
	# option that came AFTER it would otherwise leak into SSUU_POS_ARGS and
	# get forwarded to ssh/scp as part of the remote command. Values carried
	# over from the environment (e.g. inherited by an inner ssh-uuid
	# invocation through 'scp -S ssh-uuid') are preserved unless a flag
	# overrides them.
	local filtered=()
	for (( i=0; i<nargs; i++ )); do
		local pre_arg="${args[i]}"
		if [ "${pre_arg}" = '--help' ]; then
			print_help_and_quit
		fi
		# --service <name>: targets a balena service container instead of the
		# host OS by wrapping the remote command in a balena-engine exec.
		# Also accepted via a fake ssh -o option (-oBalenaService=<name> or
		# -o BalenaService=<name>) so ssh-uuid can be used as a drop-in
		# replacement for ssh in contexts where only `-o` options can be
		# customized on the caller side.
		if [ "${pre_arg}" = '--service' ]; then
			SSUU_SERVICE="${args[++i]:-}"
			continue
		fi
		if [[ "${pre_arg}" == -oBalenaService=* ]]; then
			SSUU_SERVICE="${pre_arg#-oBalenaService=}"
			continue
		fi
		if [ "${pre_arg}" = '-o' ] && [[ "${args[i+1]:-}" == BalenaService=* ]]; then
			SSUU_SERVICE="${args[++i]#BalenaService=}"
			continue
		fi
		# --balena-device-uuid <uuid>: specifies the balena device UUID
		# explicitly so the connection target on the cmdline can be anything
		# the caller needs (the UUID.balena hostname is no longer required).
		# Useful when the caller uses the SSH target for its own purposes
		# (e.g. Eternal Terminal pointing at an etserver host) while the
		# balena tunnel still has to route to a chosen device. Also accepted
		# as the fake ssh option -oBalenaDeviceUUID=<uuid> / -o BalenaDeviceUUID=<uuid>.
		if [ "${pre_arg}" = '--balena-device-uuid' ]; then
			SSUU_BALENA_DEVICE_UUID="${args[++i]:-}"
			continue
		fi
		if [[ "${pre_arg}" == -oBalenaDeviceUUID=* ]]; then
			SSUU_BALENA_DEVICE_UUID="${pre_arg#-oBalenaDeviceUUID=}"
			continue
		fi
		if [ "${pre_arg}" = '-o' ] && [[ "${args[i+1]:-}" == BalenaDeviceUUID=* ]]; then
			SSUU_BALENA_DEVICE_UUID="${args[++i]#BalenaDeviceUUID=}"
			continue
		fi
		# Suppress the "this implementation does not check CRLs" message
		# printed by recent socat versions on stderr. The warning is a real
		# security notice (revoked certs will not be detected); only enable
		# this when the user understands the trade-off and the message is
		# getting in the way (e.g. noisy automation). Also accepted as the
		# fake ssh option -oSocatSuppressCRLWarning=yes / -o SocatSuppressCRLWarning=yes.
		if [ "${pre_arg}" = '--socat-suppress-crl-warning' ]; then
			SSUU_SOCAT_SUPPRESS_CRL_WARNING=1
			continue
		fi
		if [[ "${pre_arg}" == -oSocatSuppressCRLWarning=* ]]; then
			[ "${pre_arg#-oSocatSuppressCRLWarning=}" = 'yes' ] && SSUU_SOCAT_SUPPRESS_CRL_WARNING=1
			continue
		fi
		if [ "${pre_arg}" = '-o' ] && [[ "${args[i+1]:-}" == SocatSuppressCRLWarning=* ]]; then
			[ "${args[++i]#SocatSuppressCRLWarning=}" = 'yes' ] && SSUU_SOCAT_SUPPRESS_CRL_WARNING=1
			continue
		fi
		# --no-balena-tunnel: bypass the balena cloud proxy entirely. The
		# wrapper becomes a near-passthrough to ssh/scp — no ProxyCommand
		# injection, no forced port 22222, no `-l BALENA_USERNAME` default,
		# no BALENA_USERNAME/TOKEN requirement. The --service wrapping (and
		# the rest of the parsing) still applies, so callers can still
		# dispatch into a container via balena-engine exec when an
		# alternative tunnel (zerotier, tailscale, LAN, etc.) already
		# provides reach to the host OS SSH server. Also accepted as the
		# fake ssh option -oBalenaTunnel=no / -o BalenaTunnel=no.
		if [ "${pre_arg}" = '--no-balena-tunnel' ]; then
			SSUU_NO_BALENA_TUNNEL=1
			continue
		fi
		if [[ "${pre_arg}" == -oBalenaTunnel=* ]]; then
			[ "${pre_arg#-oBalenaTunnel=}" = 'no' ] && SSUU_NO_BALENA_TUNNEL=1
			continue
		fi
		if [ "${pre_arg}" = '-o' ] && [[ "${args[i+1]:-}" == BalenaTunnel=* ]]; then
			[ "${args[++i]#BalenaTunnel=}" = 'no' ] && SSUU_NO_BALENA_TUNNEL=1
			continue
		fi
		filtered+=("${pre_arg}")
	done
	args=("${filtered[@]}")
	nargs=${#args[@]}
	if [ -n "${SSUU_BALENA_DEVICE_UUID}" ] && \
		! [[ "${SSUU_BALENA_DEVICE_UUID}" =~ ^([[:xdigit:]]{32}|[[:xdigit:]]{62})$ ]]; then
		quit "Invalid balena device UUID: '${SSUU_BALENA_DEVICE_UUID}'. Expected 32 or 62 hex characters."
	fi
	if [ -n "${SSUU_NO_BALENA_TUNNEL}" ] && [ -n "${SSUU_BALENA_DEVICE_UUID}" ]; then
		quit "--no-balena-tunnel and --balena-device-uuid are mutually exclusive (one bypasses the balena tunnel, the other configures it)."
	fi

	# Option-taking short flags. Only consulted when SSUU_BALENA_DEVICE_UUID
	# is set, where we must distinguish flag values from the connection
	# target. The default flow keeps the prior, regex-based parsing.
	local arg_flags
	if [ "${SSUU_SCP}" = 1 ]; then
		arg_flags='cFiloPSJ'
	else
		arg_flags='bcDEeFIiJLlmOopQRSWw'
	fi

	local skip_next=0
	for (( i=0; i<nargs; i++ )); do
		local arg="${args[i]}"
		if [ "${skip_next}" = 1 ]; then
			skip_next=0
			SSUU_OPT_ARGS+=("${arg}")
			continue
		fi
		# Non-UUID.balena hostname branch: fires when the caller has either
		# set --balena-device-uuid (tunnel still on, but the hostname can be
		# whatever) or --no-balena-tunnel (no tunnel, host is plain DNS / IP
		# reachable through an alternative network). In both modes any
		# non-flag arg is the connection target. Checked before the regex
		# patterns so the explicit option takes precedence if both are
		# present.
		#
		# Only the ssh branch extracts the user@ prefix (to decide whether to
		# inject `-l BALENA_USERNAME`). For scp we deliberately don't try to
		# auto-prepend BALENA_USERNAME: the first non-flag arg might be a
		# local path (e.g. `scp-uuid local.txt host:/dst`), and identifying
		# which positional is the remote target is non-trivial without the
		# UUID.balena anchor. Callers using explicit UUID with scp should
		# write `user@host:path` themselves when they need a specific user.
		#
		# For ssh we also keep parsing past the host: callers (e.g. Eternal
		# Terminal) often emit `host -oXxx=yyy ... cmd`, with real ssh
		# options after the hostname. Standard ssh would treat those as part
		# of the remote command, but in this wrapper, leaving them in
		# SSUU_POS_ARGS means they'd be wrapped into the balena-engine exec
		# payload when --service is in use. Sift them: anything starting with
		# `-` (and any value an option-taking short flag pulls in) goes to
		# SSUU_OPT_ARGS; the first remaining non-flag arg starts the actual
		# remote command.
		if { [ -n "${SSUU_BALENA_DEVICE_UUID}" ] || [ -n "${SSUU_NO_BALENA_TUNNEL}" ]; } \
				&& [ "${arg:0:1}" != '-' ]; then
			if [ "${SSUU_SCP}" = 1 ]; then
				SSUU_POS_ARGS=("${args[@]:i}")
				break
			fi
			if [[ "${arg}" =~ ^(ssh://)?((.+)@) ]]; then
				SSUU_USER="${BASH_REMATCH[3]}"
			fi
			local host="${arg}"
			local cmd_start=$((i + 1))
			local j post_skip=0
			for (( j=cmd_start; j<nargs; j++ )); do
				local jarg="${args[j]}"
				if [ "${post_skip}" = 1 ]; then
					post_skip=0
					SSUU_OPT_ARGS+=("${jarg}")
					cmd_start=$((j + 1))
					continue
				fi
				if [ "${jarg:0:1}" != '-' ]; then
					cmd_start=$j
					break
				fi
				SSUU_OPT_ARGS+=("${jarg}")
				cmd_start=$((j + 1))
				if [ "${jarg:1:1}" != '-' ]; then
					parse_short_flag "${jarg}"
					if short_flag_consumes_next "${jarg}" "${arg_flags}"; then
						post_skip=1
					fi
				fi
			done
			SSUU_POS_ARGS=("${host}" "${args[@]:cmd_start}")
			break
		fi
		# Is arg a UUID.balena hostname specification?
		# For ssh:
		#   '[user@]UUID.balena'
		#   'ssh://[user@]UUID.balena[:port]'
		# For scp:
		#   '[user@]UUID.balena:'
		#   'scp://[user@]UUID.balena[:port][/path]'
		# where UUID is a hexadecimal number with exactly 32 or 62 characters,
		# where 62 is not typo meant to read 64, it really is 62.
		if [[ "${SSUU_SCP}" = 0 &&
				"${arg}" =~ ^(ssh://)?((.+)@)?([[:xdigit:]]{32}|[[:xdigit:]]{62})\.balena(:[0-9]+)?$
			]]; then
			SSUU_USER="${BASH_REMATCH[3]}"
			SSUU_POS_ARGS=("${args[@]:i}")
			break
		elif [[ "${SSUU_SCP}" = 1 &&
			"${arg}" =~ ^scp://((.+)@)?([[:xdigit:]]{32}|[[:xdigit:]]{62})\.balena(:[0-9]+)?(/.*)?$
			]]; then
			SSUU_USER="${BASH_REMATCH[2]}"
			if [ -z "${SSUU_USER}" ] && [ -n "${BALENA_USERNAME}" ]; then
				SSUU_USER="${BALENA_USERNAME}"
				arg="scp://${BALENA_USERNAME}@${arg#scp://}"
				args[i]="${arg}"
			fi
			SSUU_POS_ARGS=("${args[@]:i}")
			break
		elif [[ "${SSUU_SCP}" = 1 &&
			"${arg}" =~ ^((.+)@)?([[:xdigit:]]{32}|[[:xdigit:]]{62})\.balena:.*$
			]]; then
			SSUU_USER="${BASH_REMATCH[2]}"
			if [ -z "${SSUU_USER}" ] && [ -n "${BALENA_USERNAME}" ]; then
				SSUU_USER="${BALENA_USERNAME}"
				arg="${BALENA_USERNAME}@${arg}"
				args[i]="${arg}"
			fi
			SSUU_POS_ARGS=("${args[@]:i}")
			break
		fi
		if [ "${arg:0:1}" = '-' ] && [ "${arg:1:1}" != '-' ]; then
			parse_short_flag "${arg}"
			# Track flags that consume the next token as their value. Limited
			# to flows where the main loop accepts arbitrary non-flag args as
			# the connection target (explicit UUID, or no-tunnel mode), so
			# the default UUID.balena-regex flow is unchanged.
			if { [ -n "${SSUU_BALENA_DEVICE_UUID}" ] || [ -n "${SSUU_NO_BALENA_TUNNEL}" ]; } \
					&& short_flag_consumes_next "${arg}" "${arg_flags}"; then
				skip_next=1
			fi
		fi
		SSUU_OPT_ARGS+=("${arg}")
	done
	if [ "${#SSUU_POS_ARGS[@]}" = 0 ]; then
		if [ -n "${SSUU_BALENA_DEVICE_UUID}" ] || [ -n "${SSUU_NO_BALENA_TUNNEL}" ]; then
			quit "Invalid command line (missing connection target)"
		elif [ "${SSUU_SCP}" = '1' ]; then
			quit "Invalid command line (missing 'UUID.balena:' remote host, including ':' character)"
		else
			quit "Invalid command line (missing 'UUID.balena' hostname)"
		fi
	fi
}

function run_ssh {
	local opt_args=("${SSUU_OPT_ARGS[@]}")  # optional arguments
	local pos_args=("${SSUU_POS_ARGS[@]}")  # positional arguments
	local l_arg=()
	local t_arg=()
	if [ -n "${SSUU_SERVICE}" ]; then
		local host="${pos_args[0]}"
		local remote_cmd=("${pos_args[@]:1}")
		if [ "${#remote_cmd[@]}" = 0 ]; then
			# interactive shell, allocate a tty
			if [ -z "${SSUU_FLAG_N}" ] && [ -z "${SSUU_FLAG_t}" ]; then
				t_arg=('-t')
			fi
		else
			remote_cmd=( "$(escape_sh "${remote_cmd[@]}")" ) # single element array
		fi
		pos_args=(
			"${host}"
			# export some functions for remote execution
			"$(declare -pf remote__get_container_name);"
			"$(declare -pf remote__main);"
			"SSUU_DEBUG=${DEBUG}"
			remote__main
			"${SSUU_SERVICE}"
			"${remote_cmd[@]}"
		)
	fi
	# In tunnel mode (the default), inject the ProxyCommand that routes
	# through balenaCloud, force port 22222 (the balenaOS host SSH port),
	# and default the login to BALENA_USERNAME if the caller did not pass
	# one. With --no-balena-tunnel, none of this applies: the wrapper hands
	# the user's args straight to ssh and only the --service wrapping (if
	# any) takes effect.
	local tunnel_args=()
	if [ -z "${SSUU_NO_BALENA_TUNNEL}" ]; then
		if [ -z "${SSUU_USER}" ] && [ -z "${SSUU_FLAG_l}" ] ; then
			l_arg=('-l' "${BALENA_USERNAME}")
		fi
		# When --balena-device-uuid is set, the cmdline hostname is whatever
		# the caller needs (e.g. an Eternal Terminal endpoint), so we cannot
		# rely on ssh's %h substitution to identify the balena device for
		# the tunnel. Hardcode the device hostname in the ProxyCommand.
		local proxy_host='%h'
		[ -n "${SSUU_BALENA_DEVICE_UUID}" ] && proxy_host="${SSUU_BALENA_DEVICE_UUID}.balena"
		tunnel_args=(
			-o "ProxyCommand='$0' do_proxy ${proxy_host} %p"
			-p 22222
		)
	fi
	opt_args=(
		"${tunnel_args[@]}"
		"${l_arg[@]}"
		"${t_arg[@]}"
		"${opt_args[@]}"
	)
	local ssh_bin
	ssh_bin="$(find_next_in_path ssh)" || quit "Cannot find 'ssh' in PATH (other than this script)"
	set +e
	[ -n "${DEBUG}" ] && set -x
	# shellcheck disable=SC2029
	"${ssh_bin}" "${opt_args[@]}" "${pos_args[@]}"
	{ local status="$?"; [ -n "${DEBUG}" ] && set +x; } 2>/dev/null
	set -e
	return "${status}"
}

function print_scp_service_msg {
	local service="$1"
	local uuid="$2"
	echo "\
scp-uuid does not support the '--service' flag. However, files and folders
can be copied to a service container with 'ssh-uuid', for example:

# local -> remote
$ cat local.txt | ssh-uuid --service ${service} ${uuid}.balena cat \\> /data/remote.txt

# remote -> local
$ ssh-uuid --service ${service} ${uuid}.balena cat /data/remote.txt > local.txt

Or multiple files and folders with 'tar' on the fly:

# local -> remote
$ tar cz local-folder | ssh-uuid --service ${service} ${uuid}.balena tar xzvC /data/

# remote -> local
$ ssh-uuid --service ${service} ${uuid}.balena tar czC /data remote-folder | tar xvz

Or multiple files and folders with the powerful 'rsync' tool:

# local -> remote
$ rsync -av -e 'ssh-uuid --service ${service}' local-folder ${uuid}.balena:/data/

# remote -> local
$ rsync -av -e 'ssh-uuid --service ${service}' ${uuid}.balena:/data/remote-folder .

In these examples respectively, 'cat' or 'tar' or 'rsync' must be installed both
on the local workstation and on the remote service container:
$ apt-get install -y rsync tar  # Debian, Ubuntu, etc
$ apk add rsync tar  # Alpine

Finally, if you are transferring files to/from a service's named volume (often
named 'data'), note that named volumes are also exposed on the host OS under
folder: '/mnt/data/docker/volumes/<fleet-id>_data/_data/'
As such, it is also possible to scp to/from named volumes without '--service':

# local -> remote
$ scp-uuid -r local-folder ${uuid}.balena:/mnt/data/docker/volumes/<fleet-id>_data/_data/

# remote -> local
$ scp-uuid -r ${uuid}.balena:/mnt/data/docker/volumes/<fleet-id>_data/_data/remote-folder .
" >/dev/stderr
}

function run_scp {
	local scp_bin
	scp_bin="$(find_next_in_path scp)" || quit "Cannot find 'scp' in PATH (other than this script)"
	if [ -n "${SSUU_SERVICE}" ]; then
		if [ -n "${SSUU_FLAG_S}" ]; then
			quit "The '-S' and '--service' options cannot be used together"
		fi
		export SSUU_SERVICE
		set +e
		[ -n "${DEBUG}" ] && set -x
		"${scp_bin}" -S ssh-uuid "${SSUU_OPT_ARGS[@]}" "${SSUU_POS_ARGS[@]}"
		{ local status="$?"; [ -n "${DEBUG}" ] && set +x; } 2>/dev/null
		set -e
		return "${status}"
	fi
	# See the matching comment in run_ssh for tunnel vs. no-tunnel modes.
	local tunnel_args=()
	if [ -z "${SSUU_NO_BALENA_TUNNEL}" ]; then
		local proxy_host='%h'
		[ -n "${SSUU_BALENA_DEVICE_UUID}" ] && proxy_host="${SSUU_BALENA_DEVICE_UUID}.balena"
		tunnel_args=(
			-P 22222
			-o "ProxyCommand='$0' do_proxy ${proxy_host} %p"
		)
	fi
	args=(
		"${tunnel_args[@]}"
		"${SSUU_OPT_ARGS[@]}"
		"${SSUU_POS_ARGS[@]}"
	)
	set +e
	[ -n "${DEBUG}" ] && set -x
	"${scp_bin}" "${args[@]}"
	{ local status="$?"; [ -n "${DEBUG}" ] && set +x; } 2>/dev/null
	set -e
	return "${status}"
}

# Run socat
function do_proxy {
	local TARGET_HOST="$1"
	local TARGET_PORT="$2"
	local PROXY_AUTH_FILE="${BALENARC_DATA_DIRECTORY}/proxy-auth"
	local SOCAT_PORT
	SOCAT_PORT="$(get_rand_port_num)"
	mkdir -p "${BALENARC_DATA_DIRECTORY}" || quit "Cannot write to '${BALENARC_DATA_DIRECTORY}'"
	echo -n "${BALENA_USERNAME}:${BALENA_TOKEN}" > "${PROXY_AUTH_FILE}" || quit "Cannot write to '${PROXY_AUTH_FILE}'"
	[ -n "${DEBUG}" ] && set -x
	if [ -n "${SSUU_SOCAT_SUPPRESS_CRL_WARNING}" ]; then
		# CRL-check warning suppressed by user request (see README).
		socat "TCP-LISTEN:${SOCAT_PORT},bind=127.0.0.1" "OPENSSL:tunnel.balena-cloud.com:443,snihost=tunnel.balena-cloud.com" 2> >(grep -v "this implementation does not check CRLs" >&2) &
	else
		socat "TCP-LISTEN:${SOCAT_PORT},bind=127.0.0.1" "OPENSSL:tunnel.balena-cloud.com:443,snihost=tunnel.balena-cloud.com" &
	fi
	{ set +x; } 2>/dev/null
	sleep 1 # poor man's wait for the background socat process to be ready
	set +e
	[ -n "${DEBUG}" ] && set -x
	socat - "PROXY:127.0.0.1:${TARGET_HOST}:${TARGET_PORT},proxyport=${SOCAT_PORT},proxy-authorization-file=${PROXY_AUTH_FILE}"
	{ local status="$?"; [ -n "${DEBUG}" ] && set +x; } 2>/dev/null
	set -e
	local pid
	pid="$(jobs -p)"
	[ -n "${pid}" ] && kill "${pid}" && wait # shutdown background tunnel
	return "${status}"
}

# Generate a random, possibly unavailable, TCP port number between
# 10,000 and 65,535 using a shady, questionable algorithm that assumes,
# based on annecodtal evidencce, that port numbers lower than 10,000
# are less likely to be available.
# If the port number is already in use, socat will produce an error.
function get_rand_port_num {
	# In bash, "$RANDOM" produces a random integer between 0 and 32767.
	# RANDOM * 2 produces an even number reasonably evenly distributed
	# over the range from 0 to 65534, and then RANDOM % 2 adds 0 or 1.
	# '% 55536 + 10000' then coerces the range into 10,000 to 65,535.
	# (This spoils the even distribution, yes, but the real problem is
	#  ensuring that the port number is not in use. It does not need
	#  to be random, it needs to be available.)
	echo $(( (RANDOM * 2 + RANDOM % 2) % 55536 + 10000 ))
}

function check_tool {
	which "$1" &>/dev/null || quit "'$1' not found in PATH. Is it installed?"
}

# Locate the next executable named "$1" on PATH that is not this script
# itself. Needed when ssh-uuid.sh is symlinked as 'ssh' (or 'scp') on PATH
# — useful for tools that only honor a PATH-resolved 'ssh' — because our
# own subprocess call would otherwise resolve back to the symlink and
# recurse forever. The `-ef` test compares device/inode, so symlinks
# resolving to the same target as $0 are detected.
function find_next_in_path {
	local name="$1"
	local IFS=':'
	local p
	for p in $PATH; do
		[ -n "${p}" ] || continue
		[ -x "${p}/${name}" ] || continue
		[ "${p}/${name}" -ef "$0" ] && continue
		echo "${p}/${name}"
		return 0
	done
	return 1
}

function main {
	get_user_and_token  # populates BALENA_USERNAME/TOKEN if available; silent if not
	if [ "$1" = 'do_proxy' ]; then
		require_balena_auth  # do_proxy always needs balenaCloud auth
		shift
		do_proxy "$@"
	else
		SSUU_SCP='0'
		if [ "$(basename "$0")" = 'scp-uuid' ]; then
			SSUU_SCP='1'
		fi
		parse_args "$@"
		# Without --no-balena-tunnel, run_ssh/run_scp will inject the
		# ProxyCommand and require balenaCloud auth — surface a clear error
		# now if it is not configured.
		if [ -z "${SSUU_NO_BALENA_TUNNEL}" ]; then
			require_balena_auth
		fi
		# Propagate to the do_proxy sub-invocation (ssh's ProxyCommand) and
		# to any inner ssh-uuid re-invocation (e.g. via 'scp -S ssh-uuid').
		export SSUU_SOCAT_SUPPRESS_CRL_WARNING
		export SSUU_BALENA_DEVICE_UUID
		export SSUU_NO_BALENA_TUNNEL
		if [ "${SSUU_SCP}" = '1' ]; then
			run_scp "$@"
		else
			run_ssh "$@"
		fi
	fi
}

main "$@"
