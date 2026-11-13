#!/usr/bin/env python3
"""Offline CDB filesystem/ASM fixtures. Only disposable local files are changed."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('files', Path(__file__).resolve().parents[1] / 'lib/cdb_files.py')
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)


class Files(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='zdlra_cdb_', dir='/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.root = self.base / 'wallet'
        for name in ('tde', 'tde_seps', 'server_seps', 'tls'):
            (self.root / name).mkdir(parents=True)
            (self.root / name / 'cwallet.sso').write_bytes(b'old-' + name.encode())
        self.source = self.base / 'source'
        self.source.mkdir()
        (self.source / 'cwallet.sso').write_bytes(b'\x00source-CKMS\xff')
        (self.source / 'ewallet.p12').write_bytes(b'\x00source-keys\xfe')
        self.stage = self.base / 'staged'
        self.work = self.base / 'recovery'

    def stage_wallet(self):
        return f.worker({'action':'stage', 'source':str(self.source), 'dest':str(self.stage), 'root':str(self.root)})

    def install_request(self):
        import base64
        self.stage_wallet()
        f.worker({'action':'wallet-backup', 'root':str(self.root), 'work':str(self.work)})
        return {'action':'wallet-install', 'root':str(self.root), 'work':str(self.work),
                'inventory':f.tree(self.stage),
                'files':{p.name:base64.b64encode(p.read_bytes()).decode() for p in self.stage.iterdir()}}

    def test_independent_source_copy(self):
        before = f.tree(self.source)
        mode = (self.source / 'cwallet.sso').stat().st_mode
        inventory = self.stage_wallet()
        self.assertEqual(before, inventory)
        self.assertEqual(mode, (self.source / 'cwallet.sso').stat().st_mode)
        self.assertEqual(0o700, self.stage.stat().st_mode & 0o777)
        self.assertEqual(0o600, (self.stage / 'cwallet.sso').stat().st_mode & 0o777)
        self.assertNotEqual((self.stage / 'cwallet.sso').stat().st_ino, (self.source / 'cwallet.sso').stat().st_ino)

    def test_password_only_and_wallet_root_input_rejected(self):
        (self.source / 'cwallet.sso').unlink()
        with self.assertRaises(ValueError):
            self.stage_wallet()
        (self.source / 'cwallet.sso').write_bytes(b'source')
        (self.source / 'tde').mkdir()
        with self.assertRaises(ValueError):
            self.stage_wallet()

    def test_links_fifo_and_unreadable_input_rejected(self):
        bad = self.source / 'bad'
        for kind in ('symlink', 'fifo', 'unreadable', 'hardlink'):
            if kind == 'symlink':
                bad.symlink_to(self.root / 'tde/cwallet.sso')
            elif kind == 'fifo':
                os.mkfifo(bad)
            elif kind == 'hardlink':
                os.link(self.source / 'ewallet.p12', bad)
            else:
                bad.write_bytes(b'no-access')
                bad.chmod(0)
            with self.assertRaises(ValueError, msg=kind):
                self.stage_wallet()
            bad.unlink()

    def test_changing_copy_rejected(self):
        real = f.shutil.copyfileobj
        def mutate(inp, out):
            real(inp, out)
            (self.source / 'added').write_bytes(b'changed')
        with patch.object(f.shutil, 'copyfileobj', side_effect=mutate):
            with self.assertRaises(ValueError):
                self.stage_wallet()

    def test_install_retains_source_and_unrelated_wallets(self):
        request = self.install_request()
        original = f.tree(self.source)
        unrelated = {n:f.tree(self.root/n) for n in ('tls','server_seps')}
        answer = f.worker(request)
        self.assertEqual('installed', answer['status'])
        self.assertEqual(original, f.tree(self.source))
        self.assertEqual(original, f.tree(self.root/'tde'))
        self.assertFalse((self.root/'tde_seps').exists())
        self.assertEqual(b'old-tde', (self.work/'old-tde/cwallet.sso').read_bytes())
        self.assertEqual(b'old-tde_seps', (Path(answer['retired'])/'quarantined-tde_seps/cwallet.sso').read_bytes())
        for n, inventory in unrelated.items():
            self.assertEqual(inventory, f.tree(self.root/n))
        self.assertEqual('already-installed-shared', f.worker(request)['status'])
        f.worker({'action':'wallet-verify', 'root':str(self.root), 'inventory':original})
        (self.root/'tde_seps').mkdir()
        with self.assertRaises(ValueError):
            f.worker({'action':'wallet-verify', 'root':str(self.root), 'inventory':original})

    def test_partial_install_leaves_recovery_copies(self):
        request = self.install_request()
        rename = Path.rename
        def fail_fresh(p, dest):
            if p.name.startswith('tde_copy_'):
                raise OSError('simulated node loss')
            return rename(p, dest)
        with patch.object(Path, 'rename', new=fail_fresh):
            with self.assertRaises(OSError):
                f.worker(request)
        self.assertTrue((self.work/'old-tde/cwallet.sso').exists())
        self.assertTrue((self.work/'old-tde_seps/cwallet.sso').exists())
        transition=json.loads((self.work/'wallet-transition.json').read_text())
        self.assertTrue((Path(transition['retired'])/'displaced-tde/cwallet.sso').exists())
        self.assertTrue((self.source/'cwallet.sso').exists())

    def file_request(self):
        keep = self.base/'spfile'
        keep.write_bytes(b'configuration')
        rows = []
        for kind in ('DATA','TEMP','REDO'):
            p = self.base/kind
            p.write_bytes(b'old-database')
            rows.append([kind,str(p),str(p.stat().st_size)])
        return {'rows':rows, 'protected':[str(keep)], 'unique':'PREM1', 'excluded':[str(self.root)]}

    def test_exact_manifest_dedup_protection_and_deletion(self):
        request = self.file_request()
        alias = self.base/'data-alias'
        alias.symlink_to(self.base/'DATA')
        request['rows'].append(['DATA',str(alias),'12'])
        rows = f.manifest(request)
        self.assertEqual(3,len(rows))
        for row in rows:
            self.assertEqual('deleted', f.remove_one({'row':row, 'protected':request['protected']})['result'])
        self.assertTrue(Path(request['protected'][0]).exists())
        self.assertTrue((self.root/'tde/cwallet.sso').exists())

    def test_manifest_refuses_retained_alias_wrong_size_kind_and_namespace(self):
        request = self.file_request()
        alias = self.base/'keep-alias'
        alias.symlink_to(request['protected'][0])
        request['rows'][0][1] = str(alias)
        with self.assertRaises(ValueError):
            f.manifest(request)
        request = self.file_request()
        request['rows'][0][1] = str(self.root/'tde/cwallet.sso')
        with self.assertRaises(ValueError):
            f.manifest(request)
        request = self.file_request()
        request['rows'][0][0] = 'CONTROL'
        with self.assertRaises(ValueError):
            f.manifest(request)
        request = self.file_request()
        request['rows'][0][1] = '+DATA/PRODM1/DATAFILE/system.1.100'
        with patch.object(f,'asm',return_value='DATAFILE UNPROT COARSE 2026 Y system.1.100'):
            with self.assertRaises(ValueError):
                f.manifest(request)

    def test_asm_aliases_resolve_to_one_protected_canonical_file(self):
        request = self.file_request()
        request['rows'] = [['DATA','+DATA/PREM1/data-alias','1048576'],
                           ['DATA','+DATA/PREM1/DATAFILE/system.1.100','1048576'],
                           request['rows'][1],request['rows'][2]]
        def listing(req,*args,**kwargs):
            if 'data-alias' in args[-1]:
                return 'DATAFILE UNPROT COARSE 2026 N data-alias => +DATA/PREM1/DATAFILE/system.1.100'
            return 'DATAFILE UNPROT COARSE 2026 Y system.1.100'
        with patch.object(f,'asm',side_effect=listing):
            rows=f.manifest(request)
            self.assertEqual(3,len(rows))
            request['protected'].append('+DATA/PREM1/data-alias')
            with self.assertRaises(ValueError):
                f.manifest(request)

    def test_delete_drift_is_fail_closed(self):
        request = self.file_request()
        row = f.manifest(request)[0]
        old = Path(row['path'])
        old.rename(old.with_suffix('.displaced'))
        old.write_bytes(b'replacement')
        with self.assertRaises(ValueError):
            f.remove_one({'row':row, 'protected':request['protected']})
        self.assertTrue(old.exists())

    def test_supported_asm_capacity_only(self):
        header='State Type Rebal Sector Block AU Total_MB Free_MB Req_mir_free_MB Usable_file_MB Offline_disks Voting_files Name'
        for redundancy in ('EXTERN','NORMAL','HIGH'):
            with patch.object(f,'asm',return_value=header+'\nMOUNTED '+redundancy+' N 512 4096 4194304 10000 6000 1000 2500 0 N DATA/'):
                self.assertEqual(2500,f.worker({'action':'capacity','group':'+DATA'})['usable_mb'])
        with patch.object(f,'asm',return_value=header+'\nMOUNTED FLEX N 512 4096 4194304 10000 6000 1000 2500 0 N DATA/'):
            with self.assertRaises(ValueError):
                f.worker({'action':'capacity','group':'+DATA'})

    def test_retained_snapshot_not_replaced(self):
        src=self.base/'spfile'
        src.write_bytes(b'private-password-setting')
        request={'action':'snapshot','kind':'PARAM','source':str(src),'dest':str(self.base/'retained')}
        result=f.worker(request)
        self.assertEqual(f.digest(src),result['sha256'])
        self.assertEqual(src.read_bytes(),(self.base/'retained').read_bytes())
        with self.assertRaises(ValueError):
            f.worker(request)

    def test_pfile_derives_local_settings_and_removes_conflicts(self):
        src=self.base/'memory.ora'
        src.write_text("*.sga_target=4000M\nPRE1.__db_cache_size=3000M\nPRE2.__db_cache_size=9000M\n*.db_file_name_convert='prod','pre'\nPRE1.log_archive_dest_2='SERVICE=PRODST'\n*.wallet_root='/old/wallet'\n*.job_queue_processes=1000\n*.db_create_online_log_dest_2='+OLD'\n*.control_files='+OLD/control'\n*.undo_tablespace='OLD_UNDO'\n")
        dest=self.base/'init.ora'
        req={'sid':'PRE1','db':'PRE','unique':'PREM1','root':str(self.root), 'data':'+DATA','reco':'+RECO',
             'number':1,'thread':1,'undo':'UNDOTBS1','controls':['+DATA/PREM1/CONTROLFILE/current.1.100']}
        f.derive_pfile(src,dest,req)
        text=dest.read_text()
        for unwanted in ('PRE2','SERVICE=','file_name_convert',"'+OLD'",'OLD_UNDO'):
            self.assertNotIn(unwanted,text)
        for expected in ('*.sga_target=4000M','*.__db_cache_size=3000M','*.cluster_database=false', '*.job_queue_processes=0',"*.db_unique_name='PREM1'", "*.control_files='+DATA/PREM1/CONTROLFILE/current.1.100'"):
            self.assertIn(expected,text)
        self.assertIn('job_queue_processes=1000',src.read_text())
        src.write_text("ifile='/unparsed'\n")
        with self.assertRaises(ValueError):
            f.derive_pfile(src,self.base/'bad.ora',req)

    def test_asm_absence_requires_documented_missing_entry_error(self):
        req={'home':'/fake/oracle', 'asm_sid':'+ASM1'}
        for code in ('ASMCMD-08002','ASMCMD-8002'):
            result=subprocess.CompletedProcess([],1,code+": entry 'system.1.100' does not exist in directory '+DATA/PREM1/DATAFILE'")
            with patch.object(f.subprocess,'run',return_value=result):
                self.assertIsNone(f.asm(req,'ls','+DATA/PREM1/DATAFILE/system.1.100',absent=True))
        for text in ('ASMCMD-08102: no connection','ASMCMD-08002: absent\nORA-15001: group not mounted', 'ASMCMD-08001: diskgroup missing'):
            result=subprocess.CompletedProcess([],1,text)
            with patch.object(f.subprocess,'run',return_value=result):
                with self.assertRaises(ValueError):
                    f.asm(req,'ls','+DATA/PREM1/DATAFILE/system.1.100',absent=True)

    def test_pfile_and_default_startup_file_preservation(self):
        home=self.base/'oracle'
        (home/'dbs').mkdir(parents=True)
        original=home/'dbs/initPRE1.ora'
        original.write_text("*.db_name='PRE'\n")
        req={'action':'pfile-probe','home':str(home),'sid':'PRE1'}
        self.assertEqual(str(original),f.worker(req)['path'])
        self.work.mkdir()
        request={'action':'startup-files','home':str(home),'sid':'PRE1','work':str(self.work),'stage':'before'}
        before=f.worker(request)
        self.assertTrue(before['spfilePRE1.ora']['absent'])
        (home/'dbs/spfilePRE1.ora').write_bytes(b'unexpected-generated-file')
        with self.assertRaises(ValueError):
            f.worker(req)
        after=f.worker(dict(request,stage='after'))
        self.assertNotEqual(before,after)
        (home/'dbs/spfilePRE1.ora').unlink()
        original.write_text("IFILE='/unverified/parameters'\n")
        with self.assertRaises(ValueError):
            f.worker(req)

    def test_database_resource_properties_are_read_only_and_unambiguous(self):
        original_read=Path.read_text
        def read(p,*args,**kw):
            if str(p)=='/etc/oracle/olr.loc':
                return 'crs_home=/fake/grid\n'
            return original_read(p,*args,**kw)
        properties='NAME=ora.prem1.db\nTYPE=ora.database.type\nENABLED=1\nUSR_ORA_SPFILE=+DATA/PREM1/parameterfile/spfile.1.100\n'
        with patch.object(Path,'read_text',new=read):
            result=subprocess.CompletedProcess([],0,properties)
            with patch.object(f.subprocess,'run',return_value=result) as client:
                before=f.worker({'action':'resource','name':'ora.prem1.db'})
                self.assertEqual(['/fake/grid/bin/crsctl','status','resource','ora.prem1.db','-p'],client.call_args.args[0])
            with patch.object(f.subprocess,'run',return_value=subprocess.CompletedProcess([],0,properties.replace('ENABLED=1','ENABLED=0'))):
                after=f.worker({'action':'resource','name':'ora.prem1.db'})
                self.assertEqual(0,after['enabled'])
                self.assertEqual(before['configuration_sha256'],after['configuration_sha256'])
            with patch.object(f.subprocess,'run',return_value=subprocess.CompletedProcess([],0,properties+'ENABLED@SERVERNAME(node2)=0\n')):
                with self.assertRaises(ValueError):
                    f.worker({'action':'resource','name':'ora.prem1.db'})

    def test_remote_worker_transmits_only_stdin_and_no_secrets_in_output(self):
        # Fake SSH executes the fixed bootstrap locally. There is no network.
        real=subprocess.run
        calls=[]
        def ssh(argv,**kw):
            calls.append(argv)
            return real(['bash','-c',argv[-1]],**kw)
        with patch.object(f.subprocess,'run',side_effect=ssh):
            result=f.node({'action':'probe','root':str(self.root),'parent':str(self.base)},'fake-node')
        self.assertEqual(str(self.root.resolve()),result['root'])
        self.assertNotIn('old-tde',json.dumps(calls))
        self.assertNotIn('source-CKMS',json.dumps(result))


if __name__=='__main__':
    unittest.main()
