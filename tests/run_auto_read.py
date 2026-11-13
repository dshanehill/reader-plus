#!/usr/bin/env python3
"""Exercise the actual pure state machine and AX adapter without speech or UI changes."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'Reader+.app/Contents/Resources/main.swift').read_text()
core = source[source.index('struct AIChatSnapshot {'):source.index('final class AIAutoReader {')]
fixture = (root / 'tests/auto_read.swift').read_text()
with tempfile.TemporaryDirectory(prefix='reader-ai-') as tmp:
    path = Path(tmp) / 'main.swift'
    path.write_text('import Foundation\n' + core + fixture)
    binary = Path(tmp) / 'auto-read'
    subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
