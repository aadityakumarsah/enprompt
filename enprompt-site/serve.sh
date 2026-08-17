#!/bin/sh
cd "$(dirname "$0")"
# Dev server with SPA fallback (routes: / and /run-locally)
exec npm run dev
