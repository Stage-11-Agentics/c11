#!/bin/sh
# c11-2.0:shim: the old name, kept for installed apps and other machines; runs c11-atlas-relay.sh.
# Its old variable names still work: C11H_<x> fills C11_<x> when that is unset. c11-2.0:shim
for _v in $(env | sed -n 's/^C11H_\([A-Za-z0-9_]*\)=.*/\1/p'); do # c11-2.0:shim
  eval "[ -n \"\${C11_$_v+x}\" ] || { C11_$_v=\"\${C11H_$_v}\"; export C11_$_v; }" # c11-2.0:shim
done
exec "$(cd "$(dirname "$0")" && pwd)/c11-atlas-relay.sh" "$@"
