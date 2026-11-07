#!/usr/bin/env python3
"""Compile the actual importer and check original/malformed EPUB fixtures on macOS."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import subprocess, tempfile, json
repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="margin-check-") as tmp:
    root = Path(tmp)
    base = {"mimetype":"application/epub+zip", "META-INF/container.xml":'<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>', "OPS/book.opf":'<package><metadata><title>Margin Release Test</title><creator>Margin Test Fixture</creator></metadata><manifest><item id="one" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/></spine></package>', "OPS/chapter.xhtml":'<html><body><h1>Room to think</h1><p>Original test text created for Margin verification.</p></body></html>'}
    for name, extra in [("valid", {}), ("traversal", {"../escape.txt":"no"}), ("protected", {"META-INF/encryption.xml":'<encryption><EncryptionMethod Algorithm="example-drm"/></encryption>'}), ("missing-chapter", {})]:
        with ZipFile(root/(name+".epub"), "w", ZIP_DEFLATED) as z:
            for key, value in (base|extra).items():
                if name == "missing-chapter" and key.endswith("chapter.xhtml"): continue
                z.writestr(key, value)
    (root/"invalid.epub").write_bytes(b"not an epub")
    harness = "\nlet root = URL(fileURLWithPath: " + json.dumps(str(root)) + ")\n" + r'''for name in ["valid", "traversal", "protected", "missing-chapter", "invalid"] {
        do {
            let source = try EPUBSource(url: root.appendingPathComponent(name + ".epub"))
            let dir = root.appendingPathComponent("out-" + name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let result = try source.prepare(in: dir, fallbackTitle: "Fallback")
            precondition(name == "valid", "Unsafe acceptance: " + name)
            precondition(result.title == "Margin Release Test")
            print("PASS valid original EPUB and metadata")
        } catch {
            precondition(name != "valid", "Valid fixture failed: \(error)")
            print("PASS rejected " + name)
        }
    }
'''
    source = root/"main.swift"
    source.write_text((repo/"Reader/EPUBSource.swift").read_text() + harness)
    subprocess.run(["xcrun", "swiftc", str(source), "-o", str(root/"check")], check=True)
    subprocess.run([str(root/"check")], check=True)
