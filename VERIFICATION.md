# Verification — November 7, 2026

- Generic iOS Simulator build succeeded with Xcode 27.2, signing disabled.
- Sanitized app launched in iPad Air 11-inch simulator with the empty library.
- Imported original synthetic EPUB, confirmed readable rendered page and saved metadata/PDF.
- Terminated/relaunched: imported book reappeared in the library.
- Repeatable importer smoke test passed five checks: valid original EPUB and metadata; rejection of traversal archive, DRM marker, missing chapter and invalid archive. Run `python3 scripts/test-importer.py` on macOS with Xcode installed.
- Source and binary checks found no bundled personal PDF, EPUB, drawing, backup, signing profile or key. Common secret-pattern scan passed; this is not a comprehensive security audit.
- MIT license added with owner approval. Public source release authorized by the owner.
- Original private app and source were not modified.

Still unverified on this release candidate: physical Apple Pencil drawing, drawing persistence, broad real-world EPUB compatibility and accessibility. The preview videos are illustrative animations, not evidence of runtime behavior.
