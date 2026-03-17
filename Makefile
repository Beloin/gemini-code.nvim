PLENARY ?= $(HOME)/.local/share/nvim/site/pack/vendor/start/plenary.nvim
NVIM    ?= nvim

SPECS := \
	tests/server_spec.lua \
	tests/discovery_spec.lua \
	tests/context_spec.lua \
	tests/diff_spec.lua \
	tests/terminal_spec.lua

.PHONY: test test-% integration help

## Run the full test suite
test:
	@for spec in $(SPECS); do \
		$(NVIM) --headless \
			--cmd "set rtp+=.$(if $(wildcard $(PLENARY)),:$(PLENARY))" \
			-c "lua require('plenary.busted').run('$$spec')" \
			-c "qa!" 2>&1; \
	done

## Launch the interactive integration demo (opens Neovim with mock CLI)
integration:
	@bash tests/run_integration.sh

## Run a single spec file, e.g.: make test-terminal
test-%:
	$(NVIM) --headless \
		--cmd "set rtp+=.$(if $(wildcard $(PLENARY)),:$(PLENARY))" \
		-c "lua require('plenary.busted').run('tests/$*_spec.lua')" \
		-c "qa!"

help:
	@echo "Targets:"
	@echo "  make test            Run all specs"
	@echo "  make test-terminal   Run tests/terminal_spec.lua"
	@echo "  make test-server     Run tests/server_spec.lua"
	@echo "  make test-context    Run tests/context_spec.lua"
	@echo "  make test-discovery  Run tests/discovery_spec.lua"
	@echo "  make test-diff       Run tests/diff_spec.lua"
	@echo "  make integration     Launch interactive integration demo"
	@echo ""
	@echo "Overrides:"
	@echo "  PLENARY=/path/to/plenary.nvim  (default: $(PLENARY))"
	@echo "  NVIM=/path/to/nvim             (default: $(NVIM))"
