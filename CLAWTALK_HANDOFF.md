# ClawTalk Gateway Integration — Handoff for New AI Session

Historical incident note. This file describes the debugging path that led to the current persistent ClawTalk integration.

Current source of truth:

- [README.md](/worksp/hiclaw/README.md)
- [docs/architecture.md](/worksp/hiclaw/docs/architecture.md)
- [docs/configuration.md](/worksp/hiclaw/docs/configuration.md)
- [docs/deployment.md](/worksp/hiclaw/docs/deployment.md)

Current expected state:

- [start-manager-agent.sh](/worksp/hiclaw/start-manager-agent.sh) bootstraps ClawTalk before gateway startup
- [manager-bootstrap-keeper.sh](/worksp/hiclaw/manager-bootstrap-keeper.sh) restores that startup patch after `hiclaw-manager` container recreation
- `openclaw clawtalk doctor` should pass `bot_connected` after the manager finishes booting

Everything below is retained as historical troubleshooting context, not the current design description.

## Goal

Make `openclaw clawtalk doctor` pass **`bot_connected`** — meaning the running OpenClaw **gateway process** inside the `hiclaw-manager` Docker container loads the `clawtalk` npm plugin and establishes a live WebSocket connection to `https://clawdtalk.com`.

Right now:
- The **CLI** (`openclaw clawtalk doctor`) loads clawtalk correctly — plugin loads, 21 tools registered, all checks pass except `bot_connected`.
- The **gateway** (the persistent process that actually handles calls) does NOT load clawtalk — it starts with "8 plugins" and clawtalk is absent.
- `bot_connected` fails because the WebSocket must come from the gateway, not the CLI.

---

## Environment

```
Host: /worksp/hiclaw/
Container: docker exec hiclaw-manager <cmd>
Gateway config: /root/manager-workspace/openclaw.json  (= /worksp/hiclaw/workspace/openclaw.json on host)
HOME inside container: /root/manager-workspace
OpenClaw state dir: /root/manager-workspace/.openclaw/
Plugin registry: /root/manager-workspace/.openclaw/plugins/installs.json
npm clawtalk: /root/manager-workspace/.openclaw/npm/node_modules/clawtalk/
```

The gateway runs as PID 1 (`exec openclaw gateway run --verbose --force`). Full `docker restart hiclaw-manager` clears module cache. In-process restarts (SIGUSR1, triggered by `commands.restart` going false→true) do NOT clear require.cache.

---

## What Has Been Done (Modifications in Place)

### 1. npm package `package.json` — MODIFIED
`/root/manager-workspace/.openclaw/npm/node_modules/clawtalk/package.json`

The `"openclaw": {"extensions": [...]}` field was changed from `"./build/index.js"` to `"./index.cjs"`. The `"clawdbot"` field was also updated to `"./index.cjs"`.

Current state:
```json
{
  "name": "clawtalk",
  "version": "0.2.3",
  "type": "module",
  "main": "./build/index.js",
  "openclaw": { "extensions": ["./index.cjs"] },
  "clawdbot": { "extensions": ["./index.cjs"] }
}
```

**WHY**: The original `build/index.js` is an ES module (`export default`). When `require()`d by OpenClaw (which uses CJS require), it returns `{ __esModule: true, default: { ... } }`. Older OpenClaw versions fail to unwrap this correctly. The `index.cjs` wrapper handles the ESM→CJS unwrapping explicitly.

### 2. `index.cjs` CJS wrapper — CREATED
`/root/manager-workspace/.openclaw/npm/node_modules/clawtalk/index.cjs`

```javascript
'use strict';
process.stderr.write('[clawtalk-probe] index.cjs required at ' + new Date().toISOString() + '\n');
const m = require('./build/index.js');
const plugin = m.default || m;
process.stderr.write('[clawtalk-probe] plugin id: ' + plugin.id + '\n');
module.exports = plugin;
```

**Note**: Has a probe (stderr writes) to detect if/when the gateway actually requires this file. The probe fires correctly in CLI context but never fires from the gateway. Once loading works, remove the probe lines.

### 3. installs.json — MODIFIED
`/root/manager-workspace/.openclaw/plugins/installs.json`

The `installRecords.clawtalk` entry was removed. Current state:
- `installRecords: {}` (empty — no clawtalk entry)
- `plugins` array still has clawtalk with `origin: bundled`, source pointing to the bundled shim (which no longer exists — see below)

### 4. Bundled shim — CREATED AND LOST
`/usr/lib/node_modules/openclaw/dist/extensions/clawtalk/` was created inside the container with:
- `index.js` (probe + require of npm build/index.js)
- `openclaw.plugin.json` (copy of npm package manifest)
- `package.json` (minimal: name, version, main)
- `skills` symlink → npm package skills dir

**THIS DIRECTORY NO LONGER EXISTS** — it was on the container's overlay filesystem and was wiped on the last `docker restart`. It must be recreated on every restart, or it needs to live on the host and be bind-mounted.

---

## What OpenClaw Does (Relevant Architecture)

### Plugin Discovery (`discoverOpenClawPlugins`)
Scans for plugins from:
1. **Config**: directories in `plugins.load.paths` (openclaw.json) → `origin: "config"`
2. **Workspace**: user's workspace dir → `origin: "workspace"`
3. **Bundled**: `/usr/lib/node_modules/openclaw/dist/extensions/` → `origin: "bundled"`
4. **Global (installed)**: paths from `installRecords` in installs.json → `origin: "global"`

For each directory found, it looks for:
- `package.json` with `"openclaw": {"extensions": [...]}` field → uses those files
- Otherwise falls back to `DEFAULT_PLUGIN_ENTRY_CANDIDATES`: `index.ts`, `index.js`, `index.mjs`, `index.cjs`

### Conflict Resolution
When two sources claim the same plugin ID, priority order is:
```
config (0) > workspace (1) > global (2) > bundled (3)
```
Lower number wins. When an `installRecord` exists for a plugin, it becomes a "config" source (origin: "config") because it was explicitly installed. The conflict message reads:
```
duplicate plugin id resolved by explicit config-selected plugin; bundled plugin will be overridden by config plugin (/path/to/config/index.cjs)
```

**CRITICAL BUG**: When "config wins" over "bundled", neither plugin actually loads. The bundled record is removed from the queue, but the config plugin's `require()` is never called either. This was confirmed by the probe in `index.cjs` never firing when the gateway has an `installRecord` for clawtalk.

### Why the `installRecord` Exists
When `openclaw plugins install clawtalk` was run previously, it created:
```json
"installRecords": {
  "clawtalk": {
    "source": "path",
    "sourcePath": "/root/manager-workspace/.openclaw/npm/node_modules/clawtalk",
    "installPath": "/root/manager-workspace/.openclaw/extensions/clawtalk"
  }
}
```
The `installPath` directory (`/root/manager-workspace/.openclaw/extensions/clawtalk/`) does NOT exist, but the installRecord causes the npm sourcePath to be treated as a "config" plugin.

### Why Removing `installRecord` Also Didn't Work (Latest Attempt)
After removing `installRecords.clawtalk` from installs.json AND creating the bundled shim at `/usr/lib/.../clawtalk/`:

1. Discovery correctly found clawtalk as bundled only (verified via direct ESM import test)
2. Manifest registry correctly built the clawtalk record with all fields including `configSchema`
3. Activation state: `enabled: true, activated: true` (because `plugins.entries.clawtalk.enabled: true` in openclaw.json)
4. BUT: The gateway showed "8 plugins (8 attempted)" — clawtalk was not even attempted

**This was not fully debugged**. The script was interrupted before we could determine why an apparently valid bundled plugin record still wasn't attempted. The bundled shim directory was also wiped by the restart.

---

## What NOT to Try

1. **Don't add clawtalk to `plugins.load.paths`** in openclaw.json. This only works reliably for **channel plugins** (plugins with `"channels"` field in openclaw.plugin.json). Clawtalk has no channels field. For non-channel plugins in load.paths, the discovery marks them as "config" origin and they conflict with other sources, resulting in nothing loading.

2. **Don't `docker restart` without first recreating files** that live on the overlay filesystem (`/usr/lib/node_modules/openclaw/dist/extensions/clawtalk/`). The overlay is wiped on restart.

3. **Don't trust the `manager-config-keeper.sh` as a solution mechanism** — it runs on the HOST every minute via cron and maintains `commands.restart: true` and `plugins.entries.clawtalk` in openclaw.json. It's already in place and working. Don't break it.

4. **Don't delete the npm clawtalk package** — the `build/index.js` there is the real plugin code. The bundled shim's `index.js` requires it.

5. **Don't reinstate `installRecords.clawtalk`** in installs.json — that's what caused the "config wins but nothing loads" bug.

6. **Don't try in-process restart** (writing `commands.restart: true` to openclaw.json) for module loading changes — it doesn't clear `require.cache`, so new versions of files won't be picked up for already-required modules.

---

## The Key Remaining Problem

The current state is:
- installs.json has no `installRecords.clawtalk` ✓
- npm package `package.json` has `openclaw.extensions: ["./index.cjs"]` ✓
- `index.cjs` wraps ESM correctly ✓
- BUT: The bundled shim at `/usr/lib/node_modules/openclaw/dist/extensions/clawtalk/` **no longer exists** (wiped on restart)
- AND: Even when the bundled shim existed, it wasn't being loaded by the gateway (we hit the `if (8 attempted)` wall without understanding why)

---

## Recommended Next Steps

### Option A: Fix the "bundled shim not loaded despite valid manifest" mystery (continue debugging)

1. Recreate the bundled shim:
```bash
docker exec hiclaw-manager sh -c "
mkdir -p /usr/lib/node_modules/openclaw/dist/extensions/clawtalk
# Copy plugin manifest
cp /root/manager-workspace/.openclaw/npm/node_modules/clawtalk/openclaw.plugin.json /usr/lib/node_modules/openclaw/dist/extensions/clawtalk/
# Minimal package.json (no openclaw.extensions field — use DEFAULT_PLUGIN_ENTRY_CANDIDATES fallback)
echo '{\"name\":\"clawtalk\",\"version\":\"0.2.3\",\"main\":\"./index.js\"}' > /usr/lib/node_modules/openclaw/dist/extensions/clawtalk/package.json
# Shim index.js
cat > /usr/lib/node_modules/openclaw/dist/extensions/clawtalk/index.js << 'JS'
'use strict';
process.stderr.write('[clawtalk-BUNDLED] required at ' + new Date().toISOString() + '\n');
const m = require('/root/manager-workspace/.openclaw/npm/node_modules/clawtalk/build/index.js');
const plugin = m.default || m;
process.stderr.write('[clawtalk-BUNDLED] id: ' + plugin.id + '\n');
module.exports = plugin;
JS
# Skills: copy (NOT symlink) to avoid 'escapes root' check
cp -r /root/manager-workspace/.openclaw/npm/node_modules/clawtalk/skills /usr/lib/node_modules/openclaw/dist/extensions/clawtalk/
chmod -R a-w /usr/lib/node_modules/openclaw/dist/extensions/clawtalk/
"
```

2. Refresh registry WITHOUT reinstating installRecord:
```bash
docker exec hiclaw-manager sh -c "openclaw plugins registry --refresh"
# Verify installRecords still empty:
docker exec hiclaw-manager sh -c "python3 -c \"import json; d=json.load(open('/root/manager-workspace/.openclaw/plugins/installs.json')); print('installRecords:', list(d.get('installRecords',{}).keys()))\""
```

3. Trigger in-process restart via config (don't docker restart — that wipes the shim again):
```bash
# Write commands.restart=false to trigger the false→true restart cycle
# Actually the manager-config-keeper.sh handles this already
# Just wait ~2min for the keeper to run and trigger restart
```

Wait 2-3 minutes and check:
```bash
docker logs hiclaw-manager --since 5m 2>&1 | grep -E "clawtalk|http server listening"
```

If clawtalk still not in the count, add debug logging directly to the OpenClaw loader to understand why it's being skipped.

### Option B: Make clawtalk persist across restarts without relying on overlay filesystem

The cleanest solution is to make the bundled shim permanent by creating it on the **host** and bind-mounting it into the container. Or modify the startup script to recreate it on every boot.

Add to `/worksp/hiclaw/start-manager-agent.sh` (before `exec openclaw gateway run`):
```bash
# Ensure clawtalk bundled shim (persists the plugin across restarts)
mkdir -p /usr/lib/node_modules/openclaw/dist/extensions/clawtalk
cp /root/manager-workspace/.openclaw/npm/node_modules/clawtalk/openclaw.plugin.json \
   /usr/lib/node_modules/openclaw/dist/extensions/clawtalk/
echo '{"name":"clawtalk","version":"0.2.3","main":"./index.js"}' \
   > /usr/lib/node_modules/openclaw/dist/extensions/clawtalk/package.json
# ... etc
```

### Option C: Proper installation via `openclaw plugins install --path`

Instead of manually creating files, use OpenClaw's own install mechanism in a way that avoids the `installRecord` conflict bug. There may be an install flag that links the plugin without creating a conflicting installRecord. Check `openclaw plugins install --help`.

---

## Diagnostic Commands

```bash
# Check what the gateway is loading
docker logs hiclaw-manager --since 5m 2>&1 | grep -E "clawtalk|http server listening|loading.*plugin|loaded.*plugin"

# Check current installs.json state
docker exec hiclaw-manager python3 -c "import json; d=json.load(open('/root/manager-workspace/.openclaw/plugins/installs.json')); print('installRecords:', list(d.get('installRecords',{}).keys())); claws=[p for p in d.get('plugins',[]) if isinstance(p,dict) and p.get('pluginId')=='clawtalk']; print('clawtalk:', json.dumps({k:claws[0][k] for k in ['pluginId','origin','source','installRecordHash'] if k in claws[0]}) if claws else 'not found')"

# Test discovery directly (ESM)
docker exec hiclaw-manager node --input-type=module <<'EOF'
import { t as discoverOpenClawPlugins } from '/usr/lib/node_modules/openclaw/dist/discovery-B19Xdk1_.js';
const r = discoverOpenClawPlugins({installRecords: {}});
const c = r.candidates.filter(x => x.source && x.source.includes('clawtalk'));
console.log('clawtalk candidates:', JSON.stringify(c.map(x=>({source:x.source,origin:x.origin})), null, 2));
EOF

# Run clawtalk doctor (CLI — not gateway!)
docker exec hiclaw-manager openclaw clawtalk doctor

# Check what's in the bundled extensions dir
docker exec hiclaw-manager ls -la /usr/lib/node_modules/openclaw/dist/extensions/clawtalk/ 2>/dev/null || echo "BUNDLED SHIM DOES NOT EXIST"

# Check npm package state
docker exec hiclaw-manager ls /root/manager-workspace/.openclaw/npm/node_modules/clawtalk/
```

---

## Files Summary

| File | Location | Status | Notes |
|------|----------|--------|-------|
| openclaw.json | `/root/manager-workspace/openclaw.json` (= `/worksp/hiclaw/workspace/openclaw.json` on host) | Current | Has `plugins.entries.clawtalk: {enabled:true, apiKey:..., autoConnect:true}`, `commands.restart:true` |
| installs.json | `/root/manager-workspace/.openclaw/plugins/installs.json` | Modified | `installRecords: {}` (no clawtalk entry), clawtalk in plugins as bundled |
| npm package.json | `/root/manager-workspace/.openclaw/npm/node_modules/clawtalk/package.json` | Modified | `openclaw.extensions: ["./index.cjs"]` |
| index.cjs | `/root/manager-workspace/.openclaw/npm/node_modules/clawtalk/index.cjs` | Created | CJS wrapper with diagnostic probe |
| bundled shim dir | `/usr/lib/node_modules/openclaw/dist/extensions/clawtalk/` | **MISSING** | Was on overlay filesystem, wiped by docker restart |
| manager-config-keeper.sh | `/worksp/hiclaw/manager-config-keeper.sh` | Modified | Removes clawtalk from load.paths, keeps plugins.entries.clawtalk |

---

## Key Facts About OpenClaw's Plugin Loading

- OpenClaw source is at `/usr/lib/node_modules/openclaw/dist/` (minified but not obfuscated)
- Key files: `loader-CiaemmFD.js` (plugin loading loop), `discovery-B19Xdk1_.js` (plugin discovery), `manifest-registry-C9Iavh95.js` (conflict resolution)
- The "config wins" conflict resolution **removes the bundled plugin from the queue** but the config plugin's `require()` is also never called (appears to be an OpenClaw bug when installPath doesn't exist)
- Skills directory symlinks that point outside the plugin's rootDir are blocked by a boundary check — use `cp -r` instead of symlinks
- The `resolvePreferredBuiltBundledRuntimeArtifact` function rewrites bundled plugin source paths — for our shim at `/usr/lib/.../dist/extensions/clawtalk/index.js`, it returns unchanged (already in dist)
- Plugin loading emits `[plugins] loading X from PATH` before requiring each module — absence of this message for clawtalk means it's not even being attempted
