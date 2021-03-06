#import "WKGPUImageMovieWriter.h"

#import "GPUImageContext.h"
#import "GLProgram.h"
#import "GPUImageFilter.h"

NSString *const kGPUImageColorSwizzlingFragmentShaderString1 = SHADER_STRING
(
 varying highp vec2 textureCoordinate;
 
 uniform sampler2D inputImageTexture;
 
 void main()
 {
     gl_FragColor = texture2D(inputImageTexture, textureCoordinate).bgra;
 }
);


@interface WKGPUImageMovieWriter ()
{
    GLuint movieFramebuffer, movieRenderbuffer;
    
    GLProgram *colorSwizzlingProgram;
    GLint colorSwizzlingPositionAttribute, colorSwizzlingTextureCoordinateAttribute;
    GLint colorSwizzlingInputTextureUniform;

    GPUImageFramebuffer *firstInputFramebuffer;
    
    CMTime startTime, previousFrameTime, previousAudioTime;

    dispatch_queue_t audioQueue, videoQueue;
    BOOL audioEncodingIsFinished, videoEncodingIsFinished;

    BOOL isRecording;
    BOOL needOtherEncoder;
}

// Movie recording
- (void)initializeMovieWithOutputSettings:(NSMutableDictionary *)outputSettings;

// Frame rendering
- (void)createDataFBO;
- (void)destroyDataFBO;
- (void)setFilterFBO;

- (void)renderAtInternalSizeUsingFramebuffer:(GPUImageFramebuffer *)inputFramebufferToUse;

@end

@implementation WKGPUImageMovieWriter
{
    CMSampleBufferRef sbufCurrentFrame;
}

- (void)willOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CFAllocatorRef allocator = CFAllocatorGetDefault();
    @synchronized(self)
    {
        if(sbufCurrentFrame)
            CFRelease(sbufCurrentFrame);
        CMSampleBufferCreateCopy(allocator, sampleBuffer, &sbufCurrentFrame);
        
        if (self.delegate && [self.delegate respondsToSelector:@selector(processFaceuSampleBuffer:)])
        {
            [self.delegate processFaceuSampleBuffer:sbufCurrentFrame];
        }
    }
    
//    CFAllocatorRef allocator1 = CFAllocatorGetDefault();
//    CMSampleBufferRef sbufCopyOut;
//    CMSampleBufferCreateCopy(allocator1, sampleBuffer, &sbufCopyOut);
}

@synthesize hasAudioTrack = _hasAudioTrack;
@synthesize encodingLiveVideo = _encodingLiveVideo;
@synthesize shouldPassthroughAudio = _shouldPassthroughAudio;
@synthesize completionBlock;
@synthesize failureBlock;
@synthesize videoInputReadyCallback;
@synthesize audioInputReadyCallback;
@synthesize enabled;
@synthesize shouldInvalidateAudioSampleWhenDone = _shouldInvalidateAudioSampleWhenDone;
@synthesize paused = _paused;
@synthesize movieWriterContext = _movieWriterContext;

@synthesize delegate = _delegate;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithSize:(CGSize)newSize
{
    needOtherEncoder = YES;
    return [self initWithMovieURL:nil size:newSize];
}

- (id)initWithMovieURL:(NSURL *)newMovieURL size:(CGSize)newSize;
{
    return [self initWithMovieURL:newMovieURL size:newSize fileType:AVFileTypeQuickTimeMovie outputSettings:nil];
}

- (id)initWithMovieURL:(NSURL *)newMovieURL size:(CGSize)newSize fileType:(NSString *)newFileType outputSettings:(NSMutableDictionary *)outputSettings;
{
    if (!(self = [super init]))
    {
		return nil;
    }

    _shouldInvalidateAudioSampleWhenDone = NO;
    
    self.enabled = YES;
    alreadyFinishedRecording = NO;
    videoEncodingIsFinished = NO;
    audioEncodingIsFinished = NO;

    videoSize = newSize;
    movieURL = newMovieURL;
    fileType = newFileType;
    startTime = kCMTimeInvalid;
    _encodingLiveVideo = [[outputSettings objectForKey:@"EncodingLiveVideo"] isKindOfClass:[NSNumber class]] ? [[outputSettings objectForKey:@"EncodingLiveVideo"] boolValue] : YES;
    previousFrameTime = kCMTimeNegativeInfinity;
    previousAudioTime = kCMTimeNegativeInfinity;
    inputRotation = kGPUImageNoRotation;
    
    _movieWriterContext = [[GPUImageContext alloc] init];
    [_movieWriterContext useSharegroup:[[[GPUImageContext sharedImageProcessingContext] context] sharegroup]];

    runSynchronouslyOnContextQueue(_movieWriterContext, ^{
        [_movieWriterContext useAsCurrentContext];
        
        if ([GPUImageContext supportsFastTextureUpload])
        {
            colorSwizzlingProgram = [_movieWriterContext programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImagePassthroughFragmentShaderString];
        }
        else
        {
            colorSwizzlingProgram = [_movieWriterContext programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImageColorSwizzlingFragmentShaderString1];
        }
        
        if (!colorSwizzlingProgram.initialized)
        {
            [colorSwizzlingProgram addAttribute:@"position"];
            [colorSwizzlingProgram addAttribute:@"inputTextureCoordinate"];
            
            if (![colorSwizzlingProgram link])
            {
                NSString *progLog = [colorSwizzlingProgram programLog];
                NSLog(@"Program link log: %@", progLog);
                NSString *fragLog = [colorSwizzlingProgram fragmentShaderLog];
                NSLog(@"Fragment shader compile log: %@", fragLog);
                NSString *vertLog = [colorSwizzlingProgram vertexShaderLog];
                NSLog(@"Vertex shader compile log: %@", vertLog);
                colorSwizzlingProgram = nil;
                NSAssert(NO, @"Filter shader link failed");
            }
        }        
        
        colorSwizzlingPositionAttribute = [colorSwizzlingProgram attributeIndex:@"position"];
        colorSwizzlingTextureCoordinateAttribute = [colorSwizzlingProgram attributeIndex:@"inputTextureCoordinate"];
        colorSwizzlingInputTextureUniform = [colorSwizzlingProgram uniformIndex:@"inputImageTexture"];
        
        [_movieWriterContext setContextShaderProgram:colorSwizzlingProgram];
        
        glEnableVertexAttribArray(colorSwizzlingPositionAttribute);
        glEnableVertexAttribArray(colorSwizzlingTextureCoordinateAttribute);
    });
    
    if (!needOtherEncoder)
    {
        [self initializeMovieWithOutputSettings:outputSettings];
    }

    return self;
}

- (void)dealloc;
{
    [self destroyDataFBO];

#if !OS_OBJECT_USE_OBJC
    if( audioQueue != NULL )
    {
        dispatch_release(audioQueue);
    }
    if( videoQueue != NULL )
    {
        dispatch_release(videoQueue);
    }
#endif
}

#pragma mark -
#pragma mark Movie recording

- (void)initializeMovieWithOutputSettings:(NSDictionary *)outputSettings;
{
    isRecording = NO;
    
    self.enabled = YES;
    NSError *error = nil;
    assetWriter = [[AVAssetWriter alloc] initWithURL:movieURL fileType:fileType error:&error];
    if (error != nil)
    {
        NSLog(@"Error: %@", error);
        if (failureBlock) 
        {
            failureBlock(error);
        }
        else 
        {
            if(self.delegate && [self.delegate respondsToSelector:@selector(movieRecordingFailedWithError:)])
            {
                [self.delegate movieRecordingFailedWithError:error];
            }
        }
    }
    
    // Set this to make sure that a functional movie is produced, even if the recording is cut off mid-stream. Only the last second should be lost in that case.
    assetWriter.movieFragmentInterval = CMTimeMakeWithSeconds(1.0, 1000);
    
    // use default output settings if none specified
    if (outputSettings == nil) 
    {
        NSMutableDictionary *settings = [[NSMutableDictionary alloc] init];
        [settings setObject:AVVideoCodecH264 forKey:AVVideoCodecKey];
        [settings setObject:[NSNumber numberWithInt:videoSize.width] forKey:AVVideoWidthKey];
        [settings setObject:[NSNumber numberWithInt:videoSize.height] forKey:AVVideoHeightKey];
        outputSettings = settings;
    }
    // custom output settings specified
    else 
    {
		NSString *videoCodec = [outputSettings objectForKey:AVVideoCodecKey];
		NSNumber *width = [outputSettings objectForKey:AVVideoWidthKey];
		NSNumber *height = [outputSettings objectForKey:AVVideoHeightKey];
		
		NSAssert(videoCodec && width && height, @"OutputSettings is missing required parameters.");
        
        if( [outputSettings objectForKey:@"EncodingLiveVideo"] ) {
            NSMutableDictionary *tmp = [outputSettings mutableCopy];
            [tmp removeObjectForKey:@"EncodingLiveVideo"];
            outputSettings = tmp;
        }
    }
    
    /*
    NSDictionary *videoCleanApertureSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                                [NSNumber numberWithInt:videoSize.width], AVVideoCleanApertureWidthKey,
                                                [NSNumber numberWithInt:videoSize.height], AVVideoCleanApertureHeightKey,
                                                [NSNumber numberWithInt:0], AVVideoCleanApertureHorizontalOffsetKey,
                                                [NSNumber numberWithInt:0], AVVideoCleanApertureVerticalOffsetKey,
                                                nil];

    NSDictionary *videoAspectRatioSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                              [NSNumber numberWithInt:3], AVVideoPixelAspectRatioHorizontalSpacingKey,
                                              [NSNumber numberWithInt:3], AVVideoPixelAspectRatioVerticalSpacingKey,
                                              nil];

    NSMutableDictionary * compressionProperties = [[NSMutableDictionary alloc] init];
    [compressionProperties setObject:videoCleanApertureSettings forKey:AVVideoCleanApertureKey];
    [compressionProperties setObject:videoAspectRatioSettings forKey:AVVideoPixelAspectRatioKey];
    [compressionProperties setObject:[NSNumber numberWithInt: 2000000] forKey:AVVideoAverageBitRateKey];
    [compressionProperties setObject:[NSNumber numberWithInt: 16] forKey:AVVideoMaxKeyFrameIntervalKey];
    [compressionProperties setObject:AVVideoProfileLevelH264Main31 forKey:AVVideoProfileLevelKey];
    
    [outputSettings setObject:compressionProperties forKey:AVVideoCompressionPropertiesKey];
    */
     
    assetWriterVideoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:outputSettings];
    assetWriterVideoInput.expectsMediaDataInRealTime = _encodingLiveVideo;
    
    // You need to use BGRA for the video in order to get realtime encoding. I use a color-swizzling shader to line up glReadPixels' normal RGBA output with the movie input's BGRA.
    NSDictionary *sourcePixelBufferAttributesDictionary = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey,
                                                           [NSNumber numberWithInt:videoSize.width], kCVPixelBufferWidthKey,
                                                           [NSNumber numberWithInt:videoSize.height], kCVPixelBufferHeightKey,
                                                           nil];
//    NSDictionary *sourcePixelBufferAttributesDictionary = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt:kCVPixelFormatType_32ARGB], kCVPixelBufferPixelFormatTypeKey,
//                                                           nil];
        
    assetWriterPixelBufferInput = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:assetWriterVideoInput sourcePixelBufferAttributes:sourcePixelBufferAttributesDictionary];
    
    [assetWriter addInput:assetWriterVideoInput];
}

- (void)setEncodingLiveVideo:(BOOL) value
{
    _encodingLiveVideo = value;
    if (isRecording) {
        NSAssert(NO, @"Can not change Encoding Live Video while recording");
    }
    else
    {
        assetWriterVideoInput.expectsMediaDataInRealTime = _encodingLiveVideo;
        assetWriterAudioInput.expectsMediaDataInRealTime = _encodingLiveVideo;
    }
}

- (void)startRecording;
{
    alreadyFinishedRecording = NO;
    startTime = kCMTimeInvalid;
    if (!needOtherEncoder)
    {
        runSynchronouslyOnContextQueue(_movieWriterContext, ^{
            if (audioInputReadyCallback == NULL)
            {
                [assetWriter startWriting];
            }
        });
    }
    
    isRecording = YES;
}

- (void)startRecordingInOrientation:(CGAffineTransform)orientationTransform;
{
	assetWriterVideoInput.transform = orientationTransform;

	[self startRecording];
}

- (void)cancelRecording;
{
    if (!needOtherEncoder)
    {
        if (assetWriter.status == AVAssetWriterStatusCompleted)
        {
            return;
        }
        
        isRecording = NO;
        
        runSynchronouslyOnContextQueue(_movieWriterContext, ^{
            alreadyFinishedRecording = YES;
            
            if( assetWriter.status == AVAssetWriterStatusWriting && ! videoEncodingIsFinished )
            {
                videoEncodingIsFinished = YES;
                [assetWriterVideoInput markAsFinished];
            }
            if( assetWriter.status == AVAssetWriterStatusWriting && ! audioEncodingIsFinished )
            {
                audioEncodingIsFinished = YES;
                [assetWriterAudioInput markAsFinished];
            }
            [assetWriter cancelWriting];
        });
    }
    else
    {
        isRecording = NO;
    }
}

- (void)finishRecording;
{
    [self finishRecordingWithCompletionHandler:NULL];
}

- (void)finishRecordingWithCompletionHandler:(void (^)(void))handler;
{
    if (!needOtherEncoder)
    {
        runSynchronouslyOnContextQueue(_movieWriterContext, ^{
            isRecording = NO;
            
            if (assetWriter.status == AVAssetWriterStatusCompleted || assetWriter.status == AVAssetWriterStatusCancelled || assetWriter.status == AVAssetWriterStatusUnknown)
            {
                if (handler)
                    runAsynchronouslyOnContextQueue(_movieWriterContext, handler);
                return;
            }
            if( assetWriter.status == AVAssetWriterStatusWriting && ! videoEncodingIsFinished )
            {
                videoEncodingIsFinished = YES;
                [assetWriterVideoInput markAsFinished];
            }
            if( assetWriter.status == AVAssetWriterStatusWriting && ! audioEncodingIsFinished )
            {
                audioEncodingIsFinished = YES;
                [assetWriterAudioInput markAsFinished];
            }
#if (!defined(__IPHONE_6_0) || (__IPHONE_OS_VERSION_MAX_ALLOWED < __IPHONE_6_0))
            // Not iOS 6 SDK
            [assetWriter finishWriting];
            if (handler)
                runAsynchronouslyOnContextQueue(_movieWriterContext,handler);
#else
            // iOS 6 SDK
            if ([assetWriter respondsToSelector:@selector(finishWritingWithCompletionHandler:)]) {
                // Running iOS 6
                [assetWriter finishWritingWithCompletionHandler:(handler ?: ^{ })];
            }
            else {
                // Not running iOS 6
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                [assetWriter finishWriting];
#pragma clang diagnostic pop
                if (handler)
                    runAsynchronouslyOnContextQueue(_movieWriterContext, handler);
            }
#endif
        });
    }
    else
    {
        isRecording = NO;
    }
}

- (void)processAudioBuffer:(CMSampleBufferRef)audioBuffer;
{
    if (!isRecording)
    {
        return;
    }
    
    if (!needOtherEncoder)
    {
        //    if (_hasAudioTrack && CMTIME_IS_VALID(startTime))
        if (_hasAudioTrack)
        {
            CFRetain(audioBuffer);
            
            CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(audioBuffer);
            
            if (CMTIME_IS_INVALID(startTime))
            {
                runSynchronouslyOnContextQueue(_movieWriterContext, ^{
                    if ((audioInputReadyCallback == NULL) && (assetWriter.status != AVAssetWriterStatusWriting))
                    {
                        [assetWriter startWriting];
                    }
                    [assetWriter startSessionAtSourceTime:currentSampleTime];
                    startTime = currentSampleTime;
                });
            }
            
            if (!assetWriterAudioInput.readyForMoreMediaData && _encodingLiveVideo)
            {
                NSLog(@"1: Had to drop an audio frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
                if (_shouldInvalidateAudioSampleWhenDone)
                {
                    CMSampleBufferInvalidate(audioBuffer);
                }
                CFRelease(audioBuffer);
                return;
            }
            
            previousAudioTime = currentSampleTime;
            
            //if the consumer wants to do something with the audio samples before writing, let him.
            if (self.audioProcessingCallback) {
                //need to introspect into the opaque CMBlockBuffer structure to find its raw sample buffers.
                CMBlockBufferRef buffer = CMSampleBufferGetDataBuffer(audioBuffer);
                CMItemCount numSamplesInBuffer = CMSampleBufferGetNumSamples(audioBuffer);
                AudioBufferList audioBufferList;
                
                CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(audioBuffer,
                                                                        NULL,
                                                                        &audioBufferList,
                                                                        sizeof(audioBufferList),
                                                                        NULL,
                                                                        NULL,
                                                                        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                                                                        &buffer
                                                                        );
                //passing a live pointer to the audio buffers, try to process them in-place or we might have syncing issues.
                for (int bufferCount=0; bufferCount < audioBufferList.mNumberBuffers; bufferCount++) {
                    SInt16 *samples = (SInt16 *)audioBufferList.mBuffers[bufferCount].mData;
                    self.audioProcessingCallback(&samples, numSamplesInBuffer);
                }
            }
            
            //        NSLog(@"Recorded audio sample time: %lld, %d, %lld", currentSampleTime.value, currentSampleTime.timescale, currentSampleTime.epoch);
            void(^write)() = ^() {
                while( ! assetWriterAudioInput.readyForMoreMediaData && ! _encodingLiveVideo && ! audioEncodingIsFinished ) {
                    NSDate *maxDate = [NSDate dateWithTimeIntervalSinceNow:0.5];
                    //NSLog(@"audio waiting...");
                    [[NSRunLoop currentRunLoop] runUntilDate:maxDate];
                }
                if (!assetWriterAudioInput.readyForMoreMediaData)
                {
                    NSLog(@"2: Had to drop an audio frame %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
                }
                else if(assetWriter.status == AVAssetWriterStatusWriting)
                {
                    if (![assetWriterAudioInput appendSampleBuffer:audioBuffer])
                        NSLog(@"Problem appending audio buffer at time: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
                }
                else
                {
                    //NSLog(@"Wrote an audio frame %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
                }
                
                if (_shouldInvalidateAudioSampleWhenDone)
                {
                    CMSampleBufferInvalidate(audioBuffer);
                }
                CFRelease(audioBuffer);
            };
            //        runAsynchronouslyOnContextQueue(_movieWriterContext, write);
            if( _encodingLiveVideo )
                
            {
                runAsynchronouslyOnContextQueue(_movieWriterContext, write);
            }
            else
            {
                write();
            }
        }
    }
    else
    {
        if (self.delegate && [self.delegate respondsToSelector:@selector(movieAudioBuffer:)])
        {
            [self.delegate movieAudioBuffer:audioBuffer];
        }
    }
}

- (void)enableSynchronizationCallbacks;
{
    if (needOtherEncoder)
    {
        return;
    }
    
    if (videoInputReadyCallback != NULL)
    {
        if( assetWriter.status != AVAssetWriterStatusWriting )
        {
            [assetWriter startWriting];
        }
        videoQueue = dispatch_queue_create("com.sunsetlakesoftware.GPUImage.videoReadingQueue", NULL);
        [assetWriterVideoInput requestMediaDataWhenReadyOnQueue:videoQueue usingBlock:^{
            if( _paused )
            {
                //NSLog(@"video requestMediaDataWhenReadyOnQueue paused");
                // if we don't sleep, we'll get called back almost immediately, chewing up CPU
                usleep(10000);
                return;
            }
            //NSLog(@"video requestMediaDataWhenReadyOnQueue begin");
            while( assetWriterVideoInput.readyForMoreMediaData && ! _paused )
            {
                if( videoInputReadyCallback && ! videoInputReadyCallback() && ! videoEncodingIsFinished )
                {
                    runAsynchronouslyOnContextQueue(_movieWriterContext, ^{
                        if( assetWriter.status == AVAssetWriterStatusWriting && ! videoEncodingIsFinished )
                        {
                            videoEncodingIsFinished = YES;
                            [assetWriterVideoInput markAsFinished];
                        }
                    });
                }
            }
            //NSLog(@"video requestMediaDataWhenReadyOnQueue end");
        }];
    }
    
    if (audioInputReadyCallback != NULL)
    {
        audioQueue = dispatch_queue_create("com.sunsetlakesoftware.GPUImage.audioReadingQueue", NULL);
        [assetWriterAudioInput requestMediaDataWhenReadyOnQueue:audioQueue usingBlock:^{
            if( _paused )
            {
                //NSLog(@"audio requestMediaDataWhenReadyOnQueue paused");
                // if we don't sleep, we'll get called back almost immediately, chewing up CPU
                usleep(10000);
                return;
            }
            //NSLog(@"audio requestMediaDataWhenReadyOnQueue begin");
            while( assetWriterAudioInput.readyForMoreMediaData && ! _paused )
            {
                if( audioInputReadyCallback && ! audioInputReadyCallback() && ! audioEncodingIsFinished )
                {
                    runAsynchronouslyOnContextQueue(_movieWriterContext, ^{
                        if( assetWriter.status == AVAssetWriterStatusWriting && ! audioEncodingIsFinished )
                        {
                            audioEncodingIsFinished = YES;
                            [assetWriterAudioInput markAsFinished];
                        }
                    });
                }
            }
            //NSLog(@"audio requestMediaDataWhenReadyOnQueue end");
        }];
    }        
    
}

#pragma mark -
#pragma mark Frame rendering

- (void)createDataFBO;
{
    glActiveTexture(GL_TEXTURE1);
    glGenFramebuffers(1, &movieFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, movieFramebuffer);
    
    if ([GPUImageContext supportsFastTextureUpload])
    {
        // Code originally sourced from http://allmybrain.com/2011/12/08/rendering-to-a-texture-with-ios-5-texture-cache-api/
        

//        CVPixelBufferPoolCreatePixelBuffer (NULL, [assetWriterPixelBufferInput pixelBufferPool], &renderTarget);
        
        CFDictionaryRef empty; // empty value for attr value.
        CFMutableDictionaryRef attrs;
        empty = CFDictionaryCreate(kCFAllocatorDefault, // our empty IOSurface properties dictionary
                                   NULL,
                                   NULL,
                                   0,
                                   &kCFTypeDictionaryKeyCallBacks,
                                   &kCFTypeDictionaryValueCallBacks);
        attrs = CFDictionaryCreateMutable(kCFAllocatorDefault,
                                          1,
                                          &kCFTypeDictionaryKeyCallBacks,
                                          &kCFTypeDictionaryValueCallBacks);
        
        CFDictionarySetValue(attrs,
                             kCVPixelBufferIOSurfacePropertiesKey,
                             empty);
        if (empty) {
            CFRelease(empty);
        }
        
        CVReturn status;
        status = CVPixelBufferCreate(kCFAllocatorDefault,
                                     videoSize.width,
                                     videoSize.height,
                                     kCVPixelFormatType_32BGRA,
                                     attrs,
                                     &renderTarget);
        CFRelease(attrs);

        /* AVAssetWriter will use BT.601 conversion matrix for RGB to YCbCr conversion
         * regardless of the kCVImageBufferYCbCrMatrixKey value.
         * Tagging the resulting video file as BT.601, is the best option right now.
         * Creating a proper BT.709 video is not possible at the moment.
         */
        CVBufferSetAttachment(renderTarget, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(renderTarget, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(renderTarget, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        
        CVOpenGLESTextureCacheCreateTextureFromImage (kCFAllocatorDefault, [_movieWriterContext coreVideoTextureCache], renderTarget,
                                                      NULL, // texture attributes
                                                      GL_TEXTURE_2D,
                                                      GL_RGBA, // opengl format
                                                      (int)videoSize.width,
                                                      (int)videoSize.height,
                                                      GL_BGRA, // native iOS format
                                                      GL_UNSIGNED_BYTE,
                                                      0,
                                                      &renderTexture);
        
        glBindTexture(CVOpenGLESTextureGetTarget(renderTexture), CVOpenGLESTextureGetName(renderTexture));
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, CVOpenGLESTextureGetName(renderTexture), 0);
    }
    else
    {
        glGenRenderbuffers(1, &movieRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, movieRenderbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, (int)videoSize.width, (int)videoSize.height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, movieRenderbuffer);	
    }
    
	
	GLenum glStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    
    NSAssert(glStatus == GL_FRAMEBUFFER_COMPLETE, @"Incomplete filter FBO: %d", glStatus);
}

- (void)destroyDataFBO;
{
    runSynchronouslyOnContextQueue(_movieWriterContext, ^{
        [_movieWriterContext useAsCurrentContext];

        if (movieFramebuffer)
        {
            glDeleteFramebuffers(1, &movieFramebuffer);
            movieFramebuffer = 0;
        }
        
        if (movieRenderbuffer)
        {
            glDeleteRenderbuffers(1, &movieRenderbuffer);
            movieRenderbuffer = 0;
        }
        
        if ([GPUImageContext supportsFastTextureUpload])
        {
            if (renderTexture)
            {
                CFRelease(renderTexture);
            }
            if (renderTarget)
            {
                CVPixelBufferRelease(renderTarget);
            }
            
        }
    });
}

- (void)setFilterFBO;
{
    if (!movieFramebuffer)
    {
        [self createDataFBO];
    }
    
    glBindFramebuffer(GL_FRAMEBUFFER, movieFramebuffer);
    
    glViewport(0, 0, (int)videoSize.width, (int)videoSize.height);
}

- (void)renderAtInternalSizeUsingFramebuffer:(GPUImageFramebuffer *)inputFramebufferToUse;
{
    [_movieWriterContext useAsCurrentContext];
    [self setFilterFBO];
    
    [_movieWriterContext setContextShaderProgram:colorSwizzlingProgram];
    
    glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    // This needs to be flipped to write out to video correctly
    static const GLfloat squareVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };
    
    const GLfloat *textureCoordinates = [GPUImageFilter textureCoordinatesForRotation:inputRotation];
    
	glActiveTexture(GL_TEXTURE4);
	glBindTexture(GL_TEXTURE_2D, [inputFramebufferToUse texture]);
	glUniform1i(colorSwizzlingInputTextureUniform, 4);
    
//    NSLog(@"Movie writer framebuffer: %@", inputFramebufferToUse);
    
    glVertexAttribPointer(colorSwizzlingPositionAttribute, 2, GL_FLOAT, 0, 0, squareVertices);
	glVertexAttribPointer(colorSwizzlingTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, textureCoordinates);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glFinish();
}

#pragma mark -
#pragma mark GPUImageInput protocol

- (void)newFrameReadyAtTime:(CMTime)frameTime atIndex:(NSInteger)textureIndex;
{
    if (!isRecording)
    {
        [firstInputFramebuffer unlock];
        return;
    }

    // Drop frames forced by images and other things with no time constants
    // Also, if two consecutive times with the same value are added to the movie, it aborts recording, so I bail on that case
    if ( (CMTIME_IS_INVALID(frameTime)) || (CMTIME_COMPARE_INLINE(frameTime, ==, previousFrameTime)) || (CMTIME_IS_INDEFINITE(frameTime)) ) 
    {
        [firstInputFramebuffer unlock];
        return;
    }

    if (!needOtherEncoder)
    {
        if (CMTIME_IS_INVALID(startTime))
        {
            runSynchronouslyOnContextQueue(_movieWriterContext, ^{
                if ((videoInputReadyCallback == NULL) && (assetWriter.status != AVAssetWriterStatusWriting))
                {
                    [assetWriter startWriting];
                }
                
                [assetWriter startSessionAtSourceTime:frameTime];
                startTime = frameTime;
            });
        }
    }
    

    GPUImageFramebuffer *inputFramebufferForBlock = firstInputFramebuffer;
    
    if (!needOtherEncoder)
        glFinish();

    runAsynchronouslyOnContextQueue(_movieWriterContext, ^{
        
        if (!needOtherEncoder)
        {
            if (!assetWriterVideoInput.readyForMoreMediaData && _encodingLiveVideo)
            {
                [inputFramebufferForBlock unlock];
                NSLog(@"1: Had to drop a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
                return;
            }
        }
        
        // Render the frame with swizzled colors, so that they can be uploaded quickly as BGRA frames
        [_movieWriterContext useAsCurrentContext];
        [self renderAtInternalSizeUsingFramebuffer:inputFramebufferForBlock];
        
        CVPixelBufferRef fromImageBuffer = NULL;
        
        if ([GPUImageContext supportsFastTextureUpload])
        {
            fromImageBuffer = renderTarget;
            CVPixelBufferLockBaseAddress(fromImageBuffer, 0);
        }
        else
        {
            CVReturn status = CVPixelBufferPoolCreatePixelBuffer (NULL, [assetWriterPixelBufferInput pixelBufferPool], &fromImageBuffer);
            if ((fromImageBuffer == NULL) || (status != kCVReturnSuccess))
            {
                CVPixelBufferRelease(fromImageBuffer);
                return;
            }
            else
            {
                CVPixelBufferLockBaseAddress(fromImageBuffer, 0);
                
                GLubyte *pixelBufferData = (GLubyte *)CVPixelBufferGetBaseAddress(fromImageBuffer);
                glReadPixels(0, 0, videoSize.width, videoSize.height, GL_RGBA, GL_UNSIGNED_BYTE, pixelBufferData);
            }
        }
        
        void(^write)() = ^() {
            
            if (needOtherEncoder)
            {
//                void *fromBaseAddress = CVPixelBufferGetBaseAddress(fromImageBuffer);
//                size_t fromBytesPerRow = CVPixelBufferGetBytesPerRow(fromImageBuffer);
//                size_t fromWidth = CVPixelBufferGetWidth(fromImageBuffer);
//                size_t fromHeight = CVPixelBufferGetHeight(fromImageBuffer);
//                
//                @synchronized(self)
//                {
//                    // 为媒体数据设置一个CMSampleBuffer的Core Video图像缓存对象
//                    if(sbufCurrentFrame)
//                    {
//                        CVImageBufferRef toImageBuffer = CMSampleBufferGetImageBuffer(sbufCurrentFrame);
//                        if(toImageBuffer)
//                        {
//                            CFRetain(toImageBuffer);
//                            // 锁定pixel buffer的基地址
//                            CVPixelBufferLockBaseAddress(toImageBuffer, 0);
//                            
//                            // 得到pixel buffer的基地址
//                            void *toBaseAddress = CVPixelBufferGetBaseAddress(toImageBuffer);
//                            
//                            // 得到pixel buffer的行字节数
//                            size_t toBytesPerRow = CVPixelBufferGetBytesPerRow(toImageBuffer);
//                            // 得到pixel buffer的宽和高
//                            size_t toWidth = CVPixelBufferGetWidth(toImageBuffer);
//                            size_t toHeight = CVPixelBufferGetHeight(toImageBuffer);
//                            
//                            if(fromBytesPerRow==toBytesPerRow && fromHeight==toHeight && fromWidth==toWidth)
//                            {
//                                memcpy(toBaseAddress, fromBaseAddress, toHeight*toBytesPerRow);
//                            }
//                                                        
//                            CVPixelBufferUnlockBaseAddress(toImageBuffer, 0);
//                            CVPixelBufferRelease(toImageBuffer);
//                            
//                            if (self.delegate && [self.delegate respondsToSelector:@selector(movieVideoBuffer:)])
//                            {
//                                [self.delegate movieVideoBuffer:sbufCurrentFrame];
//                            }
//                            if (self.delegate && [self.delegate respondsToSelector:@selector(willOutputPixelBuffer:)])
//                            {
//                                [self.delegate willOutputPixelBuffer:fromImageBuffer];
//                            }
                
                            if (self.delegate && [self.delegate respondsToSelector:@selector(movieVideoPixelBuffer:)])
                            {
                                [self.delegate movieVideoPixelBuffer:fromImageBuffer];
                            }
//                        }
                
                        CFRelease(sbufCurrentFrame);
                        sbufCurrentFrame=nil;
//                    }
//                }
            }
            else
            {
                while( ! assetWriterVideoInput.readyForMoreMediaData && ! _encodingLiveVideo && ! videoEncodingIsFinished ) {
                    NSDate *maxDate = [NSDate dateWithTimeIntervalSinceNow:0.1];
                    //            NSLog(@"video waiting...");
                    [[NSRunLoop currentRunLoop] runUntilDate:maxDate];
                }
                if (!assetWriterVideoInput.readyForMoreMediaData)
                {
                    NSLog(@"2: Had to drop a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
                }
                else if(self.assetWriter.status == AVAssetWriterStatusWriting)
                {
                    if (![assetWriterPixelBufferInput appendPixelBuffer:fromImageBuffer withPresentationTime:frameTime])
                        NSLog(@"Problem appending pixel buffer at time: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
                }
                else
                {
                    NSLog(@"Couldn't write a frame");
                    //NSLog(@"Wrote a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
                }
            }
            
            CVPixelBufferUnlockBaseAddress(fromImageBuffer, 0);
            
            previousFrameTime = frameTime;
            
            if (![GPUImageContext supportsFastTextureUpload])
            {
                CVPixelBufferRelease(fromImageBuffer);
            }
        };
        
        write();
        
        [inputFramebufferForBlock unlock];
    });
}

- (NSInteger)nextAvailableTextureIndex;
{
    return 0;
}

- (void)setInputFramebuffer:(GPUImageFramebuffer *)newInputFramebuffer atIndex:(NSInteger)textureIndex;
{
    [newInputFramebuffer lock];
//    runSynchronouslyOnContextQueue(_movieWriterContext, ^{
        firstInputFramebuffer = newInputFramebuffer;
//    });
}

- (void)setInputRotation:(GPUImageRotationMode)newInputRotation atIndex:(NSInteger)textureIndex;
{
    inputRotation = newInputRotation;
}

- (void)setInputSize:(CGSize)newSize atIndex:(NSInteger)textureIndex;
{
}

- (CGSize)maximumOutputSize;
{
    return videoSize;
}

- (void)endProcessing 
{
    if (completionBlock) 
    {
        if (!alreadyFinishedRecording)
        {
            alreadyFinishedRecording = YES;
            completionBlock();
        }        
    }
    else 
    {
        if (_delegate && [_delegate respondsToSelector:@selector(movieRecordingCompleted)])
        {
            [_delegate movieRecordingCompleted];
        }
    }
}

- (BOOL)shouldIgnoreUpdatesToThisTarget;
{
    return NO;
}

- (BOOL)wantsMonochromeInput;
{
    return NO;
}

- (void)setCurrentlyReceivingMonochromeInput:(BOOL)newValue;
{
    
}

#pragma mark -
#pragma mark Accessors

- (void)setHasAudioTrack:(BOOL)newValue
{
	[self setHasAudioTrack:newValue audioSettings:nil];
}

- (void)setHasAudioTrack:(BOOL)newValue audioSettings:(NSDictionary *)audioOutputSettings;
{
    if (needOtherEncoder)
    {
        return;
    }
    
    _hasAudioTrack = newValue;
    
    if (_hasAudioTrack)
    {
        if (_shouldPassthroughAudio)
        {
			// Do not set any settings so audio will be the same as passthrough
			audioOutputSettings = nil;
        }
        else if (audioOutputSettings == nil)
        {
            AVAudioSession *sharedAudioSession = [AVAudioSession sharedInstance];
            double preferredHardwareSampleRate;
            
            if ([sharedAudioSession respondsToSelector:@selector(sampleRate)])
            {
                preferredHardwareSampleRate = [sharedAudioSession sampleRate];
            }
            else
            {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                preferredHardwareSampleRate = [[AVAudioSession sharedInstance] currentHardwareSampleRate];
#pragma clang diagnostic pop
            }
            
            AudioChannelLayout acl;
            bzero( &acl, sizeof(acl));
            acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
            
            audioOutputSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                         [ NSNumber numberWithInt: kAudioFormatMPEG4AAC], AVFormatIDKey,
                                         [ NSNumber numberWithInt: 1 ], AVNumberOfChannelsKey,
                                         [ NSNumber numberWithFloat: preferredHardwareSampleRate ], AVSampleRateKey,
                                         [ NSData dataWithBytes: &acl length: sizeof( acl ) ], AVChannelLayoutKey,
                                         //[ NSNumber numberWithInt:AVAudioQualityLow], AVEncoderAudioQualityKey,
                                         [ NSNumber numberWithInt: 64000 ], AVEncoderBitRateKey,
                                         nil];
/*
            AudioChannelLayout acl;
            bzero( &acl, sizeof(acl));
            acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
            
            audioOutputSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                   [ NSNumber numberWithInt: kAudioFormatMPEG4AAC ], AVFormatIDKey,
                                   [ NSNumber numberWithInt: 1 ], AVNumberOfChannelsKey,
                                   [ NSNumber numberWithFloat: 44100.0 ], AVSampleRateKey,
                                   [ NSNumber numberWithInt: 64000 ], AVEncoderBitRateKey,
                                   [ NSData dataWithBytes: &acl length: sizeof( acl ) ], AVChannelLayoutKey,
                                   nil];*/
        }
        
        assetWriterAudioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioOutputSettings];
        [assetWriter addInput:assetWriterAudioInput];
        assetWriterAudioInput.expectsMediaDataInRealTime = _encodingLiveVideo;
    }
    else
    {
        // Remove audio track if it exists
    }
}

- (NSArray*)metaData {
    return assetWriter.metadata;
}

- (void)setMetaData:(NSArray*)metaData {
    assetWriter.metadata = metaData;
}
 
- (CMTime)duration {
    if (!needOtherEncoder)
    {
        if( ! CMTIME_IS_VALID(startTime) )
            return kCMTimeZero;
        if( ! CMTIME_IS_NEGATIVE_INFINITY(previousFrameTime) )
            return CMTimeSubtract(previousFrameTime, startTime);
        if( ! CMTIME_IS_NEGATIVE_INFINITY(previousAudioTime) )
            return CMTimeSubtract(previousAudioTime, startTime);
    }
    
    return kCMTimeZero;
}

- (CGAffineTransform)transform {
    return assetWriterVideoInput.transform;
}

- (void)setTransform:(CGAffineTransform)transform {
    assetWriterVideoInput.transform = transform;
}

- (AVAssetWriter*)assetWriter {
    return assetWriter;
}

@end
