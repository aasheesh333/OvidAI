# Third-Party Notices

This project bundles the following third-party components. Each remains
under its own license; the project's own `LICENSE` does not supersede them.

## Fonts (`assets/fonts/`)

- **Inter** — Copyright (c) 2016 The Inter Project Authors.
  Licensed under the SIL Open Font License, Version 1.1.
  https://github.com/rsms/inter/blob/master/LICENSE.txt
- **JetBrains Mono** — Copyright (c) 2020 The JetBrains Mono Project Authors.
  Licensed under the SIL Open Font License, Version 1.1.
  https://github.com/JetBrains/JetBrainsMono/blob/master/OFL.txt

The full OFL text is available at https://openfontlicense.org/ and in the
upstream repositories linked above.

## Native sandbox payload (`android/app/src/main/jniLibs/`)

`libovid_bootstrap.so` files are zip archives of a Termux-derived Linux
userland (bash, coreutils, python, node, apt, and their dependencies).
Termux packages are distributed under their individual upstream licenses;
the bundled Termux signing keys (`assets/termux-keyring/`) are public keys.

## Dart / Flutter packages

All Dart and Flutter dependencies and their licenses are enumerated in
`pubspec.lock` and resolvable via `flutter pub deps`. Firebase, Google
Play services, and AndroidX components are governed by their respective
Google and Apache-2.0 terms.
