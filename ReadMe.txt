### Real Time Blood Flow Simulator based on Rosy Writer ###

===========================================================================
DESCRIPTION:

RosyWriter demonstrates the use of the AV Foundation framework to capture, process, preview, and save video on iOS devices.

The ECE496 design team uses this as the freamwork, adding customized algorithm to estimate heartrate; in addition, the pixelBuffer is modified to show the color change of the user's skin.

When the application launches, it creates an AVCaptureSession with audio and video device inputs, and outputs for audio and video data. These outputs continuously supply frames of audio and video to the app, via the captureOutput:didOutputSampleBuffer:fromConnection: delegate method.

The app applies a very simple processing step to each video frame. Initially, it measures heart rate by indexing frame average of red channel. Afterwards, the array of red pixel average values is passed to peak detector to give the estimation.

Finally, the user can be seen by the front camera, with skin color tinted. Audio frames are not processed.

After a frame of video is processed, The simulator uses OpenGL ES 2 to display it on the screen. This step uses the CVOpenGLESTextureCache API, for real-time performance.

When the user chooses to record a movie, an AVAssetWriter is used to write the processed video and un-processed audio to a QuickTime movie file.

This file can then be viewed in the photo application.

===========================================================================
BUILD REQUIREMENTS:

Xcode 5 or later; iPhone iOS SDK 7.0 or later.

===========================================================================
RUNTIME REQUIREMENTS:

iOS 7.0 or later. This app will not run on the iOS simulator.

===========================================================================
Yours sincerely, team 2013154
