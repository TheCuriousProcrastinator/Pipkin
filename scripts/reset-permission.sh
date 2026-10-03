#!/bin/bash
#
set -euo pipefail

BUNDLE_ID="com.thecuriousprocrastinator.Pipkin"
APP_NAME="Pipkin"
EXEC="pipkin"   #  App pkill -x

echo "[reset-permission] Quitting running $APP_NAME ..."
pkill -x "$EXEC" 2>/dev/null || true

for service in ScreenCapture Accessibility; do
    if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "[reset-permission] Reset $service"
    else
        echo "[reset-permission] Could not reset $service; there may be no existing record"
    fi
done

echo "[reset-permission] Done. macOS will request permission again on the next launch."
echo "[reset-permission] Tip: install the app in /Applications to keep its path stable."
