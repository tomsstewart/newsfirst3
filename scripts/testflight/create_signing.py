#!/usr/bin/env python3
"""First-time (or cert-revoked) setup: mint an Apple Distribution certificate and an
App Store provisioning profile via the App Store Connect REST API, using the ASC .p8 key.

WHY this exists: this Mac has no distribution cert, and the ASC key (App Manager role)
CANNOT create one through Xcode's cloud signing ("Cloud signing permission error"). But an
App Manager key CAN mint a cert via the raw API when you generate the private key locally.

Outputs (into the sibling secrets/ dir, OUTSIDE git):
  - newsfirst_dist.p12            (Apple Distribution cert + private key; LEGACY-encrypted so
                                   macOS `security import` accepts it. pass = DIST_P12_PASS)
  - newsfirst_appstore.mobileprovision   (also installed into ~/Library/MobileDevice/Provisioning Profiles/)
Then run scripts/testflight/upload.sh. Reuse these artifacts on later uploads — Apple caps
the number of distribution certs, so don't mint a new one every time.

Env overrides: SECRETS, ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID, DIST_P12_PASS.
"""
import json, time, base64, sys, os, urllib.request, urllib.error
from cryptography.hazmat.primitives.serialization import load_pem_private_key, pkcs12, Encoding, PrivateFormat
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives import hashes
from cryptography import x509
from cryptography.x509.oid import NameOID

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SECRETS = os.environ.get("SECRETS", os.path.join(os.path.dirname(REPO_ROOT), "secrets"))
P8 = os.environ.get("ASC_KEY_PATH", os.path.join(SECRETS, "AuthKey_55V4X5BLCW.p8"))
KID = os.environ.get("ASC_KEY_ID", "55V4X5BLCW")
ISS = os.environ.get("ASC_ISSUER_ID", "fa6e71c1-7386-4d1c-aa19-6f0ae3b85c15")
BUNDLE = "com.ant2555.newsfirst"
PROF_NAME = "NewsFirst AppStore CLI"
P12_PASS = os.environ.get("DIST_P12_PASS", "tempPW123").encode()
BASE = "https://api.appstoreconnect.apple.com"

def b64u(x): return base64.urlsafe_b64encode(x).rstrip(b"=")

def mint_jwt():
    k = load_pem_private_key(open(P8, "rb").read(), None)
    hdr = {"alg": "ES256", "kid": KID, "typ": "JWT"}
    now = int(time.time())
    pl = {"iss": ISS, "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"}
    si = b64u(json.dumps(hdr, separators=(",", ":")).encode()) + b"." + b64u(json.dumps(pl, separators=(",", ":")).encode())
    r, s = decode_dss_signature(k.sign(si, ec.ECDSA(hashes.SHA256())))
    return (si + b"." + b64u(r.to_bytes(32, "big") + s.to_bytes(32, "big"))).decode()

TOKEN = mint_jwt()

def api(method, path, body=None):
    req = urllib.request.Request(BASE + path, data=(json.dumps(body).encode() if body is not None else None), method=method)
    req.add_header("Authorization", "Bearer " + TOKEN); req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or "{}")

# 1) local key + CSR
priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
csr = (x509.CertificateSigningRequestBuilder().subject_name(x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, "NewsFirst Distribution"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Stewart Innovation Ltd"),
        x509.NameAttribute(NameOID.COUNTRY_NAME, "GB")])).sign(priv, hashes.SHA256()))

# 2) Apple Distribution cert
st, resp = api("POST", "/v1/certificates", {"data": {"type": "certificates",
    "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr.public_bytes(Encoding.PEM).decode()}}})
if st not in (200, 201):
    print("CERT_CREATE_FAILED", st, json.dumps(resp)[:600]); sys.exit(2)
cert_id = resp["data"]["id"]
cert = x509.load_der_x509_certificate(base64.b64decode(resp["data"]["attributes"]["certificateContent"]))
print("CERT_OK", cert_id, cert.subject.rfc4514_string())

# 3) LEGACY p12 (macOS `security` can't read cryptography's modern default -> MAC verification failed)
enc = (PrivateFormat.PKCS12.encryption_builder()
       .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
       .hmac_hash(hashes.SHA1()).build(P12_PASS))
os.makedirs(SECRETS, exist_ok=True)
p12_path = os.path.join(SECRETS, "newsfirst_dist.p12")
open(p12_path, "wb").write(pkcs12.serialize_key_and_certificates(b"NewsFirst Dist", priv, cert, None, enc))
print("P12_OK", p12_path)

# 4) bundleId id
st, resp = api("GET", "/v1/bundleIds?filter%5Bidentifier%5D=" + BUNDLE + "&limit=200")
bid = next((d["id"] for d in resp.get("data", []) if d["attributes"]["identifier"] == BUNDLE), None)
if not bid:
    print("BUNDLEID_NOT_FOUND", st, json.dumps(resp)[:400]); sys.exit(3)

# 5) App Store profile (delete any same-name first)
def make_profile():
    return api("POST", "/v1/profiles", {"data": {"type": "profiles",
        "attributes": {"name": PROF_NAME, "profileType": "IOS_APP_STORE"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}},
                          "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})
st, resp = make_profile()
if st not in (200, 201):
    _, lst = api("GET", "/v1/profiles?filter%5Bname%5D=" + urllib.request.quote(PROF_NAME))
    for d in lst.get("data", []):
        api("DELETE", "/v1/profiles/" + d["id"])
    st, resp = make_profile()
if st not in (200, 201):
    print("PROFILE_CREATE_FAILED", st, json.dumps(resp)[:600]); sys.exit(4)
uuid = resp["data"]["attributes"]["uuid"]
content = base64.b64decode(resp["data"]["attributes"]["profileContent"])
open(os.path.join(SECRETS, "newsfirst_appstore.mobileprovision"), "wb").write(content)
pp = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
os.makedirs(pp, exist_ok=True)
open(os.path.join(pp, uuid + ".mobileprovision"), "wb").write(content)
print("PROFILE_OK", PROF_NAME, uuid)
print("\nAdd/refresh in secrets/asc.env:")
print("  DIST_P12_PASS=" + P12_PASS.decode())
print("  DIST_PROFILE_UUID=" + uuid)
print("Then: scripts/testflight/upload.sh")
