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
bak     = '/worksp/hiclaw/workspace/openclaw.json.bak'
health  = '/worksp/hiclaw/workspace/.openclaw/logs/config-health.json'
api_key = 'cc_live_d5a5025bc0dc6894ac8acc6f867b336667e3e104'

try:
    with open(path) as f:
        d = json.load(f)

    changed = False

    # In hiclaw v1.1.2, the ManagerReconciler writes commands=null. Writing
    # commands:{restart:true} here would create a diff every reconciler cycle
    # and cause a restart loop. Instead, clear commands.restart if present so
    # the diff against the reconciler's null is always zero.
    current_cmds = d.get('commands', None)
    if isinstance(current_cmds, dict) and 'restart' in current_cmds:
        del current_cmds['restart']
        if not current_cmds:
            d.pop('commands', None)
        changed = True
        print('commands.restart cleared (was: true) to match reconciler baseline')

    # Route Matrix DMs to the same main session used by OpenClaw web chat.
    if d.get('session', {}).get('dmScope') != 'main':
        d.setdefault('session', {})['dmScope'] = 'main'
        changed = True
        print('session.dmScope corrected to main')

    # Migrate legacy Matrix group allow->enabled config for current OpenClaw schema.
    matrix_groups = d.setdefault('channels', {}).setdefault('matrix', {}).get('groups', {})
    if isinstance(matrix_groups, dict):
        for group_id, group_cfg in list(matrix_groups.items()):
            if isinstance(group_cfg, dict) and 'allow' in group_cfg and 'enabled' not in group_cfg:
                group_cfg['enabled'] = group_cfg.pop('allow')
                changed = True
                print(f'matrix group {group_id} migrated from allow->enabled')

    # Remove the '*' wildcard key — OpenClaw schema rejects additional properties in groups.
    # This key causes every config reload and update.run to fail with
    # 'managed-service-handoff-unavailable'. requireMention is covered by groupPolicy/groupAllowFrom.
    if '*' in matrix_groups:
        del matrix_groups['*']
        d['channels']['matrix']['groups'] = matrix_groups
        changed = True
        print('matrix groups wildcard "*" removed (invalid in current OpenClaw schema)')

    # Remove clawtalk from plugins.load.paths if present
    # (plugins.load.paths only overrides bundled plugins; clawtalk loads from
    #  the bundled extension symlink created by start-manager-agent.sh instead)
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

    # Enforce contextWindow for models whose values are known locally.
    # OpenRouter sync handles canonical IDs at startup when possible; this
    # table keeps gateway alias IDs stable when the reconciler restores stale
    # values from its internal state.
    CONTEXT_OVERRIDES = {
        'gpt-5.4': 150000,
        'gpt-5.3-codex': 400000,
        'gpt-5-mini': 400000,
        'gpt-5-nano': 400000,
        'claude-opus-4-6': 1000000,
        'claude-sonnet-4-6': 1000000,
        'claude-haiku-4-5': 200000,
        'qwen3.6-plus': 200000,
        'qwen3.5-plus': 200000,
        'deepseek-chat': 256000,
        'deepseek-reasoner': 256000,
        'kimi-k2.5': 256000,
        'glm-5': 200000,
        'MiniMax-M2.7': 200000,
        'MiniMax-M2.7-highspeed': 200000,
        'MiniMax-M2.5': 200000,
        'deepseek/deepseek-v4-pro': 1048576,
        'deepseek/deepseek-v4-flash': 1048576,
    }
    for m in d.setdefault('models', {}).setdefault('providers', {}).setdefault('hiclaw-gateway', {}).setdefault('models', []):
        model_id = m.get('id', '')
        if model_id in CONTEXT_OVERRIDES and m.get('contextWindow') != CONTEXT_OVERRIDES[model_id]:
            m['contextWindow'] = CONTEXT_OVERRIDES[model_id]
            changed = True
            print(f'model {model_id} contextWindow enforced to {CONTEXT_OVERRIDES[model_id]}')

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
