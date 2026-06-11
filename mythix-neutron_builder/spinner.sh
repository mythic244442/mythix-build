#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  mythix-neutron_builder • Clean Terminal Output Utility                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   source scripts/spinner.sh
#   execute_with_spinner "command_to_run" "Status Message" "path/to/logfile.log"

execute_with_spinner() {
    local cmd="$1"
    local message="$2"
    local log_file="$3"

    # Start the command in the background, piping all output to the log file
    eval "$cmd" > "$log_file" 2>&1 &
    local pid=$!

    local delay=0.1
    local spinstr='|/-\'

    # Hide the cursor for a cleaner look
    tput civis 2>/dev/null || true

    # Loop while the background process is running
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        # Print carriage return (\r) and clear line (\033[K) to overwrite the same line
        printf "\r\033[K\033[1;36m[%c]\033[0m %s  \033[2m(log: %s)\033[0m" "$spinstr" "$message" "$log_file"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done

    # Wait for the command to finish and grab its exit code
    wait "$pid"
    local exit_status=$?

    # Clear the spinner line and restore the cursor
    printf "\r\033[K"
    tput cnorm 2>/dev/null || true

    # Handle success/failure output
    if [ $exit_status -ne 0 ]; then
        printf "\033[1;31m[ ✘ ]\033[0m %s failed!\n" "$message"
        printf "\033[1;33m[INFO] Last 15 lines of log:\033[0m\n"
        tail -n 15 "$log_file"
        exit $exit_status
    else
        printf "\033[1;32m[ ✔ ]\033[0m %s\n" "$message"
    fi
}
