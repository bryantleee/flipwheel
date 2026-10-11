# Flipwheel

A very lightweight macOS menu bar app that reverses scrolling for a mouse wheel and leaves the trackpad alone. It can also disable wheel scroll acceleration in the mouse.

It is built to be the smallest thing that works. The app sleeps until a scroll event arrives, and the work per event is a handful of field reads and writes in C.

## How it works

Wheel mice send discrete scroll events; trackpads and the Magic Mouse send continuous ones. A single event tap negates the deltas of discrete events and passes everything else through untouched. When the toggle is off, the tap is disabled and the app receives nothing. With Constant Scroll Speed on, it writes a fixed line count instead and lets macOS derive the rest, so that mode does less work per event, not more.

## Build

Needs macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
make          # Flipwheel.app, universal binary
make install  # copy it to /Applications and launch it
```

The first launch asks for Accessibility. Grant it in System Settings > Privacy & Security > Accessibility.

Other targets:

- `make run` launches the app from the clone instead. The login item then points into the clone, so deleting it or running `make clean` kills the login item.
- `make test` runs the self-check, see Test below.
- `make reset` clears the Accessibility grant. Each rebuild changes the ad-hoc signature and orphans the old grant, so run this and grant again, or sign with a stable identity: `make SIGN="<certificate name>"`.
- `make bare` builds a single binary with no app bundle. macOS credits its Accessibility grant to the terminal that launched it, so prefer the .app.

## Use

Click the mouse icon in the menu bar to toggle Reverse Mouse Scrolling, Constant Scroll Speed, or quit. It opens at login. Turn that off under System Settings > General > Login Items.

Constant Scroll Speed replaces the wheel acceleration macOS applies with a fixed step: three lines per click by default. To change it:

```sh
defaults write com.bryant.flipwheel lines -int 5
```

Then turn the switch off and on again.

## Test

`make test` builds `test.c` and runs it against the running app. It posts two synthetic scroll events, a wheel click and a trackpad swipe, into the session and reads them back after Flipwheel's tap. The wheel event must come back reversed, or at the fixed line count when Constant Scroll Speed is on. The trackpad event must come back unchanged. It prints the round trip time of each probe and exits nonzero on failure.

The check follows whichever mode the app is in, so run it once with Constant Scroll Speed off and once with it on. It needs Accessibility for the terminal that runs it, and it scrolls whatever is under the pointer by a line or two.

## Limits

- It reverses relative to the system setting. With Natural scrolling off, the trackpad turns traditional and the mouse turns natural.
- A Magic Mouse sends continuous events like a trackpad, so it stays natural.
- Drivers that smooth wheel scrolling, such as Logitech Options+ with smooth scrolling on, can also look like a trackpad.
- Quit the app before revoking Accessibility. A macOS bug freezes input otherwise.

## License

MIT.
