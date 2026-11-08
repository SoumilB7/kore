# Writes Tests/Fixtures/link/v2 from first principles, apart from the Swift code; run from the repo root: python3 -I scripts/fixtures/gen_link_v2.py (needs the `cryptography` package).
import base64, hashlib, json, os, struct, sys, uuid
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes, serialization

out = sys.argv[1] if len(sys.argv) > 1 else 'Tests/Fixtures/link/v2'
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

def h(label): return hashlib.sha256(label.encode()).digest()
def key(label):
    d = int.from_bytes(h(label), 'big') % (N - 1) + 1
    k = ec.derive_private_key(d, ec.SECP256R1())
    return k, d.to_bytes(32, 'big')
def spki(k): return k.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
def sign(k, msg):
    # RFC 6979: the same inputs give the same bytes on every run.
    s = k.sign(msg, ec.ECDSA(hashes.SHA256(), deterministic_signing=True))
    k.public_key().verify(s, msg, ec.ECDSA(hashes.SHA256()))
    return s
def b64(b): return base64.b64encode(b).decode()
def lp(fields):
    o = b''
    for f in fields:
        if isinstance(f, str): f = f.encode()
        elif isinstance(f, uuid.UUID): f = f.bytes
        o += struct.pack('>I', len(f)) + f
    return o
def dump(name, obj):
    with open(os.path.join(out, name), 'w') as fh:
        json.dump(obj, fh, indent=2, sort_keys=True)
        fh.write('\n')

ck, cpriv = key('kore-fixture client identity')
sk, spriv = key('kore-fixture server identity')
rk, rpriv = key('kore-fixture phone raise')
devC = uuid.UUID('6F1C3A52-0B7E-4C1D-9A3F-2E5B8D7C1A01')
devS = uuid.UUID('B3D9E1F0-7A2C-4E6B-8D41-5C0F9A3E2B02')
nonceS = h('kore-fixture nonceS')
nonceC = h('kore-fixture nonceC')
nodeC = 'nodekey:0b9928ce1a750061cf43ccd9edc42b6c4655af7c601f91216773d0de0f684116'
nodeS = 'nodekey:13870e57678032e53f4481b8ecb1d8350cbb001db281e15a675106e2375b4247'

def binding(route, nkC, nkS):
    pre = lp(['kore-bind/2', route, nonceS, nonceC, devC, devS, nkC, nkS])
    return pre, hashlib.sha256(pre).digest()

pre, B = binding('tailnet', nodeC, nodeS)
sigC, sigS = sign(ck, B), sign(sk, B)
spre, sB = binding('ssh', 'ssh', 'ssh')
ssigC, ssigS = sign(ck, sB), sign(sk, sB)
dump('bind.json', {
    'about': 'B = SHA256("kore-bind/2" | route | nonceS | nonceC | deviceC | deviceS | nodeKeyC | nodeKeyS); each side signs B.',
    'encoding': 'each field: u32 big-endian byte length, then its bytes. Strings UTF-8; device ids their 16 bytes in RFC 4122 order; nonces 32 bytes.',
    'signature': 'ECDSA P-256 with SHA-256 over the 32 bytes of B (Android SHA256withECDSA), DER. Public keys X.509 SubjectPublicKeyInfo DER, base64.',
    'client': {'device': str(devC).upper(), 'privateKey': cpriv.hex(), 'publicKey': b64(spki(ck))},
    'server': {'device': str(devS).upper(), 'privateKey': spriv.hex(), 'publicKey': b64(spki(sk))},
    'nonceS': nonceS.hex(), 'nonceC': nonceC.hex(),
    'tailnet': {'route': 'tailnet', 'nodeKeyC': nodeC, 'nodeKeyS': nodeS, 'preimage': pre.hex(), 'B': B.hex(), 'sigC': b64(sigC), 'sigS': b64(sigS)},
    'ssh': {'route': 'ssh', 'nodeKeyC': 'ssh', 'nodeKeyS': 'ssh', 'preimage': spre.hex(), 'B': sB.hex(), 'sigC': b64(ssigC), 'sigS': b64(ssigS)},
})

rnonce = h('kore-fixture raise nonce')
chat, mode = 'chat-7f3a', 'auto'
rpre = lp(['kore-raise/1', B, rnonce, chat, mode])
rd = hashlib.sha256(rpre).digest()
rsig = sign(rk, rd)
dump('raise.json', {
    'about': 'digest = SHA256("kore-raise/1" | B | nonce | chatId | modeId), same field encoding as bind.json; the phone signs the digest with kore_raise. B is bind.json tailnet.B.',
    'signature': 'ECDSA P-256 with SHA-256 over the 32-byte digest, DER.',
    'raiseKey': {'privateKey': rpriv.hex(), 'publicKey': b64(spki(rk))},
    'B': B.hex(), 'nonce': rnonce.hex(), 'chatId': chat, 'modeId': mode, 'ttlSeconds': 60,
    'preimage': rpre.hex(), 'digest': rd.hex(), 'sig': b64(rsig),
})

def frame(q, f, s, p): return struct.pack('>IBBI', len(p), q, f, s) + p
valid = [
    ('control hello-sized', 0, 0, 0, b'{"t":"credit","n":65536}'),
    ('interactive command', 0, 0, 7, b'{"cmd":"chat.send"}'),
    ('stream empty', 1, 0, 9, b''),
    ('stream last stream id', 1, 0, 0xFFFFFFFF, bytes(range(16))),
]
frag_payload = b'stream message in two fragments'
frag = [frame(1, 1, 3, frag_payload[:14]).hex(), frame(1, 0, 3, frag_payload[14:]).hex()]
inter = frame(0, 0, 5, b'{"cmd":"stop"}').hex()
invalid = [
    ('payload over 64 KiB', frame(1, 0, 3, b'')[:0] + struct.pack('>IBBI', 65537, 1, 0, 3), False, 'tooLong'),
    ('unknown queue', frame(2, 0, 3, b'x'), False, 'badQueue'),
    ('unknown flag', frame(0, 2, 3, b'x'), False, 'badFlags'),
    ('fragmented control', frame(0, 1, 0, b'x'), False, 'control'),
    ('control on stream queue', frame(1, 0, 0, b'x'), False, 'control'),
    ('pre-auth frame over 4 KiB', struct.pack('>IBBI', 4096 - 10 + 1, 0, 0, 0), True, 'preAuth'),
    ('pre-auth off stream 0', frame(0, 0, 1, b'x'), True, 'preAuth'),
    ('pre-auth second frame', frame(0, 0, 0, b'{}') + frame(0, 0, 0, b'{}'), True, 'preAuth'),
    ('queue changed mid-message', frame(1, 1, 3, b'a') + frame(0, 0, 3, b'b'), False, 'queueChanged'),
]
dump('frames.json', {
    'about': 'u32 len | u8 queue | u8 flags | u32 stream | payload, big endian; len counts the payload only. queue 0 interactive, 1 stream; flags bit 0 MORE (others must be 0); stream 0 is the session control stream (interactive, never fragmented).',
    'limits': {'headerSize': 10, 'maxPayload': 65536, 'maxMessage': 16777216, 'maxPartialStreams': 64, 'preAuthMaxFrame': 4096},
    'valid': [{'name': n, 'queue': q, 'flags': f, 'stream': s, 'payload': p.hex(), 'encoded': frame(q, f, s, p).hex()} for n, q, f, s, p in valid],
    'fragmented': {'about': 'a stream message in two fragments (MORE on the first), an interactive message between them; any fragment may carry up to maxPayload bytes', 'frames': [frag[0], inter, frag[1]],
                   'messages': [{'queue': 0, 'stream': 5, 'payload': b'{"cmd":"stop"}'.hex()},
                                {'queue': 1, 'stream': 3, 'payload': frag_payload.hex()}]},
    'invalid': [{'name': n, 'encoded': e.hex(), 'preAuth': pa, 'error': err} for n, e, pa, err in invalid],
})

ticket = h('kore-fixture ticket')[:16]
ticket2 = h('kore-fixture ticket 2')[:16]
compact = lambda o: json.dumps(o, sort_keys=True, separators=(',', ':'))
control = [
    ('challenge', {'t': 'challenge', 'v': 2, 'route': 'tailnet', 'device': str(devS).upper(), 'nonce': b64(nonceS)}),
    ('hello', {'t': 'hello', 'v': 2, 'service': 'link', 'device': str(devC).upper(), 'nonce': b64(nonceC), 'sig': b64(sigC), 'credit': 524288}),
    ('hello.ticket', {'t': 'hello', 'v': 2, 'service': 'link', 'device': str(devC).upper(), 'nonce': b64(nonceC), 'sig': b64(sigC), 'credit': 524288,
                      'ticket': b64(ticket)}),
    ('welcome', {'t': 'welcome', 'v': 2, 'sig': b64(sigS), 'credit': 524288, 'ticket': b64(ticket2), 'resumed': True, 'abilities': ['read', 'ask', 'run']}),
    ('resume', {'t': 'resume', 'cursors': {'chat.events': {'log': 'c-12', 's': 42}, 'pty': {'seq': 1048576}}}),
    ('credit', {'t': 'credit', 'n': 65536}),
    ('bye', {'t': 'bye', 'reason': 'revoked'}),
]
dump('control.json', {
    'about': 'Session control messages, JSON on stream 0; "json" is the exact compact form (sorted keys) an encoder gives. The hello carries only a resume ticket; the cursors follow in "resume", the client\'s first message after the welcome.',
    'messages': [{'name': n, 'json': compact(o)} for n, o in control],
})
dump('manifest.json', {
    'proto': {'major': 2, 'minor': 0},
    'files': {'bind': 'bind.json', 'raise': 'raise.json', 'frames': 'frames.json', 'control': 'control.json'},
    'capDomain': 'github.com/SoumilB7/kore/cap/device',
    'port': 47470,
})
print('ok')
