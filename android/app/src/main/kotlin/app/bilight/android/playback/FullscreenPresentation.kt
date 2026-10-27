package app.bilight.android.playback

fun fullscreenPresentation(requested: Boolean, portraitVideo: Boolean, landscapeWindow: Boolean, returning: Boolean, exiting: Boolean): Boolean =
    requested && (portraitVideo || landscapeWindow || returning) || exiting && landscapeWindow
