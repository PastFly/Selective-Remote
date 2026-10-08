import copy
import hashlib
import importlib.util
from pathlib import Path
import unittest
import uuid

spec = importlib.util.spec_from_file_location('native_host_launcher', Path(__file__).parents[1] / 'staging-native-gui-host.py')
launcher = importlib.util.module_from_spec(spec); spec.loader.exec_module(launcher)

class NativeEvidenceTests(unittest.TestCase):
    def fixture(self):
        account, team, vault, generation, device = [str(uuid.uuid4()) for _ in range(5)]
        manifest = {'runID': 'TEST-ONLY-CODEX-native-review', 'accountID': account, 'teamID': team, 'vaultID': vault,
                    'generationID': generation, 'sequence': 2, 'headerHash': 'b' * 64, 'rootFingerprint': 'a' * 64,
                    'counts': dict(hosts=1,snippets=1,credentials=1,forwardings=1,folders=1), 'secrets': [{}]}
        binary = dict(executablePath='/dedicated/xctest',executableSHA256='c'*64,testBundlePath='/dedicated/tests',testBundleSHA256='d'*64)
        nonce = str(uuid.uuid4()); digest='e'*64
        key=dict(kty='EC',crv='P-256',x='AQ'*21+'AQ',y='Ag'*21+'Ag',ext=True,key_ops=[])
        # Use canonical 32-byte public-coordinate encodings; native decoder also verifies the actual P256 point.
        import base64
        key['x']=base64.urlsafe_b64encode(bytes([1])*32).decode().rstrip('=')
        key['y']=base64.urlsafe_b64encode(bytes([2])*32).decode().rstrip('=')
        text='selective-remote/team-device-key/v1\0'+key['x']+'\0'+key['y']
        fp=hashlib.sha256(text.encode()).hexdigest(); fp='-'.join(fp[i:i+4] for i in range(0,64,4))
        value=dict(formatVersion=2,nativeGuiTestHost=True,productGuiAcceptance=False,runID=manifest['runID'],phase='first',
                   launchNonce=nonce,pid=321,processID=str(uuid.uuid4()),previousProcessID='',accountID=account,teamID=team,vaultID=vault,
                   deviceID=device,generationID=generation,publicKey=key,publicKeyFingerprint=fp,status='PASS',sequence=2,
                   headerHash='b'*64,manifestSHA256=digest,acceptedAttemptID=str(uuid.uuid4()),counts=manifest['counts'],binary=binary,
                   ownPin=dict(accountID=account,rootFingerprint='a'*64,highWater=3,checkpointDigest=base64.urlsafe_b64encode(bytes([3])*32).decode().rstrip('=')),
                   offlineVerified=False,networkReloadVerified=True,secretsVerified=1)
        return value,manifest,nonce,binary,digest
    def validate(self, value, manifest, nonce, binary, digest):
        return launcher.validate_evidence(value,manifest,nonce,'first',321,binary,digest)
    def test_complete_matching_evidence(self):
        self.validate(*self.fixture())
    def test_reject_malformed_or_stale_evidence(self):
        faults=['runID','accountID','teamID','vaultID','generationID','launchNonce','pid','bool_pid','sequence','bool_sequence',
                'nativeGuiTestHost','productGuiAcceptance','networkReloadVerified','offlineVerified','manifestSHA256',
                'acceptedAttemptID','secretsVerified','counts','ownPin','rootFingerprint','publicKey','extra','partial','phase','status','binary']
        for fault in faults:
            with self.subTest(fault=fault):
                value,manifest,nonce,binary,digest=self.fixture(); bad=copy.deepcopy(value)
                if fault in ['accountID','teamID','vaultID','generationID','launchNonce']: bad[fault]=str(uuid.uuid4())
                elif fault=='pid': bad[fault]=322
                elif fault=='bool_pid': bad['pid']=True
                elif fault=='sequence': bad[fault]=1
                elif fault=='bool_sequence': bad['sequence']=True
                elif fault in ['nativeGuiTestHost','networkReloadVerified']: bad[fault]='true'
                elif fault=='productGuiAcceptance': bad[fault]=0
                elif fault=='offlineVerified': bad[fault]='false'
                elif fault=='manifestSHA256': bad[fault]='f'*64
                elif fault=='acceptedAttemptID': bad[fault]=''
                elif fault=='secretsVerified': bad[fault]=0
                elif fault=='counts': bad[fault]['hosts']=True
                elif fault=='ownPin': del bad[fault]
                elif fault=='rootFingerprint': bad['ownPin'][fault]='b'*64
                elif fault=='publicKey': bad[fault]['privateKey']='forbidden'
                elif fault=='extra': bad['unreviewed']=True
                elif fault=='partial': del bad['binary']
                elif fault=='binary': bad[fault]['testBundleSHA256']='f'*64
                elif fault=='phase': bad[fault]='resume'
                elif fault=='status': bad[fault]='MATERIALIZED'
                else: bad[fault]='other-run'
                with self.assertRaises((ValueError,KeyError,TypeError)): self.validate(bad,manifest,nonce,binary,digest)
    def test_wrong_actual_binary_even_if_payload_self_consistent(self):
        value,manifest,nonce,binary,digest=self.fixture()
        actual=copy.deepcopy(binary); actual['executableSHA256']='f'*64
        with self.assertRaises(ValueError): self.validate(value,manifest,nonce,actual,digest)
    def test_two_distinct_processes_same_native_key_required(self):
        first,_,_,_,_=self.fixture(); resumed=copy.deepcopy(first)
        resumed.update(phase='resume',pid=322,processID=str(uuid.uuid4()),previousProcessID=first['processID'],offlineVerified=True,launchNonce=str(uuid.uuid4()))
        launcher.validate_pair(first,resumed)
        for field in ['deviceID','generationID','manifestSHA256','headerHash']:
            bad=copy.deepcopy(resumed); bad[field]=str(uuid.uuid4()) if field.endswith('ID') else 'f'*64
            with self.subTest(field=field), self.assertRaises(ValueError): launcher.validate_pair(first,bad)

if __name__=='__main__': unittest.main()
