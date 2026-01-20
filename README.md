# org-agenda-api

A JSON HTTP API for accessing and manipulating org-agenda data in GNU Emacs. Enables external applications to read and manage TODO items, scheduled items, and deadlines programmatically.

## Features

- REST-like JSON API for org-mode data
- Docker container with supervisord process management
- Git synchronization for org files
- Caching with automatic invalidation
- Custom capture templates
- Health monitoring

## Quick Start

### Docker (Recommended)

Build and run the container:

```bash
nix build .#container
docker load < result
docker run -p 8080:80 -v /path/to/org:/data/org org-agenda-api
```

With git sync:

```bash
docker run -p 8080:80 \
  -e GIT_SYNC_REPOSITORY=git@github.com:user/org-files.git \
  -v /path/to/ssh_key:/secrets/ssh_key:ro \
  org-agenda-api
```

### Development

```bash
nix develop
pytest tests/           # Run tests
pytest tests/ -v        # Verbose output
```

## API Endpoints

### Query Endpoints (GET)

| Endpoint | Description |
|----------|-------------|
| `/get-all-todos` | Returns all TODO items from agenda files |
| `/agenda` | Returns agenda entries for a date range |
| `/get-todays-agenda` | Returns today's scheduled and deadlined items |
| `/agenda-files` | Lists configured org-agenda-files |
| `/todo-states` | Returns active and done TODO states |
| `/custom-views` | Lists available custom agenda commands |
| `/custom-view?key=X` | Runs a specific custom agenda view |
| `/templates` | Lists registered capture templates |

### Create/Capture Endpoints (POST)

| Endpoint | Description |
|----------|-------------|
| `/capture` | Uses registered capture templates |

### Modification Endpoints (POST)

| Endpoint | Description |
|----------|-------------|
| `/update` | Updates TODO properties (scheduled, deadline, priority) |
| `/complete` | Marks TODO as complete |

### Utility Endpoints (GET)

| Endpoint | Description |
|----------|-------------|
| `/health` | Health check for monitoring |
| `/version` | Returns git commit hash |
| `/debug-config` | Returns org configuration for debugging |
| `/restart` | Graceful restart for process managers |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `GIT_SYNC_REPOSITORY` | Git repo URL to clone on startup |
| `GIT_SYNC_INTERVAL` | Sync interval in seconds (default: 60) |
| `GIT_SYNC_NEW_FILES` | Include untracked files (default: true) |
| `GIT_SSH_PRIVATE_KEY` | SSH private key content |
| `GIT_USER_EMAIL` | Git user email for commits |
| `GIT_USER_NAME` | Git user name for commits |
| `ORG_AGENDA_FILES` | Colon-separated list of org file paths |
| `ORG_INBOX_FILE` | Path for new captures (default: /data/org/inbox.org) |
| `ORG_API_MAX_REQUESTS` | Max requests before worker restart |
| `ORG_API_MAX_LIFETIME` | Max seconds before worker restart |

## Custom Emacs Configuration

To include your own Emacs config with additional packages:

```bash
# Step 1: Bootstrap packages
nix run .#bootstrap-emacs-config /path/to/emacs.d

# Step 2: Build container with your config (in your flake.nix)
container = org-agenda-api.lib.${system}.mkContainer {
  emacsConfigDir = ./path/to/emacs.d;
  emacsConfigEntryPoint = "org-config.el";
};
```

## License

GPL v3
