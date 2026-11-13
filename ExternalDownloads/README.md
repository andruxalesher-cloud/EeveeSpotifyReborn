# External downloads for Spotify 9.1.0

Experimental add-on for the supplied EeveeSpotify 9.1.0 IPA. It intercepts the playlist download action and presents an in-app download library. Device verification is required.

The add-on reads playlist metadata through the app's existing data loader. Audio is fetched separately from the user-selected Muzfrog source. Source availability and recording matches are not guaranteed. Use downloads only where you have permission. Spotify subscription entitlements and its encrypted offline cache are not modified by this add-on.

Build `ExternalDownloads.dylib` using the associated GitHub Actions workflow. The dylib must be added to the supplied IPA and the resulting application signed before installation. The test MP3 and original IPA are not included in this public repository.

Acceptance checks on iPhone:

1. Open Liked Songs containing the supplied test track and tap the top download button.
2. Confirm that the list contains the collection's songs, including songs below the initially visible rows.
3. Confirm that the test song finishes downloading and unsupported songs show individual errors.
4. Reopen the download screen and verify that completed files are retained.
5. Enable airplane mode and play a downloaded song from the in-app list.

The add-on's playback screen is separate from Spotify's native Now Playing screen. A saved external file is not marked as a native Premium download.
