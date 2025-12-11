.PHONY: pigeon generate-pigeon help

# Generate Pigeon code for Android and iOS
pigeon generate-pigeon:
	@echo "🚀 Generating Pigeon code..."
	@flutter pub get
	@flutter pub run pigeon --input pigeons/calendar_api.dart
	@echo "✅ Pigeon code generation completed!"

# Show help
help:
	@echo "Available commands:"
	@echo "  make pigeon        - Generate Pigeon code for Android and iOS"
	@echo "  make generate-pigeon - Alias for 'make pigeon'"

