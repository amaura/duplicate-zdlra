#!/usr/bin/env python3
"""Render a shareable diagnostic report without publishing deployment identities.

The input and optional NUL-delimited seed file are private, temporary evidence.
Never copy them to the output on error. Pseudonyms are local to one rendering;
their mapping, original identifiers and identifier hashes are never emitted.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile


# Fixed vocabulary for diagnostic prose, not a vocabulary learned from input.
# Values in typed identity fields are always masked, including vocabulary words.
SAFE_WORDS = set("""
 a a-z a-za a-za-z aborted above absence absent absolute ac accept accepted access accessible
account accounts across action active active-wallet actual actual-held add added additional
additionally address administer administrator administrator-managed after afterward again against
agree alias aliases all allocate allocation allocation-unit allowed alone already
already-installed-shared also alter alternate ambiguous an ancestor and another answer any appear
append appliance applicable application applied apply apply-off apply-on arbitrary are args argument
arguments argv arithmetic artifacts as asm asmcmd assignment assignments association assumption at
atomic attachment attempted attempted-result-unknown attributes audit authenticated authentication
authoritative auto-login automatic automatically aux aux-base aux-cdb aux-check aux-files aux-open
aux-pga-mb aux-pmon aux-sga-mb aux-shutdown aux-wallet-root auxiliaries auxiliary auxiliary-asm
auxiliary-path auxiliary-wallet-path auxiliary-wallet-status availability available awk background
backup backup-size backups bad basename bash batchmode be became before begin belong below beside
between bin blindly block blocked blocks bool boolean bootstrap both both-node bound boundary
bounded bounds break breaks broker broker-listed budget builder but by byte bytes calendar call
called caller caller-supplied can candidate candidates cannot canonical cap capacity capture
captured carried case cat catalog catalog-metadata catalog-only catalogued cause causes cd cdb
cdb-deletion cdb-only cdb-preflight cdb-private-work cdb-rac cdb-restore cdb-services cdb-shutdown
cdb-validation ceil cfg chain chained change changed changes changing channel channels characters
check checked checking checkpoint checks child chmod ckms cksum class classification classify clean
cleanup cleanup-failed cli client clients close close-new close-old closed closing closure
cluster-databases clusterware cmp code coexistence collapse collect collected collector collides
column columns combined come command commands comments comparisons compatibility compatible compile
complete completed completeness completion composed concat config config-paths configuration
configurations configure configured confirm confirmation confirmed conflicting conflicts connect
connected connection connections connectivity connecttimeout conservatively consistency console
consumer contacts contain container containers contains content contents continuations continue
continued continuity continuous contradict contradictory contradicts control control-backup
controlfile controlfile-count controlfiles controlled controlled-shutdown controlled-startup
controlled-startup-attempted controlmaster controlpath controls conversion copied copied-pdbs copies
copy copy-open-restricted copy-readiness-verified copyfileobj copying copyright correct
corresponding corrupt corruption could count counters counts coverage covers cp create create-issued
created creating creation credential credential-index credentials crlf cross cross-instance crs
crsctl current current-pdb-inventory custom cut cutover cwallet cyclic data database database-config
database-file database-ready database-resource database-status datafile datafiles date days db
db-nodes dbid dbids dbs ddl deadline debug declare decode def default default-path defaults defer
deferred define definition definitions delete deleted deletes deleting deleting-old-files deletion
deletion-aware depend depends deployment derived describe description designated dest destination
destinations destructive destructive-boundary detailed details detecting detector determine
determined dev device df dg dg-states dgm dgmgrl diag diagnostic diagnostics dict dictionary did die
differ different differs digest digits dir directly directories directory dirname disable disabled
disables disagree disambiguate discard discover discovered discovery disk disk-group dispatchers
displaced-tde display distinct dname do do-duplicate documented does done dormant double down
downstream drifted drop drop-issued drop-old dropped dry dry-run dry-run-complete dst dstatus dt
dtarget dtype dual dumps duplicate duplication during dvalue each earliest echo edit edition eeuo ef
effective eiq elif else empty enable enabled enablement encode encrypted encryption end ending
endpoint enter enters entries entry env envfile environ environment environment-file eo eof eq eqi
errexit error errors esac escape especially establish established estimated estimates etc even ever
every evidence exacc exact exactly exceed except exception excluded excluding exclusion exclusive
exclusively exdev exec execute execution exist existing exists exit expected expected-held
expected-rac expected-settings export expose expression extern external external-store extra fail
failed failover fails failure failure-disable failure-stop fal false far fast-start fatal feedback
fi field fields file file-deletion file-number filename filenames files filesystem filter final
final-settings find findall fingerprint fingerprints finish fiq first fixed flag follow followed
following for force forcing formatting former forms forward found framed framing free freeze fresh
from frozen fs full full-cdb fullmatch fully function functions further fuzzy fxiq fxq fxyyyy-mm-dd
gaps gate ge generation get getuid gib global gmt gnu go-rwx good govern grace greatest grep grid
group groups gsub gtimeout guarantee guard guarded guess guid gv handling handoff hard has hasattr
hashlib have header heading headroom held help helper here hexdigest hh hidden hide high hints
historical history hold holding home homes host hostname hosts hsm hup i id ident identified
identifier identifies identify identities identity idle ids if ifile ifs immediate immediately
immutable import in in-use inaccessible inactive incarnation included includes including inclusion
incompatible incomplete inconsistent independent independently index indicates indirection infer
inferred info inherited init initial initial-creation initialization initially inp input inside
inspect inst install installation installations installed installs instance instances instead instr
insufficient int integer intended intentionally interactive interior internet interpret intervention
into invalid invent inventories inventory investigate investigation ipc is isdecimal ismount
isolated isolation isspecified issubset issued it item items iter its job jobs join json just keep
keepkey key keyerror keys keystore kill kill-after kind known lambda last later latest launch layout
le leave leaves left legacy len length level lexicographic lib libra library lies like line lines
linesize linked links list listcredential listed listener listeners listing literal live load loaded
loading loads loc local local-paths locale locally location locations locator lock log logbase
logfile logical login logs lookup loop lossy lost lower lrm ls lsdg lstat lstrip made main make
makes malformed managed management manifest manifests manual manually map mapfile mapping mappings
marker masquerade match matched matches matching material max maxday maxdepth may mb md means media
member members membership meminfo memory message messages metacharacters metadata mi mib min
mindepth mirroring mismatch mismatched misreporting missing mixed mkdir mkstore mktemp mm mmin mode
mode-specific modes modify moment most mounted move moved multiple multiply must mutating mutation
mutations naborted name names namespace ncdb ne need needed needs neither nested never new new-files
new-identity new-pdb newer newly newname nexit nexpected next nf nine ninitial nno nnot no
no-configuration no-standby node nodes nolog nomount non-default non-omf non-parameterized nonblank
none nonexistent nonphysical nonregular noopen nor noreceive normal normalize normalized nosend not
not-checked not-created not-started notably notes nr nrequested nsource nstandby nsummary ntarget
ntimeout null number numbers numeric nvl observation observations observed observes occupancy occurs
ocr oe of off offline offline-clean ofs ok old old-controlfiles-protected old-file old-files
old-files-deleted old-pdb old-pdb-removed old-retired-source-pending old-tde old-wallet
old-wallets-protected olr omf omission omissions omitted on one ones online onlinelog only open
open-state opened opening opens operation operational operations operator opt option optional
optionally options or ora oracle oracle-checks order ordinal ordinary original
original-configuration-rac-startup orphaned os os-authenticated osdba oserror other otherwise out
outer output outside over overlapping overlaps override overrides overwrite owner owns packages
packaging pads pagesize pairs parallelism param parameter parameters params parent parents parms
parse parser parsers partial parts pass passed password password-file patch patches path pathlib
paths payload pdb pdb-guid pdb-inventory pdb-plugged pdb-ready pdb-services pdb-state pdbs peak
pending per per-copy per-file per-instance per-node per-sid performed permissive permits permitted
persist persisted persistent pfile pfile-derived pfile-export pfile-probe pfile-source pga phase
physical pid pipe pipefail pipestatus placement plan planning plug plug-in pluggable plus pm pmon
pname pnames point policies policy pool pop portable positive positively possible possibly post-plug
postduplicate potentially prcr pre-deletion pre-move pre-provisioned preamble prechange precreate
precutover predelete predicate predicates predrop preferred prefix preflight preliminary preparation
prepare prerequisite prerequisites prerestart presence present preserve preserved preserving
prevention previous primaries primary primary-nodes primary-only primary-side print printf prior
private privately privilege probe probes proc procedure procedures proceed process processes produce
produces production program prohibited prompts proof properties protect protected protocol prove
provider provision provisioning prune ps psids publish purge-log purged put pwcopy pwd py pyresource
pystartup python quarantine quarantined queried queries query quit quote quotes ra rac
rac-compatibility rac-readiness-verified-services-held rac-stopped-disabled raise range rather raw
rawtohex rb rc re reach reachable reactivate read read-only read-write readiness readme reads ready
real reason receive recheck reclaim reclaimable reco reconcile reconciling reconstructed record
recorded recover recoverable recovered recovering recovery recovery-group recovery-point
recovery-process recreated recreation recursive redact redacted redo redo-inventory redo-reserve-mb
redo-size ref reference references refresh refreshed refuse refused refusing registered
registered-instances registration regular reject rejects relation relations relationship
relationships relative release released remain remaining remains remote remove removed removes
rename rename-pdb render repeat repeated replace replacement replication report reported req request
requested require required requirement requires rereading rerun reserve reset resetlogs resolve
resolved resolving resource resources response rest restart restarted restarting restoration restore
restore-parallelism restore-range restored restored-controlfile restoring restricted restricted-open
restriction result resulting results resume resumption retain retained retained-datafile
retained-file retaining retains retention retired retiring-old retrying return returncode returned
returns reuse reused reuses review rf rglob rlength rm rman rmdir role roles rollback root roots
rounding row rows rs rstart rstrip ru rule run running runs runtime runtime-instances runtime-only
rw safe safely same same-name save saved saved-state saves says sbt scalar scheduler scn scns scope
script scriptdir scripts search second secondary seconds secret secrets section security sed see
seed seen select selected selection selects semantics send sensitive sent separate separately
separates seps sequence sequences server server-side serveroutput service services services-stopped
session sessions set sets setting settings setup sga sh share shared shell shellcheck shift shlex
show shut shutdown shutil sid side-effect sids silent silently simple single-command single-instance
site size sizes skip small snapshot snapshots so some sort sorted source source-cdb
source-controlfile-and-datafiles-verified source-controlfile-replacement-attempted source-files
source-online-redo source-path source-pdb source-size source-tde source-wallet-active
source-wallet-dir sourced space spbackup special specified spelling spfile split splitlines spool
spparameter sql sqlerror sqlpath sqlplus sqlplus-version sr src srcpath srv srvctl ss ssh sso st
stable stage staged staging stale stamp standalone standard standby standby-nodes standby-refresh
standbys start started starts startswith startup startup-alert startup-files stat state statement
statements states status stay stays stderr stdin stdout still stop stopoption stopped stopping
stopping-resources storage store str strict stricthostkeychecking string strip sub subprocess
subprocesserror subsep subsequently subset subshell substr subtree succeeded success successful sum
supplied supplies supply support supported suppressed svc symlink sync syntax sys sysdba sysdg
system sz tab table tablespace taf tag takes target target-and-catalog target-cdb target-dependent
target-memory target-pdb target-pdb-guid target-pdb-state target-rac target-settings target-space
target-specific targets tde tee temp temp-size tempfile tempfiles temporary term test text than that
the their them then there these they this thread threads through throughout time timed timeout
timestamp timestamps tls tmp tmpdir tns to token tolower too tool tools top-level topology
topology-dependent total touch toupper tr trace transient transition transitions transport trap
travel traversal tree trimspool true trunc truncated trusted try tsv tuple two txt type typed types
tz umask un unable uname unattended unavailable unchanged unconfigured unconfirmed under undercount
undo unexpected unfiltered unhealthy union unique united united-mode unknown unlink unmanaged
unparsed unplug unq unreadable unrecognized unregistered unrelated unresolved unrestricted unsafe
unset unsorted unsupported until untouched unusable unused unverified update updatehostkeys upper
usable usage use used user userenv username users uses using usr utc utility val valid validate
validate-aux validate-cdb validate-final validate-target validated validates validation validators
value valueerror values var verbose verification verificationerror verified verifies verify
verify-pdb version viewentry views visible volume wait walker wallet wallet-backup wallet-install
wallet-transition wallet-verify wallets warning was wc well when whenever where whether which while
whitespace whole-target whose why will with within without work work-dir worker workflow working
wrappers writable write writes written wrl wrong xb xml xxxxxx yes yet yyyy-mm-dd zdlra zdlra-alias
zero zip
""".split())
SAFE_WORDS.update("privacy masked pseudonyms pseudonym message summary omitted fingerprint fingerprints content sensitive details diagnostic operational metadata collector outcomes outcomes reported report rendering sanitized collector readiness dependencies blockers prerequisite nonblocking blocker health platform charset character endian corruption invalid registry components properties count collation timezone free reserved total requested actual code client empty python utility supported unavailable not-run mib gib bytes flags false true nan release production completed source target pass fail skip error warning aborted latest available seconds timeout grace mode version utf8 al32utf8 al16utf16 binary little big unknown absent present read write primary physical standby disabled enabled opened closed inaccessible compatible successful failed applied none null memory open hsm united isolated file ash auto local text settings estimated data temp redo control mounted restricted unrestricted satisfied requirement requirements probe staged copy readable writable private root seed sbt rman resource database instance service host catalog backup recovery wallet files nodes containers schemas gaps components registries con pid phase process counts limits budget readiness capacity logical physical preserved expected observed found missing optional fs per-file dbid id key sha256 python usable_mb required_mb verified_reclaim_mb configuration_sha256".split())
SAFE_WORDS.update("identity setting param password version patch container wallet broker rac apply pdb charset property component registry nls parameter status filecount tempfile datafile redo online archive archived threads undo tablespace instance_number thread db_block_size db_files compatible spfile wallet_root tde_configuration cluster_database job_queue_processes aq_tm_processes dg_broker_start service_names local_listener remote_listener db_create_file_dest db_recovery_file_dest db_name db_unique_name oracle_home oracle_sid db_domain log_archive_config log_archive_dest log_archive_dest_state control_files db_recovery_file_dest_size sga_target sga_max_size pga_aggregate_target processes sessions cpu_count open_cursors memory_target memory_max_target parallel_max_servers nls_characterset nls_nchar_characterset tz_version dbtimezone cdb local_undo_enabled endian_format database_properties archivelog noarchivelog force_logging flashback_on supplemental_log_data_min platform_name platform_id job_queue_processes aq_tm_processes instance_name host_name resetlogs_change resetlogs_time checkpoint_change checkpoint_time creation_change con_id file_id file_name block_size read_only stop_change incremental_level success with warnings standard enterprise edition release production plsql sqlplus sql patchset ru dbca opsd pmon linux x86 aarch64 bash gnu python3 oracle sqlplus srvctl asmcmd mkstore dgmgrl libra asm spfile pfile cdb$root pdb$seed sys$background sys$users auto-login already-installed-shared id dbinc_key db_key source_mb temp_mb redo_mb required_mb available_mb usable_mb free_mb total_mb reclaim_mb enabled disabled path paths source dest parent root work backup status size bytes kind type key directory sha256 configuration_sha256 result python files file_count directories no yes true false normal high external flex verified derived prepared staged before dry-run-complete cdb-preflight cdb-restore cdb-validation cdb-copy-companion utf-8".split())

TOKEN = re.compile(r"\[[A-Z]+_[0-9]+\]|\[(?:REDACTED|OMITTED)\]|(?<![A-Za-z0-9_])[A-Za-z_$][A-Za-z0-9_$]*(?:[.-][A-Za-z0-9_$]+)*")
ERROR_CODE = re.compile(r"\b(?:ORA|SP2|TNS|LRM|DGM|CRS|PRCR|RMAN|ASMCMD)-[0-9]+\b", re.I)
PATH = re.compile(r"(?<![A-Za-z0-9_])(?:\+[A-Za-z][A-Za-z0-9_]*(?:/[A-Za-z0-9_.-]+)*|/(?:[A-Za-z0-9_.-]+/?)+)")
OPAQUE_HEX = re.compile(r"\b[0-9A-Fa-f]{32,}\b")
NETWORK = re.compile(r"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b(?![0-9.])|\b[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+\b")
SECRET = re.compile(r"(?i)(?:password|passwd|secret|token|credential|private_key|access_key)\s*[=:]\s*(?:\"[^\"]*\"|'[^']*'|[^\s|,;]+)")
IDENTITY_KEYS = {"dbid", "db_key", "dbinc_key", "incarnation", "source_dbid", "target_dbid", "source_dbkey", "source_inc"}
NAME_SETTINGS = {"db_name", "db_unique_name", "instance_name", "undo_tablespace", "service_names", "local_listener", "remote_listener", "db_domain"}
PATH_SETTINGS = {"wallet_root", "spfile", "db_create_file_dest", "db_recovery_file_dest", "control_files"}
JSON_KEYS = {"source", "path", "key", "parent", "root", "work", "backup", "dest", "kind", "bytes", "size", "type", "status", "enabled", "python", "directory", "result", "sha256", "configuration_sha256", "usable_mb", "free_mb", "total_mb", "required_mb", "verified_reclaim_mb", "file_count", "files", "inventory"}
JSON_KEYS.update({"clients", "sqlplus", "rman", "mkstore", "srvctl", "asmcmd", "sbt_library_readable"})
SAFE_WORDS.update({"memtotal", "memfree", "memavailable", "buffers", "cached", "swapcached", "kb", "executable"})
SAFE_WORDS.add("cdb-online-redo")
SAFE_WORDS.update("standalone_disabled standalone_unconfigured appliance_disabled managed undo_tablespace log_archive_dest_state_1 log_archive_dest_1 limits per-report v1 v2".split())
SAFE_WORDS.update("cdb-identity cdb-rac cdb-settings cdb-work cdb-source-wallet cdb-registered cdb-files cdb-services cdb-catalog cdb-source-files cdb-source-redo cdb-range cdb-tempfiles cdb-compatibility cdb-capacity cdb-plan cdb-health cdb-configuration cdb-preflight".split())
SAFE_WORDS.update("advisory aggregate associations been budgets calls cdb-config cdb-dependent cdb-evidence cdb-node-config cdb-node-files cdb-nodes-and-config cdb-pdb-candidates cdb-redo cdb-retained cdb-source-metadata cdb-state cdb-work-and-wallet collector-only collision consumed describes destination-name endpoints equality exclusions failures generate histories identifiers installing interrupted invoked invoking labels lag let limit mutable old-target other-node our pdb-name phases potential protected-file protection renames replaced restored-dictionary sanitizer separation source-pdb-candidates sqlpatch statuses substitutes survive target-node undo-name unnamed bit java javavm xdb context catproc catalog catjava aps olap analytic workspace spatial sdo ordim owm dv lbacols options rac xml valid invalid loading loaded removing upgrading upgraded downgrade maxperformance maxavailability maxprotection protection transport disconnected error warning success unknown disabled enabled defer alternate reset".split())
SAFE_WORDS.update("darwin uid gid keystore_configuration cardinality dtp transaction aq ha notifications cardinality commit outcome failover basic taf retries delay connection runtime load balancing goal long short service_time throughput specification maximum lag any translation profile replay initiation drain consistency dynamic static gsm flags css critical transactional failover_restore commit_outcome automatic manual".split())
CHECK_ID = re.compile(r"(?:primary-[0-9]+|standby-[0-9]+(?:-node-[0-9]+|-nodes)?|cdb-(?:[a-z]+-)*[0-9]+(?:-[a-z]+)*)")


class Renderer:
    def __init__(self, seeds=()):
        self.mapping = {}
        self.counters = {}
        self.names = set()
        for value in seeds:
            if value and not value.isspace():
                self.names.add(value)

    def opaque(self, value, kind="NAME"):
        if not value or value in ("-", "<NULL>"):
            return value
        # Linux paths are case-sensitive; preserve differences that may explain
        # a registered/runtime path mismatch without exposing the path itself.
        key = (kind, value if kind == "PATH" else value.casefold())
        if key not in self.mapping:
            self.counters[kind] = self.counters.get(kind, 0) + 1
            self.mapping[key] = "[%s_%03d]" % (kind, self.counters[kind])
        return self.mapping[key]

    def discover(self, text):
        """Learn only typed identities; never create an input-derived safe list."""
        evidence = ""
        for line in text.splitlines():
            header = re.fullmatch(r"--- ([^\r\n]+) ---", line)
            if header:
                evidence = header[1]
                continue
            fields = line.strip().split("|")
            if fields[0] == "IDENTITY" and len(fields) >= 6:
                self.names.update((fields[1], fields[2]))
                self.names.add(fields[7] if len(fields) == 10 else fields[6] if len(fields) > 6 and fields[5] == "YES" else fields[5])
            elif len(fields) == 6 and fields[2].isdecimal() and fields[3] in ("PRIMARY", "PHYSICAL STANDBY") and fields[4] == "YES":
                self.names.update(fields[:2])
            elif fields[0] == "RAC" and len(fields) >= 3:
                self.names.update(fields[1:3])
            elif len(fields) == 4 and fields[2] == "OPEN" and re.fullmatch(r"[0-9.]+", fields[3]):
                self.names.update(fields[:2])
            elif fields[0] in ("SETTING", "PARAM") and len(fields) == 3 and fields[1].lower() in NAME_SETTINGS:
                self.names.update(v for v in fields[2].split(",") if v and v != "<NULL>")
            if (evidence.startswith(("rac.", "target-rac.", "target-node.")) or evidence in ("rac.txt", "nodes.txt", "expected-rac.txt", "pdb.txt")) and len(fields) >= 2:
                self.names.update(fields[:2])
            if evidence in ("saved-state.txt", "current-pdb-inventory.txt", "services.tsv") and len(fields) >= 2:
                self.names.add(fields[0])
                if evidence == "current-pdb-inventory.txt":
                    self.names.add(fields[1])
                if evidence == "services.tsv" and len(fields) >= 3:
                    self.names.update(fields[2].split(","))
                    if len(fields) >= 4:
                        self.names.add(fields[3])
            match = re.match(r"(?:Service name|Pluggable database name|Database unique name|Database name|ORACLE_SID|DB_UNIQUE_NAME|Expected source unique name)[:=]\s*(\S+)", line)
            if match:
                self.names.add(match[1])
            match = re.match(r"Catalog alias=(\S+) user=(\S+)", line)
            if match:
                self.names.update(match.groups())

    def prose(self, text):
        # Commands and client errors may echo arbitrary text or credentials.
        # Keep the useful error code, suppress its free-form message.
        codes = ERROR_CODE.findall(text)
        if codes:
            return " ".join(dict.fromkeys(codes)) + " [client message omitted]"
        text = SECRET.sub("[REDACTED]", text)
        text = PATH.sub(lambda m: self.opaque(m[0], "PATH"), text)
        text = OPAQUE_HEX.sub(lambda m: self.opaque(m[0], "GUID" if len(m[0]) == 32 else "FINGERPRINT"), text)
        text = re.sub(r"(?i)\b(DBID|db_key|dbinc_key|incarnation|source_dbkey|source_inc)\s*=\s*([0-9]+)", lambda m: m[1] + "=" + self.opaque(m[2], "ID"), text)
        # Versions are technical evidence. All other dotted words/IPs are names.
        text = NETWORK.sub(lambda m: m[0] if re.fullmatch(r"[0-9]+(?:\.[0-9]+)+(?:[A-Za-z]+)?", m[0]) and not re.fullmatch(r"(?:[0-9]{1,3}\.){3}[0-9]{1,3}", m[0]) else self.opaque(m[0]), text)
        for name in sorted(self.names, key=len, reverse=True):
            # Seed paths are already handled as complete paths above. Do not
            # replace status vocabulary globally for inferred short identifiers.
            if name.startswith(("/", "+")) or not name or name.casefold() in SAFE_WORDS:
                continue
            text = re.sub(r"(?<![A-Za-z0-9_$])" + re.escape(name) + r"(?![A-Za-z0-9_$])", lambda m: self.opaque(m[0]), text, flags=re.I)
        def word(match):
            value = match[0]
            if value.startswith("["):
                return value
            if value.casefold() in SAFE_WORDS or CHECK_ID.fullmatch(value) or re.fullmatch(r"log_archive_dest(?:_state)?_[0-9]+", value):
                return value
            return self.opaque(value)
        return TOKEN.sub(word, text)

    def setting(self, key, value):
        if value in ("<NULL>", "-"):
            return value
        lower = key.lower()
        if lower in NAME_SETTINGS:
            return ",".join(self.opaque(v) for v in value.split(","))
        if lower in PATH_SETTINGS:
            return self.opaque(value, "PATH")
        if re.fullmatch(r"log_archive_dest_[0-9]+", lower):
            return "<NULL>" if value == "<NULL>" else "[destination definition omitted]"
        if re.fullmatch(r"log_archive_dest_state_[0-9]+", lower):
            return value if value in ("ENABLE", "DEFER", "ALTERNATE", "RESET") else self.opaque(value)
        return self.prose(value)

    def row(self, line, evidence=""):
        fields = line.strip().split("|")
        tag = fields[0]
        match = re.match(r"^(Source|Target): ([^/\s]+)/([^\s]+)(.*)$", line)
        if match:
            return match[1] + ": " + self.opaque(match[2]) + "/" + self.opaque(match[3]) + self.prose(match[4])
        match = re.fullmatch(r"Script fingerprint (test_readonly\.sh|dup_db\.sh|cdb_copy\.sh|cdb_files\.py|readonly_cdb\.sh|readonly_report\.py): ([0-9]+ [0-9]+)", line)
        if match:
            return line
        if evidence in ("identity.before", "identity.txt") and len(fields) >= 3 and fields[2].isdecimal():
            fields[:3] = [self.opaque(fields[0]), self.opaque(fields[1]), self.opaque(fields[2], "ID")]
            return "|".join(self.prose(v) for v in fields)
        if tag == "IDENTITY" and len(fields) >= 4:
            fields[1:4] = [self.opaque(fields[1]), self.opaque(fields[2]), self.opaque(fields[3], "ID")]
            if len(fields) >= 6:
                index = 7 if len(fields) == 10 else 6 if len(fields) > 6 and fields[5] == "YES" else 5
                fields[index] = self.opaque(fields[index])
            return "|".join(self.prose(v) for v in fields)
        if tag in ("SETTING", "PARAM") and len(fields) == 3:
            return "|".join((tag, self.prose(fields[1]), self.setting(fields[1], fields[2])))
        if tag == "PASSWORD" and len(fields) == 2:
            return "PASSWORD|" + self.opaque(fields[1], "PATH")
        if tag == "RAC" and len(fields) >= 3:
            fields[1:3] = [self.opaque(v) for v in fields[1:3]]
            return "|".join(self.prose(v) for v in fields)
        if tag == "PDB" and len(fields) >= 3:
            if not fields[1].isdecimal():
                fields[1] = self.opaque(fields[1], "GUID")
            return "|".join(self.prose(v) for v in fields)
        if tag == "CHARSET" and len(fields) == 3 and fields[1] in ("NLS_CHARACTERSET", "NLS_NCHAR_CHARACTERSET") and re.fullmatch(r"[A-Z0-9_]+", fields[2]):
            return "|".join(fields)
        if evidence in ("source.txt", "source.out") and len(fields) >= 2 and all(v.isdecimal() for v in fields[:2]):
            return "|".join([self.opaque(v, "ID") for v in fields[:2]] + [self.prose(v) for v in fields[2:]])
        if evidence in ("incarnation.txt", "incarnation.out") and len(fields) == 3 and fields[0].isdecimal():
            return self.opaque(fields[0], "ID") + "|" + "|".join(fields[1:])
        if evidence == "pdb-guid.txt" and len(fields) == 1 and fields[0] != "NONE":
            return self.opaque(fields[0], "GUID")
        if evidence.startswith(("rac.", "target-rac.", "target-node.")) or evidence in ("rac.txt", "nodes.txt", "expected-rac.txt"):
            if len(fields) >= 2:
                fields[:2] = [self.opaque(v) for v in fields[:2]]
                return "|".join(self.prose(v) for v in fields)
        if evidence in ("pdb.txt", "saved-state.txt", "current-pdb-inventory.txt", "services.tsv"):
            if len(fields) > 1:
                fields[0] = self.opaque(fields[0])
                if evidence == "current-pdb-inventory.txt":
                    fields[1] = self.opaque(fields[1])
                if evidence == "pdb.txt" and len(fields) > 4:
                    fields[1] = self.opaque(fields[1])
                    fields[4] = self.opaque(fields[4], "GUID")
                if evidence == "services.tsv" and len(fields) >= 3:
                    fields[2] = ",".join(self.opaque(v) for v in fields[2].split(","))
                    if len(fields) > 3:
                        fields[3] = self.opaque(fields[3])
                return "|".join(self.prose(v) for v in fields)
        # srvctl field labels are structural; values may contain customer names.
        match = re.match(r"^(Service name|Pluggable database name|Database unique name|Database name|Database instances|Preferred instances|Available instances|Server pools|Server pool|Edition|SQL Translation Profile|Oracle user|OSDBA group|OSOPER group|Domain|Oracle home|Spfile|Password file|Disk Groups|Services):\s*(.*)$", line)
        if match:
            label, value = match.groups()
            kind = "PATH" if label in ("Oracle home", "Spfile", "Password file") else "NAME"
            return label + ": " + (",".join(self.opaque(v.strip(), kind) for v in value.split(",")) if value else "<empty>")
        return self.prose(line)

    def metadata(self, obj, key=""):
        if key.lower() in IDENTITY_KEYS and isinstance(obj, (str, int)):
            return self.opaque(str(obj), "ID")
        if isinstance(obj, dict):
            return {(name if name in JSON_KEYS or name.lower() in IDENTITY_KEYS else self.opaque(name, "PATH")): self.metadata(value, name) for name, value in obj.items()}
        if isinstance(obj, list):
            return [self.metadata(v, key) for v in obj]
        if isinstance(obj, str):
            if key in ("sha256", "configuration_sha256"):
                return self.opaque(obj, "FINGERPRINT")
            if key in ("source", "path", "parent", "root", "work", "backup", "dest", "key"):
                return self.opaque(obj, "PATH")
            if key in ("kind", "type", "status", "result"):
                return self.prose(obj)
            return self.opaque(obj)
        if isinstance(obj, (bool, int, float)) or obj is None:
            return obj
        raise ValueError("Unsupported metadata type")

    def evidence(self, name, body):
        # Top-level report lines follow the last artifact before the next
        # artifact delimiter; never lose a check result when omitting a file.
        tail = re.search(r"(?m)^(?==== |\[(?:PASS|FAIL|SKIP)\] |CDB NOT RUN:|CDB evidence limits:|NOT RUN \(|No application validation|SUMMARY:|Completed UTC:|ABORTED \()", body)
        if tail:
            return self.evidence(name, body[:tail.start()]) + "\n".join(self.row(line) for line in body[tail.start():].splitlines()) + "\n"
        label = name
        for original in sorted(self.names, key=len, reverse=True):
            if not original or original.startswith(("/", "+")):
                continue
            label = re.sub(r"(?<![A-Za-z0-9_$])" + re.escape(original) + r"(?![A-Za-z0-9_$])", lambda m: self.opaque(m[0]), label, flags=re.I)
        heading = "\n--- " + ".".join(self.prose(part) for part in label.split(".")) + " ---\n"
        lower = name.lower()
        if lower.endswith((".sql", ".rman", ".ora", ".log")) or name == "client.log":
            return heading + "[raw commands/configuration/client log omitted]\n"
        if lower.endswith(".json"):
            try:
                return heading + json.dumps(self.metadata(json.loads(body)), sort_keys=True) + "\n"
            except (ValueError, TypeError):
                return heading + "[unrecognized metadata omitted]\n"
        # Raw environment/parameter file contents must never be rendered.
        if lower.endswith((".env", ".pfile", ".spfile")) or "target-memory" in lower:
            return heading + "[private configuration omitted]\n"
        return heading + "\n".join(self.row(line, name) for line in body.splitlines()) + "\n"

    def render(self, raw):
        self.discover(raw)
        parts = re.split(r"(?m)^--- ([^\r\n]+) ---\r?$", raw)
        output = ["Privacy: names, paths and database identifiers use per-report pseudonyms; raw commands and client logs are omitted.\n"]
        output.append("\n".join(self.row(line) for line in parts[0].splitlines()) + "\n")
        for index in range(1, len(parts), 2):
            # A section may end with the next check's static header/summary;
            # render that prose with the same strict sanitizer.
            output.append(self.evidence(parts[index], parts[index + 1]))
        return "".join(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--seed-file")
    args = parser.parse_args()
    source, output = Path(args.input), Path(args.output)
    if source.resolve() == output.resolve():
        raise ValueError("Input and output must differ")
    seeds = Path(args.seed_file).read_text().split("\0") if args.seed_file else ()
    result = Renderer(seeds).render(source.read_text(errors="replace"))
    # Publish only a completely rendered report. Never fall back to raw input.
    fd, temporary = tempfile.mkstemp(prefix=".readonly_report_", dir=str(output.parent))
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(result)
        os.chmod(temporary, 0o600)
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError):
        print("Privacy report rendering failed; private evidence was not published.", file=sys.stderr)
        sys.exit(2)
