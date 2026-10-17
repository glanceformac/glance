#!/bin/bash
# Show a long-running command as a capsule beside the Glance pill.
#   Scripts/glance-activity.sh "npm test" npm test
# Needs the glance-hook helper (installed with Glance). Never changes the command's exit code.
HOOK="${GLANCE_HOOK:-/Applications/Glance.app/Contents/MacOS/glance-hook}"
LABEL="$1"; shift
ID="cmd$$"
send() { [ -x "$HOOK" ] && printf '%s' "$1" | "$HOOK" >/dev/null 2>&1; true; }
send "{\"hook_event_name\":\"IslandActivity\",\"action\":\"start\",\"id\":\"$ID\",\"text\":\"$LABEL\",\"symbol\":\"terminal\",\"tint\":\"green\",\"elapsed\":true,\"ttl\":7200}"
"$@"; RC=$?
send "{\"hook_event_name\":\"IslandActivity\",\"action\":\"end\",\"id\":\"$ID\"}"
exit $RC
