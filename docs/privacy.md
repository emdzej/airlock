# Privacy

*Last updated 6 November 2026.*

Airlock and its apps (Airlock Companion for Mac, Companion for Airlock
on iPhone and iPad) collect nothing about you. The one exception is a
problem report, and only when you write one yourself.

- **No accounts, no analytics, no tracking, no ads.** The apps send
  nothing to me or to anyone else unless you send a problem report.
- **Your network only.** Apart from problem reports, the apps talk to
  Airlock devices on your local network and to nothing else. They find
  them with Bonjour, which is why they ask for **Local Network** access.
- **Your files stay yours.** Files you browse, upload, download, flash
  or back up travel only between your device and your Airlock. Airlock
  itself runs on your own Raspberry Pi; no copy goes anywhere else.
- **What the apps keep, on your device:** the Airlocks they've seen
  (name, host name, port) and your settings. Deleting the app deletes
  them.
- **Problem reports, only when you send one.** **Report a Problem** in
  the apps sends what you write to my support desk, which runs on
  [ALIAS](https://getalias.support) at `help.getalias.support`. Along
  with it go:
  - a screenshot of the app's own window, if you leave it on, after you
    black out whatever you don't want to send. It's redrawn as a new
    image, with no location or device details in it;
  - the app's version, the name of the screen you were on (such as
    "Airlock" or "Setup"), your OS version, how many airlocks the app
    can see and whether the demo is on.

  No airlock names or addresses, no file names or contents, no email
  address and no account. The desk knows you only by an anonymous id
  it makes when you first send a report, kept in your device's Keychain,
  which is how my answer finds its way back to you in the app. Reports
  are kept for a year after they're closed, and for two years if you
  never see the answer. **Erase My Reports** in About deletes them and
  the id, at the desk and on your device.
- **Links** in the apps (the user guide, this site, GitHub) open in
  your browser, where those sites' own policies apply. This site is
  hosted on GitHub Pages; see
  [GitHub's privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).

Questions: open an issue on
[GitHub](https://github.com/emdzej/airlock/issues).
