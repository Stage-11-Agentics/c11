# Source this to run an isolated herdr-core: own session, own state, own socket dir.
# Usage: RUN=<scratch dir> . hcenv.sh   (HC binary path in $HC, set below or override)
: "${RUN:?set RUN to a scratch directory}"
mkdir -p "$RUN/state" "$RUN/config"; mkdir -p /tmp/c11hc && chmod 700 /tmp/c11hc
export XDG_STATE_HOME="$RUN/state" XDG_CONFIG_HOME="$RUN/config" XDG_RUNTIME_DIR=/tmp/c11hc HC_SESSION=c11spike
# Socket: /tmp/c11hc/herdr-core/c11spike.sock (short path: Unix sockets cap at ~104 bytes)
# Stop and clean: "$HC" server stop; pgrep -fl herdr-core; /bin/rm -rf /tmp/c11hc
