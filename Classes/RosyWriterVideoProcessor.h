#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreMedia/CMBufferQueue.h>
#define MAX_NUM_FRAMES 360
#define NUM_OF_RED_AVERAGE 300
#define RECORDING_STAGE1 10
#define RECORDING_STAGE2 40
#define RED_INDEX frame_number-RECORDING_STAGE2
#define RECORDING_STAGE3 340

@protocol RosyWriterVideoProcessorDelegate;

@interface RosyWriterVideoProcessor : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate> 
{  
    id <RosyWriterVideoProcessorDelegate> delegate;
	
    // From interface POV, they are atomic; within the class, they are readwrite.
    // Thus videoFrameRate videoDimensions videoType are redeclared in m file.
	NSMutableArray *previousSecondTimestamps;
	Float64 videoFrameRate;
	CMVideoDimensions videoDimensions;
	CMVideoCodecType videoType;

    // Capture session parameters
	AVCaptureSession *captureSession;
    AVCaptureVideoPreviewLayer *previewLayer;
	AVCaptureConnection *audioConnection;
	AVCaptureConnection *videoConnection;
    AVCaptureDevice *frontCamera;
    AVCaptureDevice *backCamera;
    // To send to preview.
	CMBufferQueueRef previewBufferQueue;
	
    // Asset writer parameters
	NSURL *movieURL;
	AVAssetWriter *assetWriter;
	AVAssetWriterInput *assetWriterAudioIn;
	AVAssetWriterInput *assetWriterVideoIn;
	dispatch_queue_t movieWritingQueue;
    
	AVCaptureVideoOrientation referenceOrientation;
	AVCaptureVideoOrientation videoOrientation;
    
    /* Added by team, use frame_number to track how many frames elapsed so far. */
    unsigned int frame_number;
    // Timing information, for the use of color.
    CGFloat currentTime;
    vDSP_Length frameSize;
    float RedAvg;
    size_t sumofRed;
    // Frame sizing parameter.
	size_t bufferWidth, bufferHeight, rowbytes;
    // For calculating HR.
	float *arrayOfRedChannelAverage;
    float *arrayOfFrameRedPixels;
    float *differences;
    unsigned int sizeOfDifferences;
    // Choosing maximum value so that profiles are compatible.
    // iPhone 5s: 1136 x 640, 4/4s 960 x 640.
    // Power of vector calculus...
    // Note: 1. contiguous allocation; 2. 16-byte aligned.
    vImage_Buffer inBuffer;
    CVPixelBufferRef yuvBufferRef;
    // Binary bitmaps...
    BOOL tmp[540][960];
    BOOL tmp2[540][960];
    BOOL lesstemp[135][240];
    float tmpY[540][960];
    
    BOOL isUsingFrontCamera, readyToRecordAudio, readyToRecordVideo, recordingWillBeStarted, recordingWillBeStopped;
	BOOL recording;
}

@property (readwrite, assign) id <RosyWriterVideoProcessorDelegate> delegate;

@property (readonly) Float64 videoFrameRate;
@property (nonatomic, readonly) CGFloat heartRate;
@property (readonly) CMVideoDimensions videoDimensions;
@property (readonly) CMVideoCodecType videoType;

@property (readwrite) AVCaptureVideoOrientation referenceOrientation;

//- (void) setReferenceOrientation:(AVCaptureVideoOrientation)referenceOrientation;
- (CGAffineTransform)transformFromCurrentVideoOrientationToOrientation:(AVCaptureVideoOrientation)orientation;

- (void) showError:(NSError*)error;

- (void) setupAndStartCaptureSession;
- (void) stopAndTearDownCaptureSession;

- (void) startRecording;
- (void) stopRecording;

- (void) pauseCaptureSession; // Pausing while a recording is in progress will cause the recording to be stopped and saved.
- (void) resumeCaptureSession;
int detect_peak(
				const float*   data, /* the data */
				int             data_count, /* row count of data */
				//       int*            emi_peaks, /* emission peaks will be put here */
				int*            num_emi_peaks, /* number of emission peaks found */
				int             max_emi_peaks, /* maximum number of emission peaks */
				//       int*            absop_peaks, /* absorption peaks will be put here */
				int*            num_absop_peaks, /* number of absorption peaks found */
				int             max_absop_peaks, /* maximum number of absorption peaks
												  */
				float          delta,//, /* delta used for distinguishing peaks */
				//       int             emi_first /* should we search emission peak first of
				//                                  absorption peak first? */
				int*         peaks_index,
				float*         peaks_values
				);

void MyPixelBufferReleaseCallback(void *releaseRefCon,
                                  const void *baseAddress);
@property(readonly, getter=isRecording) BOOL recording;

@end

@protocol RosyWriterVideoProcessorDelegate <NSObject>

@required
- (void)pixelBufferReadyForDisplay:(CVPixelBufferRef)pixelBuffer; // In view controller
- (void)recordingWillStart;
- (void)recordingDidStart;
- (void)recordingWillStop;
- (void)recordingDidStop;
@end
