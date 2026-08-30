# Third-party components in MirrorDeck

MirrorDeck's AirPlay receiver is built from third-party open-source code. All of
it is isolated in a single shared library, **`libMirrorCore.dylib`**, shipped at
`MirrorDeck.app/Contents/Frameworks/libMirrorCore.dylib`. The application binary
contains none of it and talks to the library only through the two-function C
interface in `native/include/mirror_bridge.h` (`mb_start`, `mb_stop` — the only
symbols the library exports).

| Component | Origin | License |
|---|---|---|
| AirPlay/RAOP protocol core | UxPlay `lib/` | **LGPL-2.1-or-later** |
| `playfair` (FairPlay handshake) | UxPlay `lib/playfair/` | **GPL-3.0** |
| llhttp | UxPlay `lib/llhttp/` | MIT |
| libplist | libimobiledevice | **LGPL-2.1-or-later** |
| libcrypto | OpenSSL 3 | Apache-2.0 |

License texts accompany this file: `LGPL-2.1.txt`, `GPL-3.0.txt`,
`MIT-llhttp.txt`. OpenSSL is Apache-2.0 (https://www.openssl.org/source/license.html).

## Rebuilding and replacing the library

You may rebuild `libMirrorCore.dylib` from source and run MirrorDeck against
your own build. Nothing in the application is tied to a particular build of it.

```sh
./scripts/bootstrap.sh    # fetch UxPlay at its pinned commit
./native/build.sh         # produces native/build/libMirrorCore.dylib
cp native/build/libMirrorCore.dylib \
   /Applications/MirrorDeck.app/Contents/Frameworks/libMirrorCore.dylib
codesign --force --sign - /Applications/MirrorDeck.app   # re-sign after replacing
```

Complete corresponding source for the components above is available from their
upstream projects at the commits pinned in `scripts/bootstrap.sh`:

- UxPlay (includes `playfair`, `llhttp`): https://github.com/FDH2/UxPlay
- libplist: https://github.com/libimobiledevice/libplist
- OpenSSL: https://github.com/openssl/openssl

## Status of this arrangement — read before distributing

Separating this code into a replaceable shared library is what **LGPL-2.1**
asks for: users can modify the LGPL parts and relink. That part is addressed by
the structure described above.

It does **not** resolve `playfair`, which is **GPL-3.0**. GPL-3.0 is strong
copyleft: combining it with other code generally requires the *combined work* to
be released under GPL-3.0, and unlike LGPL there is no linking exception that a
shared library satisfies. `playfair` is not optional — it performs the FairPlay
key exchange (`fairplay_decrypt`) without which no mirroring session can start.

Therefore MirrorDeck as currently built **cannot be distributed as a
closed-source product.** Options, in rough order of practicality:

1. **Release MirrorDeck itself under GPL-3.0.** Selling GPL software is
   permitted, but recipients may redistribute the source, which is usually
   incompatible with a paid-download business.
2. **Move the receiver into a separate GPL-3.0 process** that communicates with
   a proprietary UI over a local socket. Whether this constitutes separate works
   is a contested legal question, not a settled engineering pattern.
3. **Obtain different rights to a FairPlay implementation.** No permissively
   licensed one is known to exist.

**None of the above is legal advice.** It is an accurate description of what the
code is and where it came from, prepared so a qualified attorney can evaluate it.
