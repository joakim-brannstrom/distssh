# distssh(1) completion -*- shell-script -*-

_distcmd()
{
    local cur prev words cword split
    _init_completion -s || return

    # case "$prev" in
    #     -h|--help)
    #         return 0
    #         ;;
    # esac

    if [[ "$prev" == "distcmd" && $cword -eq 1 ]]; then
        COMPREPLY=($(compgen ))
    fi

    return
} &&
complete -o bashdefault -o dirnames -o plusdirs -D -F _distcmd distcmd
