#!/usr/bin/env python3
"""Opt-in native XCTest GUI: fresh/recover first process, then independent durable resume."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import uuid

HASH = re.compile(r'^[0-9a-f]{64}$')
EVIDENCE_KEYS = set('formatVersion nativeGuiTestHost productGuiAcceptance runID phase launchNonce pid processID previousProcessID accountID teamID vaultID deviceID generationID publicKey publicKeyFingerprint status sequence headerHash manifestSHA256 acceptedAttemptID counts binary ownPin offlineVerified networkReloadVerified secretsVerified'.split())
BINARY_KEYS = {'executablePath','executableSHA256','testBundlePath','testBundleSHA256'}
MANIFEST_KEYS = set('formatVersion runID testIdentityCreatedForRun endpoint accountID email approvedRuntimeConfigPath teamID vaultID teamName vaultName rootFingerprint checkpointDigest generationID sequence headerHash counts secrets'.split())


def require(condition, code):
    if not condition: raise ValueError(code)


def canonical_uuid(value):
    require(type(value) is str, 'invalid_uuid')
    parsed=uuid.UUID(value)
    require(str(parsed)==value.lower() and parsed.variant==uuid.RFC_4122, 'invalid_uuid')
    return str(parsed)


def exact(value, keys):
    return type(value) is dict and set(value)==keys


def bytes32(value):
    if type(value) is not str or not re.fullmatch(r'[A-Za-z0-9_-]{43}',value): return False
    return len(base64.urlsafe_b64decode(value+'='))==32


def read_protected_json(path):
    path=Path(path)
    require(path.is_absolute() and path.resolve()==path, 'canonical_private_path_required')
    directory=path.parent.lstat()
    require(stat.S_ISDIR(directory.st_mode) and directory.st_uid==os.getuid() and stat.S_IMODE(directory.st_mode)==0o700, 'private_directory_required')
    descriptor=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(descriptor,'rb') as handle:
        before=os.fstat(handle.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_uid==os.getuid() and stat.S_IMODE(before.st_mode)==0o600
                and before.st_nlink==1 and 0<before.st_size<=65536, 'private_regular_file_required')
        raw=handle.read(65537); after=os.fstat(handle.fileno())
        require(len(raw)==before.st_size==after.st_size and before.st_mtime_ns==after.st_mtime_ns, 'file_changed')
    return json.loads(raw),hashlib.sha256(raw).hexdigest()


def write_private_new(path, value):
    descriptor=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(descriptor,'w') as output:
        json.dump(value,output,separators=(',',':')); output.flush(); os.fsync(output.fileno())


def read_manifest(path):
    value,digest=read_protected_json(path)
    require(exact(value,MANIFEST_KEYS) and type(value['formatVersion']) is int and value['formatVersion']==1, 'invalid_manifest')
    require(value['endpoint']=='https://cloud.pastfly.ru' and value['runID']==Path(path).parent.name
            and value['testIdentityCreatedForRun']==value['runID'], 'manifest_scope')
    for field in ['accountID','teamID','vaultID','generationID']: canonical_uuid(value[field])
    approval,_=read_protected_json(value['approvedRuntimeConfigPath'])
    require(exact(approval,{'version','runID','origin','emails','expectedSourceSHA','approvedVaultIDs','moduleHashes','operator'})
            and type(approval.get('version')) is int and approval.get('version')==1 and approval.get('origin')==value['endpoint']
            and value['runID']=='TEST-ONLY-CODEX-'+approval.get('runID',''), 'runtime_approval_scope')
    emails=approval.get('emails')
    require(type(emails) is list and len(emails)==2 and all(type(x) is str for x in emails)
            and len({x.lower() for x in emails})==2 and value['email'].lower() in [x.lower() for x in emails], 'email_not_approved')
    require(canonical_uuid(value['vaultID']) in [canonical_uuid(x) for x in approval.get('approvedVaultIDs',[])], 'vault_not_approved')
    return value,digest


def validate_evidence(value, manifest, nonce, phase, pid, binary, manifest_digest):
    require(exact(value,EVIDENCE_KEYS), 'evidence_schema')
    require(type(value['formatVersion']) is int and value['formatVersion']==2, 'evidence_version')
    require(value['nativeGuiTestHost'] is True and value['productGuiAcceptance'] is False
            and value['networkReloadVerified'] is True and type(value['offlineVerified']) is bool
            and value['offlineVerified']==(phase=='resume'), 'evidence_booleans')
    require(value['status']=='PASS' and value['runID']==manifest['runID'] and value['phase']==phase, 'evidence_run_phase')
    require(canonical_uuid(value['launchNonce'])==canonical_uuid(nonce), 'stale_invocation')
    require(type(value['pid']) is int and value['pid']==pid and pid>0, 'wrong_native_pid')
    canonical_uuid(value['processID']); canonical_uuid(value['acceptedAttemptID']); canonical_uuid(value['deviceID'])
    require(value['previousProcessID']=='' if phase!='resume' else bool(canonical_uuid(value['previousProcessID'])), 'previous_process')
    for field in ['accountID','teamID','vaultID','generationID']:
        require(canonical_uuid(value[field])==canonical_uuid(manifest[field]), 'evidence_scope')
    require(type(value['sequence']) is int and value['sequence']==manifest['sequence'] and value['sequence']>0
            and value['headerHash']==manifest['headerHash'] and HASH.fullmatch(value['headerHash'])
            and value['manifestSHA256']==manifest_digest and HASH.fullmatch(value['manifestSHA256']), 'evidence_generation')
    counts=value['counts']
    require(exact(counts,{'hosts','snippets','credentials','forwardings','folders'})
            and all(type(v) is int and v>0 for v in counts.values()) and counts==manifest['counts'], 'evidence_counts')
    require(type(value['secretsVerified']) is int and value['secretsVerified']==len(manifest['secrets'])>0, 'incomplete_SECRET')
    pin=value['ownPin']
    require(exact(pin,{'accountID','rootFingerprint','highWater','checkpointDigest'})
            and canonical_uuid(pin['accountID'])==canonical_uuid(manifest['accountID'])
            and pin['rootFingerprint']==manifest['rootFingerprint'] and HASH.fullmatch(pin['rootFingerprint'])
            and type(pin['highWater']) is int and 0<pin['highWater']<=9007199254740991 and bytes32(pin['checkpointDigest']), 'evidence_trust')
    key=value['publicKey']
    require(exact(key,{'kty','crv','x','y','ext','key_ops'}) and key['kty']=='EC' and key['crv']=='P-256'
            and key['ext'] is True and key['key_ops']==[] and bytes32(key['x']) and bytes32(key['y']), 'evidence_public_key')
    fingerprint=hashlib.sha256(('selective-remote/team-device-key/v1\0'+key['x']+'\0'+key['y']).encode()).hexdigest()
    require(value['publicKeyFingerprint']=='-'.join(fingerprint[i:i+4] for i in range(0,64,4)), 'public_fingerprint')
    require(exact(value['binary'],BINARY_KEYS) and value['binary']==binary, 'wrong_actual_binary')
    return value


def validate_pair(first, resumed):
    require(first['pid']!=resumed['pid'] and canonical_uuid(first['processID'])!=canonical_uuid(resumed['processID'])
            and canonical_uuid(resumed['previousProcessID'])==canonical_uuid(first['processID'])
            and canonical_uuid(first['launchNonce'])!=canonical_uuid(resumed['launchNonce'])
            and canonical_uuid(first['deviceID'])==canonical_uuid(resumed['deviceID']) and first['publicKey']==resumed['publicKey']
            and first['ownPin']==resumed['ownPin'] and first['binary']==resumed['binary']
            and all(first[k]==resumed[k] for k in ['runID','accountID','teamID','vaultID','generationID','sequence','headerHash','manifestSHA256','counts','secretsVerified']), 'restart_identity_mismatch')


def main():
    parser=argparse.ArgumentParser(description='Public protected TEST-only native GUI manifest; password only in SecureField')
    parser.add_argument('manifest'); parser.add_argument('--recover-first',action='store_true',help='Explicitly reopen same persisted native lifecycle after interruption')
    args=parser.parse_args(); path=Path(args.manifest)
    original,_=read_manifest(path); root=Path(__file__).resolve().parent.parent
    environment=os.environ.copy()
    for name in ['SELECTIVE_REMOTE_NATIVE_GUI_MANIFEST','SELECTIVE_REMOTE_NATIVE_GUI_PHASE','SELECTIVE_REMOTE_NATIVE_GUI_INVOCATION',
                 'SELECTIVE_REMOTE_NATIVE_GUI_LOCAL_SMOKE','SELECTIVE_REMOTE_NATIVE_GUI_LOCAL_KEYCHAIN','SELECTIVE_REMOTE_STAGING_REAL_CONFIG']:
        environment.pop(name,None)
    subprocess.run(['swift','test','--filter','StagingNativeGUIHostTests'],cwd=root,env=environment,check=True)
    binaries=sorted({p.resolve() for p in (root/'.build').glob('**/SelectiveRemoteTests.xctest/Contents/MacOS/SelectiveRemoteTests')})
    require(len(binaries)==1,'one_stable_test_binary_required'); bundle_binary=binaries[0]
    executable=Path(subprocess.check_output(['xcrun','--find','xctest'],text=True).strip()).resolve()
    developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
    binary=dict(executablePath=str(executable),executableSHA256=hashlib.sha256(executable.read_bytes()).hexdigest(),
                testBundlePath=str(bundle_binary),testBundleSHA256=hashlib.sha256(bundle_binary.read_bytes()).hexdigest())
    # Launch actual native child directly: Popen.pid is the executable whose identity the child proves.
    environment['DYLD_FRAMEWORK_PATH']=str(developer/'Platforms/MacOSX.platform/Developer/Library/Frameworks')
    environment['DYLD_LIBRARY_PATH']=str(developer/'Platforms/MacOSX.platform/Developer/usr/lib')
    environment['SELECTIVE_REMOTE_NATIVE_GUI_MANIFEST']=str(path)
    phases=[]
    for phase in ['recover' if args.recover_first else 'first','resume']:
        require(hashlib.sha256(executable.read_bytes()).hexdigest()==binary['executableSHA256']
                and hashlib.sha256(bundle_binary.read_bytes()).hexdigest()==binary['testBundleSHA256'],'binary_changed')
        nonce=str(uuid.uuid4()); invocation_path=path.parent/('invocation-'+nonce+'.json')
        invocation=dict(formatVersion=1,nonce=nonce,runID=original['runID'],phase=phase,
                        accountID=original['accountID'],teamID=original['teamID'],vaultID=original['vaultID'],binary=binary)
        write_private_new(invocation_path,invocation)
        environment['SELECTIVE_REMOTE_NATIVE_GUI_INVOCATION']=str(invocation_path)
        environment['SELECTIVE_REMOTE_NATIVE_GUI_PHASE']=phase
        log_path=path.parent/(phase+'-host-'+nonce+'.log')
        descriptor=os.open(log_path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(descriptor,'wb') as output:
            process=subprocess.Popen([str(executable),'-XCTest','SelectiveRemoteTests.StagingNativeGUIHostTests/testInteractiveHost',
                str(bundle_binary.parents[2])],cwd=root,env=environment,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
            print('TEST ONLY native GUI phase:',phase,'· password only in SecureField',flush=True)
            try: code=process.wait(timeout=1800)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGTERM); process.wait(timeout=15); raise ValueError('native_host_timeout')
        require(code==0,'native_host_failed')
        current,digest=read_manifest(path)
        mutable={'generationID','sequence','headerHash','counts','secrets','checkpointDigest'}
        require(all(current[k]==v for k,v in original.items() if k not in mutable),'intended_scope_changed')
        result,_=read_protected_json(path.parent/('phase-'+nonce+'.json'))
        validate_evidence(result,current,nonce,phase,process.pid,binary,digest)
        require(hashlib.sha256(executable.read_bytes()).hexdigest()==binary['executableSHA256']
                and hashlib.sha256(bundle_binary.read_bytes()).hexdigest()==binary['testBundleSHA256'],'binary_changed')
        phases.append(result)
    validate_pair(*phases)
    print('NATIVE_GUI_TWO_PROCESS_PASS nativeGuiTestHost=true productGuiAcceptance=false binarySHA256='+binary['testBundleSHA256'])


if __name__=='__main__':
    try: main()
    except (ValueError,KeyError,TypeError,OSError,subprocess.SubprocessError):
        raise SystemExit('Native host rejected protected scope, process, or acceptance evidence; inspect dedicated sanitized logs')
