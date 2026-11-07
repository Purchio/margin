# Margin

I wanted to read a book on my iPad and mark it up the way I would a real book. Underline something, highlight a sentence, write a thought in the margin. I couldn't find an easy way to do that the way I wanted, so I built Margin for myself.

It's a small iPad app for reading DRM-free EPUBs and writing on the pages with Apple Pencil. I'm sharing the source in case someone else wants the same thing.

![Margin's illustrated library with sample books and an Add EPUB button](docs/demo/margin-library.jpg)

*Illustrative library preview with original sample content, not a screenshot of my personal books.*

## A quick look

These videos are animated previews of the idea, not recordings of the running app. The books, prose and handwritten marks are demo content.

### 20-second overview

https://github.com/user-attachments/assets/449f58af-3ed7-4229-9d72-a28fc728949c

### 10-second cut

https://github.com/user-attachments/assets/1347e2a4-6853-4c99-8587-bf101bc7583c

If the players don't appear in your GitHub app, [open the 20-second video](https://github.com/user-attachments/assets/449f58af-3ed7-4229-9d72-a28fc728949c) or [the 10-second video](https://github.com/user-attachments/assets/1347e2a4-6853-4c99-8587-bf101bc7583c) in your browser.

![Illustrated reading view with a highlighted sentence and a handwritten margin note](docs/demo/margin-pencil.jpg)

*Illustrative reading preview. Physical Apple Pencil testing on this public build is still outstanding.*

## What it does

- Keeps your imported books in a simple library.
- Gives each page wide margins for notes.
- Lets you write, highlight and erase with Apple Pencil, with finger scrolling and pinch-to-zoom.
- Saves drawings locally for each book and remembers your reading position.
- Opens the existing library copy when you import the exact same EPUB again.

Your marks are saved separately from the original EPUB. They are meant to stay with that book when you close and reopen it, rather than disappear at the end of a reading session. They aren't written back into the EPUB, and there isn't cross-device sync or a notes-export feature yet. Deleting the app can delete its local books and drawings.

## Why EPUB?

For a normal text-heavy book, EPUB can be a better starting point than PDF. It carries the book's text and structure, so a reader can usually lay it out for the screen instead of squeezing a printed page onto an iPad. PDFs are useful when the exact original layout matters, especially for things like forms, diagrams or scanned pages.

Margin takes an EPUB and creates its own fixed pages on the iPad, with room around the text for your notes. It uses a PDF internally so the writing stays in the same place. That does mean you can't change the font size or reflow the pages after import in this version.

Margin imports **DRM-free EPUB**, not arbitrary PDF files. It won't unlock protected books, and complex EPUB layouts may not render perfectly. Bring books you have permission to use.

## How to try it

Margin is **not on the App Store or TestFlight yet**. Right now this is a source release for people who can build it with Xcode. Downloading the repository alone won't install an app on your iPad.

You'll need a Mac with a recent Xcode, an iPad running iPadOS 17 or later, and an Apple account set up for development signing. Apple Pencil is needed for the intended handwriting experience. You can also try importing and reading in an iPad simulator without connecting a device.

1. Clone this repository, or use **Code → Download ZIP** and unzip it.
2. Open `Margin.xcodeproj` in Xcode.
3. To try the simulator, select an iPad simulator and click **Run**.
4. To install on your own iPad, connect and trust it, select it in Xcode, and choose your development team under **Signing & Capabilities**.
5. Set a unique bundle identifier and click **Run**. Follow Apple's device-trust or Developer Mode prompts if required. Signing eligibility and expiration depend on your Apple account.

The project uses `com.example.margin.reader` as a placeholder. Give this build its own identity so you don't replace another copy of Margin and its data.

### Open a book

1. Save a DRM-free `.epub` file in the iPad's **Files** app.
2. Open Margin and tap **Add EPUB**.
3. Choose the file and let Margin prepare its pages.
4. Open the book from the library, read, and use the Pencil tools to mark it up.

Everything is prepared on-device. There are no API keys or external Swift packages to configure.

## Still a work in progress

The clean build passed an iPad simulator test: importing an original test EPUB, rendering it, and finding it in the library after relaunch. There are also five repeatable importer smoke checks.

Physical Apple Pencil drawing and reopening drawings on this public build, wider EPUB compatibility, and accessibility still need testing. See [VERIFICATION.md](VERIFICATION.md) and the [release checklist](RELEASE-CHECKLIST.md).

If enough people are interested, I might look into an App Store release. No timeline or promise yet. For now, if this is something you'd use, a star or an issue with feedback helps me know.

## Privacy

No account, backend, analytics SDK or cloud-sync feature is included. Imported books and notes live in the app's local container. Your device's backups and whichever Files provider you use are separate services. No commercial books, personal reading history or private notes are bundled. More in [PRIVACY.md](PRIVACY.md).

## For developers

Built with SwiftUI, UIKit, PencilKit, WebKit, PDFKit, CryptoKit and system zlib.

Run the importer checks on a Mac with Xcode installed:

```sh
python3 scripts/test-importer.py
```

## License

Code and documentation are [MIT licensed](LICENSE). Books keep their own copyrights. The illustrative videos and stills aren't offered under an additional open media license; see [demo details](docs/demo/README.md).
