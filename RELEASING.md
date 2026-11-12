# Releasing

## Flow

- **devel**: every push runs `flutter analyze` + offline tests (`ci` workflow).
- **main**: only ever fast-forwarded from devel. Pushes run tests and a signed
  release build, so problems show up before a tag.
- **tags** `vX.Y.Z-alpha.N`, `vX.Y.Z-beta.N`, `vX.Y.Z`: the `release` workflow
  builds the signed APK and publishes it to Forgejo releases (alpha/beta as
  prereleases) with a changelog from the commit messages.

Start a release with `just`:

```bash
just release alpha          # ff main to devel, tag v1.0.0-alpha.1 (or alpha.N+1)
just release beta           # next beta of the same version
just release stable         # finish the version: v1.0.0
just release beta minor     # after a stable: start v1.1.0-beta.1 (major|minor|patch|X.Y.Z)
just promote stable         # tag current main as-is, e.g. ship the tested beta
```

The script refuses to go backwards (beta -> alpha of the same version), to tag
the same commit twice on one channel, or to release unpushed devel commits.

## Versions

Nothing is committed for a release; `version:` in `pubspec.yaml` only matters
for local builds. CI derives:

- versionName: the tag without `v` (untagged main builds: `git describe`)
- versionCode: `commits on HEAD * 10 + channel` (alpha 1, beta 2, stable 3),
  always increasing because main only fast-forwards.

## One-time setup

1. Create the keystore (needs a JDK for `keytool`), and **back it up**: losing
   it means users must uninstall to get updates.

   ```bash
   just keystore
   ```

2. For local signed builds, create `android/key.properties` (gitignored):

   ```properties
   storeFile=upload.jks
   storePassword=...
   keyAlias=upload
   keyPassword=...
   ```

3. Add repository secrets in Forgejo (Settings -> Actions -> Secrets):

   | Secret | Value |
   |---|---|
   | `ANDROID_KEYSTORE_B64` | `base64 -w0 android/upload.jks` |
   | `ANDROID_KEYSTORE_PASSWORD` | store password |
   | `ANDROID_KEY_ALIAS` | `upload` |
   | `ANDROID_KEY_PASSWORD` | key password |
   | `RELEASE_TOKEN` | optional: access token with `write:repository`, only if the automatic token can't create releases |

4. Make sure a runner with the `docker` label is available to the repository.
