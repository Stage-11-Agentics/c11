#!/usr/bin/env python3
"""C11-552 guest precondition only; no c11 URL delivery or navigation.

Run via sandbox-tests-v2.sh. The outer runner must stop if this fails before
invoking test_external_panel_links_native.py.
"""
from pathlib import Path
import traceback

import test_external_panel_links_native as external

external.OUT = Path('/Volumes/My Shared Files/out/external-link-precondition')
external.native.OUT = external.OUT

if __name__ == '__main__':
    proof = external.Proof()
    try:
        proof.precondition()
        proof.report['status'] = 'passed'
    except BaseException as error:
        proof.report.update(status='failed', error=str(error), traceback=traceback.format_exc())
        try:
            proof.capture('failure')
        except Exception:
            pass
        raise
    finally:
        proof.cleanup()
