#!/usr/bin/env bash

# AirTag / Find My BLE advertisement scanner with RSSI smoothing and
# approximate distance estimation, By B3770 B4r4j45
#
# Based conceptually on AirTag-scan.sh from:
# https://github.com/haxorthematrix/AirTag-tools
# Original AirTag beacon detection work by Larry Pesce (@haxorthematrix).
#
# Distance is estimated from BLE RSSI. It is not UWB ranging and is not a
# replacement for Apple's Precision Finding. Reflections, antenna orientation,
# obstacles, radio hardware, and calibration can cause large errors.

set -u
set -o pipefail

SCRIPT_NAME=${0##*/}

INTERFACE="hci0"
MODE="pretty"
RSSI_AT_1M="-59"
PATH_LOSS="2.2"
EMA_ALPHA="0.25"

SCAN_PID=""
DUMP_PID=""
DUMP_FD=""
CURSOR_HIDDEN=0

declare -a PRIVILEGE=()
declare -A T_TYPE=()
declare -A T_COUNT=()
declare -A T_RSSI=()
declare -A T_FILTERED=()
declare -A T_DISTANCE=()
declare -A T_PROXIMITY=()
declare -A T_SEEN=()
declare -A T_PAYLOAD=()

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [options]

Scan BLE advertisements for Apple AirTag / Find My payloads.

Output modes (the last one specified wins):
      --pretty              Readable output with the full payload (default)
      --table               Live table of unique devices
      --raw                 Full raw HCI event for every matching packet
      --csv                 CSV stream with a header row

Scanner and distance options:
  -i, --interface hciN      Bluetooth interface (default: hci0)
      --rssi1m DBM          Calibrated RSSI at one meter (default: -59)
      --path-loss N         Path-loss exponent, greater than 0 (default: 2.2)
      --ema ALPHA           EMA coefficient, greater than 0 and at most 1
                            (default: 0.25)
  -h, --help                Show this help and exit

Examples:
  sudo ./$SCRIPT_NAME --pretty
  sudo ./$SCRIPT_NAME --table --interface hci1
  sudo ./$SCRIPT_NAME --csv --rssi1m -62 --path-loss 2.6 --ema 0.20
  sudo ./$SCRIPT_NAME --raw

Distance model:
  distance = 10 ^ ((RSSI_AT_1M - filtered_RSSI) / (10 * PATH_LOSS))

The distance is an approximate BLE/RSSI estimate, not UWB ranging or
Apple Precision Finding. Calibrate RSSI_AT_1M for the receiver and environment.
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*" >&2
}

require_option_value() {
    local option=$1
    local value=${2-}
    [[ -n "$value" ]] || die "Option $option requires a value."
}

require_command() {
    local command_name=$1
    command -v "$command_name" >/dev/null 2>&1 || \
        die "Required command '$command_name' was not found in PATH."
}

is_number() {
    LC_ALL=C grep -Eq -- '^-?[0-9]+([.][0-9]+)?$' <<<"$1"
}

validate_configuration() {
    grep -Eq -- '^hci[0-9]+$' <<<"$INTERFACE" || \
        die "Invalid interface '$INTERFACE'; expected a name such as hci0."

    is_number "$RSSI_AT_1M" || \
        die "--rssi1m must be a number, for example -59 or -62.5."
    awk -v value="$RSSI_AT_1M" \
        'BEGIN { exit !(value >= -127 && value < 0) }' || \
        die "--rssi1m must be at least -127 and less than 0 dBm."

    is_number "$PATH_LOSS" || \
        die "--path-loss must be a positive number, for example 2.2."
    awk -v value="$PATH_LOSS" 'BEGIN { exit !(value > 0) }' || \
        die "--path-loss must be greater than 0."

    is_number "$EMA_ALPHA" || \
        die "--ema must be a number greater than 0 and at most 1."
    awk -v value="$EMA_ALPHA" \
        'BEGIN { exit !(value > 0 && value <= 1) }' || \
        die "--ema must be greater than 0 and at most 1."
}

check_dependencies() {
    local dependency
    for dependency in hcitool hcidump awk sed grep date sleep; do
        require_command "$dependency"
    done

    if [[ "$MODE" == "table" ]]; then
        require_command tput
        [[ -t 1 ]] || die "--table requires an interactive terminal."
        [[ -n "${TERM:-}" ]] || die "--table requires the TERM environment variable."
        tput cols >/dev/null 2>&1 || \
            die "Terminal capabilities are unavailable; use --pretty or --csv."
    fi

    if (( EUID != 0 )); then
        require_command sudo
        PRIVILEGE=(sudo)
    fi
}

calculate_ema() {
    local current=$1
    local previous=$2
    awk -v alpha="$EMA_ALPHA" -v current="$current" -v previous="$previous" \
        'BEGIN { printf "%.2f", (alpha * current) + ((1 - alpha) * previous) }'
}

estimate_distance() {
    local filtered_rssi=$1
    awk -v reference="$RSSI_AT_1M" -v rssi="$filtered_rssi" \
        -v exponent="$PATH_LOSS" \
        'BEGIN { printf "%.2f", 10 ^ ((reference - rssi) / (10 * exponent)) }'
}

classify_proximity() {
    local distance=$1
    awk -v distance="$distance" 'BEGIN {
        if (distance <= 1.0)      print "IMMEDIATE"
        else if (distance <= 3.0) print "NEAR"
        else if (distance <= 10)  print "FAR"
        else                      print "DISTANT"
    }'
}

detect_type() {
    local payload=$1

    # Apple manufacturer data (0x004C), Find My type 0x12, length 0x19.
    if [[ "$payload" =~ (^|[[:space:]])FF[[:space:]]4C[[:space:]]00[[:space:]]12[[:space:]]19([[:space:]]|$) ]]; then
        printf 'REGISTERED'
        return 0
    fi

    # AirTag setup / unregistered advertisement used by the original scanner.
    if [[ "$payload" =~ (^|[[:space:]])FF[[:space:]]4C[[:space:]]00[[:space:]]07[[:space:]]19([[:space:]]|$) ]]; then
        printf 'UNREGISTERED'
        return 0
    fi

    return 1
}

redraw_table() {
    local mac distance_display

    tput cup 0 0
    tput ed
    printf ' AirTag / Find My scanner on %s | %d unique device(s) | Ctrl-C to exit\n' \
        "$INTERFACE" "${#T_COUNT[@]}"
    printf ' RSSI distance is approximate BLE ranging, not UWB Precision Finding.\n\n'
    printf ' %-17s %-12s %7s %6s %8s %9s %-10s %-9s\n' \
        'MAC' 'TYPE' 'COUNT' 'RSSI' 'AVG' 'DIST' 'PROXIMITY' 'LAST SEEN'
    printf ' %-17s %-12s %7s %6s %8s %9s %-10s %-9s\n' \
        '-----------------' '------------' '-------' '------' '--------' \
        '---------' '----------' '---------'

    for mac in "${!T_COUNT[@]}"; do
        if [[ "${T_DISTANCE[$mac]}" == "N/A" ]]; then
            distance_display="N/A"
        else
            distance_display="${T_DISTANCE[$mac]}m"
        fi
        printf ' %-17s %-12s %7s %6s %8s %9s %-10s %-9s\n' \
            "$mac" "${T_TYPE[$mac]}" "${T_COUNT[$mac]}" \
            "${T_RSSI[$mac]}" "${T_FILTERED[$mac]}" "$distance_display" \
            "${T_PROXIMITY[$mac]}" "${T_SEEN[$mac]}"
    done
}

emit_pretty() {
    local timestamp=$1
    local mac=$2
    local type=$3
    local rssi=$4
    local filtered=$5
    local distance=$6
    local proximity=$7
    local count=$8
    local payload=$9

    printf '[%s] %-12s %s RSSI: %4s dBm  EMA: %7s dBm  DIST: %8s m  %-9s  COUNT: %d\n' \
        "$timestamp" "$type" "$mac" "$rssi" "$filtered" "$distance" \
        "$proximity" "$count"
    printf '  Payload: %s\n' "$payload"
}

emit_csv() {
    local timestamp=$1
    local mac=$2
    local type=$3
    local rssi=$4
    local filtered=$5
    local distance=$6
    local proximity=$7
    local count=$8
    local payload=$9

    # Payload only contains normalized hexadecimal bytes and spaces, so quoting
    # it is sufficient for a valid CSV field.
    printf '%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
        "$timestamp" "$mac" "$type" "$rssi" "$filtered" "$distance" \
        "$proximity" "$count" "$payload"
}

record_detection() {
    local mac=$1
    local type=$2
    local rssi=$3
    local payload=$4
    local timestamp seen previous filtered distance proximity count

    timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
    seen=${timestamp:11:8}
    count=$(( ${T_COUNT[$mac]:-0} + 1 ))

    if [[ "$rssi" == "N/A" ]]; then
        filtered="N/A"
        distance="N/A"
        proximity="UNKNOWN"
    else
        previous=${T_FILTERED[$mac]-}
        if [[ -z "$previous" || "$previous" == "N/A" ]]; then
            filtered=$(awk -v value="$rssi" 'BEGIN { printf "%.2f", value }')
        else
            filtered=$(calculate_ema "$rssi" "$previous")
        fi
        distance=$(estimate_distance "$filtered")
        proximity=$(classify_proximity "$distance")
    fi

    T_TYPE[$mac]=$type
    T_COUNT[$mac]=$count
    T_RSSI[$mac]=$rssi
    T_FILTERED[$mac]=$filtered
    T_DISTANCE[$mac]=$distance
    T_PROXIMITY[$mac]=$proximity
    T_SEEN[$mac]=$seen
    T_PAYLOAD[$mac]=$payload

    case "$MODE" in
        pretty)
            emit_pretty "$timestamp" "$mac" "$type" "$rssi" "$filtered" \
                "$distance" "$proximity" "$count" "$payload"
            ;;
        csv)
            emit_csv "$timestamp" "$mac" "$type" "$rssi" "$filtered" \
                "$distance" "$proximity" "$count" "$payload"
            ;;
        table)
            redraw_table
            ;;
        raw)
            # The complete HCI packet is emitted once by parse_hci_event().
            ;;
    esac
}

process_advertising_report() {
    local packet=$1
    local report_start=$2
    local data_length=$3
    local rssi_index=$4
    local -a bytes=()
    local mac payload="" type rssi_byte rssi_value rssi i data_start

    read -r -a bytes <<<"$packet"
    data_start=$((report_start + 9))

    mac=$(printf '%s:%s:%s:%s:%s:%s' \
        "${bytes[$((report_start + 7))]}" \
        "${bytes[$((report_start + 6))]}" \
        "${bytes[$((report_start + 5))]}" \
        "${bytes[$((report_start + 4))]}" \
        "${bytes[$((report_start + 3))]}" \
        "${bytes[$((report_start + 2))]}")

    for ((i = 0; i < data_length; i++)); do
        payload+="${payload:+ }${bytes[$((data_start + i))]}"
    done

    type=$(detect_type "$payload") || return 1

    rssi_byte=${bytes[$rssi_index]}
    rssi_value=$((16#$rssi_byte))
    if (( rssi_value == 127 )); then
        # The Bluetooth specification reserves 0x7F for unavailable RSSI.
        rssi="N/A"
    else
        (( rssi_value > 127 )) && rssi_value=$((rssi_value - 256))
        rssi=$rssi_value
    fi

    record_detection "$mac" "$type" "$rssi" "$payload"
    return 0
}

normalize_packet() {
    local input=$1
    local token normalized=""
    local -a raw_bytes=()

    read -r -a raw_bytes <<<"$input"
    ((${#raw_bytes[@]} >= 15)) || return 1

    for token in "${raw_bytes[@]}"; do
        token=${token^^}
        [[ "$token" =~ ^[0-9A-F]{2}$ ]] || return 1
        normalized+="${normalized:+ }$token"
    done

    printf '%s' "$normalized"
}

parse_hci_event() {
    local input_packet=$1
    local packet
    local -a bytes=()
    local report_count report_index report_start data_length_index
    local data_length rssi_index raw_match=0 total_bytes

    packet=$(normalize_packet "$input_packet") || return 0
    read -r -a bytes <<<"$packet"
    total_bytes=${#bytes[@]}

    # HCI packet type 0x04, LE Meta Event 0x3E, Advertising Report 0x02.
    [[ "${bytes[0]}" == "04" && "${bytes[1]}" == "3E" && \
       "${bytes[3]}" == "02" ]] || return 0

    report_count=$((16#${bytes[4]}))
    report_start=5

    for ((report_index = 0; report_index < report_count; report_index++)); do
        data_length_index=$((report_start + 8))
        (( data_length_index < total_bytes )) || break

        data_length=$((16#${bytes[$data_length_index]}))
        rssi_index=$((report_start + 9 + data_length))
        (( rssi_index < total_bytes )) || break

        if process_advertising_report "$packet" "$report_start" \
            "$data_length" "$rssi_index"; then
            raw_match=1
        fi

        report_start=$((rssi_index + 1))
    done

    if [[ "$MODE" == "raw" && "$raw_match" -eq 1 ]]; then
        printf '%s\n' "$packet"
    fi
}

parse_stream() {
    local line clean packet="" capturing=0

    if [[ "$MODE" == "csv" ]]; then
        printf 'timestamp,mac,type,rssi,rssi_filtered,distance,proximity,count,payload\n'
    elif [[ "$MODE" == "table" ]]; then
        tput civis
        CURSOR_HIDDEN=1
        tput clear
        redraw_table
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == '>'* ]]; then
            if (( capturing )); then
                parse_hci_event "$packet"
            fi
            clean=$(sed -E \
                's/^>[[:space:]]*//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' \
                <<<"$line")
            if [[ "$clean" =~ ^[[:xdigit:]]{2}([[:space:]]+[[:xdigit:]]{2})*$ ]]; then
                packet=$clean
                capturing=1
            else
                packet=""
                capturing=0
            fi
        elif (( capturing )); then
            clean=$(sed -E \
                's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' \
                <<<"$line")
            if [[ "$clean" =~ ^[[:xdigit:]]{2}([[:space:]]+[[:xdigit:]]{2})*$ ]]; then
                packet+=" $clean"
            else
                parse_hci_event "$packet"
                packet=""
                capturing=0
            fi
        fi
    done

    if (( capturing )); then
        parse_hci_event "$packet"
    fi
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP

    if [[ -n "$SCAN_PID" ]] && kill -0 "$SCAN_PID" 2>/dev/null; then
        kill "$SCAN_PID" 2>/dev/null || true
    fi
    if [[ -n "$DUMP_PID" ]] && kill -0 "$DUMP_PID" 2>/dev/null; then
        kill "$DUMP_PID" 2>/dev/null || true
    fi

    if [[ -n "$SCAN_PID" ]]; then
        wait "$SCAN_PID" 2>/dev/null || true
    fi
    if [[ -n "$DUMP_PID" ]]; then
        wait "$DUMP_PID" 2>/dev/null || true
    fi

    if (( CURSOR_HIDDEN )); then
        tput cnorm 2>/dev/null || true
        printf '\n'
    fi

    exit "$status"
}

handle_signal() {
    exit "$1"
}

start_scanner() {
    local dump_status

    if (( EUID != 0 )); then
        info "Bluetooth scanning needs elevated privileges; requesting sudo access."
        "${PRIVILEGE[0]}" -v || die "Unable to obtain sudo privileges."
    fi

    if command -v hciconfig >/dev/null 2>&1; then
        "${PRIVILEGE[@]}" hciconfig "$INTERFACE" up || \
            die "Failed to bring up Bluetooth interface $INTERFACE."
    else
        info "Warning: hciconfig was not found; $INTERFACE must already be up."
    fi

    info "Scanning on $INTERFACE (mode: $MODE, RSSI@1m: $RSSI_AT_1M dBm, path-loss: $PATH_LOSS, EMA: $EMA_ALPHA)."
    info "Distance values are BLE/RSSI estimates, not UWB Precision Finding. Press Ctrl-C to stop."

    coproc HCIDUMP_PROCESS {
        "${PRIVILEGE[@]}" hcidump -i "$INTERFACE" --raw
    }
    DUMP_PID=$HCIDUMP_PROCESS_PID
    DUMP_FD=${HCIDUMP_PROCESS[0]}

    "${PRIVILEGE[@]}" hcitool -i "$INTERFACE" lescan --duplicates \
        >/dev/null 2>&1 &
    SCAN_PID=$!

    sleep 1
    kill -0 "$DUMP_PID" 2>/dev/null || \
        die "hcidump failed to start on $INTERFACE."
    kill -0 "$SCAN_PID" 2>/dev/null || \
        die "hcitool lescan failed to start on $INTERFACE."

    parse_stream <&"$DUMP_FD"

    wait "$DUMP_PID" 2>/dev/null
    dump_status=$?
    if (( dump_status != 0 )); then
        die "hcidump stopped with status $dump_status."
    fi
    die "hcidump stopped unexpectedly."
}

main() {
    if (( BASH_VERSINFO[0] < 4 )); then
        die "Bash 4 or newer is required for per-device associative arrays."
    fi

    while (($# > 0)); do
        case "$1" in
            -i|--interface)
                require_option_value "$1" "${2-}"
                INTERFACE=$2
                shift 2
                ;;
            --rssi1m)
                require_option_value "$1" "${2-}"
                RSSI_AT_1M=$2
                shift 2
                ;;
            --path-loss)
                require_option_value "$1" "${2-}"
                PATH_LOSS=$2
                shift 2
                ;;
            --ema)
                require_option_value "$1" "${2-}"
                EMA_ALPHA=$2
                shift 2
                ;;
            --pretty)
                MODE="pretty"
                shift
                ;;
            --table)
                MODE="table"
                shift
                ;;
            --raw)
                MODE="raw"
                shift
                ;;
            --csv)
                MODE="csv"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                (($# == 0)) || die "Unexpected positional argument '$1'."
                ;;
            -*|--*)
                die "Unknown option '$1'. Run $SCRIPT_NAME --help for usage."
                ;;
            *)
                die "Unexpected positional argument '$1'. Run $SCRIPT_NAME --help for usage."
                ;;
        esac
    done

    check_dependencies
    validate_configuration

    trap cleanup EXIT
    trap 'handle_signal 130' INT
    trap 'handle_signal 143' TERM
    trap 'handle_signal 129' HUP

    start_scanner
}

main "$@"
