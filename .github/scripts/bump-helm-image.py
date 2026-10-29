#!/usr/bin/env python3
"""Update image.tag and image.pullPolicy in a Helm values.yaml."""

from __future__ import annotations

import pathlib
import re
import sys

if len(sys.argv) != 3:
    raise SystemExit("Uso: bump-helm-image.py <values.yaml> <nova-tag>")

path = pathlib.Path(sys.argv[1])
new_tag = sys.argv[2]
text = path.read_text(encoding="utf-8")
posix_path = path.as_posix()
pull_policy = (
    "Always"
    if "ci-test-dev" in posix_path or "ci-test-hml" in posix_path
    else "IfNotPresent"
)

updated, tag_count = re.subn(
    r"(^image:\n(?:[ \t]+.+\n)*?[ \t]+tag:\s*)([\"']?)[^\n\"']+\2",
    rf'\1"{new_tag}"',
    text,
    count=1,
    flags=re.MULTILINE,
)
if tag_count != 1:
    raise SystemExit(f"Não foi possível atualizar image.tag em {path}")

updated, policy_count = re.subn(
    r"(^image:\n(?:[ \t]+.+\n)*?[ \t]+pullPolicy:\s*)([\"']?)[^\n\"']+\2",
    rf"\1{pull_policy}",
    updated,
    count=1,
    flags=re.MULTILINE,
)
if policy_count != 1:
    raise SystemExit(f"Não foi possível atualizar image.pullPolicy em {path}")

path.write_text(updated, encoding="utf-8")