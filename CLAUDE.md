# CLAUDE.md

Project notes for assistants working on this repository. The user-facing
README is `README.md`; this file is for context and process when editing
the code.

## What this project is

`ssh-uuid` / `scp-uuid` is a thin bash wrapper around the standard `ssh` and
`scp` tools. It lets a user connect to a balenaOS device by its UUID
(`<uuid>.balena` hostname) by injecting a `ProxyCommand` that tunnels the
TCP stream through the balenaCloud backend via `socat`. The wrapper is
deliberately minimal: real ssh/scp options pass through unchanged, so all
of ssh's features (port forwarding, identity files, ProxyJump, etc.) work
normally.

The whole implementation is a single script: **`ssh-uuid.sh`**. The
`ssh-uuid` and `scp-uuid` commands are symlinks to it; the script inspects
`$(basename "$0")` at runtime to decide whether to act as ssh or scp.

## Architecture (one-pager)

```
ssh-uuid.sh
├── check_bash_version          requires bash >= 4.4
├── get_user_and_token          reads BALENA_USERNAME / BALENA_TOKEN
│                               (env or ~/.balena/cachedUsername)
├── parse_args
│     1. Pre-scan: extract every ssh-uuid-specific ("fake") option no
│        matter where it appears, and strip those tokens from args.
│        Sets SSUU_SERVICE, SSUU_BALENA_DEVICE_UUID,
│        SSUU_SOCAT_SUPPRESS_CRL_WARNING.
│     2. Main loop: identify the connection target and split args into
│        SSUU_OPT_ARGS (real ssh/scp options) and SSUU_POS_ARGS
│        (hostname + remote command). With an explicit UUID, real
│        options that appear after the host are also moved to
│        SSUU_OPT_ARGS so ssh consumes them locally instead of treating
│        them as part of the remote command.
├── run_ssh / run_scp
│     Compose the final argv: injects ProxyCommand, forces port 22222
│     (the balenaOS host SSH port), adds -l BALENA_USERNAME if no user
│     was given, and (with --service) wraps the remote command in a
│     balena-engine exec invocation that runs in the named container.
├── do_proxy
│     Invoked by ssh as the ProxyCommand; spins up a local socat that
│     tunnels through tunnel.balena-cloud.com using proxy authentication.
└── find_next_in_path
      Locates the real ssh/scp on PATH, skipping any entry whose file
      matches $0 (so symlinking ssh-uuid.sh as 'ssh' on PATH doesn't
      cause infinite recursion).
```

### Fake options (intercepted, never forwarded to ssh/scp)

| Long form                          | -o equivalent (also `-o KEY=VAL` split form)        |
|------------------------------------|-----------------------------------------------------|
| `--service <name>`                 | `-oBalenaService=<name>`                            |
| `--balena-device-uuid <uuid>`      | `-oBalenaDeviceUUID=<uuid>`                         |
| `--socat-suppress-crl-warning`     | `-oSocatSuppressCRLWarning=yes`                     |
| `--no-balena-tunnel`               | `-oBalenaTunnel=no`                                 |

The `-o`-style forms exist so the wrapper can be used as a drop-in
replacement for ssh in tools (e.g. Eternal Terminal, git, rsync) that
only allow customising `-o` options.

`--balena-device-uuid` decouples the balena tunnel target from the SSH
hostname on the cmdline. With it set, any non-flag arg is accepted as the
SSH connection target; the ProxyCommand hardcodes `<uuid>.balena` so the
tunnel routes to the explicit device regardless of what ssh thinks it is
connecting to.

`--no-balena-tunnel` is the opposite: skip the balena cloud proxy
entirely. The wrapper becomes a near-passthrough to ssh/scp (no
ProxyCommand, no forced port 22222, no `-l BALENA_USERNAME` default, no
BALENA_USERNAME/TOKEN requirement). `--service` still wraps remote
commands via `balena-engine exec`. Useful when the device is reachable
via another network (zerotier, tailscale, LAN) and only the
container-dispatch part of the wrapper is wanted. Mutually exclusive
with `--balena-device-uuid`.

## Key gotchas (when editing the script)

- **bash 4.4+ is required.** The script uses `declare -pf`, `readarray -t`,
  and `mapfile -d`. Don't introduce features that need an even newer bash.
- **`set -e` + `((expr))`**: the arithmetic-command form returns the OLD
  value, so `((i++))` evaluates to 0 on the first increment and trips
  `set -e`. Use `i=$((i+1))` (or guard with `|| true`) when incrementing
  inside a loop that runs with `set -e`. Existing pattern for index
  bumps inside `for` loops: `SSUU_X="${args[++i]}"` (pre-increment inside
  parameter expansion is safe because the arithmetic happens inside `$(( ))`
  context, which doesn't propagate exit status).
- **Symlinks as `ssh` on PATH.** Users may symlink `ssh-uuid.sh` as `ssh`
  for tools that only honour a PATH-resolved `ssh`. `find_next_in_path`
  prevents the resulting recursion via an `-ef` (same inode) check against
  `$0`. Anywhere we shell out to ssh/scp, use the resolved binary, not
  the bare name.
- **Env var propagation.** `scp -S ssh-uuid` spawns an inner ssh-uuid that
  re-parses its argv. Variables that affect parsing or runtime
  (`SSUU_SERVICE`, `SSUU_BALENA_DEVICE_UUID`,
  `SSUU_SOCAT_SUPPRESS_CRL_WARNING`) are `export`-ed in `main` so the
  inner invocation inherits them.

## How to test

The repository has two completely separate test suites. Run both when
changing parsing/composition logic; run the parsing tests alone for
pure-CLI changes.

### 1. Parsing tests — no device required

`tests/run_parsing_tests.sh`

Stubs out `ssh` and `scp` in a temporary sandbox and asserts on the argv
that `ssh-uuid.sh` composes for them. Covers:

- fake options before / after / interleaved with the hostname
- real ssh options before / after the hostname (must end up before host
  in the ssh argv)
- long-form vs `-o` style for every fake option
- `user@host` vs `-l user` (incl. `-l` after host)
- option-taking short flags after host (`-p 2022`, `-i /key`)
- short-flag tracking after host (`-N` after host must suppress `-t`)
- UUID validation (invalid UUID rejected; 32- and 62-char accepted)
- classic `<uuid>.balena` flow regressions
- scp variants

Run from anywhere:

```sh
tests/run_parsing_tests.sh
```

Exit code is 0 on full success, 1 if any case fails. No external setup or
network access is needed. Add a new `assert` line whenever you fix a
parsing bug, so the regression is captured.

### 2. Integration tests — require a live balenaOS device

`tests/run_tests.sh`

Talks to a real balenaOS device on the local network and a real
balenaCloud account. Configure by either:

- editing the `TEST_DEVICE_*` / `TEST_SERVICE*` vars at the top of the
  script, or
- creating `tests/test-config.sh` (sourced if present) and setting them
  there.

The device must be running a service whose container has `rsync`
installed. See the comments at the top of `tests/run_tests.sh` for the
exact requirements. These tests verify real ssh / scp / rsync round-trips
through the balena tunnel.

### 3. Lint — every change

`./lint.sh` (wraps `shellcheck -- *.sh tests/*.sh`).

Run after every code change. If shellcheck flags anything, fix the script
rather than disabling the rule, unless there's a concrete reason to
disable it locally (in which case use a narrowly-scoped `# shellcheck
disable=SCxxxx` comment with a one-line justification). On Debian/Ubuntu,
install shellcheck with `apt-get install shellcheck`; on macOS, `brew
install shellcheck`.

### Suggested order

1. Edit code.
2. `./lint.sh` — fix any warnings.
3. `tests/run_parsing_tests.sh` — must be 0 failures.
4. If the change touches argv composition, the ProxyCommand, or the
   `--service` wrapper, also run `tests/run_tests.sh` against a real
   device.
