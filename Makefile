.PHONY: lint format stylua-lint stylua-format license-lint license-format test wc

DEFAULT_GOAL := lint

lint: stylua-lint license-lint

format: stylua-format license-format


stylua-lint:
	stylua --check .

stylua-format:
	stylua .


license-lint:
	@scripts/license-fix.sh lint

license-format:
	@scripts/license-fix.sh format

test:
	nvim --headless --clean -u ./scripts/minitest.lua

wc:
	@find lua/ plugin/ \
		-name '*.lua' \
		-not -path '*/filters/*' \
		-exec grep \
		-cve '^[[:space:]]*$$' \
		-e '^[[:space:]]*--' {} + \
		| awk -F: '{s+=$$2} END {print s " non-blank non-comment lines across " NR " files"}'