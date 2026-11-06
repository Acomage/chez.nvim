NVIM ?= nvim
CHEZ ?= chez

.PHONY: test test-lua test-scheme generate

test: test-scheme test-lua

test-lua:
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/lua { minimal_init = 'tests/minimal_init.lua', sequential = true }"

test-scheme:
	@for f in tests/scheme/*.ss; do \
		[ -e "$$f" ] || continue; \
		echo "== $$f"; \
		$(CHEZ) --libdirs scheme --script "$$f" || exit 1; \
	done

# Regenerate data/builtins.json and queries/scheme/highlights.scm
generate:
	$(CHEZ) --libdirs scheme --script scheme/gen-builtins.ss > data/builtins.json
	$(NVIM) -l scripts/gen-highlights.lua

# Regenerate data/docs.json:
#   CSUG      = csug/ of https://github.com/cisco/ChezScheme
#   CSUG_HTML = directory with https://cisco.github.io/ChezScheme/csug/<chapter>.html
#   R6RS      = r6rs/document/ of https://www.r6rs.org/final/r6rs.tar.gz
docs:
	$(NVIM) -l scripts/gen-docs.lua $(CSUG) $(CSUG_HTML) $(R6RS)

.PHONY: docs
