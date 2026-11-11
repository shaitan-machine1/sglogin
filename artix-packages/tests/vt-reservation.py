#!/usr/bin/env python3
"""Validate the exact reservation without running udev or touching terminals."""
import fnmatch
import re
import sys


def validate(text):
    matched = set()
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = dict(re.findall(r'([A-Z]+)(?:==|=)"([^"]*)"', line))
        assert fields.get('SUBSYSTEM') == 'tty', line
        assert fields.get('OWNER') == fields.get('GROUP') == 'root', line
        assert fields.get('MODE') == '0600', line
        assert set(fields) == {'SUBSYSTEM', 'KERNEL', 'OWNER', 'GROUP', 'MODE'}, line
        pattern = fields['KERNEL']
        # Include unrelated device names to reject accidental general wildcards.
        universe = [f'tty{i}' for i in range(64)] + ['console', 'ttyS0', 'ttyUSB0', 'tty']
        covered = {name for name in universe if fnmatch.fnmatchcase(name, pattern)}
        assert covered, pattern
        assert not covered & matched, pattern
        matched |= covered
    assert matched == {f'tty{i}' for i in range(7, 13)} | {'tty0', 'console'}, matched


if __name__ == '__main__':
    validate(sys.stdin.read())
