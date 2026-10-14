# Changelog

## [4.11.2]

- fix(container): stop the hosted Mova web app from hanging on its loading spinner after a deploy. Every file in the Nix-built app has a 1980 mtime and nginx sent no Cache-Control, so browsers cached `index.html` heuristically for years, and revalidation still answered 304 because nginx's ETag (mtime + size) never changed between releases. That stale page requested the previous release's bundle, and the `try_files` fallback returned `index.html` for the missing `.js`, so the bundle failed to run and the static loading spinner stayed up for good. HTML is now served with `Cache-Control: no-cache` and no ETag or Last-Modified, so every load picks up the current bundle name. The content-hashed `/_expo/static/` and `/assets/` files are cached for a year and return 404 when missing. A browser already stuck needs one reload after this ships.
