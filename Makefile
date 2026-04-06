.PHONY: lint test test-shell test-python build ci

lint:
	pre-commit run --all-files

test: test-shell test-python

test-shell:
	bats tests/bats/

test-python:
	uv run --with pytest --with pyyaml --with mitmproxy pytest tests/pytest/ -v

build:
	docker build -t devbox-proxy:latest ./proxy
	docker build -t devbox-agent:latest .

smoke:
	@echo "Smoke test: start → shell ready → stop"
	@cd /tmp && devbox start . >/dev/null 2>&1
	@docker compose -f $(shell pwd)/docker-compose.yml ps -q agent 2>/dev/null | head -1 | \
		xargs -I{} docker exec {} test -f /tmp/.devbox-ready || \
		{ echo "FAIL: container not ready"; exit 1; }
	@docker compose -f $(shell pwd)/docker-compose.yml ps -q agent 2>/dev/null | head -1 | \
		xargs -I{} docker exec {} gosu devbox test -f /home/devbox/.zshrc || \
		{ echo "FAIL: .zshrc missing"; exit 1; }
	@cd /tmp && devbox stop >/dev/null 2>&1
	@echo "PASS"

# Local CI: runs lint + unit tests (fast, no Docker required).
# GitHub Actions CI additionally builds images, scans them, and runs
# integration tests — see .github/workflows/ci.yml for the full pipeline.
ci: lint test
