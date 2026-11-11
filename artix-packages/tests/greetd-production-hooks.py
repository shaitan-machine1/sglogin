#!/usr/bin/env python3
"""Run an extracted executable without installing or contacting live services."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
with tempfile.TemporaryDirectory(prefix='greetd-production-') as temporary:
    work = Path(temporary)
    binary = work/'greetd'
    binary.write_bytes(subprocess.check_output(['bsdtar', '-xOf', sys.argv[1], 'usr/bin/greetd']))
    binary.chmod(0o755)
    for hook in ('test_pam_dir', 'test_preload', 'test_library_path'):
        config = work/'config'
        config.write_text('[default_session]\ncommand = "/irrelevant/seat-launch /irrelevant/compositor"\n[multiseat]\nseat = "seat-test"\n'+hook+' = "/not/a/real/fixture"\n')
        result = subprocess.run([str(binary), '--config', str(config)], env={**os.environ, 'GREETD_TEST_MODE':'1'}, text=True, capture_output=True, timeout=5)
        assert result.returncode == 1 and 'require test-support' in result.stderr, (hook, result)
print('Production greetd archive rejects all private PAM/preload/library test hooks')
