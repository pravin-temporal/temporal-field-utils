# Tracked and new (not ignored) files, so scripts are linted before `git add`.
# Falls back to find outside a git checkout (e.g. a downloaded archive).
SHELL_SCRIPTS := $(shell git ls-files --cached --others --exclude-standard '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './.git/*')
BATS_FILES := $(shell git ls-files --cached --others --exclude-standard '*.bats' 2>/dev/null || find . -name '*.bats' -not -path './.git/*')

# Bash used to run the tests; CI sets /bin/bash on macOS to cover bash 3.2.
TEST_BASH ?= bash

.PHONY: check lint test

check: lint test

lint:
	shellcheck $(SHELL_SCRIPTS) $(BATS_FILES)
	for f in $(SHELL_SCRIPTS); do bash -n "$$f" && zsh -n "$$f" || exit 1; done

test:
	TEST_SHELL=$(TEST_BASH) bats tests
	TEST_SHELL=zsh bats tests
