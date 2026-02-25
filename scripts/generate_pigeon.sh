#!/bin/bash

# Script to generate Pigeon code for Android and iOS
# Usage: ./scripts/generate_pigeon.sh

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CALENDAR_INPUT="lib/core/platform/pigeon/calendar_api.dart"
BACKGROUND_INPUT="lib/core/platform/pigeon/background_sync_api.dart"

echo -e "${GREEN}🚀 Generating Pigeon code...${NC}"

if ! command -v flutter &> /dev/null; then
  echo -e "${RED}❌ Flutter is not installed or not in PATH${NC}"
  exit 1
fi

cd "$PROJECT_ROOT"

echo -e "${YELLOW}📦 Installing dependencies...${NC}"
flutter pub get

echo -e "${YELLOW}🔨 Generating calendar Pigeon code...${NC}"
flutter pub run pigeon --input "$CALENDAR_INPUT"

echo -e "${YELLOW}🔨 Generating background-sync Pigeon code...${NC}"
flutter pub run pigeon --input "$BACKGROUND_INPUT"

verify_file() {
  local label="$1"
  local path="$2"
  if [ -f "$path" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}: $path"
  else
    echo -e "  ${RED}✗${NC} ${label}: $path (not found)"
  fi
}

echo -e "\n${GREEN}✅ Pigeon code generation completed!${NC}\n"
echo -e "${YELLOW}📋 Generated files:${NC}"
verify_file "Dart (calendar)" "$PROJECT_ROOT/lib/core/platform/pigeon/calendar_api.g.dart"
verify_file "Kotlin (calendar)" "$PROJECT_ROOT/android/app/src/main/kotlin/com/viso/caleesync/CalendarApi.g.kt"
verify_file "Swift (calendar)" "$PROJECT_ROOT/ios/Runner/CalendarApi.g.swift"
verify_file "Dart (background)" "$PROJECT_ROOT/lib/core/platform/pigeon/background_sync_api.g.dart"
verify_file "Kotlin (background)" "$PROJECT_ROOT/android/app/src/main/kotlin/com/viso/caleesync/BackgroundSyncApi.g.kt"
verify_file "Swift (background)" "$PROJECT_ROOT/ios/Runner/BackgroundSyncApi.g.swift"

echo -e "\n${GREEN}✨ Done!${NC}"
