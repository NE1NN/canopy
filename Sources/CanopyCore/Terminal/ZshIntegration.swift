import Foundation

/// Canopy's zsh startup shim, which reports each command that finishes to the activity log. zsh terminals start with
/// ZDOTDIR pointing at its folder, and the user's own ZDOTDIR, if any, in CANOPY_USER_ZDOTDIR. It puts ZDOTDIR back and
/// loads the user's .zshenv, so zsh then reads the user's .zprofile, .zshrc, and .zlogin from their usual place, and
/// the user's setup is unchanged.
public enum ZshIntegration {
    /// The private OSC code of the shim's command reports.
    public static let reportCode = 6973

    /// Writes the shim into CANOPY_HOME/shell/zsh, if it changed, and returns the folder for ZDOTDIR.
    public static func install(in home: CanopyHome) throws -> String {
        try home.ensureExists()
        let folder = home.zshShimFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: ".zshenv")
        if (try? String(contentsOf: file, encoding: .utf8)) != script {
            try script.write(to: file, atomically: true, encoding: .utf8)
        }
        return folder.path
    }

    static let script = #"""
        # Written by Canopy, which starts zsh with ZDOTDIR pointing here. This puts your own ZDOTDIR back and loads
        # your .zshenv, so zsh reads your .zprofile, .zshrc, and .zlogin as usual. It also reports each command that
        # finishes to Canopy's activity log. "logCommands": false in Canopy's config.json turns this off.

        builtin typeset -g _canopy_token=${CANOPY_COMMAND_TOKEN-}
        if [[ -n ${CANOPY_USER_ZDOTDIR+set} ]]; then
            builtin export ZDOTDIR="$CANOPY_USER_ZDOTDIR"
        else
            builtin unset ZDOTDIR
        fi
        builtin unset CANOPY_COMMAND_TOKEN CANOPY_USER_ZDOTDIR

        # Defined before your .zshenv runs, so none of your aliases can reach into them.
        if [[ -n $_canopy_token && -o interactive ]]; then
            builtin zmodload -F zsh/datetime p:EPOCHREALTIME 2>/dev/null

            # Percent-encodes %, ;, and control characters, so any text fits in a report.
            _canopy_encode() {
                builtin emulate -L zsh
                local text=$1 code
                text=${text//\%/%25}
                text=${text//;/%3B}
                for code in {1..31} 127; do
                    text=${text//${(#)code}/%${(l:2::0:)$(( [##16] code ))}}
                done
                typeset -g _canopy_encoded=$text
            }

            # Each hook puts the other back if the user's .zshrc replaced its list, so logging survives that.
            _canopy_preexec() {
                # A leading space keeps a command out of history under hist_ignore_space, so out of the log too.
                local skip=0
                [[ -o hist_ignore_space ]] && skip=1
                builtin emulate -L zsh
                (( ${precmd_functions[(I)_canopy_precmd]} )) || precmd_functions+=(_canopy_precmd)
                (( skip )) && [[ $1 == ' '* ]] && return
                # zsh never writes lines matching HISTORY_IGNORE to the history file.
                [[ -n ${HISTORY_IGNORE-} && $1 == ${~HISTORY_IGNORE} ]] && return
                typeset -g _canopy_command=$1 _canopy_cwd=$PWD _canopy_started=${EPOCHREALTIME-}
            }

            _canopy_precmd() {
                local code=$?
                builtin emulate -L zsh
                (( ${preexec_functions[(I)_canopy_preexec]} )) || preexec_functions+=(_canopy_preexec)
                [[ -n ${_canopy_command+set} ]] || return 0
                local ms=
                if [[ -n $_canopy_started && -n ${EPOCHREALTIME-} ]]; then
                    local -i elapsed
                    (( elapsed = (EPOCHREALTIME - _canopy_started) * 1000 ))
                    ms=$elapsed
                fi
                _canopy_encode $_canopy_command
                local command=$_canopy_encoded
                _canopy_encode $_canopy_cwd
                builtin print -rn -- $'\e]\#(reportCode);command;'"$_canopy_token;$code;$ms;$command;$_canopy_encoded"$'\a'
                builtin unset _canopy_command _canopy_cwd _canopy_started
            }

            precmd_functions+=(_canopy_precmd)
            preexec_functions+=(_canopy_preexec)
        fi

        # zsh's own rule: a ZDOTDIR that is set, even to nothing, is used instead of HOME.
        [[ -f ${ZDOTDIR-$HOME}/.zshenv ]] && builtin source "${ZDOTDIR-$HOME}/.zshenv"
        """#
}
