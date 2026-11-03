#!/usr/bin/env python3
"""Argument/exec composition test; upstream with-seat tests own FD semantics.
Only installed locations are mapped to disposable probe executables.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
source = (root/'weston/sglogin-weston').read_text()
assert source.count('/usr/libexec/multiseatd/with-seat') == 1
assert source.count('/usr/bin/weston') == 1
with tempfile.TemporaryDirectory(prefix='weston-entrypoint-') as temporary:
    work = Path(temporary)
    launcher = work/'entrypoint'
    seat = work/'with-seat'
    weston = work/'weston'
    launcher.write_text(source.replace('/usr/libexec/multiseatd/with-seat', str(seat)).replace('/usr/bin/weston', str(weston)))
    seat.write_text('#!/usr/bin/python3\nimport os,sys\nassert os.environ.pop("MULTISEATD_AUTHORITY_FD") == "59"\nos.execv(sys.argv[1],sys.argv[1:])\n')
    weston.write_text('#!/usr/bin/python3\nimport json,os,sys\nassert "MULTISEATD_AUTHORITY_FD" not in os.environ\nprint(json.dumps(sys.argv[1:]))\n')
    for path in (launcher, seat, weston): path.chmod(0o755)
    arguments = ['space argument', '$literal;', '', '--shell=desktop-shell.so']
    result = subprocess.check_output([str(launcher), *arguments], env={**os.environ, 'MULTISEATD_AUTHORITY_FD':'59'}, text=True)
    assert json.loads(result) == ['--backend=drm-backend.so', *arguments]
print('Weston entrypoint forwards exact arguments directly through with-seat')
