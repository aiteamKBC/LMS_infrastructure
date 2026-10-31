"""Convert backend/.env into a Terraform tfvars file (app_secrets = {...}).

Parses .env exactly like config/settings.py:load_env_file, so the services get
the same values Django sees on the VPS. Prints only counts, never values.
Usage: python3 -I env_to_tfvars.py <path/to/.env> <path/to/output.tfvars>
"""
import hashlib
import json
import os
import re
import sys

# A real variable name. Lines of a multi-line value in .env (e.g. a pasted JSON
# service-account key) also contain '=' and would otherwise become junk "keys"
# holding pieces of the value. Django never reads those names, so skip them.
VALID_NAME = re.compile(r'^[A-Za-z_][A-Za-z0-9_-]*$')

LAST_DECLARATION_KEYS = {
    'MICROSOFT_CLIENT_ID', 'MICROSOFT_CLIENT_SECRET',
    'MICROSOFT_TENANT', 'MICROSOFT_TENANT_ID', 'MICROSOFT_CALLBACK_URI',
}


def parse(path):
    values = {}
    skipped = 0
    with open(path, encoding='utf-8') as f:
        for line in f.read().splitlines():
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            key, value = line.split('=', 1)
            key = key.strip()
            if not VALID_NAME.match(key):
                skipped += 1
                continue
            value = value.strip().strip('"').strip("'")
            if key in LAST_DECLARATION_KEYS or key not in values:
                values[key] = value
    return values, skipped


def hcl_string(value):
    value = value.replace('\\', '\\\\').replace('"', '\\"')
    # Stop Terraform treating ${ and %{ in a value as interpolation
    return '"' + value.replace('${', '$${').replace('%{', '%%{') + '"'


def main(env_path, out_path):
    values, skipped = parse(env_path)
    # Changes whenever any value changes, so terraform apply re-sends the
    # secret and restarts the services without a manual version bump
    digest = hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()
    version = int(digest[:8], 16)
    lines = [
        '# GENERATED from backend/.env - contains secrets, never commit or share.',
        '# Regenerate after changing .env: python3 -I scripts/env_to_tfvars.py ../backend/.env secrets.auto.tfvars',
        f'app_secrets_version = {version}',
        'app_secrets = {',
    ]
    lines += [f'  {hcl_string(k)} = {hcl_string(v)}' for k, v in sorted(values.items())]
    lines.append('}')
    fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    os.chmod(out_path, 0o600)
    empty = sum(1 for v in values.values() if not v)
    print(f'wrote {len(values)} keys ({empty} with empty values) to {out_path}; '
          f'skipped {skipped} lines that are not KEY=value (parts of multi-line values)')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
