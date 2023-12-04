log_exit() {
    echo "Error: $1" >&2
    exit 1
}

set_env_vars() {
    for var in "$@"; do
        local file_var="${var}_FILE"
        if [ -z "${!var}" ]; then
            if [ -n "${!file_var}" ]; then
                if [ -r "${!file_var}" ]; then
                    export "$var"="$(< "${!file_var}")"
                elif [ -f "${!file_var}" ]; then
                    log_exit "File specified in '$file_var' is not readable"
                else
                    log_exit "Couldn't find file specified in '$file_var'"
                fi
            elif [ -n "${ENV_VAR_DEFAULTS[$var]}" ]; then
                export "$var"="${ENV_VAR_DEFAULTS[$var]}"
            else
                log_exit "Required variable '$var[_FILE]' is unset"
            fi
        fi
    done
}
