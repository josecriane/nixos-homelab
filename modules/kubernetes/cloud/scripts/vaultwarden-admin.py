import sys
import json
import base64
import os
import urllib.request
import urllib.error
import hashlib
import hmac

from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand
from cryptography.hazmat.primitives import hashes, serialization, padding as sym_padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.asymmetric import rsa, padding as asym_padding
from cryptography.hazmat.backends import default_backend

BASE_URL = sys.argv[1]
EMAIL = sys.argv[2]
PASSWORD = sys.argv[3]

KDF_ITERATIONS = 600000


def make_master_key(password, email, iterations):
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=32,
        salt=email.lower().encode("utf-8"),
        iterations=iterations,
        backend=default_backend(),
    )
    return kdf.derive(password.encode("utf-8"))


def make_master_password_hash(password, email, iterations):
    master_key = make_master_key(password, email, iterations)
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=32,
        salt=password.encode("utf-8"),
        iterations=1,
        backend=default_backend(),
    )
    return base64.b64encode(kdf.derive(master_key)).decode("utf-8")


def hkdf_expand(master_key, info, length=32):
    hkdf = HKDFExpand(
        algorithm=hashes.SHA256(),
        length=length,
        info=info.encode("utf-8"),
        backend=default_backend(),
    )
    return hkdf.derive(master_key)


def make_enc_key(master_key):
    stretched = hkdf_expand(master_key, "enc", 32)
    mac_key = hkdf_expand(master_key, "mac", 32)
    enc_key = os.urandom(32) + os.urandom(32)
    iv = os.urandom(16)
    cipher = Cipher(algorithms.AES(stretched), modes.CBC(iv), backend=default_backend())
    encryptor = cipher.encryptor()
    padder = sym_padding.PKCS7(128).padder()
    padded = padder.update(enc_key) + padder.finalize()
    ct = encryptor.update(padded) + encryptor.finalize()
    mac_data = iv + ct
    mac_val = hmac.new(mac_key, mac_data, hashlib.sha256).digest()
    # Type 2 = AesCbc256_HmacSha256_B64
    return "2." + base64.b64encode(iv).decode() + "|" + base64.b64encode(ct).decode() + "|" + base64.b64encode(mac_val).decode(), enc_key


def encrypt_string(plaintext, enc_key):
    key = enc_key[:32]
    mac_key = enc_key[32:64]
    iv = os.urandom(16)
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
    encryptor = cipher.encryptor()
    padder = sym_padding.PKCS7(128).padder()
    padded = padder.update(plaintext) + padder.finalize()
    ct = encryptor.update(padded) + encryptor.finalize()
    mac_data = iv + ct
    mac_val = hmac.new(mac_key, mac_data, hashlib.sha256).digest()
    return "2." + base64.b64encode(iv).decode() + "|" + base64.b64encode(ct).decode() + "|" + base64.b64encode(mac_val).decode()


def encrypt_with_rsa(plaintext, public_key_pem):
    public_key = serialization.load_der_public_key(public_key_pem, backend=default_backend())
    ct = public_key.encrypt(
        plaintext,
        asym_padding.OAEP(
            mgf=asym_padding.MGF1(algorithm=hashes.SHA1()),
            algorithm=hashes.SHA1(),
            label=None,
        ),
    )
    # Type 4 = Rsa2048_OaepSha1_B64
    return "4." + base64.b64encode(ct).decode()


def generate_rsa_keypair():
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
        backend=default_backend(),
    )
    public_key = private_key.public_key()
    pub_der = public_key.public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    priv_der = private_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    return pub_der, priv_der


def api_request(path, data=None, token=None, method=None):
    url = BASE_URL + path
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    body = json.dumps(data).encode("utf-8") if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8") if e.fp else ""
        print(f"HTTP {e.code} on {path}: {error_body}", file=sys.stderr)
        raise


def form_request(path, data, token=None):
    import urllib.parse
    url = BASE_URL + path
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    if token:
        headers["Authorization"] = "Bearer " + token
    body = urllib.parse.urlencode(data).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8") if e.fp else ""
        print(f"HTTP {e.code} on {path}: {error_body}", file=sys.stderr)
        raise


def login(email, password_hash):
    import urllib.parse
    import uuid
    data = {
        "grant_type": "password",
        "username": email,
        "password": password_hash,
        "scope": "api offline_access",
        "client_id": "web",
        "deviceType": "10",
        "deviceName": "vaultwarden-setup",
        "deviceIdentifier": str(uuid.uuid4()),
    }
    return form_request("/identity/connect/token", data)


def register_user(email, master_password_hash, enc_key_str, pub_b64, enc_priv_b64):
    data = {
        "email": email,
        "name": email.split("@")[0],
        "masterPasswordHash": master_password_hash,
        "masterPasswordHint": "",
        "key": enc_key_str,
        "kdf": 0,
        "kdfIterations": KDF_ITERATIONS,
        "keys": {
            "publicKey": pub_b64,
            "encryptedPrivateKey": enc_priv_b64,
        },
    }
    return api_request("/api/accounts/register", data)


def main():
    import urllib.parse

    print("Deriving master key...")
    master_key = make_master_key(PASSWORD, EMAIL, KDF_ITERATIONS)
    master_password_hash = make_master_password_hash(PASSWORD, EMAIL, KDF_ITERATIONS)
    enc_key_str, enc_key_raw = make_enc_key(master_key)

    print("Generating RSA keypair...")
    pub_der, priv_der = generate_rsa_keypair()
    pub_b64 = base64.b64encode(pub_der).decode("utf-8")
    enc_priv_b64 = encrypt_string(priv_der, enc_key_raw)

    # Try login first (idempotency: user may already exist)
    try:
        print("Attempting login (checking if user exists)...")
        token_resp = login(EMAIL, master_password_hash)
        access_token = token_resp["access_token"]
        print("User already exists, logged in successfully")
    except urllib.error.HTTPError:
        print("User does not exist, registering...")
        register_user(EMAIL, master_password_hash, enc_key_str, pub_b64, enc_priv_b64)
        print("Registration successful, logging in...")
        token_resp = login(EMAIL, master_password_hash)
        access_token = token_resp["access_token"]
        print("Login successful")

    # Check if org already exists
    print("Checking existing organizations...")
    sync = api_request("/api/sync?excludeDomains=true", token=access_token)
    orgs = sync.get("profile", {}).get("organizations", [])
    org_exists = any(o.get("name") == "Homelab Admin" for o in orgs)

    if org_exists:
        print("Organization 'Homelab Admin' already exists, skipping creation")
    else:
        print("Creating organization 'Homelab Admin' with collection 'Services'...")
        # Need to encrypt the org key with the user's public key
        org_sym_key = os.urandom(64)
        enc_org_key = encrypt_with_rsa(org_sym_key, pub_der)

        # Generate org RSA keypair
        org_pub_der, org_priv_der = generate_rsa_keypair()
        org_pub_b64 = base64.b64encode(org_pub_der).decode("utf-8")
        enc_org_priv = encrypt_string(org_priv_der, org_sym_key)

        enc_collection_name = encrypt_string("Services".encode("utf-8"), org_sym_key)

        org_data = {
            "name": "Homelab Admin",
            "billingEmail": EMAIL,
            "collectionName": enc_collection_name,
            "key": enc_org_key,
            "keys": {
                "publicKey": org_pub_b64,
                "encryptedPrivateKey": enc_org_priv,
            },
            "planType": 0,
        }
        org_resp = api_request("/api/organizations", org_data, token=access_token)
        print(f"Organization created: {org_resp.get('id', 'unknown')}")

    print("SETUP_COMPLETE")


if __name__ == "__main__":
    main()
