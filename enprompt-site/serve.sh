#!/bin/sh
cd "$(dirname "$0")"
exec /usr/bin/python3 -m http.server 8000