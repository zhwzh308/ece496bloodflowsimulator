#import <MobileCoreServices/MobileCoreServices.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <Endian.h>
#import "RosyWriterVideoProcessor.h"

#define BYTES_PER_PIXEL 4
#define WR 0.299
#define WG 0.587
#define WB 0.114

// Static kernel for image convolution.
//static const signed int kernel_emboss[] = {-2, -2, 0, -2, 6, 0, 0, 0, 0};
//static const signed int kernel_Gaussianblur[] = {1,2,1,2,4,2,1,2,1};
//static const float kernel_edgeDetection[9] = {-1, -1, -1, -1, 9, -1, -1, -1, -1};

@interface RosyWriterVideoProcessor ()

// Redeclared as readwrite so that we can write to the property and still be atomic with external readers.
@property (readwrite) Float64 videoFrameRate;
@property (readwrite) float heartRate, percentComplete;
@property (readwrite) CMVideoDimensions videoDimensions;
@property (readwrite) CMVideoCodecType videoType;

@property (readwrite, getter=isRecording) BOOL recording;

@property (readwrite) AVCaptureVideoOrientation videoOrientation;

@end

@implementation RosyWriterVideoProcessor

@synthesize delegate;
@synthesize videoFrameRate, videoDimensions, videoType, referenceOrientation, videoOrientation, recording;

- (id) init
{
    if (self = [super init]) {
        previousSecondTimestamps = [[NSMutableArray alloc] init];
        referenceOrientation = UIDeviceOrientationPortrait;
        
        // The temporary path for the video before saving it to the photo album
        movieURL = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@%@", NSTemporaryDirectory(), @"ECE496.MOV"]];
        [movieURL retain];
        frame_number = 0;
        isUsingFrontCamera = NO;

        _heartRate = _percentComplete = 0.0f;

        frontCamera = nil;

        backCamera = nil;
    }
    return self;
}

- (void)dealloc
{
    [previousSecondTimestamps release];
    [movieURL release];

	[super dealloc];
}

#pragma mark Utilities

- (void) calculateFramerateAtTimestamp:(CMTime) timestamp
{
	[previousSecondTimestamps addObject:[NSValue valueWithCMTime:timestamp]];
    
	CMTime oneSecond = CMTimeMake( 1, 1 );
	CMTime oneSecondAgo = CMTimeSubtract( timestamp, oneSecond );
    
	while( CMTIME_COMPARE_INLINE( [[previousSecondTimestamps objectAtIndex:0] CMTimeValue], <, oneSecondAgo ) )
		[previousSecondTimestamps removeObjectAtIndex:0];
	Float64 newRate = (Float64) [previousSecondTimestamps count];
	self.videoFrameRate = (self.videoFrameRate + newRate) / 2;
}
// Set tmp at row and col.

- (void) step1_pixelFromRGBtoYCbCr
{
    float cb, cr, y;
    // BGR ordered.
    float vec_y[3] = {0.0979f, 0.5041f, 0.2568f};
    float vec_cb[3] = {0.4392f, -0.2910f, -0.1482f};
    float vec_cr[3] = {-0.0714f, -0.3678f, 0.4392f};
    float computeTemp[3];
    unsigned char *p = inBuffer.data;
    for (int row = 0; row < inBuffer.height; ++row) {
        for (int col = 0; col < inBuffer.width; ++col) {
            vDSP_vfltu8(p, 1, computeTemp, 1, 3);
            vDSP_dotpr(computeTemp, 1, vec_y, 1, &y, 3);
            vDSP_dotpr(computeTemp, 1, vec_cb, 1, &cb, 3);
            vDSP_dotpr(computeTemp, 1, vec_cr, 1, &cr, 3);
            //cb = 128.0f - 0.14822656f * p[2] - 0.290992188f * p[1] + 0.4392148f * p[0];
            //cr = 128.0f + 0.4392148f * p[2] - (0.367789f * p[1]) - (0.07142578f * p[0]);
            //tmp[row][col] = (cb >= 77.0f && cb <= 127.0f && cr >= 133.0f && cr <= 173.0f);
            tmp[row][col] = (cb >= -51.0f && cb <= -1.0f) && (cr >= 5.0f && cr <= 45.0f);
            tmpY[row][col] = y + 16.0f;
            p += BYTES_PER_PIXEL;
        }
//        p += BYTES_PER_PIXEL;
    }
    //CGFloat Y = 16.0f + 0.256789f * p[2] + 0.5041289f * p[1] + 0.09790625f * p[0];
    //tmpY[row][col] = Y;
}

/****************************************************************************
 * Store threshold result by from Cb [77,127], Cr [133,173]; store luma val *
 * Y´ = floor(0.5 + 219 * EY´ +  16)    Y´ = [16,235] as EY´ = [0,1]        *
 * Cb = floor(0.5 + 224 * ECb + 128)    Cb = [16,240] as ECb = [-0.5, +0.5] *
 * Cr = floor(0.5 + 224 * ECr + 128)    Cr = [16,240] as ECr = [-0.5, +0.5] *
 * v308: Byte 0 Byte 1 Byte 2 8-bit Cr 8-bit Y´ 8-bit Cb                    *
 * v408: Byte 0 8-bit Cb Byte 1 8-bit Y´ Byte 2 8-bit Cr Byte 3 8-bit A     *
 ****************************************************************************/

- (void) step1_YCbCrThresholding
{
    CVReturn myBufferCreation = CVPixelBufferCreateWithBytes(NULL, inBuffer.width,
                                                             inBuffer.height,
                                                             //kComponentVideoCodecType
                                                             kCVPixelFormatType_4444YpCbCrA8,
                                                             inBuffer.data,
                                                             inBuffer.rowBytes,
                                                             NULL, NULL, NULL,
                                                             &yuvBufferRef);
    if (myBufferCreation) {
        NSLog(@"pixelBuffer creation error %d", myBufferCreation);
    }
	CVPixelBufferLockBaseAddress( yuvBufferRef, kCVPixelBufferLock_ReadOnly );
    unsigned char *pixel = CVPixelBufferGetBaseAddress(yuvBufferRef);
    for (int i = 0; i < inBuffer.height; ++i) {
        vDSP_vfltu8(pixel + 1, BYTES_PER_PIXEL, tmpY[i], 1, inBuffer.width);
        for (int j = 0; j < inBuffer.width; ++j) {
            // tmp[i][j]=(pixel[2] >= 77 && pixel[2] <= 127 && pixel[0] >= 133 && pixel[0] <= 173);
            tmp[i][j] = (*pixel >= 83 && *pixel <= 127 && pixel[2] >= 132 && pixel[2] <= 167);
            pixel += BYTES_PER_PIXEL;
        }
        pixel += BYTES_PER_PIXEL;
    }
	CVPixelBufferUnlockBaseAddress( yuvBufferRef, kCVPixelBufferLock_ReadOnly );
}

- (void) step2_densityRegularization
{
    CGFloat sumY, devSumY;
    unsigned char sum;
    for (int row = 0; row<inBuffer.height; ++row) {
        for (int col = 0; col<inBuffer.width; ++col) {
            if ( !( ((row+1) % 4) || ((col+1) % 4) ) ) {
                // that is, on row 3, 7, 11, etc
                // after col 3, 7, 11, etc inclusive
                
                // 1. Work on sum.
                sum = tmp[row-3][col-3] + tmp[row-3][col-2] + tmp[row-3][col-1] + tmp[row-3][col];
                sum += tmp[row-2][col-3] + tmp[row-2][col-2] + tmp[row-2][col-1] + tmp[row-2][col];
                sum += tmp[row-1][col-3] + tmp[row-1][col-2] + tmp[row-1][col-1] + tmp[row-1][col];
                sum += tmp[row][col-3] + tmp[row][col-2] + tmp[row][col-1] + tmp[row][col];
                if (sum < 16)
                    lesstemp[row/4][col/4] = 0;
                else {
                    sumY = tmpY[row-3][col-3] + tmpY[row-3][col-2] + tmpY[row-3][col-1] + tmpY[row-3][col];
                    sumY += tmpY[row-2][col-3] + tmpY[row-2][col-2] + tmpY[row-2][col-1] + tmpY[row-2][col];
                    sumY += tmpY[row-1][col-3] + tmpY[row-1][col-2] + tmpY[row-1][col-1] + tmpY[row-1][col];
                    sumY += tmpY[row][col-3] + tmpY[row][col-2] + tmpY[row][col-1] + tmpY[row][col];
                    sumY = sumY * 0.0625f;
                    devSumY = fabsf(tmpY[row-3][col-3] - sumY)+fabsf(tmpY[row-3][col-2] - sumY);
                    devSumY += fabsf(tmpY[row-3][col-1] - sumY) + fabsf(tmpY[row-3][col-0] - sumY);
                    
                    devSumY += fabsf(tmpY[row-2][col-3] - sumY);
                    devSumY += fabsf(tmpY[row-2][col-2] - sumY);
                    devSumY += fabsf(tmpY[row-2][col-1] - sumY);
                    devSumY += fabsf(tmpY[row-2][col-0] - sumY);
                    
                    devSumY += fabsf(tmpY[row-1][col-3] - sumY);
                    devSumY += fabsf(tmpY[row-1][col-2] - sumY);
                    devSumY += fabsf(tmpY[row-1][col-1] - sumY);
                    devSumY += fabsf(tmpY[row-1][col-0] - sumY);
                    
                    devSumY += fabsf(tmpY[row][col-3] - sumY);
                    devSumY += fabsf(tmpY[row][col-2] - sumY);
                    devSumY += fabsf(tmpY[row][col-1] - sumY);
                    devSumY += fabsf(tmpY[row][col-0] - sumY);
                    if (devSumY < 64.0f)
                        // The skin area should be:
                        // a. Step 2: sum of the 4 by 4 block equal to 16;
                        // b. standard deviation of the 4 by 4 block greater than 2.
                        
						// Optimized: this should still work because
						// 3/4 = 0, 7/4 = 1, ..., 956/4 = 239 in int arithmatic.
                        lesstemp[row/4][col/4] = 0;
                    else {
                        lesstemp[row/4][col/4] = 1;
                    }
                }// 2. Return to reality
			}
        }
    }
    
    for (int row = 0; row < inBuffer.height; row++) {
        for (int col = 0; col < inBuffer.width; col++) {
            if (lesstemp[row/4][col/4]) {
                tmp[row][col] = 1;
            }
        }
    }
}

- (void) step1_pixelFromRGB:(unsigned char *)p row:(int)row column:(int) col
{
    // Using information from Inaz
    tmp2[row][col] = ((p[2] >= 95) && (p[1] >40) && (p[0] >= 20) && (fmaxf(p[2], (fmaxf(p[1], p[0])) - fminf(p[2], fminf(p[1], p[0]))) > 15) && (p[2] > p[0]) && (p[1] > p[0]) && (fabsf(p[2] - p[1]) <= 15.0f));
}

- (void) plotInHoles
    // step 4: plot in holes. seems like repeat 8 times will have better performance.
{
    for (int row = 2; row < bufferWidth; row++) {
        for (int col = 2; col < bufferHeight; col++) {
            int sum = tmp[row-2][col-2] + tmp[row-2][col-1] + tmp[row-2][col];
            sum += tmp[row-1][col-2] + tmp[row-1][col-1] + tmp[row-1][col-0];
            sum += tmp[row][col-2] + tmp[row][col-1] + tmp[row][col];
            if ((tmp[row][col] == 1) && sum > 3)
                tmp2[row][col] = 1;
            else if ((tmp[row][col] == 0) && sum > 5)
                tmp2[row][col] = 1;
            else
                tmp2[row][col] = 0;
        }
    }
    for (int row = 2; row < bufferWidth; row++) {
        for (int col = 2; col < bufferHeight; col++) {
            int sum = tmp2[row-2][col-2] + tmp2[row-2][col-1] + tmp2[row-2][col];
            sum += tmp2[row-1][col-2] + tmp2[row-1][col-1] + tmp2[row-1][col-0];
            sum += tmp2[row][col-2] + tmp2[row][col-1] + tmp2[row][col];
            if ((tmp2[row][col] == 1) && sum > 3)
                tmp[row][col] = 1;
            else if ((tmp2[row][col] == 0) && sum > 5)
                tmp[row][col] = 1;
            else
                tmp[row][col] = 0;
        }
    }
    for (int row = 2; row < bufferWidth; row++) {
        for (int col = 2; col < bufferHeight; col++) {
            int sum = tmp[row-2][col-2] + tmp[row-2][col-1] + tmp[row-2][col];
            sum += tmp[row-1][col-2] + tmp[row-1][col-1] + tmp[row-1][col-0];
            sum += tmp[row][col-2] + tmp[row][col-1] + tmp[row][col];
            if ((tmp[row][col] == 1) && sum > 3)
                tmp2[row][col] = 1;
            else if ((tmp[row][col] == 0) && sum > 5)
                tmp2[row][col] = 1;
            else
                tmp2[row][col] = 0;
        }
    }
    for (int row = 2; row < bufferWidth; row++) {
        for (int col = 2; col < bufferHeight; col++) {
            int sum = tmp2[row-2][col-2] + tmp2[row-2][col-1] + tmp2[row-2][col];
            sum += tmp2[row-1][col-2] + tmp2[row-1][col-1] + tmp2[row-1][col-0];
            sum += tmp2[row][col-2] + tmp2[row][col-1] + tmp2[row][col];
            if ((tmp2[row][col] == 1) && sum > 3)
                tmp[row][col] = 1;
            else if ((tmp2[row][col] == 0) && sum > 5)
                tmp[row][col] = 1;
            else
                tmp[row][col] = 0;
        }
    }
    for (int row = 2; row < bufferWidth; row++) {
        for (int col = 2; col < bufferHeight; col++) {
            int sum = tmp[row-2][col-2] + tmp[row-2][col-1] + tmp[row-2][col];
            sum += tmp[row-1][col-2] + tmp[row-1][col-1] + tmp[row-1][col-0];
            sum += tmp[row][col-2] + tmp[row][col-1] + tmp[row][col];
            if ((tmp[row][col] == 1) && sum > 3)
                tmp2[row][col] = 1;
            else if ((tmp[row][col] == 0) && sum > 5)
                tmp2[row][col] = 1;
            else
                tmp2[row][col] = 0;
        }
    }
    for (int row = 2; row < bufferWidth; row++) {
        for (int col = 2; col < bufferHeight; col++) {
            int sum = tmp2[row-2][col-2] + tmp2[row-2][col-1] + tmp2[row-2][col];
            sum += tmp2[row-1][col-2] + tmp2[row-1][col-1] + tmp2[row-1][col-0];
            sum += tmp2[row][col-2] + tmp2[row][col-1] + tmp2[row][col];
            if ((tmp2[row][col] == 1) && sum > 3)
                tmp[row][col] = 1;
            else if ((tmp2[row][col] == 0) && sum > 5)
                tmp[row][col] = 1;
            else
                tmp[row][col] = 0;
        }
    }
    for (int row = 2; row < bufferWidth; row++) {
        for (int col = 2; col < bufferHeight; col++) {
            int sum = tmp[row-2][col-2] + tmp[row-2][col-1] + tmp[row-2][col];
            sum += tmp[row-1][col-2] + tmp[row-1][col-1] + tmp[row-1][col-0];
            sum += tmp[row][col-2] + tmp[row][col-1] + tmp[row][col];
            if ((tmp[row][col] == 1) && sum > 3)
                tmp2[row][col] = 1;
            else if ((tmp[row][col] == 0) && sum > 5)
                tmp2[row][col] = 1;
            else
                tmp2[row][col] = 0;
        }
    }
    for (int row = 2; row < bufferWidth; row++) {
        for (int col = 2; col < bufferHeight; col++) {
            int sum = tmp2[row-2][col-2] + tmp2[row-2][col-1] + tmp2[row-2][col];
            sum += tmp2[row-1][col-2] + tmp2[row-1][col-1] + tmp2[row-1][col-0];
            sum += tmp2[row][col-2] + tmp2[row][col-1] + tmp2[row][col];
            if ((tmp2[row][col] == 1) && sum > 3)
                tmp[row][col] = 1;
            else if ((tmp2[row][col] == 0) && sum > 5)
                tmp[row][col] = 1;
            else
                tmp[row][col] = 0;
        }
    }
}

- (void)removeFile:(NSURL *)fileURL
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *filePath = [fileURL path];
    if ([fileManager fileExistsAtPath:filePath]) {
        NSError *error;
        BOOL success = [fileManager removeItemAtPath:filePath error:&error];
		if (!success)
			[self showError:error];
    }
}

- (CGFloat)angleOffsetFromPortraitOrientationToOrientation:(AVCaptureVideoOrientation)orientation
{
	CGFloat angle = 0.0;
	switch (orientation) {
		case AVCaptureVideoOrientationPortrait:
			angle = 0.0;
			break;
		case AVCaptureVideoOrientationPortraitUpsideDown:
			angle = M_PI;
			break;
		case AVCaptureVideoOrientationLandscapeRight:
			angle = -M_PI_2;
			break;
		case AVCaptureVideoOrientationLandscapeLeft:
			angle = M_PI_2;
			break;
		default:
			break;
	}
	return angle;
}

- (CGAffineTransform)transformFromCurrentVideoOrientationToOrientation:(AVCaptureVideoOrientation)orientation
{
	CGAffineTransform transform = CGAffineTransformIdentity;

	// Calculate offsets from an arbitrary reference orientation (portrait)
	CGFloat orientationAngleOffset = [self angleOffsetFromPortraitOrientationToOrientation:orientation];
	CGFloat videoOrientationAngleOffset = [self angleOffsetFromPortraitOrientationToOrientation:self.videoOrientation];
	
	// Find the difference in angle between the passed in orientation and the current video orientation
	CGFloat angleOffset = orientationAngleOffset - videoOrientationAngleOffset;
	transform = CGAffineTransformMakeRotation(angleOffset);
	
	return transform;
}

#pragma mark Recording

- (void)saveMovieToCameraRoll
{
	ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
	[library writeVideoAtPathToSavedPhotosAlbum:movieURL
								completionBlock:^(NSURL *assetURL, NSError *error) {
									if (error)
										[self showError:error];
									else
										[self removeFile:movieURL];
									
									dispatch_async(movieWritingQueue, ^{
										recordingWillBeStopped = NO;
										self.recording = NO;
										
										[self.delegate recordingDidStop];
									});
								}];
	[library release];
}

- (void) writeSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(NSString *)mediaType
{
	if ( assetWriter.status == AVAssetWriterStatusUnknown ) {
		
        if ([assetWriter startWriting]) {			
			[assetWriter startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
		}
		else {
			[self showError:[assetWriter error]];
		}
	}
	
	if ( assetWriter.status == AVAssetWriterStatusWriting ) {
		
		if (mediaType == AVMediaTypeVideo) {
			if (assetWriterVideoIn.readyForMoreMediaData) {
				if (![assetWriterVideoIn appendSampleBuffer:sampleBuffer]) {
					[self showError:[assetWriter error]];
				}
			}
		}
		else if (mediaType == AVMediaTypeAudio) {
			if (assetWriterAudioIn.readyForMoreMediaData) {
				if (![assetWriterAudioIn appendSampleBuffer:sampleBuffer]) {
					[self showError:[assetWriter error]];
				}
			}
		}
	}
}

- (BOOL) setupAssetWriterAudioInput:(CMFormatDescriptionRef)currentFormatDescription
{
	const AudioStreamBasicDescription *currentASBD = CMAudioFormatDescriptionGetStreamBasicDescription(currentFormatDescription);

	size_t aclSize = 0;
	const AudioChannelLayout *currentChannelLayout = CMAudioFormatDescriptionGetChannelLayout(currentFormatDescription, &aclSize);
	NSData *currentChannelLayoutData = nil;
	
	// AVChannelLayoutKey must be specified, but if we don't know any better give an empty data and let AVAssetWriter decide.
	if ( currentChannelLayout && aclSize > 0 )
		currentChannelLayoutData = [NSData dataWithBytes:currentChannelLayout length:aclSize];
	else
		currentChannelLayoutData = [NSData data];
	
	NSDictionary *audioCompressionSettings = [NSDictionary dictionaryWithObjectsAndKeys:
											  [NSNumber numberWithInteger:kAudioFormatMPEG4AAC], AVFormatIDKey,
											  [NSNumber numberWithFloat:currentASBD->mSampleRate], AVSampleRateKey,
											  [NSNumber numberWithInt:64000], AVEncoderBitRatePerChannelKey,
											  [NSNumber numberWithInteger:currentASBD->mChannelsPerFrame], AVNumberOfChannelsKey,
											  currentChannelLayoutData, AVChannelLayoutKey,
											  nil];
	if ([assetWriter canApplyOutputSettings:audioCompressionSettings forMediaType:AVMediaTypeAudio]) {
		assetWriterAudioIn = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:audioCompressionSettings];
		assetWriterAudioIn.expectsMediaDataInRealTime = YES;
		if ([assetWriter canAddInput:assetWriterAudioIn])
			[assetWriter addInput:assetWriterAudioIn];
		else {
			NSLog(@"Couldn't add asset writer audio input.");
            return NO;
		}
	}
	else {
		NSLog(@"Couldn't apply audio output settings.");
        return NO;
	}
    
    return YES;
}

- (BOOL) setupAssetWriterVideoInput:(CMFormatDescriptionRef)currentFormatDescription 
{
	float bitsPerPixel;
	CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(currentFormatDescription);
	int numPixels = dimensions.width * dimensions.height;
	int bitsPerSecond;
	
	// Assume that lower-than-SD resolutions are intended for streaming, and use a lower bitrate
	if ( numPixels < (640 * 480) )
		bitsPerPixel = 4.05; // This bitrate matches the quality produced by AVCaptureSessionPresetMedium or Low.
	else
		bitsPerPixel = 11.4; // This bitrate matches the quality produced by AVCaptureSessionPresetHigh.
	
	bitsPerSecond = numPixels * bitsPerPixel;
	
	NSDictionary *videoCompressionSettings = [NSDictionary dictionaryWithObjectsAndKeys:
											  AVVideoCodecH264, AVVideoCodecKey,
											  [NSNumber numberWithInteger:dimensions.width], AVVideoWidthKey,
											  [NSNumber numberWithInteger:dimensions.height], AVVideoHeightKey,
											  [NSDictionary dictionaryWithObjectsAndKeys:
											   [NSNumber numberWithInteger:bitsPerSecond], AVVideoAverageBitRateKey,
											   [NSNumber numberWithInteger:30], AVVideoMaxKeyFrameIntervalKey,
											   nil], AVVideoCompressionPropertiesKey,
											  nil];
    //use an AVAssetWriter object to write media data to a new file of a specified audiovisual container type
	if ([assetWriter canApplyOutputSettings:videoCompressionSettings forMediaType:AVMediaTypeVideo]) {
		assetWriterVideoIn = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoCompressionSettings];
		assetWriterVideoIn.expectsMediaDataInRealTime = YES;
		assetWriterVideoIn.transform = [self transformFromCurrentVideoOrientationToOrientation:self.referenceOrientation];
		if ([assetWriter canAddInput:assetWriterVideoIn])
			[assetWriter addInput:assetWriterVideoIn];
		else {
			NSLog(@"Couldn't add asset writer video input.");
            return NO;
		}
	}
	else {
		NSLog(@"Couldn't apply video output settings.");
        return NO;
	}
    
    return YES;
}

- (void) startRecording
{
	dispatch_async(movieWritingQueue, ^{
	
		if ( recordingWillBeStarted || self.recording )
			return;

		recordingWillBeStarted = YES;

		// recordingDidStart is called from captureOutput:didOutputSampleBuffer:fromConnection: once the asset writer is setup
		[self.delegate recordingWillStart];

		// Remove the file if one with the same name already exists
		[self removeFile:movieURL];

		// Create an asset writer
		NSError *error;
		assetWriter = [[AVAssetWriter alloc] initWithURL:movieURL fileType:(NSString *)kUTTypeQuickTimeMovie error:&error];
		if (error)
			[self showError:error];
	});	
}

- (void) stopRecording
{
	dispatch_async(movieWritingQueue, ^{
		
		if ( recordingWillBeStopped || (self.recording == NO) )
			return;
		
		recordingWillBeStopped = YES;
		[self.delegate recordingWillStop];

		if ([assetWriter finishWriting]) {
			[assetWriterAudioIn release];
			[assetWriterVideoIn release];
			[assetWriter release];
			assetWriter = nil;
			
			readyToRecordVideo = NO;
			readyToRecordAudio = NO;
			
			[self saveMovieToCameraRoll];
		}
		else {
			[self showError:[assetWriter error]];
		}
	});
}

#pragma mark Processing

- (void)fillInArray: (CVImageBufferRef)pixelBuffer
{
	/* Lock pixel bitmap for read only, saving CPU integrity check. */
	CVPixelBufferLockBaseAddress( pixelBuffer, kCVPixelBufferLock_ReadOnly );
	/* Refresh parameters once. */
    if (frame_number == RECORDING_STAGE2) {
        bufferWidth = CVPixelBufferGetWidth(pixelBuffer);
        bufferHeight = CVPixelBufferGetHeight(pixelBuffer);
        /* Total number of pixels. */
        frameSize = bufferHeight * bufferWidth;
    }
	/* first element of BGRA array */
    unsigned char *pixelBase = (unsigned char *)CVPixelBufferGetBaseAddress(pixelBuffer);
    
	/* Point head to R pixel. */
    pixelBase += 2;
    
	/* Process frame size of R pixels (fit u8 into floats)
        source: bitmap
        destination: float array
     */
    vDSP_vfltu8(pixelBase, 4, arrayOfFrameRedPixels, 1, frameSize);
	/* Find mean of this 1xframeSize vector. */
    vDSP_meanv(arrayOfFrameRedPixels, 1, &(RedAvg), frameSize);
    if (RedAvg < 200.0f) {
        /* Reset data float collection */
        if (frame_number > RECORDING_STAGE2) {
            frame_number = RECORDING_STAGE2;
        }
    }
    else {
        /* User behaving, add this to the array. */
        arrayOfRedChannelAverage[RED_INDEX] = RedAvg;
    }
	CVPixelBufferUnlockBaseAddress( pixelBuffer, kCVPixelBufferLock_ReadOnly );
}

- (void) createBitmapsfromPixelBuffer: (CVImageBufferRef) pixelBuffer
{
	CVPixelBufferLockBaseAddress( pixelBuffer, 0 );
	bufferWidth = CVPixelBufferGetWidth(pixelBuffer);
    bufferHeight = CVPixelBufferGetHeight(pixelBuffer);
    
	unsigned char *pixelBase = (unsigned char *)CVPixelBufferGetBaseAddress(pixelBuffer);

    inBuffer.data = pixelBase;
    inBuffer.width = CVPixelBufferGetWidth(pixelBuffer);
    inBuffer.height = CVPixelBufferGetHeight(pixelBuffer);
    inBuffer.rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);

	// Since the pixel is an unsigned char, the following variables are always ints.
	// Access pointer. Moving during the loop operation
    unsigned char *pixel = pixelBase;
    
    // Condition 2: sufficient data is collected, we simulate HR.
	CGFloat hr_sim = 40.0f * sinf(currentTime * 6.28f * [self heartRate] / 60.0f);
		// Step 1 and partial 2
    for (int row = 0; row < inBuffer.height; row++) {
        for (int col = 0; col < inBuffer.width; col++) {
            // Step 1. Chrominance threshold, large bitmap
            [self step1_pixelFromRGBtoYCbCr];
//			[self step1_pixelFromRGB:pixel row:row column:col];
			// Step 2. Set low res bitmap
            
            if ( !( ((row+1) % 4) || ((col+1) % 4) ) ) {
					// that is, on row 3, 7, 11, etc
					// after col 3, 7, 11, etc inclusive
					
					// 1. Roll back and work on sum.
                int sum = tmp[row-3][col-3] + tmp[row-3][col-2] + tmp[row-3][col-1] + tmp[row-3][col];
					sum += tmp[row-2][col-3] + tmp[row-2][col-2] + tmp[row-2][col-1] + tmp[row-2][col];
					sum += tmp[row-1][col-3] + tmp[row-1][col-2] + tmp[row-1][col-1] + tmp[row-1][col];
					sum += tmp[row][col-3] + tmp[row][col-2] + tmp[row][col-1] + tmp[row][col];
                    //calculate sume of Y
                if (sum < 16)
                    lesstemp[row/4][col/4] = 0;
                else {
                    CGFloat sumY = tmpY[row-3][col-3] + tmpY[row-3][col-2] + tmpY[row-3][col-1] + tmpY[row-3][col];
                    sumY += tmpY[row-2][col-3] + tmpY[row-2][col-2] + tmpY[row-2][col-1] + tmpY[row-2][col];
                    sumY += tmpY[row-1][col-3] + tmpY[row-1][col-2] + tmpY[row-1][col-1] + tmpY[row-1][col];
                    sumY += tmpY[row][col-3] + tmpY[row][col-2] + tmpY[row][col-1] + tmpY[row][col];
                    sumY = sumY * 0.0625f;
                    CGFloat devSumY = (tmpY[row-3][col-3] - sumY) * (tmpY[row-3][col-3] - sumY);
                    devSumY += (tmpY[row-3][col-2] - sumY) * (tmpY[row-3][col-2] - sumY);
                    devSumY += (tmpY[row-3][col-1] - sumY) * (tmpY[row-3][col-1] - sumY);
                    devSumY += (tmpY[row-3][col-0] - sumY) * (tmpY[row-3][col-0] - sumY);
                    
                    devSumY += (tmpY[row-2][col-3] - sumY) * (tmpY[row-2][col-3] - sumY);
                    devSumY += (tmpY[row-2][col-2] - sumY) * (tmpY[row-2][col-2] - sumY);
                    devSumY += (tmpY[row-2][col-1] - sumY) * (tmpY[row-2][col-1] - sumY);
                    devSumY += (tmpY[row-2][col-0] - sumY) * (tmpY[row-2][col-0] - sumY);
                    
                    devSumY += (tmpY[row-1][col-3] - sumY) * (tmpY[row-1][col-3] - sumY);
                    devSumY += (tmpY[row-1][col-2] - sumY) * (tmpY[row-1][col-2] - sumY);
                    devSumY += (tmpY[row-1][col-1] - sumY) * (tmpY[row-1][col-1] - sumY);
                    devSumY += (tmpY[row-1][col-0] - sumY) * (tmpY[row-1][col-0] - sumY);
                    
                    devSumY += (tmpY[row][col-3] - sumY) * (tmpY[row][col-3] - sumY);
                    devSumY += (tmpY[row][col-2] - sumY) * (tmpY[row][col-2] - sumY);
                    devSumY += (tmpY[row][col-1] - sumY) * (tmpY[row][col-1] - sumY);
                    devSumY += (tmpY[row][col-0] - sumY) * (tmpY[row][col-0] - sumY);
                    if (devSumY < 64.0f)
                        // The skin area should be:
                        // a. Step 2: sum of the 4 by 4 block equal to 16;
                        // b. standard deviation of the 4 by 4 block greater than 2.
                    
						// Optimized: this should still work because
						// 3/4 = 0, 7/4 = 1, ..., 956/4 = 239 in int arithmatic.
                        lesstemp[row/4][col/4] = 0;
                    else {
                        lesstemp[row/4][col/4] = 1;
                    }
                }// 2. Return to reality
			}
            
			pixel += BYTES_PER_PIXEL;
		}
//		pixel += BYTES_PER_PIXEL;
	}
    pixel = pixelBase;
    
    for (int row = 0; row < bufferHeight; row++) {
        for (int col = 0; col < bufferWidth; col++) {
            if (lesstemp[row/4][col/4]) {
                tmp[row][col] = 1;
            }
            pixel += BYTES_PER_PIXEL;
        }
//        pixel += BYTES_PER_PIXEL;
    }
    
    // Render loop
    pixel = pixelBase;
    for (int row = 0; row < bufferHeight; row++) {
        for (int col = 0; col < bufferWidth; col++) {
            //           if ((tmp[row][col])) {
            if (tmp[row][col]) {
                
                CGFloat to_color = ((float) pixel[2]) + hr_sim;
                if (to_color >= 255.0f) {
                    pixel[2] = 255;
                } else if (to_color <= 0.0f){
                    pixel[2] = 0;
                }
                else {
                    pixel[2] = (unsigned char) to_color;
                }
                // Use these to check mask: (int) *pixel = (int) 255; // watch out endian
            }
            pixel += BYTES_PER_PIXEL;
        }
//        pixel += BYTES_PER_PIXEL;
    }
	CVPixelBufferUnlockBaseAddress( pixelBuffer, 0 );
}

- (void) vImageHelpMeDoWork: (CVImageBufferRef)pixelBuffer
{
    // Lock buffer base addr for modification.
	CVPixelBufferLockBaseAddress( pixelBuffer, 0 );
    unsigned char *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    // Setting up vImage buffers: necessary for vImage to work!
    // At base address is the bitmap data.
    inBuffer.data = baseAddress;
    // Setting up sizes
    inBuffer.width = CVPixelBufferGetWidth(pixelBuffer);
    inBuffer.height = CVPixelBufferGetHeight(pixelBuffer);
    inBuffer.rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);

    //vImage_Error error = vImageRotate_ARGB8888(&inBuffer, &outBuffer, NULL, M_PI_4, bgcolor, kvImageNoFlags);
    // vImageVerticalReflect_ARGB8888(&inBuffer, &inBuffer, kvImageNoFlags);
    
    // Vertical reflect is done on GPU
    
    //[self step1_YCbCrThresholding];
    [self step1_pixelFromRGBtoYCbCr];
    [self step2_densityRegularization];
    // Render loop
    CGFloat hr_sim = 40.0f * sinf(currentTime * 6.28f * [self heartRate] / 60.0f);
    if (yuvBufferRef != NULL) {
        CVBufferRelease(yuvBufferRef);
    }
    baseAddress += 2;
    for (int row = 0; row < inBuffer.height; ++row) {
        for (int col = 0; col < inBuffer.width; ++col) {
            if (tmp[row][col]) {
                // Simply turn off pixels
                // pixel[0] = pixel[1] = pixel[2] = 0;
                /* Lasy  calculation: only when the condition is matched. */
                CGFloat to_color = ((float) *baseAddress) + hr_sim;
                if (to_color >= 255.0f) {
                    *baseAddress = 255;
                } else if (to_color <= 0.0f){
                    *baseAddress = 0;
                }
                else {
                    *baseAddress = (unsigned char) to_color;
                }
            }
            baseAddress += BYTES_PER_PIXEL;
        }
//        baseAddress += BYTES_PER_PIXEL;
    }
    CVPixelBufferUnlockBaseAddress( pixelBuffer, 0 );
}
#pragma mark Capture

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
	CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    
	if ( connection == videoConnection ) {
		
		// Get framerate
		CMTime timestamp = CMSampleBufferGetPresentationTimeStamp( sampleBuffer );
		[self calculateFramerateAtTimestamp:timestamp];
        currentTime = CMTimeGetSeconds(timestamp);
		// Get frame dimensions (for onscreen display)
		if (self.videoDimensions.width == 0 && self.videoDimensions.height == 0)
			self.videoDimensions = CMVideoFormatDescriptionGetDimensions( formatDescription );
		
		// Get buffer type
		if ( self.videoType == 0 )
			self.videoType = CMFormatDescriptionGetMediaSubType( formatDescription );
		if (frame_number < MAX_NUM_FRAMES) {
			if (frame_number == RECORDING_STAGE1) { // 10th frame
				[self switchDeviceTorchMode:backCamera];
                arrayOfFrameRedPixels = (float *) malloc(sizeof(float) * 405504);
                arrayOfRedChannelAverage = (float *) malloc(sizeof(float) * NUM_OF_RED_AVERAGE);
            }
			else if (frame_number == RECORDING_STAGE3) { // 340th frame
				[self switchDeviceTorchMode:backCamera];
			}
            // 1. Collect average color channel values for HR estimation
            // 2. Synchronously process the pixel buffer
            if (frame_number >= RECORDING_STAGE2 && frame_number < RECORDING_STAGE3) {
                // Allow 1 second time to adjust the camera exposure.
                // Fill 300 datapoints
                [self fillInArray:CMSampleBufferGetImageBuffer(sampleBuffer)];
            }
            ++frame_number;
            _percentComplete = ((float)RED_INDEX) / ((float)NUM_OF_RED_AVERAGE);
		}
        else {
            if (!isUsingFrontCamera) {
				[self heartRateEstimate];
                free(arrayOfFrameRedPixels);
                free(arrayOfRedChannelAverage);
                [self stopAndTearDownCaptureSession];
                isUsingFrontCamera = YES;
                [self setupAndStartCaptureSession];
            }
            else {
                //[self createBitmapsfromPixelBuffer:CMSampleBufferGetImageBuffer(sampleBuffer)];
                [self vImageHelpMeDoWork:CMSampleBufferGetImageBuffer(sampleBuffer)];
            }
            ++frame_number;
        }
		 
		// Enqueue it for preview.  This is a shallow queue, so if image processing is taking too long,
		// we'll drop this frame for preview (this keeps preview latency low).
		OSStatus err = CMBufferQueueEnqueue(previewBufferQueue, sampleBuffer);
		if ( !err ) {
			dispatch_async(dispatch_get_main_queue(), ^{
				CMSampleBufferRef sbuf = (CMSampleBufferRef)CMBufferQueueDequeueAndRetain(previewBufferQueue);
				if (sbuf) {
					CVImageBufferRef pixBuf = CMSampleBufferGetImageBuffer(sbuf);
					[self.delegate pixelBufferReadyForDisplay:pixBuf];
					CFRelease(sbuf); // Destroy sbuf.
				}
			});
		}
	}
    
	CFRetain(sampleBuffer);
	CFRetain(formatDescription);
	dispatch_async(movieWritingQueue, ^{

		if ( assetWriter ) {
		
			BOOL wasReadyToRecord = (readyToRecordAudio && readyToRecordVideo);
			
			if (connection == videoConnection) {
				
				// Initialize the video input if this is not done yet
				if (!readyToRecordVideo)
					readyToRecordVideo = [self setupAssetWriterVideoInput:formatDescription];
				
				// Write video data to file
				if (readyToRecordVideo && readyToRecordAudio)
					[self writeSampleBuffer:sampleBuffer ofType:AVMediaTypeVideo];
			}
			else if (connection == audioConnection) {
				
				// Initialize the audio input if this is not done yet
				if (!readyToRecordAudio)
					readyToRecordAudio = [self setupAssetWriterAudioInput:formatDescription];
				
				// Write audio data to file
				if (readyToRecordAudio && readyToRecordVideo)
					[self writeSampleBuffer:sampleBuffer ofType:AVMediaTypeAudio];
			}
			
			BOOL isReadyToRecord = (readyToRecordAudio && readyToRecordVideo);
			if ( !wasReadyToRecord && isReadyToRecord ) {
				recordingWillBeStarted = NO;
				self.recording = YES;
				[self.delegate recordingDidStart];
			}
		}
		CFRelease(sampleBuffer);
		CFRelease(formatDescription);
	});
}

// Flash on

- (void) switchDeviceTorchMode:(AVCaptureDevice *)device
{
    if ([device isTorchModeSupported:AVCaptureTorchModeOn]) {
        NSError *error = nil;
        if ([device lockForConfiguration:&error]) {
            if ([device isTorchActive]) {
                [device setTorchMode:AVCaptureTorchModeOff];
            }
            else
                [device setTorchMode:AVCaptureTorchModeOn];
            [device unlockForConfiguration];
        }
        else {
            NSLog(@"I am not an iPhone!\n");
        }
    }
}

- (void) heartRateEstimate
{
	float min, max;
	min = arrayOfRedChannelAverage[0];
	max = min;
	for (int i = 0; i < NUM_OF_RED_AVERAGE; ++i){
		if (arrayOfRedChannelAverage[i] < min)
			min = arrayOfRedChannelAverage[i];
		else if (arrayOfRedChannelAverage[i] > max)
			max = arrayOfRedChannelAverage[i];
	}
    printf("%f, %f\n",min,max);
	int num_emi_peaks, num_absop_peaks = 0;
	int max_emi_peaks = 500, max_absop_peaks = 500;
	float delta = 0.05f;
	int minHR = 24;
	int maxHR = 240;
	
	int* peak_indices = (int*) malloc(sizeof(int) * max_emi_peaks);
	float* peak_values = (float *) malloc(sizeof(float) * max_emi_peaks);
	memset (peak_indices, 0, sizeof(int) * max_emi_peaks);
	memset (peak_values, 0, sizeof(float) * max_emi_peaks);
    
	if (!detect_peak(arrayOfRedChannelAverage, NUM_OF_RED_AVERAGE, &num_emi_peaks, max_emi_peaks, &num_absop_peaks, max_absop_peaks, delta, peak_indices, peak_values)) {
		NSLog(@"num_emi_peaks = %d\n",num_emi_peaks);
		NSLog(@"num_absop_peaks = %d\n",num_absop_peaks);
		if (num_emi_peaks > 2){
			if (differences != nil){
				free(differences);
				differences = NULL;
			}
			differences = (float *) malloc(sizeof(float) * (num_emi_peaks - 1));
			memset(differences, 0, sizeof(float) * (num_emi_peaks - 1));
			sizeOfDifferences = num_emi_peaks - 1;
			for (int i = 0; i < sizeOfDifferences;++i){
				if (peak_values[i] < 255){ // it's counting mx = MAXDBL as a max
					
					// calculate the difference
					differences[i] = peak_indices[i+1] - peak_indices[i];
					
					// If that difference isn't within range, set the difference to 0
					// This must be interpreted by later code as being NULL
					
					if (60 * NUM_OF_RED_AVERAGE / (10.0f * differences[i]) < minHR
						||
						60 * NUM_OF_RED_AVERAGE / (10.0f * differences[i]) > maxHR){
						differences[i] = 0;
					}
				}
				else {
					// If the peak was greater than 255, it doesn't count and we don't have a valid difference.
					differences[i] = 0;
				}
				// print the calculated differences, for easier debugging!
				printf("%d - %d = %f\n", peak_indices[i+1], peak_indices[i], differences[i]);
			}
			
			//Sometimes the last one shows a false peak.
			// Calculate the average without it.
			// If it is more than 5 away from the average, don't count it.
			float tempSum = 0.0f;
			for (int i = 0; i < num_emi_peaks - 2;++i){
				tempSum += differences[i];
			}
			double tempAvg = tempSum / (num_emi_peaks-2);
			if (tempAvg - differences[num_emi_peaks-2] > 5){
				differences[num_emi_peaks-2] = 0.0f;
			}
			
			float sum = 0;
			unsigned int numSums = 0;
			
			for (int i = 0; i < num_emi_peaks-1; ++i){
				if (differences[i] != 0){
					sum += differences[i];
					++numSums;
				}
			}
			_heartRate = 60.0f * NUM_OF_RED_AVERAGE / (10.0f * sum / numSums) * 0.75f;
			NSLog(@"Heart rate measured is %f", _heartRate);
		}
	}
}

int detect_peak (
				 const float*   data, /* the data */
				 int             data_count, /* row count of data */
				 //       int*            emi_peaks, /* emission peaks will be put here */
				 int*            num_emi_peaks, /* number of emission peaks found */
				 int             max_emi_peaks, /* maximum number of emission peaks */
				 //       int*            absop_peaks, /* absorption peaks will be put here */
				 int*            num_absop_peaks, /* number of absorption peaks found */
				 int             max_absop_peaks, /* maximum number of absorption peaks */
				 float          delta, /* delta used for distinguishing peaks */
				 //       int             emi_first /* should we search emission peak first of
				 //                                  absorption peak first? */
				 int*         peaks_index,
				 float*         peaks_values
				 ) {
    int i = 1;
    int j = 0;
    float  mx, mn;
    int     mx_pos = 0;
    int     mn_pos = 0;
    int     is_detecting_emi = 0;// = emi_first;
    
    mx = data[0];
    mn = data[0];
    
    *num_emi_peaks = 0;
    *num_absop_peaks = 0;
    
    if (data[i+1] > data[i])
        is_detecting_emi = 1;
    
    for(i = 1; i < data_count; ++i)
    {
        if(data[i] > mx)
        {
            mx_pos = i;
            mx = data[i];
        }
        if(data[i] < mn)
        {
            mn_pos = i;
            mn = data[i];
        }
        
        if(is_detecting_emi && data[i] < mx - delta)
        {
            if(*num_emi_peaks >= max_emi_peaks) /* not enough spaces */
                return 1;
            
            ++ (*num_emi_peaks);
            
            is_detecting_emi = 0;
            
            i = mx_pos - 1;
            
            peaks_index[j] = mx_pos;
            peaks_values[j] = data[mx_pos];
            j = j+1;
            
            mn = data[mx_pos];
            mn_pos = mx_pos;
        }
        else if((!is_detecting_emi) && data[i] > mn + delta) {
            if(*num_absop_peaks >= max_absop_peaks)
                return 2;
            
            ++ (*num_absop_peaks);
            
            is_detecting_emi = 1;
            
            i = mn_pos - 1;
            
            mx = data[mn_pos];
            mx_pos = data[mn_pos];
        }
    }
    
    return 0;
}

void MyPixelBufferReleaseCallback (void *releaseRefCon,
                                   const void *baseAddress)
{;
}

- (AVCaptureDevice *)videoDeviceWithPosition:(AVCaptureDevicePosition)position
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *device in devices)
        if ([device position] == position) {
            return device;
        }
    return nil;
}

- (AVCaptureDevice *)audioDevice
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
    if ([devices count] > 0)
        return [devices objectAtIndex:0];
    
    return nil;
}

- (BOOL) setupCaptureSession 
{
	/*
		Overview: RosyWriter uses separate GCD queues for audio and video capture.  If a single GCD queue
		is used to deliver both audio and video buffers, and our video processing consistently takes
		too long, the delivery queue can back up, resulting in audio being dropped.
		
		When recording, RosyWriter creates a third GCD queue for calls to AVAssetWriter.  This ensures
		that AVAssetWriter is not called to start or finish writing from multiple threads simultaneously.
		
		RosyWriter uses AVCaptureSession's default preset, AVCaptureSessionPresetHigh.
	 */
	 
    /*
	 * Create capture session
     * Instead of not configuring the preset, let's make it VGA
     * This way, we have no need to worry about selecting video area.
	 */
    captureSession = [[AVCaptureSession alloc] init];
    NSString *option = isUsingFrontCamera?AVCaptureSessionPreset352x288:AVCaptureSessionPreset352x288;
    if ([captureSession canSetSessionPreset:option]) {
        // Most resource efficient.
        captureSession.sessionPreset = option;
    }
    /*
	 * Create audio connection
	 */
    AVCaptureDeviceInput *audioIn = [[AVCaptureDeviceInput alloc] initWithDevice:[self audioDevice] error:nil];
    if ([captureSession canAddInput:audioIn])
        [captureSession addInput:audioIn];
	[audioIn release];
	
	AVCaptureAudioDataOutput *audioOut = [[AVCaptureAudioDataOutput alloc] init];
	dispatch_queue_t audioCaptureQueue = dispatch_queue_create("Audio Capture Queue", DISPATCH_QUEUE_SERIAL);
	[audioOut setSampleBufferDelegate:self queue:audioCaptureQueue];
	dispatch_release(audioCaptureQueue);
	if ([captureSession canAddOutput:audioOut])
		[captureSession addOutput:audioOut];
	audioConnection = [audioOut connectionWithMediaType:AVMediaTypeAudio];
	[audioOut release];
    
	/*
	 * Create video connection: AVCaptureDevicePositionBack, rear camera
	 */
    NSArray *devices= [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    // Search device list for target devices.
    for (AVCaptureDevice *device in devices) {
        if(frontCamera && backCamera)
            break;
        else if (device.position == AVCaptureDevicePositionFront) {
            frontCamera = device;
        }
        else if (device.position == AVCaptureDevicePositionBack)
            backCamera = device;
    }
    AVCaptureDeviceInput *videoIn;
    if (isUsingFrontCamera) {
        videoIn = [[AVCaptureDeviceInput alloc] initWithDevice:frontCamera error:nil];
		NSLog(@"Using Front camera");
    } else {
		NSLog(@"Using back camera");
        videoIn = [[AVCaptureDeviceInput alloc] initWithDevice:backCamera error:nil];
    }
    if ([captureSession canAddInput:videoIn]) {
        [captureSession addInput:videoIn];
    }
	[videoIn release];
    
	AVCaptureVideoDataOutput *videoOut = [[AVCaptureVideoDataOutput alloc] init];
	/*
		RosyWriter prefers to discard late video frames early in the capture pipeline, since its
		processing can take longer than real-time on some platforms (such as iPhone 3GS).
		Clients whose image processing is faster than real-time should consider setting AVCaptureVideoDataOutput's
		alwaysDiscardsLateVideoFrames property to NO. 
	 */
    
    // Experiment: performance demaning setting. Set to yes for old platforms.
	[videoOut setAlwaysDiscardsLateVideoFrames:YES];
    // Camera pixel buffers are natively YUV but most image processing algorithms expect RBGA data.
	// [videoOut setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    // using kCVPixelFormatType_420YpCvCr88iPlanarFullRange, full-range (luma=[0,255] chroma=[1,255])
    
    NSDictionary *options = @{(id)kCVPixelBufferPixelFormatTypeKey:
                                  [NSNumber numberWithInt:kCVPixelFormatType_32BGRA]};
    [videoOut setVideoSettings:options];
	dispatch_queue_t videoCaptureQueue = dispatch_queue_create("Video Capture Queue", DISPATCH_QUEUE_SERIAL);
	[videoOut setSampleBufferDelegate:self queue:videoCaptureQueue];
	dispatch_release(videoCaptureQueue);
	if ([captureSession canAddOutput:videoOut])
		[captureSession addOutput:videoOut];
	videoConnection = [videoOut connectionWithMediaType:AVMediaTypeVideo];
	previewLayer = [[AVCaptureVideoPreviewLayer alloc]
                    initWithSession:captureSession];
	[previewLayer setBackgroundColor:[[UIColor blackColor] CGColor]];
	[previewLayer setVideoGravity:AVLayerVideoGravityResizeAspect];
	self.videoOrientation = [videoConnection videoOrientation]; // AVLayerVideoGravityResize
	[videoOut release];
    
	return YES;
}

- (void) setupAndStartCaptureSession
{
	// Create a shallow queue for buffers going to the display for preview.
	OSStatus err = CMBufferQueueCreate(kCFAllocatorDefault, 1, CMBufferQueueGetCallbacksForUnsortedSampleBuffers(), &previewBufferQueue);
	if (err)
		[self showError:[NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:nil]];
	
	// Create serial queue for movie writing
	movieWritingQueue = dispatch_queue_create("Movie Writing Queue", DISPATCH_QUEUE_SERIAL);
	
    if ( !captureSession )
		[self setupCaptureSession];
	
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(captureSessionStoppedRunningNotification:) name:AVCaptureSessionDidStopRunningNotification object:captureSession];
	
	if ( !captureSession.isRunning )
		[captureSession startRunning];
}

- (void) pauseCaptureSession
{
	if ( captureSession.isRunning )
		[captureSession stopRunning];
}

- (void) resumeCaptureSession
{
	if ( !captureSession.isRunning )
		[captureSession startRunning];
}

- (void)captureSessionStoppedRunningNotification:(NSNotification *)notification
{
	dispatch_async(movieWritingQueue, ^{
		if ( [self isRecording] ) {
			[self stopRecording];
		}
	});
}

- (void) stopAndTearDownCaptureSession
{
    [captureSession stopRunning];
	if (captureSession)
		[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureSessionDidStopRunningNotification object:captureSession];
	[captureSession release];
	captureSession = nil;
	if (previewBufferQueue) {
		CFRelease(previewBufferQueue);
		previewBufferQueue = NULL;	
	}
	if (movieWritingQueue) {
		dispatch_release(movieWritingQueue);
		movieWritingQueue = NULL;
	}
}

#pragma mark Error Handling

- (void)showError:(NSError *)error
{
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^(void) {
        UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:[error localizedDescription]
                                                            message:[error localizedFailureReason]
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
        [alertView show];
        [alertView release];
    });
}

@end
