#!/bin/sh
# Model-checks DurableSession.tla with TLC, confirms each witness is
# violated, and writes the state graphs drive.mjs walks against the code.
#
# Needs Java 11+ and tla2tools.jar:
#   brew install openjdk
#   mkdir -p ~/.local/share/tla
#   curl -fL -o ~/.local/share/tla/tla2tools.jar \
#     https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
#
# Then drive the code along the graphs:
#   bun drive.mjs send && bun drive.mjs lookup
set -eu
cd "$(dirname "$0")"

jar="${TLA2TOOLS_JAR:-$HOME/.local/share/tla/tla2tools.jar}"
[ -f "$jar" ] || { echo "tla2tools.jar not found at $jar (set TLA2TOOLS_JAR)" >&2; exit 2; }
java=""
for candidate in "${JAVA_HOME:+$JAVA_HOME/bin/java}" /opt/homebrew/opt/openjdk/bin/java /usr/local/opt/openjdk/bin/java "$(command -v java 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -version >/dev/null 2>&1; then java="$candidate"; break; fi
done
[ -n "$java" ] || { echo "no working Java runtime (set JAVA_HOME or brew install openjdk)" >&2; exit 2; }

work="${TMPDIR:-/tmp}/libfx-model-tlc"
mkdir -p "$work" graphs
status=0
for tool in send lookup; do
    echo "== DurableSession ($tool)"
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -deadlock -workers 1 -cleanup \
        -metadir "$work/$tool" -dump dot,actionlabels "graphs/$tool" \
        -config "DurableSession-$tool.cfg" DurableSession.tla > "$work/$tool.log" 2>&1; then
        cat "$work/$tool.log"; status=1; continue
    fi
    grep -E 'distinct states|depth of' "$work/$tool.log"
done
# Each witness must be violated: it shows the model reaches that state.
# NoSelfStop breaks TwoActiveNeedsFreeze: without the self-stop, two workers
# are active at once with no freeze at all.
for witness in UiInOrder NoStaleShown NotTwoActive NoSelfStop; do
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/w-$witness" \
        -config "Witness-$witness.cfg" DurableSession.tla 2>&1 | grep -q -E "Invariant ($witness|TwoActiveNeedsFreeze) is violated"; then
        echo "== witness $witness reached"
    else
        echo "== witness $witness NOT reached" >&2; status=1
    fi
done
exit "$status"
