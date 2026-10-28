# ShrinkML Import

把 ShrinkML 的交付 zip 匯入 Xcode 專案旁的本機 Swift 套件 `ShrinkMLModels/`。離線：沒有任何網路程式碼、不需要任何金鑰、不會被連進你的 App。

Imports the hand-over zip that ShrinkML gives you into a local Swift package, `ShrinkMLModels/`, next to your Xcode project. Offline: no network code, no key, and nothing from this package is linked into your app.

## What is in it

| Product                    | What it is                                                                                      |
| -------------------------- | ----------------------------------------------------------------------------------------------- |
| `shrinkml-import`          | the command-line tool: checks a hand-over (sha256, paths, sizes), then writes `ShrinkMLModels/` |
| `shrinkml-import` (plugin) | the command plugin that runs the tool with permission to write that folder                      |
| `shrinkml-import-plan`     | the same without any write permission: shows what an import would change                        |
| `ShrinkMLImportKit`        | the library behind both (nothing in your app depends on it)                                     |

Your `ShrinkMLModels/Package.swift` depends on this package only so that the two plugins show up on that package.

## Add it to Xcode

Add the package by URL, from 0.9.0: in Xcode, File, Add Package Dependencies, paste `https://github.com/teyrallc/shrinkml-xcode`, and choose "Up to Next Major Version" from `0.9.0`. (A `ShrinkMLModels/Package.swift` that ShrinkML or this tool writes already carries that dependency.)

在 Xcode 裡：File，Add Package Dependencies，貼上 `https://github.com/teyrallc/shrinkml-xcode`，選「Up to Next Major Version」，從 `0.9.0` 起。ShrinkML 或這個工具產生的 `ShrinkMLModels/Package.swift` 已經帶著這個相依。

## Use it

1. Drop the zip you downloaded from ShrinkML into `ShrinkMLModels/Inbox/` (the first time, the tool can make the folder: `--create`).
2. In the `ShrinkMLModels` folder, look first: `swift package shrinkml-import-plan`. Then import: `swift package --allow-writing-to-package-directory shrinkml-import`.
3. Add `ShrinkMLModels` to your project (File, Add Package Dependencies, Add Local) and `import ShrinkMLModels`.

Importing twice changes nothing. A file you edited is never overwritten: the new text is written beside it as `<name>.new`. Your own code goes in `Sources/<Model>/Overrides/`.

The first import, from a checkout of this repository:

    swift run --package-path <this checkout> shrinkml-import --apply --create --package ShrinkMLModels

Two flags are for programs (ShrinkML Desktop's "Put in Xcode" button uses both): `--add <zip>` puts one hand-over in `Inbox/` itself and imports only that file (a link is never followed; the same bytes already there change nothing; other bytes under that name are replaced only when the lock shows that an earlier import read exactly that file, otherwise the run stops), and `--json` prints one document, `shrinkml.import-report.v1`, instead of the text.

When you develop against a local checkout, add `--import-package <path to the checkout>`: `Package.swift` then points at the checkout instead of the public repository. Without it, `Package.swift` depends on this repository, `.package(url: "https://github.com/teyrallc/shrinkml-xcode.git", from: "0.9.0")` (the address is the one constant in `Sources/ShrinkMLImportKit/PublicRepository.swift`).

## Licence

Apache License 2.0: see `LICENSE`, and `NOTICE` for the copyright line (Copyright 2026 Teyra LLC).

## Where this comes from

This repository is the published copy of the ShrinkMLImport package, taken from the ShrinkML source tree by Teyra LLC at each release (the tests, which read that tree's contract files, stay there). Release `0.9.0` is the tag `v0.9.0`.
