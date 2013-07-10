#!/bin/bash

rightPad() {
  padding=$1
  shift
  str="$*"
  pad=$(( $padding - ${#str} ))
  printf "%s%${pad}s" "$str" ""
}

formatBytes() {
  bytes="$1"
  padding=$2
  [ ! -z "$padding" ] || padding=0

  num=$(( $1 + 0 ))
  div=1
  units=""
  if [ $num -gt $(( 1024 ** 3 )) ]; then
    div=$(( 1024 ** 3 ))
    units="GiB"
  elif [ $num -gt $(( 1024 * 1024 )) ]; then
    div=$(( 1024 * 1024 ))
    units="MiB"
  elif [ $num -gt $(( 1024 )) ]; then
    div=1024
    units="KiB"
  fi

  if [ -z "$units" ]; then
    ret="$num"B
  else
    ret=$(( ( num * 100 ) / div ))
    ind=$(( ${#ret} - 2 ))
    ret="${ret:0:$ind}.${ret:$ind}${units}"
  fi

  echo -n "$ret"
  pad=$(( $padding - ${#ret} ))
  if [ $pad -gt 0 ]; then
    printf "%${pad}s" " "
  fi
  echo
}

# Tries to connect to keychain, invalidates SSH_AGENT vars if it cannot.
try_keychain() {
  keyfile="$HOME/.keychain/$HOSTNAME-sh"
  [ ! -f "$keyfile" ] || source "$keyfile"
  if [ -z "$SSH_AUTH_SOCK" ] || \
     [ -z "$SSH_AGENT_PID" ] || \
     [ ! -e "$SSH_AUTH_SOCK" ] || \
     [ -z "$(ps -p "$SSH_AGENT_PID" -o comm=)" ]; then
    unset SSH_AUTH_SOCK
    unset SSH_AGENT_PID
    return 1
  fi
  return 0
}

sh_c()
{
  [ ! -z "$NEPH_COLOR_TERM" ] || return
  local c="$1"
  local b="$2"
  [ ! -z "$c" ] || c=0
  [ ! -z "$b" ] || [ $c -eq 0 ] || b=0
  [ -z "$b" ] || b="$b;"
  echo -n -e "\e[$b${c}m"
}

prettyquote()
{
  local args=()
  for arg in "$@"; do
    if [ "$arg" != "$(printf '%q' "$arg")" ]; then
      arg="'${arg//'/'\\''}'"
    fi
    args[${#args[@]}]="$arg"
  done
  echo "${args[@]}"
}

estat() { echo >&2 "$(sh_c 32 1)::$(sh_c) $*"; }
ewarn() { echo >&2 "$(sh_c 33 1);;$(sh_c) $*"; }
eerr() { echo >&2 "$(sh_c 31 1)!!$(sh_c) $*"; }

cmd() { echo >&2 "$(sh_c 30 1)+$(sh_c) $(prettyquote "$@")"; "$@"; }
qcmd() { cmd "$@" >/dev/null; }
xcmd() { cmd "$@" &>/dev/null; }

die() { eerr "$*"; exit 1; }

# Tries to find the running session for this user and steals its
# DISPLAY/XAUTHORITY env
get_x_session()
{
  pid=$(pgrep -o -u $USER gnome-session || true)
  [ -z "$pid" ] && pid=$(pgrep -o -u $USER xfce4-session || true)
  [ -z "$pid" ] && pid=$(pgrep -o -u $USER kded4 || true)
  if [ ! -z "$pid" ]; then
    echo >&2 ":: Stealing env from $pid"
    export $(cat /proc/$pid/environ | grep -z XAUTHORITY)
    export $(cat /proc/$pid/environ | grep -z DISPLAY)
  else
      export XAUTHORITY=$HOME/.Xauthority
  fi
  [ ! -z "$DISPLAY" ] || export DISPLAY=:0
  [ ! -z "$XAUTHORITY" ] || export XAUTHORITY=$HOME/.Xauthority
}

# Prints eval-able expression to set given variable, e.g.:
# sh_var DISPLAY -> "DISPLAY=':0'"
sh_var()
{
  eval local ret="\$$1"
  echo $1=\'${ret//\'/\'\\\'\'}\';
}

parse_args()
{
  if [ "$#" -lt 3 ]; then
    eerr "Internal error: incorrect usage of parse_args"
    return
  fi
  [ "$#" -gt 3 ] || return

  local app_name="$1"
  local short_opts="$2"
  local long_opts="$3"

  shift; shift; shift

  _parse_args_options=()
  _parse_args_values=()
  local args=()
  local parsed

  if ! parsed="$(getopt -n "$app_name" -o "$short_opts" -l "$long_opts" -- "$@")"; then
    return 1
  fi
  eval parsed=("$parsed")
  local i=0
  while [ $i -lt ${#parsed[@]} ]; do
    local arg="${parsed[$i]}"
    local opt
    local val
    (( ++i ))
    if [ ${#arg} -lt 2 ] || [ "${arg:0:1}" != "-" ]; then
      eerr "Internal error: Unexpected arg \"$arg\" while parsing getopt output"
      continue
    fi
    if [ "$arg" = "--" ]; then # end of options
      args=("${parsed[@]:$i}")
      break
    elif [ "${arg:1:1}" = "-" ]; then # long opt
      local opt_name="${arg:2}"
      local IFS=","
      for x in ${long_opts}; do
        if [ "${x:$(( ${#x} - 1 ))}" = ":" ] &&
           [ "${x:0:$(( ${#x} - 1 ))}" = "$opt_name" ]; then
          # arg long opt
          opt="$opt_name"
          val="${parsed[$i]}"
          (( ++i ))
          opt_name=""
          continue
        elif [ "$x" = "$opt_name" ]; then
          # boolean long opt
          opt="$opt_name"
          val=1
          opt_name=""
          continue
        fi
      done
      if [ ! -z "$opt_name" ]; then
        eerr "Internal error: Failed to find opt \"$opt_name\""
      fi
    elif [ ${#arg} -eq 2 ]; then # short opt
      local shorts="$short_opts"
      while [ ! -z "$shorts" ] && [ "${shorts:0:1}" != "${arg:1:1}" ]; do
        shorts="${shorts:1}"
      done
      if [ -z "$shorts" ]; then
        eerr "Internal error: Unfound short option $arg"
      else
        if [ "${shorts:1:1}" = ":" ]; then
          # arg short opt
          opt="${arg:1:1}"
          val="${parsed[$i]}"
          (( ++i ))
        else
          # bool short opt
          opt="${arg:1:1}"
          val=1
        fi
      fi
    fi
    _parse_args_options[${#_parse_args_options[@]}]="$opt"
    _parse_args_values[${#_parse_args_values[@]}]="$val"
  done
  for x in "${args[@]}"; do
    echo -n \'${x//\'/\'\\\'\'}\'' '
  done
}

get_option()
{
  local opt_name="$1"
  local default="$2"
  local i=0
  while [ $i -lt ${#_parse_args_options[@]} ]; do
    if [ "${_parse_args_options[$i]}" = "$opt_name" ]; then
      echo "${_parse_args_values[$i]}"
      return
    fi
    (( ++i ))
  done
  echo "$default"
}
