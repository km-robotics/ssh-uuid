#!/usr/bin/env bash

# Copyright 2026 Balena Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0

# Parsing-only tests for ssh-uuid.sh.
#
# Unlike tests/run_tests.sh — which talks to a real balenaOS device — this
# script tests just the wrapper's command-line parsing and the argv it
# composes for the underlying ssh/scp. Stubs stand in for ssh/scp and echo
# their argv; assertions then check that:
#
#   * "fake" options (--service, --balena-device-uuid,
#     --socat-suppress-crl-warning, and their -o equivalents) are intercepted
#     and NEVER reach ssh/scp;
#   * real ssh options are forwarded and end up BEFORE the host so ssh
#     consumes them locally (not as part of the remote command);
#   * positional handling stays correct across mixed orderings.
#
# Run from anywhere — the script discovers its own location and the
# repository root. No external configuration or network access is required.
#
# Usage:
#   tests/run_parsing_tests.sh
#
# Exit code: 0 on full success, 1 if any case failed.

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${REPO_DIR}/ssh-uuid.sh"

if [ ! -x "${SCRIPT}" ]; then
	echo "ssh-uuid.sh not found or not executable at ${SCRIPT}" >&2
	exit 1
fi

# Sandbox with stub ssh/scp first on PATH, plus ssh-uuid/scp-uuid symlinks
# so the wrapper's basename-based mode detection picks the right mode.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT

cat > "${SANDBOX}/ssh" <<'STUB'
#!/usr/bin/env bash
printf 'ssh-called'
for a in "$@"; do printf '\t%s' "$a"; done
printf '\n'
STUB
cat > "${SANDBOX}/scp" <<'STUB'
#!/usr/bin/env bash
printf 'scp-called'
for a in "$@"; do printf '\t%s' "$a"; done
printf '\n'
STUB
chmod +x "${SANDBOX}/ssh" "${SANDBOX}/scp"
ln -s "${SCRIPT}" "${SANDBOX}/ssh-uuid"
ln -s "${SCRIPT}" "${SANDBOX}/scp-uuid"

# Fake auth state so the wrapper proceeds past get_user_and_token without
# needing ~/.balena or balena CLI.
export BALENA_USERNAME='testuser'
export BALENA_TOKEN='testtok'
export PATH="${SANDBOX}:${PATH}"

UUID32='00d019bc1e4db605c4d36ac4565a1c25'
UUID62='ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
CLASSIC_HOST="${UUID32}.balena"

# Tokens that should NEVER reach the underlying ssh/scp argv.
FAKE_LEAKS=(
	'-oBalenaService='
	'-oBalenaDeviceUUID='
	'-oSocatSuppressCRLWarning='
	'-oBalenaTunnel='
	'--service'
	'--balena-device-uuid'
	'--socat-suppress-crl-warning'
	'--no-balena-tunnel'
	'BalenaService='
	'BalenaDeviceUUID='
	'SocatSuppressCRLWarning='
	'BalenaTunnel='
)

PASS=0
FAIL=0
FAILED_LABELS=()

# Return 0 if `needle` appears as a tab-delimited token in `hay`. If the
# needle ends in '=' it is treated as a prefix (matches any token starting
# with it, e.g. '-oBalenaService=' matches '-oBalenaService=svc'). Otherwise
# the match is exact. Padded with tabs so first/last tokens match too.
# Implemented with bash glob matching, not grep, so newlines inside tokens
# (the --service wrapper injects multi-line function bodies) don't break it.
has_token() {
	local needle="$1"
	local hay="$2"
	local sep=$'\t'
	local padded="${sep}${hay}${sep}"
	if [[ "${needle}" == *= ]]; then
		# shellcheck disable=SC2053
		[[ "${padded}" == *"${sep}${needle}"* ]]
	else
		# shellcheck disable=SC2053
		[[ "${padded}" == *"${sep}${needle}${sep}"* ]]
	fi
}

# Run a command and assert on the resulting ssh/scp argv.
#
# Usage:
#   assert "<label>" "<must_have>" "<must_not>" -- <cmd...>
#
# `must_have` is a semicolon-separated list of substrings; each must appear
# somewhere in the argv (substring match — useful for matching multi-token
# fragments like 'ProxyCommand=...'). `must_not` is a semicolon-separated
# list of forbidden tokens, checked with has_token (exact or prefix).
# The fake-option leak check is always applied on top.
assert() {
	local label="$1"; shift
	local must_have="$1"; shift
	local must_not="$1"; shift
	[ "${1:-}" = '--' ] && shift
	local out
	out="$("$@" 2>&1)"
	# Strip the leading "ssh-called\t" / "scp-called\t" emitted by the stub.
	local argv="${out#*-called$'\t'}"

	local ok=1 why=''
	local tok
	if [ -n "${must_have}" ]; then
		local IFS=';'
		for tok in ${must_have}; do
			[ -z "${tok}" ] && continue
			if ! printf '%s' "${argv}" | grep -qF -- "${tok}"; then
				ok=0; why+=" MISSING<${tok}>"
			fi
		done
	fi
	for tok in "${FAKE_LEAKS[@]}"; do
		if has_token "${tok}" "${argv}"; then
			ok=0; why+=" LEAKED<${tok}>"
		fi
	done
	if [ -n "${must_not}" ]; then
		local IFS=';'
		for tok in ${must_not}; do
			[ -z "${tok}" ] && continue
			if has_token "${tok}" "${argv}"; then
				ok=0; why+=" UNWANTED<${tok}>"
			fi
		done
	fi
	if [ "${ok}" = 1 ]; then
		PASS=$((PASS+1))
		printf '  PASS  %s\n' "${label}"
	else
		FAIL=$((FAIL+1))
		FAILED_LABELS+=("${label}")
		printf '  FAIL  %s --%s\n' "${label}" "${why}"
		printf '        argv: %s\n' "${argv}"
	fi
}

# The wrapper's ProxyCommand embeds $0, which when invoked via PATH expands
# to the full path of the ssh-uuid/scp-uuid symlink in our sandbox. Match
# only the part that does not depend on that path.
PROXY_EXPLICIT="do_proxy ${UUID32}.balena"
PROXY_CLASSIC='do_proxy %h %p'

echo '--- fake-option position (explicit UUID) ---'
assert 'fake -o ALL before host' \
	"${PROXY_EXPLICIT};jakub2@localhost;echo;hi" '' -- \
	ssh-uuid -oBalenaService=svc -oBalenaDeviceUUID=${UUID32} -oSocatSuppressCRLWarning=yes \
		jakub2@localhost echo hi

assert "fake -o ALL after host (user's reported case)" \
	"${PROXY_EXPLICIT};-oStrictHostKeyChecking=no;-oUserKnownHostsFile=/dev/null;jakub2@localhost;echo;hello" '' -- \
	ssh-uuid jakub2@localhost -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null \
		-oBalenaService=svc -oSocatSuppressCRLWarning=yes -oBalenaDeviceUUID=${UUID32} \
		echo hello

assert 'fake -o interleaved with real -o and host' \
	"${PROXY_EXPLICIT};-oStrictHostKeyChecking=no;-oUserKnownHostsFile=/dev/null;jakub2@localhost;echo;hi" '' -- \
	ssh-uuid -oBalenaService=svc -oStrictHostKeyChecking=no \
		-oBalenaDeviceUUID=${UUID32} jakub2@localhost \
		-oUserKnownHostsFile=/dev/null -oSocatSuppressCRLWarning=yes echo hi

echo '--- long-form flags (--service, --balena-device-uuid, --socat-...) ---'
assert '--service before classic host' \
	"${PROXY_CLASSIC};${CLASSIC_HOST}" '' -- \
	ssh-uuid --service svc "${CLASSIC_HOST}" echo hi

assert '--service AFTER classic host' \
	"${PROXY_CLASSIC};${CLASSIC_HOST}" '' -- \
	ssh-uuid "${CLASSIC_HOST}" --service svc echo hi

assert '--balena-device-uuid before host' \
	"${PROXY_EXPLICIT};jakub2@localhost;echo" '' -- \
	ssh-uuid --balena-device-uuid "${UUID32}" jakub2@localhost echo hi

assert '--balena-device-uuid AFTER host' \
	"${PROXY_EXPLICIT};jakub2@localhost;echo" '' -- \
	ssh-uuid jakub2@localhost --balena-device-uuid "${UUID32}" echo hi

assert 'all three long-forms after host' \
	"${PROXY_EXPLICIT};jakub2@localhost;echo" '' -- \
	ssh-uuid jakub2@localhost --service svc --balena-device-uuid "${UUID32}" \
		--socat-suppress-crl-warning echo hi

echo '--- -o split form (-o KEY=VAL as two tokens) ---'
assert '-o BalenaDeviceUUID= split form' \
	"${PROXY_EXPLICIT};jakub2@localhost" '' -- \
	ssh-uuid -o BalenaDeviceUUID="${UUID32}" jakub2@localhost echo hi

assert '-o BalenaService= split form, before host' \
	"${PROXY_EXPLICIT};jakub2@localhost" '' -- \
	ssh-uuid -o BalenaService=svc -oBalenaDeviceUUID="${UUID32}" jakub2@localhost echo hi

assert '-o SocatSuppressCRLWarning=yes split form' \
	"${PROXY_EXPLICIT};jakub2@localhost" '' -- \
	ssh-uuid -oBalenaDeviceUUID="${UUID32}" -o SocatSuppressCRLWarning=yes \
		jakub2@localhost echo hi

echo '--- user spec variants ---'
assert 'user@host (no -l injection)' \
	"${PROXY_EXPLICIT};jakub2@localhost" '-l' -- \
	ssh-uuid --balena-device-uuid "${UUID32}" jakub2@localhost echo hi

assert 'bare host -> -l BALENA_USERNAME injected' \
	"${PROXY_EXPLICIT};-l;testuser;localhost" '' -- \
	ssh-uuid --balena-device-uuid "${UUID32}" localhost echo hi

assert '-l user before host (no duplicate -l)' \
	"${PROXY_EXPLICIT};-l;myuser;localhost;echo" 'testuser' -- \
	ssh-uuid --balena-device-uuid "${UUID32}" -l myuser localhost echo hi

assert '-l user AFTER host (no duplicate -l)' \
	"${PROXY_EXPLICIT};-l;myuser;localhost;echo" 'testuser' -- \
	ssh-uuid --balena-device-uuid "${UUID32}" localhost -l myuser echo hi

echo '--- option-taking short flags after host ---'
assert '-p 2022 after host (separate value)' \
	"${PROXY_EXPLICIT};-p;2022;jakub2@localhost;echo" '' -- \
	ssh-uuid --balena-device-uuid "${UUID32}" jakub2@localhost -p 2022 echo

assert '-i /key after host (separate value)' \
	"${PROXY_EXPLICIT};-i;/k/file;jakub2@localhost;echo" '' -- \
	ssh-uuid --balena-device-uuid "${UUID32}" jakub2@localhost -i /k/file echo

echo '--- post-host short-flag tracking (parse_short_flag) ---'
assert '-N after host + --service: no -t injected' \
	"${PROXY_EXPLICIT};-N;jakub2@localhost" '-t' -- \
	ssh-uuid -oBalenaService=svc -oBalenaDeviceUUID="${UUID32}" jakub2@localhost -N

assert 'no -N, --service, no remote cmd: -t IS injected' \
	"${PROXY_EXPLICIT};-t;jakub2@localhost" '' -- \
	ssh-uuid -oBalenaService=svc -oBalenaDeviceUUID="${UUID32}" jakub2@localhost

echo '--- classic UUID.balena flow regressions ---'
assert 'classic, no remote cmd' \
	"${PROXY_CLASSIC};-l;testuser;${CLASSIC_HOST}" '' -- \
	ssh-uuid "${CLASSIC_HOST}"

assert 'classic + --service + cmd' \
	"${PROXY_CLASSIC};${CLASSIC_HOST}" '' -- \
	ssh-uuid --service svc "${CLASSIC_HOST}" cat /etc/issue

assert 'classic + real -o before host' \
	"${PROXY_CLASSIC};-oStrictHostKeyChecking=no;${CLASSIC_HOST}" '' -- \
	ssh-uuid -oStrictHostKeyChecking=no "${CLASSIC_HOST}" ls

echo '--- scp variants ---'
assert 'scp explicit UUID, fake mixed' \
	"do_proxy ${UUID32}.balena;local.txt;jakub2@localhost:/dst" '' -- \
	scp-uuid -oBalenaDeviceUUID="${UUID32}" local.txt -oSocatSuppressCRLWarning=yes \
		jakub2@localhost:/dst

assert 'scp classic UUID.balena (no --service)' \
	"${UUID32}.balena:/dst" '' -- \
	scp-uuid local.txt "${UUID32}.balena:/dst"

echo '--- --no-balena-tunnel (skip balena cloud proxy) ---'
# Without the tunnel, NONE of these tunnel-mode tokens should appear:
# the ProxyCommand, the forced -p 22222 / -P 22222, or the auto-injected
# `-l BALENA_USERNAME`. The user's args otherwise pass through unchanged.
NO_TUNNEL_FORBIDDEN='ProxyCommand=;-p 22222;-P 22222;-l;testuser'

assert '--no-balena-tunnel + --service: ProxyCommand etc. skipped' \
	'remote__main;svc;myhost' "${NO_TUNNEL_FORBIDDEN}" -- \
	ssh-uuid --no-balena-tunnel --service svc myhost echo hi

assert '--no-balena-tunnel (no --service): bare passthrough' \
	'myhost;echo;hi' "${NO_TUNNEL_FORBIDDEN}" -- \
	ssh-uuid --no-balena-tunnel myhost echo hi

assert '-oBalenaTunnel=no equivalent' \
	'myhost;echo' "${NO_TUNNEL_FORBIDDEN}" -- \
	ssh-uuid -oBalenaTunnel=no myhost echo hi

assert '-o BalenaTunnel=no split form' \
	'myhost;echo' "${NO_TUNNEL_FORBIDDEN}" -- \
	ssh-uuid -o BalenaTunnel=no myhost echo hi

assert '--no-balena-tunnel + custom -p preserved (no forced 22222)' \
	'-p;2022;myhost;echo' '-p 22222' -- \
	ssh-uuid --no-balena-tunnel -p 2022 myhost echo

assert '--no-balena-tunnel + user@host: user untouched' \
	'jakub2@myhost' "${NO_TUNNEL_FORBIDDEN}" -- \
	ssh-uuid --no-balena-tunnel jakub2@myhost echo

assert '--no-balena-tunnel + bare host: no -l injection' \
	'myhost' "${NO_TUNNEL_FORBIDDEN}" -- \
	ssh-uuid --no-balena-tunnel myhost echo

assert '--no-balena-tunnel: real -o options after host still sifted to opts' \
	'-oStrictHostKeyChecking=no;myhost;echo' "${NO_TUNNEL_FORBIDDEN}" -- \
	ssh-uuid --no-balena-tunnel myhost -oStrictHostKeyChecking=no echo

assert 'scp --no-balena-tunnel: no ProxyCommand / -P 22222' \
	'local.txt;myhost:/dst' "${NO_TUNNEL_FORBIDDEN}" -- \
	scp-uuid --no-balena-tunnel local.txt myhost:/dst

# Without BALENA_USERNAME/TOKEN the tunnel mode would error out; no-tunnel
# mode must succeed and produce normal ssh argv.
nt_out="$(env -u BALENA_USERNAME -u BALENA_TOKEN ssh-uuid --no-balena-tunnel myhost echo hi 2>&1 || true)"
if printf '%s' "${nt_out}" | grep -q 'ssh-called' && \
   ! printf '%s' "${nt_out}" | grep -q "ERROR"; then
	PASS=$((PASS+1))
	printf '  PASS  --no-balena-tunnel works without BALENA_USERNAME/TOKEN\n'
else
	FAIL=$((FAIL+1))
	FAILED_LABELS+=('--no-balena-tunnel works without BALENA_USERNAME/TOKEN')
	printf '  FAIL  --no-balena-tunnel without BALENA_*: out=%s\n' "${nt_out}"
fi

# Mutually exclusive with --balena-device-uuid: must error clearly.
conflict_out="$(ssh-uuid --no-balena-tunnel --balena-device-uuid "${UUID32}" host 2>&1 || true)"
if printf '%s' "${conflict_out}" | grep -q 'mutually exclusive'; then
	PASS=$((PASS+1))
	printf '  PASS  --no-balena-tunnel + --balena-device-uuid rejected\n'
else
	FAIL=$((FAIL+1))
	FAILED_LABELS+=('--no-balena-tunnel + --balena-device-uuid rejected')
	printf '  FAIL  mutual-exclusion check missing -- out: %s\n' "${conflict_out}"
fi

echo '--- UUID validation ---'
val_out="$(ssh-uuid --balena-device-uuid not-a-uuid host 2>&1 || true)"
if printf '%s' "${val_out}" | grep -q 'Invalid balena device UUID'; then
	PASS=$((PASS+1))
	printf '  PASS  invalid UUID rejected with clear error\n'
else
	FAIL=$((FAIL+1))
	FAILED_LABELS+=('invalid UUID rejected with clear error')
	printf '  FAIL  invalid UUID rejection -- output: %s\n' "${val_out}"
fi

assert '62-char UUID accepted' \
	"${UUID62}.balena" '' -- \
	ssh-uuid --balena-device-uuid "${UUID62}" jakub2@localhost echo

echo
printf 'TOTAL: %d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
	echo 'FAILED:'
	for label in "${FAILED_LABELS[@]}"; do
		printf '  - %s\n' "${label}"
	done
	exit 1
fi
