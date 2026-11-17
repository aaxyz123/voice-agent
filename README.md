# Voice Command Agent

The build script creates **Voice Command Agent.app** on the Desktop. Open the app once to start listening; it opens no window and shows a microphone icon in the menu bar. Click that icon to stop or resume listening. Launching the app again toggles listening as well. Right-click the menu-bar icon for status and quit options.

## Commands

- `open Safari` opens the named installed application.
- `search how to make pancakes` opens a Google search in the default browser.
- `search budget report in Notes` uses the target app's standard Command-F search field.
- `view Alex chat` opens the matching chat in the WhatsApp desktop app.
- `type I'll call you in ten minutes` types into the currently focused text field. It does **not** send the message.

The app asks macOS for Microphone and Speech Recognition access. The `type` and `view` commands also require Accessibility access; approve the request in System Settings if prompted. The agent reports access or automation errors in the menu-bar icon's tooltip and right-click menu.

## Build

Run `bash build.command` from this folder. The app requires macOS 13 or later and Xcode Command Line Tools.
