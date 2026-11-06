# 본인 Apple 계정으로 서명하고 iPad에 설치하기

처음에는 Mac의 **Xcode → Settings → Accounts**에서 Apple 계정에 로그인하고, 연결된 iPad를 **Window → Devices and Simulators**에서 확인하세요. 아래 명령의 세 변수에 본인의 기기 식별자(UDID), Apple Team ID, 고유한 번들 ID를 넣습니다. 이 값과 인증 자료는 Mac에서만 사용하세요.

1. **프로필 준비** — 아래 `prepare-signing` 명령이 Xcode로 작은 프로젝트를 빌드해 해당 기기와 번들 ID용 프로필을 준비합니다. 이미 가지고 있는 프로필을 쓰려면 바로 `sign --profile` 단계로 이동하세요.
2. **게임 서명** — `sign`에 기본 빌드 또는 선택 모드 빌드의 앱 경로를 전달하세요. 새 폴더에 서명한 사본을 만들고 실제 서명과 키체인 권한을 확인합니다.
3. **설치와 갱신** — `install`에 서명한 앱 경로를 전달하세요. 같은 캠페인을 이어갈 때는 처음 사용한 번들 ID와 팀을 유지하고, 게임을 저장하고 닫은 뒤 아래 갱신 예시를 따르세요. 이전 설치 영수증과 백업은 `work/`에 보관하세요.



These commands run on your Mac from the TFM2PAD repository root. They use your own Apple account, certificate, team, iPad and unique app identifier. No signing credentials or provisioning profiles are included in this repository.

## Prepare Xcode and your iPad

1. Install the full Xcode app, open it once and finish its component installation/license prompts. In **Xcode > Settings > Accounts**, sign in with your Apple account. A paid membership is optional for personal development: Xcode also supports a **Personal Team**. Personal Team device profiles expire **seven days** after issuance, so you must renew and reinstall periodically; Apple also applies account/device limits. See [Apple's account overview](https://developer.apple.com/help/account/basics/about-your-developer-account).
2. Connect your iPad, unlock it and accept **Trust This Computer**. In **Xcode > Window > Devices and Simulators**, select the iPad, wait for preparation to finish, and copy its **Identifier (UDID)**. Use that UDID in all commands, rather than the connection UUID that `devicectl` may display. Enable **Settings > Privacy & Security > Developer Mode** on the iPad when requested and complete its restart/confirmation.
3. Choose a unique reverse-domain identifier you own, such as `com.yourname.tfm2pad`. Find your **10-character team ID** in Xcode's account/team details or your Apple developer account. Keep the same bundle ID and team for every renewal and update. The internal unsigned identifier `org.tfm2pad.staging` cannot be installed through this helper.

Set your own values in your terminal; the examples below use these variables:

```sh
export TFM_BUNDLE_ID='com.yourname.tfm2pad'
export TFM_TEAM='YOURTEAMID'
export TFM_DEVICE_UDID='YOUR-IPAD-UDID'
```

If Xcode is installed somewhere other than `/Applications/Xcode.app`, or you want a particular Xcode version, set `DEVELOPER_DIR` to that app's `Contents/Developer` directory. An explicitly selected Xcode is respected.

## Obtain a profile through Xcode

```sh
python3 scripts/install.py prepare-signing \
  --bundle-id "$TFM_BUNDLE_ID" --team "$TFM_TEAM" \
  --device "$TFM_DEVICE_UDID" --work work/signing-01
```

This creates a tiny Xcode project, then runs `xcodebuild build` with automatic signing. Xcode may register the app ID/device and create or update your development certificate and profile using the account already signed in on your Mac. Keychain may ask you to permit signing. **It builds the helper without installing or launching it.** Its profile authorizes the same final bundle ID as the game. Do not run/install the signing helper over a game installation.

If Xcode needs interactive account setup, generate just the project instead:

```sh
python3 scripts/install.py prepare-signing \
  --bundle-id "$TFM_BUNDLE_ID" --team "$TFM_TEAM" \
  --device "$TFM_DEVICE_UDID" --work work/signing-ui --project-only
open work/signing-ui/TFM2PADSigning.xcodeproj
```

In Xcode select the `TFM2PADSigning` target, your team under **Signing & Capabilities**, **Automatically manage signing**, and your connected iPad as the destination. Choose **Product > Build**. Fix any signing errors Xcode displays, then locate the built `.app` using the Products group's **Show in Finder**. Supply that `.app` to `--xcode-app` in the next step. Apple describes [automatic signing and Personal Teams here](https://help.apple.com/xcode/mac/current/en.lproj/dev60b6fbbc7.html).

## Sign your unsigned game

First build your own installed game:

```sh
python3 scripts/build.py build --output work/first
```

Sign a fresh copy using the helper's embedded profile:

```sh
python3 scripts/install.py sign \
  --app work/first/app/TFM2Probe.app \
  --output work/signed-01/TFM2Probe.app \
  --xcode-app work/signing-01/DerivedData/Build/Products/Debug-iphoneos/TFM2PADSigning.app \
  --bundle-id "$TFM_BUNDLE_ID" --team "$TFM_TEAM" \
  --device "$TFM_DEVICE_UDID"
```

For an optional mod package, use the unsigned `package/TFM2Probe.app` produced by the mod command as `--app` instead. Existing provisioning files also work: replace `--xcode-app ...` with `--profile /path/to/your.mobileprovision`. The certificate's private key must already be in your Keychain. If several local certificates match the profile, select one with `--identity CERTIFICATE_SHA1`; `security find-identity -v -p codesigning` lists available identities. You do not need to export a private key.

The signer checks the profile's bundle authorization, Apple team, expiration, target UDID and locally available certificate. It assigns your identifier to a copy, signs native libraries and the app, then checks the actual code signature, certificate, team and entitlements, including the app-private Keychain group used for Steam login. A failed sign leaves the unsigned source untouched and publishes no completed output. The output path must be new.

## Install and preserve saves

For your first installation:

```sh
python3 scripts/install.py install \
  --app work/signed-01/TFM2Probe.app \
  --bundle-id "$TFM_BUNDLE_ID" --team "$TFM_TEAM" \
  --device "$TFM_DEVICE_UDID" --backup work/install-01
```

The installer rechecks signing and expiry, inspects installed apps and installs without launching. Keep `work/install-01/install.json` and its sibling `signing-check.json`: they identify your installation for future updates. If another app already owns your chosen identifier, the command refuses to replace it unless it can identify the game or its previous toolkit receipt.

Before an update, save and close the game on the iPad. Use the **same bundle ID and team**, a newly signed app, a new backup directory, and your previous successful installation receipt:

```sh
python3 scripts/install.py install \
  --app work/signed-02/TFM2Probe.app \
  --bundle-id "$TFM_BUNDLE_ID" --team "$TFM_TEAM" \
  --device "$TFM_DEVICE_UDID" --backup work/install-02 \
  --game-closed --previous-install work/install-01/install.json
```

For an existing installation, the script first checks whether the game's save directory exists using successful parent-directory listings, then backs up `Library/Application Support/com.TeamSamoyed.TeamfightManager2` and hashes its files. That tree contains the game's saves, backups and configuration. It updates in place and checks every pre-existing file hash afterward. An inaccessible directory or failed backup stops installation; a genuinely absent save tree is allowed. The script does not copy runtime libraries, caches or Steam session folders. It never uninstalls, launches, deletes the container, migrates accounts or restores saves automatically.

Keep the game closed until the command finishes. If it reports a save mismatch after installation, keep the `before` directory and `changed-files.json`, and inspect them before launching. Device disconnection or an install failure leaves the backups available. Never delete the existing app to troubleshoot signing: deleting it removes its local container. Choosing a different bundle ID creates a separate app/container and does not migrate the old saves; changing teams may also prevent updates and access to the old private Keychain group.

After installation, open the game yourself. If iPadOS requests developer trust, use **Settings > General > VPN & Device Management** and trust your development identity. Installation, app launch, Steam login and game compatibility are separate checks; a successful installation receipt only confirms installation.

## Renew an expired Personal Team profile

Repeat `prepare-signing` into a new directory such as `work/signing-02`, with the same ID/team/device. Sign the existing unsigned build or a freshly rebuilt app into `work/signed-02/TFM2Probe.app`, then run the update command above. Retain your previous signed app, backups and receipts. Resolve account, certificate, device-limit and profile errors in Xcode; the scripts do not revoke certificates or delete profiles to work around them.

Everything under `work/` is local and ignored by Git. Keep profiles, signing projects, certificates, device receipts, Steam data and saves private.
