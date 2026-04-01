#!/bin/bash
# Demo mode launcher for Forge
# Builds and runs the app with selected demo mode for screenshots

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Forge Demo Mode Launcher ==="
echo ""

MODES=(
    "projectList|Sidebar with projects and workspaces"
    "agentActive|Agent mid-task with file changes"
    "diffReview|Inspector showing unified diff review"
    "splitPanes|Multiple split panes with agent activity"
)

echo "Select a demo mode:"
echo ""

for i in "${!MODES[@]}"; do
    mode="${MODES[$i]%%|*}"
    desc="${MODES[$i]#*|}"
    printf "  %d) %-16s - %s\n" $((i+1)) "$mode" "$desc"
done

echo ""
read -p "Enter choice [1-${#MODES[@]}]: " choice

if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#MODES[@]} ]; then
    echo "Invalid choice"
    exit 1
fi

SELECTED="${MODES[$((choice-1))]}"
SELECTED_MODE="${SELECTED%%|*}"
echo ""
echo "Selected: $SELECTED_MODE"
echo ""

# Kill any running Forge instances
echo "Killing any running Forge instances..."
pkill -x Forge 2>/dev/null || true
sleep 1

# Build Debug
echo "Building Forge (Debug)..."
cd "$PROJECT_DIR"
xcodebuild -project Forge.xcodeproj \
    -scheme Forge \
    -configuration Debug \
    -derivedDataPath build/demo \
    -quiet

APP_PATH="build/demo/Build/Products/Debug/Forge.app"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: Forge.app not found at $APP_PATH"
    exit 1
fi

echo "Launching with --demo $SELECTED_MODE..."
open "$APP_PATH" --args --demo "$SELECTED_MODE"

echo ""
echo "Done! Forge launched with demo mode: $SELECTED_MODE"
