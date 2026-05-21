#!/bin/bash
# Stabilizes openclaw.json: fixes Matrix group schema (allow→enabled), ensures
# clawtalk/whatsapp plugin entries survive observe-recovery drift, routes Matrix
# DMs to the main session, and clears commands.restart when the startup script
# sets it (before the controller's first reconciliation at ~5 min).
#
# WHY (restart): The startup script sets commands.restart=true so the gateway
# does an initial reload. This keeper clears it to {} (when explicitly true)
# so subsequent controller writes (commands:null) do not cause a restart diff.
# The controller writes commands:null (not true), so null is left untouched —
# changing null→{} causes the gateway to see commands.restart in the diff and
# restart. See docs/configuration.md § commands.restart for the full explanation.
#
# WHY (session.dmScope): Without this, Matrix direct messages use
# per-channel sessions and diverge from the OpenClaw web chat transcript.
# For this single-manager deployment we intentionally collapse direct chat
# into the main session so both UI surfaces stay in sync.
#
# WHY (clawtalk): OpenClaw's observe-recovery mechanism reverts config changes
# that produce a hash mismatch vs config-health.json. The entrypoint's jq
# reformats the JSON (changing hash), triggering a restore from .bak.
#
# FIX (clawtalk/whatsapp): Write managed config atomically, delete .bak, and sync
# config-health.json so observe-recovery sees a clean match.
# The entrypoint jq preserves plugins, so once clawtalk is in the config
# it survives through the jq reformat.
sudo python3 -c "
import json, sys, hashlib, os, time

path    = '/worksp/hiclaw/workspace/openclaw.json'
bak     = '/worksp/hiclaw/workspace/.openclaw/openclaw.json.bak'
health  = '/worksp/hiclaw/workspace/.openclaw/logs/config-health.json'
api_key = 'cc_live_d5a5025bc0dc6894ac8acc6f867b336667e3e104'

try:
    with open(path) as f:
        d = json.load(f)

    changed = False

    # Always write commands:{restart:true} to match the gateway's baseline.
    # The gateway's last-accepted config (recorded in config-health.json) was written
    # at initial container startup when the startup script set commands.restart=true.
    # Any diff that changes the 'commands' field (null→{}, {}→null, or restart going
    # true→absent) triggers a gateway restart. Writing {restart:true} here means the
    # diff shows no change in commands — so the keeper's schema fixes (allow→enabled,
    # whatsapp entries, etc.) are applied as a hot reload, not a full restart.
    # The gateway processes commands.restart only when it CHANGES (diff-based), not
    # when the value is simply true, so keeping it true at steady state is a no-op.
    current_cmds = d.get('commands', None)
    desired_cmds = {'restart': True}
    if current_cmds != desired_cmds:
        d['commands'] = desired_cmds
        changed = True
        print('commands set to {restart:true} (was: %s)' % json.dumps(current_cmds))

    # Route Matrix DMs to the same main session used by OpenClaw web chat.
    if d.get('session', {}).get('dmScope') != 'main':
        d.setdefault('session', {})['dmScope'] = 'main'
        changed = True
        print('session.dmScope corrected to main')

    # Migrate legacy Matrix group allow->enabled config for current OpenClaw schema.
    matrix_groups = d.setdefault('channels', {}).setdefault('matrix', {}).get('groups', {})
    if isinstance(matrix_groups, dict):
        for group_id, group_cfg in matrix_groups.items():
            if isinstance(group_cfg, dict) and 'allow' in group_cfg and 'enabled' not in group_cfg:
                group_cfg['enabled'] = group_cfg.pop('allow')
                changed = True
                print(f'matrix group {group_id} migrated from allow->enabled')

    # Remove clawtalk from plugins.load.paths if present
    # (plugins.load.paths only overrides bundled plugins; clawtalk loads from
    #  the global installed copy at .openclaw/extensions/clawtalk/ instead)
    clawtalk_path = '/root/manager-workspace/.openclaw/npm/node_modules/clawtalk'
    load_paths = d.setdefault('plugins', {}).setdefault('load', {}).setdefault('paths', [])
    if clawtalk_path in load_paths:
        load_paths.remove(clawtalk_path)
        changed = True
        print('clawtalk load path removed (using installed copy instead)')

    # Ensure clawtalk plugin entry is present
    entries = d.setdefault('plugins', {}).setdefault('entries', {})
    if 'clawtalk' not in entries:
        entries['clawtalk'] = {
            'enabled': True,
            'config': {
                'apiKey': api_key,
                'autoConnect': True
            }
        }
        changed = True
        print('clawtalk plugin entry added')

    # Raise per-file bootstrap char limit so AGENTS.md (15k+ chars) is not truncated.
    agent_defaults = d.setdefault('agents', {}).setdefault('defaults', {})
    if agent_defaults.get('bootstrapMaxChars') != 20000:
        agent_defaults['bootstrapMaxChars'] = 20000
        changed = True
        print('agents.defaults.bootstrapMaxChars set to 20000')

    # Ensure WhatsApp and ClawTalk are in the plugin allow list.
    whatsapp_path = '/root/manager-workspace/.openclaw/npm/node_modules/@openclaw/whatsapp'
    plugin_allow = d.setdefault('plugins', {}).setdefault('allow', [])
    if 'whatsapp' not in plugin_allow:
        plugin_allow.append('whatsapp')
        changed = True
        print('whatsapp plugin allow entry added')
    if 'clawtalk' not in plugin_allow:
        plugin_allow.append('clawtalk')
        changed = True
        print('clawtalk plugin allow entry added')

    if whatsapp_path not in load_paths:
        load_paths.append(whatsapp_path)
        changed = True
        print('whatsapp load path added')

    whatsapp_entry = entries.setdefault('whatsapp', {})
    if whatsapp_entry.get('enabled') is not True:
        whatsapp_entry['enabled'] = True
        changed = True
        print('whatsapp plugin entry enabled')

    whatsapp_cfg = d.setdefault('channels', {}).setdefault('whatsapp', {})
    if whatsapp_cfg.get('enabled') is not True:
        whatsapp_cfg['enabled'] = True
        changed = True
        print('whatsapp channel enabled')
    if 'dmPolicy' not in whatsapp_cfg:
        whatsapp_cfg['dmPolicy'] = 'pairing'
        changed = True
        print('whatsapp dmPolicy set to pairing')
    if 'groupPolicy' not in whatsapp_cfg:
        whatsapp_cfg['groupPolicy'] = 'allowlist'
        changed = True
        print('whatsapp groupPolicy set to allowlist')

    if changed:
        content = json.dumps(d, indent=2).encode('utf-8')
        with open(path, 'wb') as f:
            f.write(content)
        new_hash = hashlib.sha256(content).hexdigest()

        # Delete .bak so observe-recovery cannot revert this change
        if os.path.exists(bak):
            os.remove(bak)

        # Sync config-health.json so the running gateway sees a clean hash match
        if os.path.exists(health):
            with open(health) as f:
                h = json.load(f)
            fstat = os.stat(path)
            entry_key = list(h['entries'].keys())[0]
            h['entries'][entry_key]['lastKnownGood'] = {
                'hash': new_hash,
                'bytes': len(content),
                'mtimeMs': fstat.st_mtime_ns / 1_000_000,
                'ctimeMs': fstat.st_ctime_ns / 1_000_000,
                'dev': str(fstat.st_dev),
                'ino': str(fstat.st_ino),
                'mode': fstat.st_mode,
                'nlink': fstat.st_nlink,
                'uid': fstat.st_uid,
                'gid': fstat.st_gid,
                'hasMeta': True,
                'gatewayMode': 'local',
                'observedAt': time.strftime('%Y-%m-%dT%H:%M:%S.000Z', time.gmtime())
            }
            with open(health, 'w') as f:
                json.dump(h, f, indent=2)
            print('config-health.json synced, hash=' + new_hash[:16])

except Exception as e:
    print('error:', e, file=sys.stderr)
    sys.exit(1)
"
