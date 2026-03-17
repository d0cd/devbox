.PHONY: lint test test-shell test-python ci

lint:
	pre-commit run --all-files

test: test-shell test-python

test-shell:
	bats tests/bats/

test-python:
	python3 -m pytest tests/pytest/ -v

ci: lint test
