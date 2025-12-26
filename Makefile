.PHONY: all build zephyria bench clean test help

# Default target
all: build

# Build both executables
build: zephyria bench

# Build the main zephyria node
zephyria:
	@echo "\033[1;34m[🔨] Building Zephyria Node...\033[0m"
	@go build -o zephyria main.go
	@echo "\033[1;32m[✓] Zephyria built successfully!\033[0m"

# Build the benchmark tool
bench:
	@echo "\033[1;34m[🔨] Building Benchmark Tool...\033[0m"
	@go build -o zephyria-bench ./cmd/bench
	@echo "\033[1;32m[✓] Benchmark tool built successfully!\033[0m"

# Run all tests
test:
	@echo "\033[1;34m[🧪] Running Tests...\033[0m"
	@go test ./...
	@echo "\033[1;32m[✓] All tests passed!\033[0m"

# Clean up binaries
clean:
	@echo "\033[1;31m[🧹] Cleaning build artifacts...\033[0m"
	@rm -f zephyria zephyria-bench
	@echo "\033[1;32m[✓] Cleanup complete.\033[0m"

# Show help
help:
	@echo "\033[1;36mZephyria Blockchain Build System\033[0m"
	@echo "--------------------------------"
	@echo "\033[1;33mUsage:\033[0m make [target]"
	@echo ""
	@echo "\033[1;33mAvailable Targets:\033[0m"
	@echo "  \033[1;32mbuild\033[0m     Build both executables (default)"
	@echo "  \033[1;32mzephyria\033[0m  Build the main node"
	@echo "  \033[1;32mbench\033[0m     Build the benchmark tool"
	@echo "  \033[1;32mtest\033[0m      Run all tests"
	@echo "  \033[1;32mclean\033[0m     Remove built binaries"
	@echo "  \033[1;32mhelp\033[0m      Show this help message"
