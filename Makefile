SHELL := /usr/bin/env bash

VERSION := $(shell cat VERSION 2>/dev/null | tr -d '[:space:]')
# VERSION now contains 'v1.x.x', so BUNDLE_NAME will be 'process_health_v1.x.x'
BUNDLE_NAME ?= process_health_$(VERSION)
OUT ?= $(BUNDLE_NAME).tar.xz

.PHONY: bundle lint bash-n docs readme

readme:
	@sed -i 's/^\*\*Current version:\*\* .*/\*\*Current version:\*\* $(VERSION)/' README.md
	@echo "README.md updated to version $(VERSION)"

bundle: readme
	@echo "Creating $(OUT)"
	@if command -v go >/dev/null 2>&1; then \
	  echo "Building gsc_calc..."; \
	  go build -o gsc_calc gsc_calc.go; \
	  echo "Building gsc_vault..."; \
	  go build -o gsc_vault gsc_vault.go; \
	fi
	@tar -C . --exclude='./.git' --exclude='./.github' --exclude='*.tar.xz' --exclude='*.xz' --exclude='*.sha256' --exclude='./.' --exclude='./2026*' --exclude='./supportLogs*' --exclude='*.log' --exclude='*.log.*' --exclude='._*' -cJf "/tmp/$(OUT)" . && mv "/tmp/$(OUT)" "$(OUT)"
	@echo "Wrote $(OUT)"

docs:
	@echo "Generating docs/ (Markdown + PDF) from man pages"
	@mkdir -p docs
	@for f in man/man1/*.1 man/man7/*.7; do \
	    base=$$(basename "$$f" | sed 's/\.[0-9]$$//'); \
	    pandoc -f man -t gfm "$$f" -o "docs/$${base}.md" && echo "  MD  docs/$${base}.md"; \
	    groff -mandoc -T ps "$$f" | ps2pdf - "docs/$${base}.pdf" && echo "  PDF docs/$${base}.pdf"; \
	done

bash-n:
	@echo "Running bash -n on scripts"
	@find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n

lint:
	@echo "Running shellcheck (if installed)"
	@if command -v shellcheck >/dev/null 2>&1; then \
	  find . -type f -name '*.sh' -print0 | xargs -0 shellcheck; \
	else \
	  echo "shellcheck not installed"; \
	fi
