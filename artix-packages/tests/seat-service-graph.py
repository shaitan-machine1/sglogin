#!/usr/bin/env python3
"""Compile only a disposable s6-rc graph; never start or install services."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
compiler = os.environ.get('S6_RC_COMPILE') or shutil.which('s6-rc-compile')
if not compiler or not Path(compiler).is_file():
    print('s6-rc-compile is required (or supply S6_RC_COMPILE)', file=sys.stderr)
    sys.exit(77)

expected = {f'{component}-seat{seat}-{kind}'
            for component in ('multiseatd', 'greetd')
            for seat in (0, 1) for kind in ('srv', 'log')}
assert {p.name for p in (root/'seat-services/services').iterdir()} == expected
external = {'dbus-srv', 'udevadm', 'mount-tmpfs', 'mount-cgroups', 'tmpfiles-setup'}
with tempfile.TemporaryDirectory(prefix='sglogin-seat-graph-') as temporary:
    work = Path(temporary)
    source = work/'source'
    source.mkdir()
    for directory in ('s6-services', 'seat-services'):
        for service in (root/directory/'services').iterdir():
            assert not (source/service.name).exists(), service
            shutil.copytree(service, source/service.name)
    for name in external:
        stub = source/name
        stub.mkdir()
        (stub/'type').write_text('oneshot\n')
        (stub/'up').write_text('/bin/true\n')
    for service in source.iterdir():
        dependencies = service/'dependencies.d'
        if dependencies.exists():
            assert all((source/p.name).is_dir() for p in dependencies.iterdir()), service
    bundle = source/'fixture-all'
    bundle.mkdir()
    (bundle/'type').write_text('bundle\n')
    contents = bundle/'contents.d'
    contents.mkdir()
    for name in expected | {'sessiond-srv', 'sessiond-log'}:
        (contents/name).touch()
    subprocess.run([compiler, str(work/'compiled'), str(source)], check=True, timeout=20)
    # A wrong seat dependency must fail rather than disappearing in the graph.
    (source/'greetd-seat1-srv/dependencies.d/multiseatd-missing-srv').touch()
    broken = subprocess.run([compiler, str(work/'broken'), str(source)], capture_output=True, timeout=20)
    assert broken.returncode != 0, broken
print('Four-output and independent sessiond s6-rc graph compiled; missing-owner fixture rejected')
