.PHONY: test lint check
lint:
	shellcheck bin/*
test:
	bats tests/
check: lint test