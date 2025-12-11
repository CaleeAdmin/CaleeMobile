#!/bin/bash

# Script to generate Pigeon code for Android and iOS
# Usage: ./scripts/generate_pigeon.sh

set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get the project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${GREEN}🚀 Generating Pigeon code...${NC}"

# Check if pigeon is installed
if ! command -v flutter &> /dev/null; then
    echo -e "${RED}❌ Flutter is not installed or not in PATH${NC}"
    exit 1
fi

# Change to project root
cd "$PROJECT_ROOT"

# Ensure dependencies are installed
echo -e "${YELLOW}📦 Installing dependencies...${NC}"
flutter pub get

# Generate Pigeon code
echo -e "${YELLOW}🔨 Running Pigeon code generator...${NC}"
flutter pub run pigeon --input pigeons/calendar_api.dart

# Check if files were generated
DART_OUTPUT="$PROJECT_ROOT/lib/core/platform/pigeon/calendar_api.g.dart"
KOTLIN_OUTPUT="$PROJECT_ROOT/android/app/src/main/kotlin/com/nextcloud/caleesync/CalendarApi.g.kt"
SWIFT_OUTPUT="$PROJECT_ROOT/ios/Runner/CalendarApi.g.swift"

echo -e "\n${GREEN}✅ Pigeon code generation completed!${NC}\n"

# Verify outputs
echo -e "${YELLOW}📋 Generated files:${NC}"
if [ -f "$DART_OUTPUT" ]; then
    echo -e "  ${GREEN}✓${NC} Dart: $DART_OUTPUT"
else
    echo -e "  ${RED}✗${NC} Dart: $DART_OUTPUT (not found)"
fi

if [ -f "$KOTLIN_OUTPUT" ]; then
    echo -e "  ${GREEN}✓${NC} Kotlin: $KOTLIN_OUTPUT"
else
    echo -e "  ${RED}✗${NC} Kotlin: $KOTLIN_OUTPUT (not found)"
fi

if [ -f "$SWIFT_OUTPUT" ]; then
    echo -e "  ${GREEN}✓${NC} Swift: $SWIFT_OUTPUT"
else
    echo -e "  ${RED}✗${NC} Swift: $SWIFT_OUTPUT (not found)"
fi

echo -e "\n${GREEN}✨ Done!${NC}"

