# Mova Web Integration Design

## Overview

Integrate mova (React Native/Expo mobile client) as a web app served from the org-agenda-api container at `/app`.

## Goals

1. Add mova as a git submodule
2. Build mova's web export during container build
3. Serve mova at `/app` without authentication (static files)
4. API routes at `/` remain authenticated
5. Auto-configure mova to connect to the same-origin backend on web

## Architecture

### Container Structure

```
nginx (port 80)
├── /app/* → static files from /var/www/mova (NO AUTH)
├── /health → proxy to Emacs (NO AUTH)
└── /* → proxy to Emacs (WITH AUTH)

Emacs (port 2025) → org-agenda-api
```

### Build Process

1. Add mova submodule: `git submodule add https://github.com/colonelpanic8/mova mova`
2. Build mova web export: `npx expo export --platform web`
3. Copy `dist/` to `/var/www/mova` in container
4. Configure nginx to serve static files at `/app`

### Nginx Configuration

```nginx
# Mova web app - public static files
location /app {
    alias /var/www/mova;
    try_files $uri $uri/ /app/index.html;
}

# Health check - no auth
location = /health {
    proxy_pass http://127.0.0.1:2025;
}

# API routes - authenticated
location / {
    auth_basic "org-agenda-api";
    auth_basic_user_file /tmp/nginx-auth.conf;
    proxy_pass http://127.0.0.1:2025;
    # CORS headers...
}
```

## Mova Changes

### Login Screen Server Field

Current: Always-editable text input with URL suggestions dropdown.

New: Lockable field with two states:

**Locked state:**
- Shows server URL as read-only styled display
- "Edit" button to unlock

**Unlocked state:**
- Current text input with suggestions dropdown
- Selecting a URL or submitting locks it

### Web Platform Auto-Detection

On web platform (`Platform.OS === 'web'`):
1. Detect `window.location.origin` on mount
2. Pre-fill server URL field with detected origin
3. Start in locked state

On mobile:
- Start with empty field in unlocked state
- Show DEFAULT_URLS suggestions as user types

### Code Changes (app/login.tsx)

```tsx
const [serverLocked, setServerLocked] = useState(false);

useEffect(() => {
  if (Platform.OS === 'web' && typeof window !== 'undefined') {
    setApiUrl(window.location.origin);
    setServerLocked(true);
  }
}, []);

// Render locked or unlocked field based on state
{serverLocked ? (
  <LockedServerField url={apiUrl} onEdit={() => setServerLocked(false)} />
) : (
  <ServerUrlInput ... />
)}
```

## Auth Flow

1. User navigates to `https://server.com/app`
2. Nginx serves mova static files (no auth required)
3. Mova detects origin, shows locked server field
4. User enters username/password in mova login form
5. Mova calls `POST /templates` to verify credentials
6. On success, mova stores credentials and includes `Authorization` header on all API requests
7. Nginx validates basic auth on API routes

## Implementation Steps

1. Add mova as submodule to org-agenda-api
2. Update container.nix:
   - Add Node.js/npm to build dependencies
   - Add build step for mova web export
   - Copy built assets to /var/www/mova
   - Update nginx config
3. Update mova app/login.tsx:
   - Add serverLocked state
   - Add useEffect for web origin detection
   - Create locked field UI component
   - Conditionally render locked vs unlocked field
