# Build from source

You need macOS 14 or later and the Command Line Tools (`xcode-select --install`). Xcode isn't needed.

```sh
./build.sh             # build build/Yafie.app
./build.sh --install   # build, copy to /Applications and open
./build.sh --pkg       # build the installer, downloads/Yafie.pkg, for Apple silicon and Intel
swift test             # run the unit tests
```

The installer copies Yafie into `/Applications`, hands it to the person installing (so **Check for Updates…** can replace it later), then opens it. Its scripts and closing page are in `Resources/pkg`.

## Signing

Every build is signed with one self-signed certificate, **Yafie Code Signing**. A stable signature means macOS keeps Yafie's permissions (Accessibility for window snapping, Microphone for the tuner) across updates. `./build.sh --pkg` refuses to run without it; other builds fall back to ad hoc signing.

- **First time:** `./Resources/make-signing-identity.sh` creates it in your login keychain. macOS asks for your password to trust it for code signing. The first build then asks to use the key: enter your password and click **Always Allow**.
- **Back it up:** in Keychain Access, select **Yafie Code Signing** under login → My Certificates, then choose File → Export Items… and save a .p12 with a password. Keep both somewhere safe. A new certificate would look like a new app to macOS, and everyone would have to allow Yafie again.
- **On another Mac:** double-click the .p12 to import it. Then open the certificate in Keychain Access and set Trust → Code Signing to **Always Trust**.
- **For GitHub:** the Release workflow signs with a copy stored in two repository secrets, `YAFIE_SIGNING_P12` (the .p12, base64) and `YAFIE_SIGNING_PASSWORD`. The workflow also checks that every release is signed by this certificate's fingerprint. If the certificate ever has to change, update both secrets and `CERTIFICATE_SHA1` in `.github/workflows/release.yml`.
- **Without trust:** a Mac can have the certificate without trusting it, like GitHub's Macs, where macOS won't let a job trust one. `codesign` refuses to use it there, so `build.sh` signs through the Security framework's signing API with `Resources/sign-untrusted.swift`. The result is the same signature.

## Release an update

1. Raise `CFBundleShortVersionString` in `Resources/Info.plist`. **Check for Updates…** only offers a higher version.
2. Commit and push. The Release workflow (`.github/workflows/release.yml`) does the rest on GitHub's Macs:
   - runs the tests
   - builds the installer with `./build.sh --pkg` and signs it
   - checks it the way **Check for Updates…** will
   - commits `downloads/Yafie.pkg`, `downloads/latest.json` and the README's version line to `main`

   Follow it under the repo's **Actions** tab. After it finishes, GitHub can take up to 5 minutes to serve the new files.

To try a build without publishing, choose **Actions → Release → Run workflow**, leaving **Publish** off. The installer is attached to the run.

Building the release yourself still works: run `./build.sh --pkg`, then commit and push `downloads/` along with the version. The workflow sees that the version is already published, so it only checks the build.

## Icon and artwork

Two masters drive the artwork: `Resources/AppIcon.png`, the app icon at 1024 × 1024 pixels on Apple's macOS icon grid, and `Resources/MenuIcon.png`, the menu bar's glyph, black on a clear background. The menu bar draws only the glyph's shape, not its colors, so parts that overlap, like the sunglasses on the Y, need a clear gap around them. After changing either, run:

```sh
./Resources/make-icon.swift
```

This rebuilds `Resources/AppIcon.icns`, the menu bar icons (`Resources/MenuIcon.tiff`, and the outlined `MenuIconOutline.tiff` it draws from the same glyph), `docs/icon.png` and `docs/social-preview.png`. GitHub takes the social preview by hand, under the repo's **Settings → Social preview**.
