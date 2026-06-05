#!/bin/bash

alias nginx="docker exec -i docker_nginx nginx"
alias dspa="docker system prune -a"
alias dc="bash /root/.docker_tools/dc.sh"
alias dcs="bash /root/.docker_tools/dcstats.sh"
alias dcps="bash /root/.docker_tools/dcps.sh"
alias dcip="bash /root/.docker_tools/dcip.sh"
alias dclogs="bash /root/.docker_tools/dclogs.sh"
alias dr="bash /root/.docker_tools/drestart.sh"
alias dcr="bash /root/.docker_tools/dcrestart.sh"

unalias dlogs dexec 2>/dev/null

dlogs() {
    bash "/root/.docker_tools/dlogs.sh" "$@"
}

dexec() {
    bash "/root/.docker_tools/dexec.sh" "$@"
}

_docker_tools_container_names() {
    local current="${COMP_WORDS[COMP_CWORD]}"
    local containers=()
    local i name candidate index
    mapfile -t containers < <(docker ps --format '{{.Names}}' 2>/dev/null)
    compopt -o nosort 2>/dev/null || true
    COMPREPLY=()
    for i in "${!containers[@]}"; do
        index=$((i + 1))
        name="${containers[$i]}"
        candidate="${index}. ${name}"
        if [ -z "$current" ] || [[ "$candidate" == "$current"* ]] || [[ "$name" == "$current"* ]] || [[ "$index" == "$current"* ]]; then
            COMPREPLY+=("$candidate")
        fi
    done
}

complete -F _docker_tools_container_names dlogs dexec
