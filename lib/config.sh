#!/usr/bin/env bash
# lib/config.sh — YAML config loading for task-drain.
#
# Config file: ~/.task-drain/config.yaml (also $DRAIN_CONFIG if set)
#
# Supported YAML subset:
#   key: value          (string, int, bool, null)
#   key:                (nested map, 2-space indent)
#   # comments
#
# Example:
#   remotes:
#     llama:
#       ssh: /home/hatch/bin/llama-ssh
#       git_root: /Users/lou/git
#   default_remote: llama
#   worker:
#     allow_sudo: true
#
# Keys are flattened with dots: remotes.llama.ssh, worker.allow_sudo
# Environment variables DRAIN_CONFIG_<PATH> (dots→underscores, uppercase)
# override config file values. E.g. DRAIN_CONFIG_WORKER_ALLOW_SUDO=1.

_DRAIN_CONFIG_LOADED=""

# _config_parse <file> — print KEY=value lines (flattened with dots)
_config_parse() {
	python3 - "$1" << 'PYEOF'
import sys, re

def parse_value(s):
    s = s.strip()
    if s in ('', '~', 'null', 'Null', 'NULL'):
        return ''
    if s in ('true', 'True', 'TRUE', 'yes', 'Yes', 'YES'):
        return 'true'
    if s in ('false', 'False', 'FALSE', 'no', 'No', 'NO'):
        return 'false'
    # quoted strings
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ('"', "'"):
        return s[1:-1]
    return s

def parse_file(path):
    result = {}
    # stack of (indent, key_prefix)
    stack = [(-1, '')]
    try:
        with open(path) as f:
            lines = f.readlines()
    except FileNotFoundError:
        return result
    for raw in lines:
        # strip comments (naive: # not in quotes)
        line = raw.rstrip('\n')
        stripped = line.lstrip()
        if not stripped or stripped.startswith('#'):
            continue
        indent = len(line) - len(stripped)
        # remove inline comments
        # find # not inside quotes
        in_s = None
        cut = len(stripped)
        for i, ch in enumerate(stripped):
            if in_s:
                if ch == in_s:
                    in_s = None
            elif ch in ('"', "'"):
                in_s = ch
            elif ch == '#':
                cut = i
                break
        stripped = stripped[:cut].rstrip()
        if not stripped or ':' not in stripped:
            continue
        key, _, val = stripped.partition(':')
        key = key.strip()
        val = val.strip()
        # pop stack to parent indent
        while stack and stack[-1][0] >= indent:
            stack.pop()
        prefix = stack[-1][1] if stack else ''
        full = f"{prefix}.{key}" if prefix else key
        if val == '':
            # nested map
            stack.append((indent, full))
        else:
            result[full] = parse_value(val)
    return result

for k, v in parse_file(sys.argv[1]).items():
    # flatten: lowercase, dots/dashes -> underscores for valid shell var names
    var = 'DRAIN_CFG_' + k.lower().replace('.', '_').replace('-', '_')
    v_esc = v.replace("'", "'\\''")
    print(f"{var}='{v_esc}'")
PYEOF
}

# load_config — populate DRAIN_CFG_* vars from config file.
# Env overrides: DRAIN_CONFIG_<UPPER_DOTS_TO_UNDERSCORES> wins.
load_config() {
	[ -n "$_DRAIN_CONFIG_LOADED" ] && return 0
	_DRAIN_CONFIG_LOADED=1
	local cfg="${DRAIN_CONFIG:-$HOME/.task-drain/config.yaml}"
	if [ -f "$cfg" ]; then
		eval "$(_config_parse "$cfg")"
	fi
	# Env overrides: DRAIN_CONFIG_FOO_BAR -> DRAIN_CFG_foo.bar
	local var cfgkey
	for var in $(compgen -v DRAIN_CONFIG_ 2>/dev/null); do
		[ "$var" = "DRAIN_CONFIG" ] && continue
		cfgkey=$(echo "${var#DRAIN_CONFIG_}" | tr '[:upper:]' '[:lower:]' | tr '_' '.')
		# shellcheck disable=SC2086
		eval "DRAIN_CFG_${cfgkey//./_}=\"\${$var}\""
		# also set dotted form via assoc if available — simpler: set both
		eval "DRAIN_CFG_DOT_${cfgkey}=\"\${$var}\""
	done
}

# config_get <dotted.key> [default] — print the config value.
config_get() {
	load_config
	local key="$1" def="${2:-}"
	# normalize: dots and dashes -> underscores, lowercase
	local norm
	norm=$(echo "$key" | tr '[:upper:]' '[:lower:]' | tr '.-' '__')
	local var="DRAIN_CFG_${norm}"
	local val
	eval "val=\"\${$var:-}\""
	if [ -n "$val" ]; then
		printf '%s' "$val"
		return 0
	fi
	printf '%s' "$def"
}

# config_get_bool <dotted.key> [default] — normalize to 0/1.
config_get_bool() {
	local v
	v=$(config_get "$1" "${2:-false}")
	case "$v" in
		1|true|True|TRUE|yes|Yes|YES) echo 1 ;;
		*) echo 0 ;;
	esac
}
