#!/usr/bin/env python3
"""Private CDB copy file operations. Never print wallet/parameter/password bytes.

Called locally or over authenticated SSH by cdb_copy.sh. Input JSON is carried
on stdin (never argv); the worker only returns metadata. No Oracle SQL here.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile


class VerificationError(ValueError):
    """Safe diagnostic composed only of fixed messages and validated metadata."""


def require(ok, message):
    if not ok:
        raise VerificationError(message)


def path(value):
    require(bool(re.fullmatch(r'/[A-Za-z0-9_./-]+', value)), 'Unsafe filesystem path')
    p = Path(value)
    require('..' not in p.parts and p != Path('/'), 'Unsafe filesystem root/traversal')
    return p


def digest(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hash_stream(f)


def hash_stream(f):
    h = hashlib.sha256()
    for block in iter(lambda: f.read(1024 * 1024), b''):
        h.update(block)
    return h.hexdigest()


def regular(p):
    st = p.lstat()
    require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and os.access(p, os.R_OK),
            'Unreadable, linked, or nonregular file')
    return st


def tree(p):
    require(p.is_dir() and not p.is_symlink() and os.access(p, os.R_OK | os.X_OK), 'Unsafe wallet directory')
    result = {}
    for child in sorted(p.rglob('*')):
        relative = str(child.relative_to(p))
        require(re.fullmatch(r'[A-Za-z0-9_./-]+', relative), 'Unsafe wallet entry')
        require(not child.is_symlink(), 'Wallet links are unsupported')
        if child.is_dir():
            require(os.access(child, os.R_OK | os.X_OK), 'Unreadable wallet directory')
            result[relative] = {'directory': True}
        else:
            st = regular(child)
            result[relative] = {'sha256': digest(child), 'size': st.st_size}
    return result


def copy_tree(src, dst):
    before = tree(src)
    require(not dst.exists(), 'Refusing to overwrite wallet copy')
    dst.mkdir(mode=0o700)
    for name, info in before.items():
        dest = dst / name
        if info.get('directory'):
            dest.mkdir(mode=0o700)
        else:
            with (src / name).open('rb') as f, dest.open('xb') as out:
                shutil.copyfileobj(f, out)
            dest.chmod(0o600)
    require(before == tree(src) == tree(dst), 'Changing or incomplete wallet copy')
    return before


def asm_path(value):
    require(re.fullmatch(r'\+[A-Za-z][A-Za-z0-9_]*(?:/[A-Za-z0-9_.-]+)+', value), 'Unsafe ASM path')
    require('..' not in value.split('/'), 'ASM traversal')
    return value


def asm(req, *args, absent=False):
    env = os.environ.copy()
    # Use the local ASM SID, never the stopped database SID. Membership in
    # OSDBA for ASM and an accessible 19c ASMCMD are deployment prerequisites.
    sid = req.get('asm_sid')
    if not sid:
        processes = subprocess.check_output(['ps', '-eo', 'args='], text=True)
        sids = re.findall(r'^\s*asm_pmon_(\+ASM\w*)\s*$', processes, re.M)
        require(len(sids) == 1, 'Cannot establish one local ASM SID')
        sid = sids[0]
    require(re.fullmatch(r'\+ASM\w*', sid), 'Unsafe ASM SID')
    env['ORACLE_SID'] = sid
    env['ORACLE_HOME'] = req['home']
    result = subprocess.run([req['home'] + '/bin/asmcmd', '--privilege', 'sysdba', *args],
                            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    errors = re.findall(r'(?:ORA|ASMCMD)-[0-9]+', result.stdout)
    if absent and errors and all(re.fullmatch(r'ASMCMD-0?8002', code) for code in errors):
        return None
    require(result.returncode == 0 and not re.search(r'(?:ORA-|ASMCMD-)[0-9]+', result.stdout),
            'ASMCMD operation failed: ' + args[0])
    return result.stdout.strip()


def canonical(req, value, kind=None):
    if not value.startswith('+'):
        p = path(value).resolve(strict=True)
        st = regular(p)
        return str(p), 'fs:%s:%s' % (st.st_dev, st.st_ino)
    value = asm_path(value)
    listing = asm(req, 'ls', '-l', value)
    # Oracle 19c aliases show "alias => +DG/DB/TYPE/name.file.incarnation".
    targets = re.findall(r'=>\s*(\+\S+)', listing)
    require(len(targets) <= 1, 'Ambiguous ASM alias')
    full = targets[0] if targets else value
    asm_path(full)
    require(re.search(r'\.[0-9]+\.[0-9]+$', full), 'Unresolved ASM alias')
    if kind:
        types = {'DATA': 'DATAFILE', 'TEMP': 'TEMPFILE', 'REDO': 'ONLINELOG', 'CONTROL': 'CONTROLFILE'}
        require(re.search(r'^\s*' + types[kind] + r'\s', listing, re.M), 'ASM file type differs from inventory')
    return full.upper(), full.upper()


def snapshot(req):
    src, dest = req['source'], path(req['dest'])
    require(not dest.exists(), 'Snapshot already exists')
    if src.startswith('+'):
        asm_path(src)
        operation = {'PARAM': 'spbackup', 'PASSWORD': 'pwcopy'}.get(req['kind'], 'cp')
        asm(req, operation, src, str(dest))
    else:
        srcpath = path(src).resolve(strict=True)
        regular(srcpath)
        with srcpath.open('rb') as inp, dest.open('xb') as out:
            shutil.copyfileobj(inp, out)
    dest.chmod(0o600)
    regular(dest)
    if not src.startswith('+'):
        require(digest(srcpath) == digest(dest), 'Snapshot byte verification failed')
    return {'source': str(Path(src).resolve()) if not src.startswith('+') else src.upper(),
            'sha256': digest(dest), 'size': dest.stat().st_size}


def manifest(req):
    protected = set()
    excluded = [Path(p).resolve() for p in req.get('excluded', [])]
    for value in req['protected']:
        full, key = canonical(req, value)
        protected.update((full, key))
    result, seen = [], set()
    for row in req['rows']:
        require(len(row) == 3, 'Bad database file manifest columns')
        kind, value, size = row
        require(kind in ('DATA', 'TEMP', 'REDO') and size.isdecimal() and int(size) > 0,
                'Unknown database file kind/size')
        full, key = canonical(req, value, kind)
        require(full not in protected and key not in protected, 'Database file aliases a retained file')
        if not full.startswith('+'):
            require(all(Path(full) != p and p not in Path(full).parents for p in excluded), 'File overlaps protected working/wallet directory')
        if full.startswith('+'):
            require(full.split('/')[1].upper() == req['unique'].upper(), 'File outside verified target ASM namespace')
        if key in seen:
            old = next(r for r in result if r['key'] == key)
            require(old['kind'] == kind and old['bytes'] == int(size), 'Conflicting duplicate file metadata')
            continue
        seen.add(key)
        result.append({'kind': kind, 'path': full, 'key': key, 'bytes': int(size)})
    require(result and all(any(r['kind'] == k for r in result) for k in ('DATA', 'TEMP', 'REDO')),
            'Incomplete old target file inventory')
    return sorted(result, key=lambda r: r['path'])


def remove_one(req):
    row = req['row']
    full, key = canonical(req, row['path'], row['kind'])
    require(full == row['path'] and key == row['key'], 'File identity changed before deletion')
    # Repeat the retained-file alias gate at the last possible moment.
    for retained in req['protected']:
        keep, keepkey = canonical(req, retained)
        require(full != keep and key != keepkey, 'Deletion overlaps retained file')
    if full.startswith('+'):
        asm(req, 'rm', full)  # one canonical file, no recursive or force flag
        require(asm(req, 'ls', full, absent=True) is None, 'ASM deletion result unknown')
    else:
        p = path(full)
        regular(p)
        p.unlink()
        require(not p.exists() and not p.is_symlink(), 'Filesystem deletion result unknown')
    return {'result': 'deleted', 'path': full}


def worker(req):
    action = req['action']
    if action == 'pfile-probe':
        sid = req['sid']
        require(re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', sid), 'Unsafe SID')
        dbs = path(req['home']) / 'dbs'
        require(not any((dbs/name).exists() or (dbs/name).is_symlink() for name in ('spfile'+sid+'.ora','spfile.ora')),
                'Default SPFILE conflicts with PFILE startup')
        source = dbs / ('init'+sid+'.ora')
        regular(source)
        require(not re.search(r'^\s*(?:[^.\s]+\.)?(?:ifile|spfile)\s*=', source.read_text(), re.M | re.I),
                'PFILE indirection is unsupported; retained file cannot be established')
        return {'path': str(source), 'sha256': digest(source)}
    if action == 'startup-files':
        sid = req['sid']
        require(re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', sid) and re.fullmatch(r'[a-z]+', req['stage']), 'Unsafe startup snapshot name')
        result = {}
        for name in ('spfile'+sid+'.ora', 'spfile.ora', 'init'+sid+'.ora'):
            source = path(req['home']) / 'dbs' / name
            if source.exists() or source.is_symlink():
                result[name] = snapshot(dict(req, source=str(source), dest=str(path(req['work'])/('startup_'+sid+'_'+req['stage']+'_'+name)), kind='PARAM'))
            else:
                result[name] = {'absent': True}
        return result
    if action == 'resource':
        require(re.fullmatch(r'ora\.[a-z][a-z0-9_]*\.db', req['name']), 'Unsafe database resource name')
        locator = Path('/etc/oracle/olr.loc').read_text()
        homes = re.findall(r'^crs_home=(.+)$', locator, re.M)
        require(len(homes) == 1, 'Cannot establish Grid home from olr.loc')
        grid = path(homes[0])
        result = subprocess.run([str(grid/'bin/crsctl'), 'status', 'resource', req['name'], '-p'],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        require(result.returncode == 0 and not re.search(r'(?:CRS-|PRCR-)[0-9]+', result.stdout), 'Cannot inspect database resource properties')
        lines = result.stdout.splitlines()
        require('NAME=' + req['name'] in lines and 'TYPE=ora.database.type' in lines, 'Unexpected resource identity/type')
        enabled = [line.split('=', 1)[1] for line in lines if re.match(r'^ENABLED(?:@[^=]+)?=', line)]
        require(enabled and all(x in ('0','1') for x in enabled) and len(set(enabled)) == 1,
                'Unsupported/mixed database resource enablement')
        stable = '\n'.join(line for line in lines if not re.match(r'^ENABLED(?:@[^=]+)?=', line))
        return {'enabled': int(enabled[0]), 'configuration_sha256': hashlib.sha256(stable.encode()).hexdigest()}
    if action == 'stopped':
        require(re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', req['sid']), 'Unsafe SID')
        processes = subprocess.check_output(['ps', '-eo', 'args='], text=True)
        require(not re.search(r'^\s*ora_pmon_' + re.escape(req['sid']) + r'\s*$', processes, re.M | re.I),
                'Unmanaged target instance remains running')
        return {'status': 'stopped'}
    if action == 'prepare':
        parent = path(req['parent']).resolve(strict=True)
        dest = parent / req['name']
        require(re.fullmatch(r'cdb_copy_[A-Za-z0-9_]+', req['name']), 'Unsafe work name')
        if not dest.exists():
            dest.mkdir(mode=0o700)
        require(dest.is_dir() and not dest.is_symlink() and dest.stat().st_uid == os.getuid() and dest.stat().st_mode & 0o077 == 0, 'Unsafe work directory')
        return {'work': str(dest)}
    if action == 'probe':
        parent = path(req['parent']).resolve(strict=True)
        root = path(req['root']).resolve(strict=True)
        require(os.access(parent, os.W_OK | os.X_OK), 'Work parent is not writable')
        require(parent != root and root not in parent.parents, 'Work parent is inside WALLET_ROOT')
        if req.get('source'):
            source = path(req['source']).resolve(strict=True)
            require(parent != source and source not in parent.parents, 'Work parent overlaps supplied wallet input')
            require(source != root and root not in source.parents and source not in root.parents,
                    'Supplied wallet input overlaps active wallet root')
        require(not (root / 'tde').is_symlink() and (root / 'tde').is_dir(), 'Target tde must be a regular directory')
        require(not os.path.ismount(root/'tde'), 'Target tde must support atomic rename within WALLET_ROOT')
        tree(root / 'tde')
        if (root / 'tde_seps').exists() or (root / 'tde_seps').is_symlink():
            require(not os.path.ismount(root/'tde_seps'), 'Target tde_seps must support atomic rename within WALLET_ROOT')
            tree(root / 'tde_seps')
        return {'parent': str(parent), 'root': str(root), 'python': list(sys.version_info[:2])}
    if action == 'stage':
        src, dst = path(req['source']).resolve(strict=True), path(req['dest'])
        root = path(req['root']).resolve(strict=True)
        require(src != root and root not in src.parents and src not in root.parents,
                'Source TDE directory overlaps target wallet root')
        require(not (src / 'tde').exists(), 'Supply the tde contents directly, not a wallet root')
        require((src / 'cwallet.sso').is_file() and (src / 'cwallet.sso').stat().st_size > 0,
                'Portable auto-login cwallet.sso is required')
        return copy_tree(src, dst)
    if action == 'wallet-backup':
        root, work = path(req['root']).resolve(strict=True), path(req['work'])
        require(not work.exists(), 'Node recovery directory already exists')
        work.mkdir(mode=0o700)
        result = {'tde': copy_tree(root / 'tde', work / 'old-tde')}
        if (root / 'tde_seps').exists():
            result['tde_seps'] = copy_tree(root / 'tde_seps', work / 'old-tde_seps')
        (work / 'wallet-backup.json').write_text(json.dumps(result, sort_keys=True))
        return {'backup': str(work), 'status': 'verified'}
    if action == 'wallet-install':
        root, work = path(req['root']).resolve(strict=True), path(req['work'])
        require((work / 'wallet-backup.json').is_file(), 'Verified old-wallet backup is required')
        if tree(root / 'tde') == req['inventory'] and not (root / 'tde_seps').exists():
            return {'status': 'already-installed-shared', 'inventory': tree(root / 'tde')}
        require(tree(root / 'tde') == tree(work / 'old-tde'), 'Target wallet changed after backup')
        tag = work.parent.name + '_' + work.name
        fresh = root / ('tde_copy_' + tag)
        retired = root / ('.cdb_retired_' + tag)
        require(not fresh.exists(), 'Wallet installation path exists')
        fresh.mkdir(mode=0o700)
        expected = req['inventory']
        for name, info in expected.items():
            require(re.fullmatch(r'[A-Za-z0-9_./-]+', name) and '..' not in Path(name).parts,
                    'Unsafe supplied wallet name')
            target = fresh / name
            if info.get('directory'):
                target.mkdir(mode=0o700)
            else:
                target.write_bytes(base64.b64decode(req['files'][name], validate=True))
                target.chmod(0o600)
        require(tree(fresh) == expected, 'Installed wallet byte verification failed')
        # Shared storage: the second host observes the already installed wallet;
        # the shell probes both hosts again and verifies the same fingerprint.
        # Rename within WALLET_ROOT so a filesystem work parent on a different
        # volume never causes EXDEV in the active-wallet transition. Verified
        # recovery copies already exist in work; this additional retired tree
        # stays private, inactive, and outside Oracle's tde/tde_seps lookup paths.
        retired.mkdir(mode=0o700)
        transition = work/'wallet-transition.json'
        transition.write_text(json.dumps({'status':'retiring-old', 'root':str(root), 'retired':str(retired), 'fresh':str(fresh)}))
        if (root / 'tde_seps').exists():
            require(tree(root / 'tde_seps') == tree(work / 'old-tde_seps'), 'Target tde_seps changed')
            (root / 'tde_seps').rename(retired / 'quarantined-tde_seps')
        (root / 'tde').rename(retired / 'displaced-tde')
        transition.write_text(json.dumps({'status':'old-retired-source-pending', 'root':str(root), 'retired':str(retired), 'fresh':str(fresh)}))
        fresh.rename(root / 'tde')
        transition.write_text(json.dumps({'status':'installed', 'root':str(root), 'retired':str(retired)}))
        return {'status': 'installed', 'inventory': tree(root / 'tde'), 'retired':str(retired)}
    if action == 'wallet-verify':
        root = path(req['root']).resolve(strict=True)
        require(not (root / 'tde_seps').exists() and not (root / 'tde_seps').is_symlink(),
                'Stale target tde_seps credentials remain active')
        require(tree(root / 'tde') == req['inventory'], 'Active TDE wallet differs from staged source')
        return {'status': 'verified'}
    if action == 'snapshot':
        return snapshot(req)
    if action == 'manifest':
        return manifest(req)
    if action == 'delete':
        return remove_one(req)
    if action == 'capacity':
        lines = asm(req, 'lsdg', req['group']).splitlines()
        require(len(lines) == 2, 'Unknown ASM capacity output')
        fields = dict(zip(lines[0].split(), lines[1].split()))
        require(fields['State'] == 'MOUNTED' and fields['Type'] in ('EXTERN', 'NORMAL', 'HIGH'),
                'Unsupported ASM group capacity/mirroring semantics')
        require(fields['Name'].rstrip('/').upper() == req['group'].lstrip('+').upper(), 'Wrong ASM group')
        return {'usable_mb': int(fields['Usable_file_MB']), 'type': fields['Type']}
    raise ValueError('Unknown file operation')


def node(req, host=None):
    if not host:
        return worker(req)
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', host), 'Unsafe node hostname')
    # Fixed trusted program; source and request travel only over stdin. The
    # request can contain wallet bytes, which must never reach command logs.
    program = Path(__file__).read_text()
    payload = json.dumps({'program': program, 'request': req})
    bootstrap = """import json,sys
p=json.load(sys.stdin)
scope={'__name__':'cdb_remote'}
exec(compile(p['program'],'cdb_files.py','exec'),scope)
try:
    answer=scope['worker'](p['request'])
except scope['VerificationError'] as error:
    answer={'_verification_error':str(error)}
print(json.dumps(answer,sort_keys=True))
"""
    import shlex
    result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                             '-o', 'UpdateHostKeys=no', '-o', 'ConnectTimeout=10', 'oracle@' + host,
                             'python3 -c ' + shlex.quote(bootstrap)], input=payload, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    require(result.returncode == 0, 'Remote file operation failed on ' + host + ' (request/secret output suppressed)')
    answer = json.loads(result.stdout)
    require('_verification_error' not in answer,
            'Remote verification on ' + host + ': ' + answer.get('_verification_error', 'unknown'))
    return answer


def derive_pfile(src, dst, req):
    # CREATE PFILE FROM MEMORY produces one assignment per line. Refuse
    # includes, continuations and ambiguous forms rather than retaining an
    # isolation override hidden in an unparsed record. Collapse per-SID values
    # to the controlled SID's effective value, preserving its memory settings.
    values = {}
    for line in Path(src).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        m = re.fullmatch(r'([A-Za-z0-9_*]+)\.([A-Za-z0-9_]+)\s*=\s*(.+)', line)
        require(m, 'Unsupported derived PFILE syntax')
        sid, key, value = m.groups()
        require(key.lower() not in ('ifile', 'spfile'), 'PFILE indirection is unsupported')
        if sid == '*' or sid.upper() == req['sid'].upper():
            k = key.lower()
            if k not in values or sid != '*':
                values[k] = (sid, value)
    removed = re.compile(r'^(db_file_name_convert|log_file_name_convert|db_create_online_log_dest_[1-5]|log_archive_dest(_state)?_\d+|fal_server|fal_client|log_archive_config|db_create_file_dest|db_recovery_file_dest|dg_broker_config_file[12]|control_files|wallet_root|instance_name|instance_number|thread|undo_tablespace|service_names|local_listener|remote_listener|listener_networks|dispatchers|dg_broker_start|cluster_database|job_queue_processes|aq_tm_processes)$')
    values = {k: v for k, v in values.items() if not removed.fullmatch(k)}
    overrides = {'db_name': "'%s'" % req['db'], 'db_unique_name': "'%s'" % req['unique'],
                 'cluster_database': 'false', 'job_queue_processes': '0', 'aq_tm_processes': '0',
                 'dg_broker_start': 'false', 'remote_listener': "''", 'listener_networks': "''", 'dispatchers': "''",
                 'local_listener': "'(ADDRESS=(PROTOCOL=IPC)(KEY=CDB_COPY_%s))'" % req['sid'],
                 'service_names': "'%s'" % req['db'], 'wallet_root': "'%s'" % req['root'],
                 'db_create_file_dest': "'%s'" % req['data'], 'db_recovery_file_dest': "'%s'" % req['reco'],
                 'db_create_online_log_dest_1': "'%s'" % req['data'],
                 'log_archive_dest_1': "'LOCATION=%s'" % req['reco'],
                 'instance_number': str(req['number']), 'thread': str(req['thread']),
                 'undo_tablespace': "'%s'" % req['undo'],
                 'control_files': ','.join("'%s'" % p for p in req['controls'])}
    for n in range(2, 32):
        overrides['log_archive_dest_state_%s' % n] = "'DEFER'"
    with Path(dst).open('x') as out:
        for key, (_, value) in sorted(values.items()):
            out.write('*.%s=%s\n' % (key, value))
        for key, value in overrides.items():
            out.write('*.%s=%s\n' % (key, value))
    Path(dst).chmod(0o600)


if __name__ == '__main__':
    try:
        if len(sys.argv) > 1:
            require(len(sys.argv) % 2 == 0, 'Invalid worker argument pairs')
            request = dict(zip(sys.argv[2::2], sys.argv[3::2]))
            request['action'] = sys.argv[1]
            for key in ('rows', 'protected', 'controls', 'excluded'):
                filename = request.pop(key + '_file', None)
                if filename:
                    rows = Path(filename).read_text().splitlines()
                    request[key] = [r.split('|') for r in rows] if key == 'rows' else rows
            if 'inventory_file' in request:
                request['inventory'] = json.loads(Path(request.pop('inventory_file')).read_text())
            if 'manifest_file' in request:
                request['row'] = json.loads(Path(request.pop('manifest_file')).read_text())[int(request.pop('index'))]
        else:
            request = json.load(sys.stdin)
        if request['action'] == 'pfile':
            derive_pfile(request['source'], request['dest'], request)
            answer = {'status': 'derived'}
        else:
            if request['action'] == 'wallet-install':
                src = path(request.pop('staged'))
                request['inventory'] = tree(src)
                request['files'] = {name: base64.b64encode((src / name).read_bytes()).decode()
                                    for name, info in request['inventory'].items() if not info.get('directory')}
            answer = node(request, request.pop('host', None))
        print(json.dumps(answer, sort_keys=True))
    except VerificationError as error:
        print('CDB file verification: ' + str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        # Do not render exception values: filenames/provider errors can contain
        # sensitive input. Detailed phase/request metadata stays in shell evidence.
        print('CDB file verification/operation failed; inspect phase metadata.', file=sys.stderr)
        sys.exit(1)
