# org-agenda-api development commands

# Production API base URL
prod_url := "https://colonelpanic-org-agenda.fly.dev"
pass_entry := "colonelpanic-org-agenda.fly.dev"

# Run authenticated curl against production API
prod *args:
    @curl -s -u "$(pass show {{pass_entry}} | grep '^user:' | cut -d' ' -f2):$(pass show {{pass_entry}} | head -1)" {{prod_url}}{{args}} | jq

# Health check
health:
    @just prod /health

# Get API version
version:
    @just prod /version

# Get all todos
todos:
    @just prod /get-all-todos

# Get today's agenda
today:
    @just prod /get-todays-agenda

# Get agenda with optional span (day/week)
agenda span="day":
    @just prod "/agenda?span={{span}}"

# Get capture templates
templates:
    @just prod /capture-templates

# Get agenda files
files:
    @just prod /agenda-files

# Get metadata
metadata:
    @just prod /metadata

# Get filter options
filters:
    @just prod /filter-options

# Get todo states
states:
    @just prod /todo-states

# Run pytest
test *args:
    pytest tests/ {{args}}

# Lint Python files
lint:
    ruff check tests/

# Format check Python files
format-check:
    ruff format --check tests/

# Byte-compile elisp
compile:
    emacs --batch -f batch-byte-compile org-agenda-api.el
