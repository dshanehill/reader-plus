#!/usr/bin/env python3
"""Compile the repository's real implementation with isolated macOS regression fixtures.

Transport boundaries are replaced only in the pipeline fixture; speech and Vision tests
use the actual macOS engines. No fabricated mouse event is posted to the desktop.
"""
import argparse
import concurrent.futures
import json
from pathlib import Path
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORKS = ['AppKit', 'AVFoundation', 'Carbon', 'ApplicationServices', 'ServiceManagement', 'SwiftUI', 'Vision', 'ScreenCaptureKit']

def segment(source, start, end, replacement):
    first = source.index(start)
    last = source.index(end, first)
    return source[:first] + replacement + source[last:]

def prefix(source, suite, log_path):
    source = source[:source.rindex('let app = NSApplication.shared')]
    original = 'let prefs = UserDefaults.standard'
    assert original in source
    source = source.replace(original, f'let regressionSuiteName = {json.dumps(suite)}\nlet prefs = UserDefaults(suiteName: regressionSuiteName)!', 1)
    first = source.index('let logURL = ')
    last = source.index('\n', first)
    source = source[:first] + f'let logURL = URL(fileURLWithPath: {json.dumps(str(log_path))})' + source[last:]
    return source

def pipeline(source):
    source = segment(source, 'func clickUse(_ p: CGPoint', '/// Older check', '''func clickUse(_ p: CGPoint, hitElement: inout AXUIElement?, targetPID: inout pid_t) -> ClickUse {
    Thread.sleep(forTimeInterval: (p.x == 100 || p.x == 400) ? 0.01 : 0.25)
    targetPID = 8888
    return p.x >= 500 ? .readAndPass : .read
}

''')
    source = segment(source, 'func ownWindowHit(', '/// Selected text:', '''func ownWindowHit(_ cp: NSPoint) -> (inOwnWindow: Bool, textView: NSTextView?, index: Int) { (true, nil, 0) }

''')
    source = segment(source, 'func ax(_ e: AXUIElement', 'func axString', '''var graph: [Int: [String: Any]] = [:]
var nodes: [AXUIElement] = []
func ax(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
    guard AXWork.current?.expired != true, let i = nodes.firstIndex(where: { CFEqual($0, e) }) else { return nil }
    return graph[i]?[attr] as CFTypeRef?
}
''')
    source = segment(source, '    func read(at p: CGPoint, request:', '\n}\n\nlet clickTapCallback', '''    func read(at p: CGPoint, request: ReadRequest? = nil, hitElement: AXUIElement? = nil) {
        let r = request ?? begin()
        DispatchQueue.global().asyncAfter(deadline: .now() + ((p.x == 100 || p.x == 400) ? 0.4 : 0.03)) {
            DispatchQueue.main.async {
                guard r.valid else { return }
                testDelivered.append(Int(p.x))
                self.deliver(ReadSource(text: "Test \\(Int(p.x)).", element: nil, base: 0), request: r, showWindow: false)
            }
        }
    }
''')
    assert 'event.postToPid(targetPID)' in source
    source = source.replace('event.postToPid(targetPID)', 'testReplayed.append(event.copy()!); testReplayPIDs.append(targetPID)', 1)
    source = source.replace('var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }', 'var hasScreenRecording: Bool { false }', 1)
    source = segment(source, 'func askForScreenRecording() {', '/// Takes a picture', 'func askForScreenRecording() { permissionRequests += 1 }\n\n')
    return source

def build(name, source, folder):
    path = folder / f'{name}.swift'
    path.write_text(source)
    executable = folder / name
    command = ['xcrun', 'swiftc', '-O', '-swift-version', '5', str(path), '-o', str(executable)]
    for framework in FRAMEWORKS:
        command += ['-framework', framework]
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{name} compilation failed:\n{result.stdout}\n{result.stderr}')
    return executable

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--only', choices=['pipeline', 'speech'])
    args = parser.parse_args()
    actual = (ROOT / 'Reader+.app/Contents/Resources/main.swift').read_text()
    names = [args.only] if args.only else ['pipeline', 'speech']
    with tempfile.TemporaryDirectory(prefix='readerplus-regressions-') as scratch:
        folder = Path(scratch)
        sources = {}
        for name in names:
            suite = f'local.readerplus.regression.{uuid.uuid4().hex}'
            body = prefix(actual, suite, folder / f'{name}.log')
            if name == 'pipeline':
                body = pipeline(body)
            fixture = (ROOT / f'tests/{name}.swift').read_text()
            fixture = fixture.replace('exit(', 'prefs.removePersistentDomain(forName: regressionSuiteName); exit(')
            sources[name] = body + fixture
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            jobs = {name: pool.submit(build, name, sources[name], folder) for name in names}
            executables = {name: job.result() for name, job in jobs.items()}
        for name, executable in executables.items():
            print(f'RUN {name}', flush=True)
            result = subprocess.run([str(executable)], timeout=60)
            if result.returncode:
                log = folder / f'{name}.log'
                if log.exists():
                    print(log.read_text())
                raise SystemExit(f'{name} failed ({result.returncode})')
    print('ALL REQUESTED CHECKS PASSED', flush=True)

if __name__ == '__main__':
    main()
