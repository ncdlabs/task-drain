# lib/display.sh — shared terminal display functions for task-drain.sh
# Sourced by task-drain.sh. Do not run directly.

# Terminal setup: color only on a TTY, respect NO_COLOR
drain_terminal_setup() {
	local use_color=0
	if [ -n "${DRAIN_FORCE_COLOR:-}" ] && [ -z "${NO_COLOR:-}" ]; then
		use_color=1
	elif [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
		use_color=1
	fi
	DRAIN_B=""
	DRAIN_C=""
	DRAIN_G=""
	DRAIN_Y=""
	DRAIN_R=""
	DRAIN_M=""
	DRAIN_DIM=""
	DRAIN_RESET=""
	if [ "$use_color" = 1 ]; then
		DRAIN_B=$'\033[1m'
		DRAIN_C=$'\033[36m'
		DRAIN_G=$'\033[32m'
		DRAIN_Y=$'\033[33m'
		DRAIN_R=$'\033[31m'
		DRAIN_M=$'\033[35m'
		DRAIN_DIM=$'\033[2m'
		DRAIN_RESET=$'\033[0m'
	fi
	DRAIN_COLS=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
	[[ "$DRAIN_COLS" =~ ^[0-9]+$ ]] || DRAIN_COLS=80
	[ "$DRAIN_COLS" -ge 40 ] || DRAIN_COLS=40
	[ "$DRAIN_COLS" -le 200 ] || DRAIN_COLS=200
}

drain_divider() {
	local i
	for ((i = 0; i < DRAIN_COLS; i++)); do printf '─'; done
	printf '\n'
}

drain_section() { printf '\n%s%s%s%s%s\n' "$DRAIN_B" "$DRAIN_C" "$1" "$DRAIN_RESET" ""; }

drain_trunc_str() { # $1=text $2=maxlen
	local s="$1" max="$2"
	if [ "${#s}" -gt "$max" ]; then printf '%s…' "${s:0:$((max - 1))}"; else printf '%s' "$s"; fi
}

drain_bar() { # $1=n $2=max $3=width
	local n="$1" max="$2" width="${3:-18}" fill empty i
	[[ "$n" =~ ^[0-9]+$ ]] || n=0
	[[ "$max" =~ ^[0-9]+$ ]] || max=1
	[ "$max" -ge 1 ] || max=1
	fill=$((n * width / max))
	[ "$fill" -gt "$width" ] && fill=$width
	empty=$((width - fill))
	for ((i = 0; i < fill; i++)); do printf '█'; done
	for ((i = 0; i < empty; i++)); do printf '░'; done
}

drain_meter() { # $1=elapsed_sec $2=budget_sec $3=width -> capped bar
	local el="$1" budget="$2" width="${3:-14}" fill empty i
	[[ "$el" =~ ^[0-9]+$ ]] || el=0
	[[ "$budget" =~ ^[0-9]+$ ]] || budget=1
	[ "$budget" -ge 1 ] || budget=1
	fill=$((el * width / budget))
	[ "$fill" -gt "$width" ] && fill=$width
	empty=$((width - fill))
	for ((i = 0; i < fill; i++)); do printf '█'; done
	for ((i = 0; i < empty; i++)); do printf '░'; done
}

drain_fmt_dur() { # $1=sec -> 45s / 12m / 3h / 2d ; unknown -> ?
	local s="$1"
	[[ "$s" =~ ^[0-9]+$ ]] || {
		printf '?'
		return
	}
	if [ "$s" -lt 60 ]; then
		printf '%ss' "$s"
	elif [ "$s" -lt 7200 ]; then
		printf '%sm' "$((s / 60))"
	elif [ "$s" -lt 172800 ]; then
		printf '%sh' "$((s / 3600))"
	else
		printf '%sd' "$((s / 86400))"
	fi
}

drain_dur() { # seconds -> 45s / 12m / 3h / 15d / ?
	local s="$1"
	[[ "$s" =~ ^[0-9]+$ ]] || {
		printf '?'
		return
	}
	if [ "$s" -lt 90 ]; then
		printf '%ss' "$s"
	elif [ "$s" -lt 5400 ]; then
		printf '%sm' "$((s / 60))"
	elif [ "$s" -lt 172800 ]; then
		printf '%sh' "$((s / 3600))"
	else
		printf '%sd' "$((s / 86400))"
	fi
}
