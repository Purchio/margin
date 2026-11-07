# Privacy notes

This source contains no analytics SDK, login or backend endpoint. EPUB conversion occurs with a non-persistent WKWebView, JavaScript disabled and a restrictive Content Security Policy. Imported page copies, book metadata, Pencil drawings and reading positions are stored locally in the app container.

Files may originate from an external provider selected by the user. iOS may include app data in device backups; this project does not control those provider or operating-system services. It does not implement encrypted storage, export/restore or cross-device synchronization.

Do not post books, drawings, app-container exports, signing profiles or personal device logs in public issues. Report potential security problems privately to the maintainer through a channel confirmed on their GitHub profile. A dedicated reporting mechanism must be configured before public launch.
