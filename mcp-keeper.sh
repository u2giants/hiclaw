#!/bin/bash
# Ensures the browser MCP server config stays in openclaw.json.
# The hiclaw-manager gateway strips unknown keys when it syncs config to MinIO.
# This script re-adds the mcp section before the next sync window.
docker exec hiclaw-manager python3 -c "
import json, os
path = '/root/manager-workspace/openclaw.json'
try:
    d = json.load(open(path))
    if 'mcp' not in d:
        d['mcp'] = {'servers': {'browser': {'command': 'npx', 'args': ['@playwright/mcp', '--cdp-endpoint', 'http://10.0.5.4:9223']}}}
        json.dump(d, open(path, 'w'), indent=2)
        print('mcp re-added')
except Exception as e:
    print('error:', e)
" 2>/dev/null
