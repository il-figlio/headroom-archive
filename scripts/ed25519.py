"""Minimal Ed25519 (RFC 8032 section 6 reference algorithm) for release checks.

The release scripts sign with Sparkle's own sign_update. This independent
verifier confirms each signature against the SUPublicEDKey the app ships with,
so a feed or archive signed by the wrong key never gets published. It only
handles public data; it is not constant-time and must not be used to sign.
"""
import hashlib

P = 2 ** 255 - 19
L = 2 ** 252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _recover_x(y, sign):
    if y >= P:
        return None
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P)
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P:
        return None
    return P - x if (x & 1) != sign else x


_GY = 4 * pow(5, P - 2, P) % P
_GX = _recover_x(_GY, 0)
G = (_GX, _GY, 1, _GX * _GY % P)


def _add(a, b):
    k1 = (a[1] - a[0]) * (b[1] - b[0]) % P
    k2 = (a[1] + a[0]) * (b[1] + b[0]) % P
    k3 = 2 * a[3] * b[3] * D % P
    k4 = 2 * a[2] * b[2] % P
    e, f, g, h = k2 - k1, k4 - k3, k4 + k3, k2 + k1
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _mul(scalar, point):
    result = (0, 1, 1, 0)
    while scalar:
        if scalar & 1:
            result = _add(result, point)
        point = _add(point, point)
        scalar >>= 1
    return result


def _equal(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % P == 0 and (a[1] * b[2] - b[1] * a[2]) % P == 0


def _compress(point):
    zinv = pow(point[2], P - 2, P)
    x, y = point[0] * zinv % P, point[1] * zinv % P
    return int.to_bytes(y | ((x & 1) << 255), 32, 'little')


def _decompress(data):
    if len(data) != 32:
        return None
    y = int.from_bytes(data, 'little')
    sign, y = y >> 255, y & ((1 << 255) - 1)
    x = _recover_x(y, sign)
    return None if x is None else (x, y, 1, x * y % P)


def public_key(private):
    """Public key for a Sparkle private key: a 32-byte seed (current
    generate_keys export) or the legacy 64-byte expanded secret."""
    if len(private) == 32:
        digest = hashlib.sha512(private).digest()
        scalar = int.from_bytes(digest[:32], 'little')
        scalar = (scalar & ((1 << 254) - 8)) | (1 << 254)
    elif len(private) == 64:
        scalar = int.from_bytes(private[:32], 'little')
    else:
        raise ValueError('Sparkle EdDSA private keys are 32 or 64 bytes')
    return _compress(_mul(scalar, G))


def verify(public, message, signature):
    if len(public) != 32 or len(signature) != 64:
        return False
    a, r = _decompress(public), _decompress(signature[:32])
    s = int.from_bytes(signature[32:], 'little')
    if a is None or r is None or s >= L:
        return False
    h = int.from_bytes(hashlib.sha512(signature[:32] + public + message).digest(), 'little') % L
    return _equal(_mul(s, G), _add(r, _mul(h, a)))
