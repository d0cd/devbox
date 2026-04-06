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

# Local CI: runs lint + unit tests (fast, no Docker required).
# GitHub Actions CI additionally builds images, scans them, and runs
# integration tests — see .github/workflows/ci.yml for the full pipeline.
ci: lint test
