@import simd;
@import MetalKit;

#import "iTermMetalDriver.h"

#import "DebugLogging.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermASCIITexture.h"
#import "iTermBackgroundImageRenderer.h"
#import "iTermBackgroundColorRenderer.h"
#import "iTermBadgeRenderer.h"
#import "iTermBroadcastStripesRenderer.h"
#import "iTermCopyBackgroundRenderer.h"
#import "iTermCursorGuideRenderer.h"
#import "iTermCursorRenderer.h"
#import "iTermFullScreenFlashRenderer.h"
#import "iTermHighlightRowRenderer.h"
#import "iTermHistogram.h"
#import "iTermImageRenderer.h"
#import "iTermIndicatorRenderer.h"
#import "iTermMarginRenderer.h"
#import "iTermMetalFrameData.h"
#import "iTermMarkRenderer.h"
#import "iTermMetalRowData.h"
#import "iTermPreciseTimer.h"
#import "iTermTextRendererTransientState.h"
#import "iTermTimestampsRenderer.h"
#import "iTermShaderTypes.h"
#import "iTermTextRenderer.h"
#import "iTermTextureArray.h"
#import "MovingAverage.h"
#import "NSArray+iTerm.h"
#import "NSMutableData+iTerm.h"

#import <IOKit/ps/IOPowerSources.h>

@implementation iTermMetalCursorInfo
@end

@implementation iTermMetalIMEInfo

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p cursor=%@ range=%@>",
            NSStringFromClass(self.class),
            self,
            VT100GridCoordDescription(_cursorCoord),
            VT100GridCoordRangeDescription(_markedRange)];
}
- (void)setRangeStart:(VT100GridCoord)start {
    _markedRange.start = start;
}

- (void)setRangeEnd:(VT100GridCoord)end {
    _markedRange.end = end;
}

@end

@interface iTermMetalDriver()
// This indicates if a draw call was made while busy. When we stop being busy
// and this is set, then we must schedule another draw.
@property (atomic) BOOL needsDraw;
@end

@implementation iTermMetalDriver {
    iTermMarginRenderer *_marginRenderer;
    iTermBackgroundImageRenderer *_backgroundImageRenderer;
    iTermBackgroundColorRenderer *_backgroundColorRenderer;
    iTermTextRenderer *_textRenderer;
    iTermMarkRenderer *_markRenderer;
    iTermBadgeRenderer *_badgeRenderer;
    iTermFullScreenFlashRenderer *_flashRenderer;
    iTermTimestampsRenderer *_timestampsRenderer;
    iTermIndicatorRenderer *_indicatorRenderer;
    iTermBroadcastStripesRenderer *_broadcastStripesRenderer;
    iTermCursorGuideRenderer *_cursorGuideRenderer;
    iTermHighlightRowRenderer *_highlightRowRenderer;
    iTermCursorRenderer *_underlineCursorRenderer;
    iTermCursorRenderer *_barCursorRenderer;
    iTermCursorRenderer *_imeCursorRenderer;
    iTermCursorRenderer *_blockCursorRenderer;
    iTermCursorRenderer *_frameCursorRenderer;
    iTermCopyModeCursorRenderer *_copyModeCursorRenderer;
    iTermCopyBackgroundRenderer *_copyBackgroundRenderer;
    iTermImageRenderer *_imageRenderer;

    // The command Queue from which we'll obtain command buffers
    id<MTLCommandQueue> _commandQueue;

    // The current size of our view so we can use this in our render pipeline
    vector_uint2 _viewportSize;
    CGSize _cellSize;
    CGSize _cellSizeWithoutSpacing;
    int _rows;
    int _columns;
    BOOL _sizeChanged;
    CGFloat _scale;
#if ENABLE_PRIVATE_QUEUE
    dispatch_queue_t _queue;
#endif
    iTermPreciseTimerStats _stats[iTermMetalFrameDataStatCount];
    int _dropped;
    int _total;

    // @synchronized(self)
    int _framesInFlight;
    NSMutableArray *_currentFrames;
    NSTimeInterval _startTime;
    MovingAverage *_fpsMovingAverage;
    NSTimeInterval _lastFrameTime;
    NSTimeInterval _lastFrameStartTime;
    iTermHistogram *_startToStartHistogram;
    iTermHistogram *_inFlightHistogram;
}

- (nullable instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView {
    self = [super init];
    if (self) {
        static int gNextIdentifier;
        _identifier = [NSString stringWithFormat:@"[driver %d]", gNextIdentifier++];
        _startToStartHistogram = [[iTermHistogram alloc] init];
        _inFlightHistogram = [[iTermHistogram alloc] init];
        _startTime = [NSDate timeIntervalSinceReferenceDate];
        _marginRenderer = [[iTermMarginRenderer alloc] initWithDevice:mtkView.device];
        _backgroundImageRenderer = [[iTermBackgroundImageRenderer alloc] initWithDevice:mtkView.device];
        _textRenderer = [[iTermTextRenderer alloc] initWithDevice:mtkView.device];
        _backgroundColorRenderer = [[iTermBackgroundColorRenderer alloc] initWithDevice:mtkView.device];
        _markRenderer = [[iTermMarkRenderer alloc] initWithDevice:mtkView.device];
        _badgeRenderer = [[iTermBadgeRenderer alloc] initWithDevice:mtkView.device];
        _flashRenderer = [[iTermFullScreenFlashRenderer alloc] initWithDevice:mtkView.device];
        _timestampsRenderer = [[iTermTimestampsRenderer alloc] initWithDevice:mtkView.device];
        _indicatorRenderer = [[iTermIndicatorRenderer alloc] initWithDevice:mtkView.device];
        _broadcastStripesRenderer = [[iTermBroadcastStripesRenderer alloc] initWithDevice:mtkView.device];
        _cursorGuideRenderer = [[iTermCursorGuideRenderer alloc] initWithDevice:mtkView.device];
        _highlightRowRenderer = [[iTermHighlightRowRenderer alloc] initWithDevice:mtkView.device];
        _imageRenderer = [[iTermImageRenderer alloc] initWithDevice:mtkView.device];
        _underlineCursorRenderer = [iTermCursorRenderer newUnderlineCursorRendererWithDevice:mtkView.device];
        _barCursorRenderer = [iTermCursorRenderer newBarCursorRendererWithDevice:mtkView.device];
        _imeCursorRenderer = [iTermCursorRenderer newIMECursorRendererWithDevice:mtkView.device];
        _blockCursorRenderer = [iTermCursorRenderer newBlockCursorRendererWithDevice:mtkView.device];
        _frameCursorRenderer = [iTermCursorRenderer newFrameCursorRendererWithDevice:mtkView.device];
        _copyModeCursorRenderer = [iTermCursorRenderer newCopyModeCursorRendererWithDevice:mtkView.device];
        _copyBackgroundRenderer = [[iTermCopyBackgroundRenderer alloc] initWithDevice:mtkView.device];

        _commandQueue = [mtkView.device newCommandQueue];
#if ENABLE_PRIVATE_QUEUE
        _queue = dispatch_queue_create("com.iterm2.metalDriver", NULL);
#endif
        _currentFrames = [NSMutableArray array];
        _fpsMovingAverage = [[MovingAverage alloc] init];
        _fpsMovingAverage.alpha = 0.75;
        iTermMetalFrameDataStatsBundleInitialize(_stats);
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:NSApplicationDidBecomeActiveNotification
                                                   object:nil];
    }

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
#if ENABLE_PRIVATE_QUEUE
    dispatch_async(_queue, ^{
        iTermMetalFrameDataStatsBundleInitialize(_stats);
    });
#else
    iTermMetalFrameDataStatsBundleInitialize(_stats);
#endif
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p identifier=%@>", NSStringFromClass([self class]), self, _identifier];
}

#pragma mark - APIs

- (void)setCellSize:(CGSize)cellSize
cellSizeWithoutSpacing:(CGSize)cellSizeWithoutSpacing
           gridSize:(VT100GridSize)gridSize
              scale:(CGFloat)scale {
    scale = MAX(1, scale);
    cellSize.width *= scale;
    cellSize.height *= scale;

    cellSizeWithoutSpacing.width *= scale;
    cellSizeWithoutSpacing.height *= scale;

    [self dispatchAsyncToPrivateQueue:^{
        if (scale == 0) {
            ELog(@"Warning: scale is 0");
        }
        DLog(@"Cell size is now %@x%@, grid size is now %@x%@", @(cellSize.width), @(cellSize.height), @(gridSize.width), @(gridSize.height));
        _sizeChanged = YES;
        _cellSize = cellSize;
        _cellSizeWithoutSpacing = cellSizeWithoutSpacing;
        _rows = MAX(1, gridSize.height);
        _columns = MAX(1, gridSize.width);
        _scale = scale;
    }];
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
    [self dispatchAsyncToPrivateQueue: ^{
        // Save the size of the drawable as we'll pass these
        //   values to our vertex shader when we draw
        _viewportSize.x = size.width;
        _viewportSize.y = size.height;
    }];
}

// Called whenever the view needs to render a frame
- (void)drawInMTKView:(nonnull MTKView *)view {
    const NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    const NSTimeInterval dt = now - _lastFrameStartTime;
    _lastFrameStartTime = now;

    [self reallyDrawInMTKView:view startToStartTime:dt];
    iTermPreciseTimerSaveLog([NSString stringWithFormat:@"%@: Dropped frames", _identifier],
                             [NSString stringWithFormat:@"%0.1f%%\n", 100.0 * ((double)_dropped / (double)_total)]);
    if (_total % 10 == 1) {
        iTermPreciseTimerSaveLog([NSString stringWithFormat:@"%@: Start-to-Start Time (ms)", _identifier],
                                 [_startToStartHistogram stringValue]);
        iTermPreciseTimerSaveLog([NSString stringWithFormat:@"%@: Frames In Flight at Start", _identifier],
                                 [_inFlightHistogram stringValue]);
    }
}

- (BOOL)connectedToPower {
    static CFTimeInterval timeRemaining;
    static NSTimeInterval lastUpdate;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    @synchronized(self) {
        if (now - lastUpdate > 5) {
            timeRemaining = IOPSGetTimeRemainingEstimate();
            lastUpdate = now;
            if (timeRemaining == kIOPSTimeRemainingUnlimited) {
                DLog(@"Connected to power");
            } else {
                DLog(@"On battery");
            }
        }
    }

    if (timeRemaining == kIOPSTimeRemainingUnlimited) {
        return YES;
    } else {
        return NO;
    }
}

- (int)maximumNumberOfFramesInFlight {
    if ([self connectedToPower]) {
        return iTermMetalDriverMaximumNumberOfFramesInFlight;
    } else {
        return 1;
    }
}

- (BOOL)reallyDrawInMTKView:(nonnull MTKView *)view startToStartTime:(NSTimeInterval)startToStartTime {
    @synchronized (self) {
        [_inFlightHistogram addValue:_framesInFlight];
    }
    if (_rows == 0 || _columns == 0) {
        DLog(@"  abort: uninitialized");
        [self scheduleDrawIfNeededInView:view];
        return NO;
    }

    _total++;
    if (_total % 60 == 0) {
        @synchronized (self) {
            ELog(@"fps=%f (%d in flight)", (_total - _dropped) / ([NSDate timeIntervalSinceReferenceDate] - _startTime), (int)_framesInFlight);
            ELog(@"%@", _currentFrames);
        }
    }

    if (view.bounds.size.width == 0 || view.bounds.size.height == 0) {
        ELog(@"  abort: 0x0 view");
        return NO;
    }

    iTermMetalFrameData *frameData = [self newFrameDataForView:view];
    if (VT100GridSizeEquals(frameData.gridSize, VT100GridSizeMake(0, 0))) {
        ELog(@"  abort: 0x0 grid");
        return NO;
    }

    BOOL shouldDrop;
    @synchronized(self) {
        shouldDrop = (_framesInFlight >= [self maximumNumberOfFramesInFlight]);
        if (!shouldDrop) {
            _framesInFlight++;
        }
    }
    if (shouldDrop) {
        ELog(@"  abort: busy (dropped %@%%, number in flight: %d)", @((_dropped * 100)/_total), (int)_framesInFlight);
        @synchronized(self) {
            ELog(@"  current frames:\n%@", _currentFrames);
        }

        _dropped++;
        self.needsDraw = YES;
        return NO;
    }

    if (_total > 1) {
        [_startToStartHistogram addValue:startToStartTime * 1000];
    }
#if ENABLE_PRIVATE_QUEUE
    [self acquireScarceResources:frameData view:view];
    if (frameData.drawable == nil || frameData.renderPassDescriptor == nil) {
        ELog(@"  abort: failed to get drawable or RPD");
        self.needsDraw = YES;
        return NO;
    }
#endif

    @synchronized(self) {
        [_currentFrames addObject:frameData];
    }

    void (^block)(void) = ^{
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (_lastFrameTime) {
            [_fpsMovingAverage addValue:now - _lastFrameTime];
        }
        _lastFrameTime = now;

        [self performPrivateQueueSetupForFrameData:frameData view:view];
    };
#if ENABLE_PRIVATE_QUEUE
    [frameData dispatchToPrivateQueue:_queue forPreparation:block];
#else
    block();
#endif

    return YES;
}

#pragma mark - Draw Helpers

// Called on the main queue
- (iTermMetalFrameData *)newFrameDataForView:(MTKView *)view {
    iTermMetalFrameData *frameData = [[iTermMetalFrameData alloc] initWithView:view];

    [frameData measureTimeForStat:iTermMetalFrameDataStatMtExtractFromApp ofBlock:^{
        frameData.viewportSize = _viewportSize;

        // This is the slow part
        frameData.perFrameState = [_dataSource metalDriverWillBeginDrawingFrame];

        frameData.rows = [NSMutableArray array];
        frameData.gridSize = frameData.perFrameState.gridSize;
        frameData.scale = _scale;
    }];
    return frameData;
}

#pragma mark - Private Queue Orchestration

// Runs in private queue
- (void)performPrivateQueueSetupForFrameData:(iTermMetalFrameData *)frameData
                                        view:(nonnull MTKView *)view {
    // Get glyph keys, attributes, background colors, etc. from datasource.
    [frameData measureTimeForStat:iTermMetalFrameDataStatPqBuildRowData ofBlock:^{
        [self addRowDataToFrameData:frameData];
    }];

    // If we're rendering to an intermediate texture because there's something complicated
    // behind text and we need to use the fancy subpixel antialiasing algorithm, create it now.
    // This has to be done before updates so the copyBackgroundRenderer's `enabled` flag can be
    // set properly.
    if ([self shouldCreateIntermediateRenderPassDescriptor:frameData]) {
        [frameData createIntermediateRenderPassDescriptor];
    }

    // Set properties of the renderers for values that tend not to change very often and which
    // are used to create transient states. This must happen before creating transient states
    // since renderers use this info to decide if they should return a nil transient state.
    [frameData measureTimeForStat:iTermMetalFrameDataStatPqUpdateRenderers ofBlock:^{
        [self updateRenderersForNewFrameData:frameData];
    }];

    // Create each renderer's transient state, which its per-frame object.
    __block id<MTLCommandBuffer> commandBuffer;
    [frameData measureTimeForStat:iTermMetalFrameDataStatPqCreateTransientStates ofBlock:^{
        commandBuffer = [_commandQueue commandBuffer];
        [self createTransientStatesWithFrameData:frameData view:view commandBuffer:commandBuffer];
    }];

    // Copy state from frame data to transient states
    [frameData measureTimeForStat:iTermMetalFrameDataStatPqPopulateTransientStates ofBlock:^{
        [self populateTransientStatesWithFrameData:frameData range:NSMakeRange(0, frameData.rows.count)];
    }];

#if !ENABLE_PRIVATE_QUEUE
    [self acquireScarceResources:frameData view:view];
    if (frameData.drawable == nil || frameData.renderPassDescriptor == nil) {
        ELog(@"  abort: failed to get drawable or RPD");
        self.needsDraw = YES;
        [self complete:frameData];
        return;
    }
#endif

    [frameData enqueueDrawCallsWithBlock:^{
        [self enequeueDrawCallsForFrameData:frameData
                              commandBuffer:commandBuffer];
    }];
}

- (void)addRowDataToFrameData:(iTermMetalFrameData *)frameData {
    for (int y = 0; y < frameData.gridSize.height; y++) {
        iTermMetalRowData *rowData = [[iTermMetalRowData alloc] init];
        [frameData.rows addObject:rowData];
        rowData.y = y;
        rowData.keysData = [iTermData dataOfLength:sizeof(iTermMetalGlyphKey) * _columns];
        rowData.attributesData = [iTermData dataOfLength:sizeof(iTermMetalGlyphAttributes) * _columns];
        rowData.backgroundColorRLEData = [iTermData dataOfLength:sizeof(iTermMetalBackgroundColorRLE) * _columns];
        iTermMetalGlyphKey *glyphKeys = (iTermMetalGlyphKey *)rowData.keysData.mutableBytes;
        int drawableGlyphs = 0;
        int rles = 0;
        iTermMarkStyle markStyle;
        NSDate *date;
        [frameData.perFrameState metalGetGlyphKeys:glyphKeys
                                        attributes:rowData.attributesData.mutableBytes
                                         imageRuns:rowData.imageRuns
                                        background:rowData.backgroundColorRLEData.mutableBytes
                                          rleCount:&rles
                                         markStyle:&markStyle
                                               row:y
                                             width:_columns
                                    drawableGlyphs:&drawableGlyphs
                                              date:&date];
        rowData.date = date;
        rowData.numberOfBackgroundRLEs = rles;
        rowData.numberOfDrawableGlyphs = drawableGlyphs;
        rowData.markStyle = markStyle;
    }
}

- (BOOL)shouldCreateIntermediateRenderPassDescriptor:(iTermMetalFrameData *)frameData {
    if (!_backgroundImageRenderer.rendererDisabled && [frameData.perFrameState metalBackgroundImageGetTiled:NULL]) {
        return YES;
    }
    if (!_badgeRenderer.rendererDisabled && [frameData.perFrameState badgeImage]) {
        return YES;
    }
    if (!_broadcastStripesRenderer.rendererDisabled && frameData.perFrameState.showBroadcastStripes) {
        return YES;
    }

    return NO;
}

- (void)updateRenderersForNewFrameData:(iTermMetalFrameData *)frameData {
    [self updateTextRendererForFrameData:frameData];
    [self updateBackgroundImageRendererForFrameData:frameData];
    [self updateCopyBackgroundRendererForFrameData:frameData];
    [self updateBadgeRendererForFrameData:frameData];
    [self updateBroadcastStripesRendererForFrameData:frameData];
    [self updateCursorGuideRendererForFrameData:frameData];
    [self updateIndicatorRendererForFrameData:frameData];
    [self updateTimestampsRendererForFrameData:frameData];
}

- (void)createTransientStatesWithFrameData:(iTermMetalFrameData *)frameData
                                      view:(nonnull MTKView *)view
                             commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    iTermRenderConfiguration *configuration = [[iTermRenderConfiguration alloc] initWithViewportSize:_viewportSize scale:frameData.scale];

    [commandBuffer enqueue];
    commandBuffer.label = @"Draw Terminal";
    for (id<iTermMetalRenderer> renderer in self.nonCellRenderers) {
        if (renderer.rendererDisabled) {
            continue;
        }
        [frameData measureTimeForStat:renderer.createTransientStateStat ofBlock:^{
            __kindof iTermMetalRendererTransientState * _Nonnull tState =
            [renderer createTransientStateForConfiguration:configuration
                                             commandBuffer:commandBuffer];
            if (tState) {
                [frameData setTransientState:tState forRenderer:renderer];
            }
        }];
    };
    const VT100GridSize gridSize = frameData.gridSize;
    iTermCellRenderConfiguration *cellConfiguration = [[iTermCellRenderConfiguration alloc] initWithViewportSize:_viewportSize
                                                                                                           scale:frameData.scale
                                                                                                        cellSize:_cellSize
                                                                                          cellSizeWithoutSpacing:_cellSizeWithoutSpacing
                                                                                                        gridSize:gridSize
                                                                                           usingIntermediatePass:(frameData.intermediateRenderPassDescriptor != nil)];
    for (id<iTermMetalCellRenderer> renderer in self.cellRenderers) {
        if (renderer.rendererDisabled) {
            continue;
        }
        [frameData measureTimeForStat:renderer.createTransientStateStat ofBlock:^{
            __kindof iTermMetalCellRendererTransientState * _Nonnull tState =
                [renderer createTransientStateForCellConfiguration:cellConfiguration
                                                     commandBuffer:commandBuffer];
            if (tState) {
                [frameData setTransientState:tState forRenderer:renderer];
            }
        }];
    };
}

// Called when all renderers have transient state
- (void)populateTransientStatesWithFrameData:(iTermMetalFrameData *)frameData
                                       range:(NSRange)range {
    [self populateMarginRendererTransientStateWithFrameData:frameData];
    [self populateCopyBackgroundRendererTransientStateWithFrameData:frameData];
    [self populateCursorRendererTransientStateWithFrameData:frameData];
    [self populateTextAndBackgroundRenderersTransientStateWithFrameData:frameData];
    [self populateBadgeRendererTransientStateWithFrameData:frameData];
    [self populateMarkRendererTransientStateWithFrameData:frameData];
    [self populateCursorGuideRendererTransientStateWithFrameData:frameData];
    [self populateHighlightRowRendererTransientStateWithFrameData:frameData];
    [self populateTimestampsRendererTransientStateWithFrameData:frameData];
    [self populateFlashRendererTransientStateWithFrameData:frameData];
    [self populateImageRendererTransientStateWithFrameData:frameData];
}

- (void)acquireScarceResources:(iTermMetalFrameData *)frameData view:(MTKView *)view {
    [frameData measureTimeForStat:iTermMetalFrameDataStatMtGetCurrentDrawable ofBlock:^{
        frameData.drawable = view.currentDrawable;
        frameData.drawable.texture.label = @"Drawable";
    }];

    [frameData measureTimeForStat:iTermMetalFrameDataStatMtGetRenderPassDescriptor ofBlock:^{
        frameData.renderPassDescriptor = view.currentRenderPassDescriptor;
    }];
}

- (void)enequeueDrawCallsForFrameData:(iTermMetalFrameData *)frameData
                        commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    DLog(@"  enequeueDrawCallsForFrameData");

    id<MTLRenderCommandEncoder> renderEncoder = [self newRenderEncoderFromCommandBuffer:commandBuffer
                                                                              frameData:frameData
                                                                                   pass:0];

    [self drawContentBehindTextWithFrameData:frameData renderEncoder:renderEncoder];

    // If we're using an intermediate render pass, copy from it to the view for final steps.
    if (frameData.intermediateRenderPassDescriptor) {
        renderEncoder = [self newRenderEncoderFromCommandBuffer:commandBuffer
                                                      frameData:frameData
                                                           pass:1];
        [self drawRenderer:_copyBackgroundRenderer
                 frameData:frameData
             renderEncoder:renderEncoder
                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueCopyBackground]];
    }

    [self drawCellRenderer:_textRenderer
                 frameData:frameData
             renderEncoder:renderEncoder
                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawText]];

    [self drawCellRenderer:_imageRenderer
                 frameData:frameData
             renderEncoder:renderEncoder
                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawImage]];

    [self drawCursorAfterTextWithFrameData:frameData
                             renderEncoder:renderEncoder];

    [self drawCellRenderer:_markRenderer
                 frameData:frameData
             renderEncoder:renderEncoder
                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawMarks]];

    [self drawCellRenderer:_cursorGuideRenderer
                 frameData:frameData
             renderEncoder:renderEncoder
                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawCursorGuide]];

    [self drawRenderer:_indicatorRenderer
             frameData:frameData
         renderEncoder:renderEncoder
                  stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawIndicators]];

    [self drawCellRenderer:_timestampsRenderer
                 frameData:frameData
             renderEncoder:renderEncoder
                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawTimestamps]];

    [self drawRenderer:_flashRenderer
             frameData:frameData
         renderEncoder:renderEncoder
                  stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawFullScreenFlash]];

    [self drawCellRenderer:_highlightRowRenderer
                 frameData:frameData
             renderEncoder:renderEncoder
                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawHighlightRow]];

    [self finishDrawingWithCommandBuffer:commandBuffer
                               frameData:frameData
                           renderEncoder:renderEncoder];
}

#pragma mark - Update Renderers

- (void)updateTextRendererForFrameData:(iTermMetalFrameData *)frameData {
    if (_textRenderer.rendererDisabled) {
        return;
    }
    __weak __typeof(self) weakSelf = self;
    CGSize cellSize = _cellSize;
    CGFloat scale = _scale;
    __weak iTermMetalFrameData *weakFrameData = frameData;
    [_textRenderer setASCIICellSize:_cellSize
                 creationIdentifier:[frameData.perFrameState metalASCIICreationIdentifier]
                           creation:^NSDictionary<NSNumber *, iTermCharacterBitmap *> * _Nonnull(char c, iTermASCIITextureAttributes attributes) {
                               __typeof(self) strongSelf = weakSelf;
                               iTermMetalFrameData *strongFrameData = weakFrameData;
                               if (strongSelf && strongFrameData) {
                                   static const int typefaceMask = ((1 << iTermMetalGlyphKeyTypefaceNumberOfBitsNeeded) - 1);
                                   iTermMetalGlyphKey glyphKey = {
                                       .code = c,
                                       .isComplex = NO,
                                       .boxDrawing = NO,
                                       .thinStrokes = !!(attributes & iTermASCIITextureAttributesThinStrokes),
                                       .drawable = YES,
                                       .typeface = (attributes & typefaceMask),
                                   };
                                   BOOL emoji = NO;
                                   return [strongFrameData.perFrameState metalImagesForGlyphKey:&glyphKey
                                                                                           size:cellSize
                                                                                          scale:scale
                                                                                          emoji:&emoji];
                               } else {
                                   return nil;
                               }
                           }];
}

- (void)updateBackgroundImageRendererForFrameData:(iTermMetalFrameData *)frameData {
    if (_backgroundImageRenderer.rendererDisabled) {
        return;
    }
    BOOL tiled;
    NSImage *backgroundImage = [frameData.perFrameState metalBackgroundImageGetTiled:&tiled];
    [_backgroundImageRenderer setImage:backgroundImage tiled:tiled context:frameData.framePoolContext];
}

- (void)updateCopyBackgroundRendererForFrameData:(iTermMetalFrameData *)frameData {
    if (_copyBackgroundRenderer.rendererDisabled) {
        return;
    }
    _copyBackgroundRenderer.enabled = (frameData.intermediateRenderPassDescriptor != nil);
}

- (void)updateBadgeRendererForFrameData:(iTermMetalFrameData *)frameData {
    if (_badgeRenderer.rendererDisabled) {
        return;
    }
    [_badgeRenderer setBadgeImage:frameData.perFrameState.badgeImage context:frameData.framePoolContext];
}

- (void)updateIndicatorRendererForFrameData:(iTermMetalFrameData *)frameData {
    if (_indicatorRenderer.rendererDisabled) {
        return;
    }
    const CGFloat scale = frameData.scale;
    NSRect frame = NSMakeRect(0,
                              0,
                              frameData.viewportSize.x / scale,
                              frameData.viewportSize.y / scale);
    [_indicatorRenderer reset];
    [frameData.perFrameState enumerateIndicatorsInFrame:frame block:^(iTermIndicatorDescriptor * _Nonnull indicator) {
        [_indicatorRenderer addIndicator:indicator context:frameData.framePoolContext];
    }];
}

- (void)updateBroadcastStripesRendererForFrameData:(iTermMetalFrameData *)frameData {
    if (_broadcastStripesRenderer.rendererDisabled) {
        return;
    }
    _broadcastStripesRenderer.enabled = frameData.perFrameState.showBroadcastStripes;
}

- (void)updateCursorGuideRendererForFrameData:(iTermMetalFrameData *)frameData {
    if (_cursorGuideRenderer.rendererDisabled) {
        return;
    }
    [_cursorGuideRenderer setColor:frameData.perFrameState.cursorGuideColor];
    _cursorGuideRenderer.enabled = frameData.perFrameState.cursorGuideEnabled;
}

- (void)updateTimestampsRendererForFrameData:(iTermMetalFrameData *)frameData {
    if (_timestampsRenderer.rendererDisabled) {
        return;
    }
    _timestampsRenderer.enabled = frameData.perFrameState.timestampsEnabled;
}

#pragma mark - Populate Transient States

- (void)populateCopyBackgroundRendererTransientStateWithFrameData:(iTermMetalFrameData *)frameData {
    if (_copyBackgroundRenderer.rendererDisabled) {
        return;
    }
    // Copy state
    iTermCopyBackgroundRendererTransientState *copyState = [frameData transientStateForRenderer:_copyBackgroundRenderer];
    copyState.sourceTexture = frameData.intermediateRenderPassDescriptor.colorAttachments[0].texture;
}

- (void)populateCursorRendererTransientStateWithFrameData:(iTermMetalFrameData *)frameData {
    if (_underlineCursorRenderer.rendererDisabled &&
        _barCursorRenderer.rendererDisabled &&
        _blockCursorRenderer.rendererDisabled &&
        _imeCursorRenderer.rendererDisabled) {
        return;
    }

    // Update glyph attributes for block cursor if needed.
    iTermMetalCursorInfo *cursorInfo = [frameData.perFrameState metalDriverCursorInfo];
    if (!cursorInfo.frameOnly &&
        cursorInfo.cursorVisible &&
        cursorInfo.shouldDrawText &&
        cursorInfo.coord.y >= 0 &&
        cursorInfo.coord.y < frameData.gridSize.height) {
        iTermMetalRowData *rowWithCursor = frameData.rows[cursorInfo.coord.y];
        iTermMetalGlyphAttributes *glyphAttributes = (iTermMetalGlyphAttributes *)rowWithCursor.attributesData.mutableBytes;
        glyphAttributes[cursorInfo.coord.x].foregroundColor = cursorInfo.textColor;
        glyphAttributes[cursorInfo.coord.x].backgroundColor = simd_make_float4(cursorInfo.cursorColor.redComponent,
                                                                               cursorInfo.cursorColor.greenComponent,
                                                                               cursorInfo.cursorColor.blueComponent,
                                                                               1);
    }

    if (cursorInfo.copyMode) {
        iTermCopyModeCursorRendererTransientState *tState = [frameData transientStateForRenderer:_copyModeCursorRenderer];
        tState.selecting = cursorInfo.copyModeCursorSelecting;
        tState.coord = cursorInfo.copyModeCursorCoord;
    } else if (cursorInfo.cursorVisible) {
        switch (cursorInfo.type) {
            case CURSOR_UNDERLINE: {
                iTermCursorRendererTransientState *tState = [frameData transientStateForRenderer:_underlineCursorRenderer];
                tState.coord = cursorInfo.coord;
                tState.color = cursorInfo.cursorColor;
                break;
            }
            case CURSOR_BOX: {
                iTermCursorRendererTransientState *tState = [frameData transientStateForRenderer:_blockCursorRenderer];
                tState.coord = cursorInfo.coord;
                tState.color = cursorInfo.cursorColor;

                tState = [frameData transientStateForRenderer:_frameCursorRenderer];
                tState.coord = cursorInfo.coord;
                tState.color = cursorInfo.cursorColor;
                break;
            }
            case CURSOR_VERTICAL: {
                iTermCursorRendererTransientState *tState = [frameData transientStateForRenderer:_barCursorRenderer];
                tState.coord = cursorInfo.coord;
                tState.color = cursorInfo.cursorColor;
                break;
            }
            case CURSOR_DEFAULT:
                break;
        }
    }

    iTermMetalIMEInfo *imeInfo = frameData.perFrameState.imeInfo;
    if (imeInfo) {
        iTermCursorRendererTransientState *tState = [frameData transientStateForRenderer:_imeCursorRenderer];
        tState.coord = imeInfo.cursorCoord;
        tState.color = [NSColor colorWithSRGBRed:iTermIMEColor.x
                                           green:iTermIMEColor.y
                                            blue:iTermIMEColor.z
                                           alpha:iTermIMEColor.w];
    }
}

- (void)populateBadgeRendererTransientStateWithFrameData:(iTermMetalFrameData *)frameData {
    if (_badgeRenderer.rendererDisabled) {
        return;
    }
    iTermBadgeRendererTransientState *tState = [frameData transientStateForRenderer:_badgeRenderer];
    tState.sourceRect = frameData.perFrameState.badgeSourceRect;
    tState.destinationRect = frameData.perFrameState.badgeDestinationRect;
}

- (void)populateTextAndBackgroundRenderersTransientStateWithFrameData:(iTermMetalFrameData *)frameData {
    if (_textRenderer.rendererDisabled && _backgroundColorRenderer.rendererDisabled) {
        return;
    }

    // Update the text renderer's transient state with current glyphs and colors.
    CGFloat scale = frameData.scale;
    iTermTextRendererTransientState *textState = [frameData transientStateForRenderer:_textRenderer];

    // Set the background texture if one is available.
    textState.backgroundTexture = frameData.intermediateRenderPassDescriptor.colorAttachments[0].texture;

    // Configure underlines
    iTermMetalUnderlineDescriptor asciiUnderlineDescriptor;
    iTermMetalUnderlineDescriptor nonAsciiUnderlineDescriptor;
    [frameData.perFrameState metalGetUnderlineDescriptorsForASCII:&asciiUnderlineDescriptor
                                                         nonASCII:&nonAsciiUnderlineDescriptor];
    textState.asciiUnderlineDescriptor = asciiUnderlineDescriptor;
    textState.nonAsciiUnderlineDescriptor = nonAsciiUnderlineDescriptor;
    textState.defaultBackgroundColor = frameData.perFrameState.defaultBackgroundColor;
    
    CGSize cellSize = textState.cellConfiguration.cellSize;
    iTermBackgroundColorRendererTransientState *backgroundState = [frameData transientStateForRenderer:_backgroundColorRenderer];

    iTermMetalIMEInfo *imeInfo = frameData.perFrameState.imeInfo;

    [frameData.rows enumerateObjectsUsingBlock:^(iTermMetalRowData * _Nonnull rowData, NSUInteger idx, BOOL * _Nonnull stop) {
        NSRange markedRangeOnLine = NSMakeRange(NSNotFound, 0);
        if (imeInfo &&
            rowData.y >= imeInfo.markedRange.start.y &&
            rowData.y <= imeInfo.markedRange.end.y) {
            // This line contains at least part of the marked range
            if (rowData.y == imeInfo.markedRange.start.y) {
                // Makred range starts on this line
                if (rowData.y == imeInfo.markedRange.end.y) {
                    // Marked range starts and ends on this line.
                    markedRangeOnLine = NSMakeRange(imeInfo.markedRange.start.x,
                                                    imeInfo.markedRange.end.x - imeInfo.markedRange.start.x);
                } else {
                    // Marked line begins on this line and ends later
                    markedRangeOnLine = NSMakeRange(imeInfo.markedRange.start.x,
                                                    frameData.gridSize.width - imeInfo.markedRange.start.x);
                }
            } else {
                // Marked range started on a prior line
                if (rowData.y == imeInfo.markedRange.end.y) {
                    // Marked range ends on this line
                    markedRangeOnLine = NSMakeRange(0, imeInfo.markedRange.end.x);
                } else {
                    // Marked range ends on a later line
                    markedRangeOnLine = NSMakeRange(0, frameData.gridSize.width);
                }
            }
        }

        iTermMetalGlyphKey *glyphKeys = (iTermMetalGlyphKey *)rowData.keysData.mutableBytes;
        if (idx == 0 && [iTermAdvancedSettingsModel showMetalFPSmeter]) {
            [self writeFPSMeterIntoGlyphKeys:glyphKeys
                                       count:rowData.numberOfDrawableGlyphs
                                  attributes:(iTermMetalGlyphAttributes *)rowData.attributesData.mutableBytes
                                       width:frameData.gridSize.width
                                 frameNumber:frameData.frameNumber];
            rowData.numberOfDrawableGlyphs = frameData.gridSize.width;
        }

        if (!_textRenderer.rendererDisabled) {
            [textState setGlyphKeysData:rowData.keysData
                                  count:rowData.numberOfDrawableGlyphs
                         attributesData:rowData.attributesData
                                    row:rowData.y
                 backgroundColorRLEData:rowData.backgroundColorRLEData
                      markedRangeOnLine:markedRangeOnLine
                                context:textState.poolContext
                               creation:^NSDictionary<NSNumber *, iTermCharacterBitmap *> * _Nonnull(int x, BOOL *emoji) {
                                   return [frameData.perFrameState metalImagesForGlyphKey:&glyphKeys[x]
                                                                                     size:cellSize
                                                                                    scale:scale
                                                                                    emoji:emoji];
                               }];
        }
    }];
    if (!_backgroundColorRenderer.rendererDisabled) {
        BOOL (^comparator)(iTermMetalRowData *obj1, iTermMetalRowData *obj2) = ^BOOL(iTermMetalRowData *obj1, iTermMetalRowData *obj2) {
            const NSUInteger count = obj1.numberOfBackgroundRLEs;
            if (count != obj2.numberOfBackgroundRLEs) {
                return NO;
            }
            const iTermMetalBackgroundColorRLE *array1 = (const iTermMetalBackgroundColorRLE *)obj1.backgroundColorRLEData.mutableBytes;
            const iTermMetalBackgroundColorRLE *array2 = (const iTermMetalBackgroundColorRLE *)obj2.backgroundColorRLEData.mutableBytes;
            for (int i = 0; i < count; i++) {
                if (array1[i].color.x != array2[i].color.x ||
                    array1[i].color.y != array2[i].color.y ||
                    array1[i].color.z != array2[i].color.z ||
                    array1[i].count != array2[i].count) {
                    return NO;
                }
            }
            return YES;
        };
        [frameData.rows enumerateCoalescedObjectsWithComparator:comparator block:^(iTermMetalRowData *rowData, NSUInteger count) {
            [backgroundState setColorRLEs:(const iTermMetalBackgroundColorRLE *)rowData.backgroundColorRLEData.mutableBytes
                                    count:rowData.numberOfBackgroundRLEs
                                      row:rowData.y
                            repeatingRows:count];
        }];
    }
    
    // Tell the text state that it's done getting row data.
    if (!_textRenderer.rendererDisabled) {
        [textState willDraw];
    }
}

- (void)writeFPSMeterIntoGlyphKeys:(iTermMetalGlyphKey *)glyphKeys
                             count:(int)count
                        attributes:(iTermMetalGlyphAttributes *)attributes
                             width:(int)width
                       frameNumber:(NSInteger)frameNumber {
    const size_t fpsMeterSize = MAX(0, MIN(80, width));
    if (fpsMeterSize > 1) {
        const double period = [_fpsMovingAverage value];
        double fps = 1.0 / period;
        if (period < 0.001) {
            fps = 0;
        }
        char frame[fpsMeterSize];
        snprintf(frame,
                 fpsMeterSize - 1,
                 " [Frame %d: %d fps] ",
                 (int)frameNumber,
                 (int)round(fps));
        int o = MAX(0, width - strlen(frame));
        for (int i = count; i < o; i++) {
            glyphKeys[o].drawable = NO;
        }
        for (int i = 0; frame[i]; i++, o++) {
            glyphKeys[o].code = frame[i];
            glyphKeys[o].isComplex = NO;
            glyphKeys[o].boxDrawing = NO;
            glyphKeys[o].thinStrokes = NO;
            glyphKeys[o].drawable = YES;
            glyphKeys[o].typeface = iTermMetalGlyphKeyTypefaceRegular;

            attributes[o].backgroundColor = simd_make_float4(0.0, 0.0, 0.0, 1.0);
            attributes[o].foregroundColor = simd_make_float4(1.0, 0.0, 1.0, 1.0);
            attributes[o].underlineStyle = iTermMetalGlyphAttributesUnderlineNone;
            attributes[o].annotation = NO;
        }
    }
}

- (void)populateMarkRendererTransientStateWithFrameData:(iTermMetalFrameData *)frameData {
    iTermMarkRendererTransientState *tState = [frameData transientStateForRenderer:_markRenderer];
    [frameData.rows enumerateObjectsUsingBlock:^(iTermMetalRowData * _Nonnull rowData, NSUInteger idx, BOOL * _Nonnull stop) {
        [tState setMarkStyle:rowData.markStyle row:idx];
    }];
}

- (void)populateHighlightRowRendererTransientStateWithFrameData:(iTermMetalFrameData *)frameData {
    iTermHighlightRowRendererTransientState *tState = [frameData transientStateForRenderer:_highlightRowRenderer];
    [frameData.perFrameState metalEnumerateHighlightedRows:^(vector_float3 color, NSTimeInterval age, int row) {
        const CGFloat opacity = MAX(0, 0.75 - age);
        [tState setOpacity:opacity color:color row:row];
    }];
}

- (void)populateCursorGuideRendererTransientStateWithFrameData:(iTermMetalFrameData *)frameData {
    iTermCursorGuideRendererTransientState *tState = [frameData transientStateForRenderer:_cursorGuideRenderer];
    iTermMetalCursorInfo *cursorInfo = frameData.perFrameState.metalDriverCursorInfo;
    if (cursorInfo.coord.y >= 0 &&
        cursorInfo.coord.y < frameData.gridSize.height) {
        [tState setRow:frameData.perFrameState.metalDriverCursorInfo.coord.y];
    } else {
        [tState setRow:-1];
    }
}

- (void)populateTimestampsRendererTransientStateWithFrameData:(iTermMetalFrameData *)frameData {
    iTermTimestampsRendererTransientState *tState = [frameData transientStateForRenderer:_timestampsRenderer];
    if (frameData.perFrameState.timestampsEnabled) {
        tState.backgroundColor = frameData.perFrameState.timestampsBackgroundColor;
        tState.textColor = frameData.perFrameState.timestampsTextColor;

        tState.timestamps = [frameData.rows mapWithBlock:^id(iTermMetalRowData *row) {
            return row.date;
        }];
    }
}

- (void)populateFlashRendererTransientStateWithFrameData:(iTermMetalFrameData *)frameData {
    iTermFullScreenFlashRendererTransientState *tState = [frameData transientStateForRenderer:_flashRenderer];
    tState.color = frameData.perFrameState.fullScreenFlashColor;
}

- (void)populateMarginRendererTransientStateWithFrameData:(iTermMetalFrameData *)frameData {
    iTermMarginRendererTransientState *tState = [frameData transientStateForRenderer:_marginRenderer];
    [tState setColor:frameData.perFrameState.defaultBackgroundColor];
}

- (void)populateImageRendererTransientStateWithFrameData:(iTermMetalFrameData *)frameData {
    iTermImageRendererTransientState *tState = [frameData transientStateForRenderer:_imageRenderer];
    tState.firstVisibleAbsoluteLineNumber = frameData.perFrameState.firstVisibleAbsoluteLineNumber;
    [frameData.rows enumerateObjectsUsingBlock:^(iTermMetalRowData * _Nonnull row, NSUInteger idx, BOOL * _Nonnull stop) {
        [row.imageRuns enumerateObjectsUsingBlock:^(iTermMetalImageRun * _Nonnull imageRun, NSUInteger idx, BOOL * _Nonnull stop) {
            [tState addRun:imageRun];
        }];
    }];
}

#pragma mark - Draw

- (void)drawRenderer:(id<iTermMetalRenderer>)renderer
           frameData:(iTermMetalFrameData *)frameData
       renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
                stat:(iTermPreciseTimerStats *)stat {
    if (renderer.rendererDisabled) {
        return;
    }
    iTermPreciseTimerStatsStartTimer(stat);

    iTermMetalRendererTransientState *state = [frameData transientStateForRenderer:renderer];
    // NOTE: State may be nil if we determined it should be skipped early on.
    if (state != nil && !state.skipRenderer) {
        [renderer drawWithRenderEncoder:renderEncoder transientState:state];
    }

    iTermPreciseTimerStatsMeasureAndRecordTimer(stat);
}

- (void)drawCellRenderer:(id<iTermMetalCellRenderer>)renderer
               frameData:(iTermMetalFrameData *)frameData
           renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
                    stat:(iTermPreciseTimerStats *)stat {
    if (renderer.rendererDisabled) {
        return;
    }
    iTermPreciseTimerStatsStartTimer(stat);

    iTermMetalCellRendererTransientState *state = [frameData transientStateForRenderer:renderer];
    if (state != nil && !state.skipRenderer) {
        [renderer drawWithRenderEncoder:renderEncoder transientState:state];
    }

    iTermPreciseTimerStatsMeasureAndRecordTimer(stat);
}

- (void)drawCursorBeforeTextWithFrameData:(iTermMetalFrameData *)frameData
                            renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder {
    iTermMetalCursorInfo *cursorInfo = [frameData.perFrameState metalDriverCursorInfo];

    if (!cursorInfo.copyMode && cursorInfo.cursorVisible) {
        switch (cursorInfo.type) {
            case CURSOR_UNDERLINE:
                if (frameData.intermediateRenderPassDescriptor) {
                    [self drawCellRenderer:_underlineCursorRenderer
                                 frameData:frameData
                             renderEncoder:renderEncoder
                                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawCursor]];
                }
                break;
            case CURSOR_BOX:
                if (!cursorInfo.frameOnly) {
                    [self drawCellRenderer:_blockCursorRenderer
                                 frameData:frameData
                             renderEncoder:renderEncoder
                                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawCursor]];
                }
                break;
            case CURSOR_VERTICAL:
                if (frameData.intermediateRenderPassDescriptor) {
                    [self drawCellRenderer:_barCursorRenderer
                                 frameData:frameData
                             renderEncoder:renderEncoder
                                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawCursor]];
                }
                break;
            case CURSOR_DEFAULT:
                break;
        }
    }
}

- (void)drawCursorAfterTextWithFrameData:(iTermMetalFrameData *)frameData
                           renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder {
    iTermMetalCursorInfo *cursorInfo = [frameData.perFrameState metalDriverCursorInfo];

    if (cursorInfo.copyMode) {
        [self drawCellRenderer:_copyModeCursorRenderer
                     frameData:frameData
                 renderEncoder:renderEncoder
                          stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawCursor]];
    } else if (cursorInfo.cursorVisible) {
        switch (cursorInfo.type) {
            case CURSOR_UNDERLINE:
                if (!frameData.intermediateRenderPassDescriptor) {
                    [self drawCellRenderer:_underlineCursorRenderer
                                 frameData:frameData
                             renderEncoder:renderEncoder
                                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawCursor]];
                }
                break;
            case CURSOR_BOX:
                if (cursorInfo.frameOnly) {
                    [self drawCellRenderer:_frameCursorRenderer
                                 frameData:frameData
                             renderEncoder:renderEncoder
                                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawCursor]];
                }
                break;
            case CURSOR_VERTICAL:
                if (!frameData.intermediateRenderPassDescriptor) {
                    [self drawCellRenderer:_barCursorRenderer
                                 frameData:frameData
                             renderEncoder:renderEncoder
                                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawCursor]];
                }
                break;
            case CURSOR_DEFAULT:
                break;
        }
    }
    if (frameData.perFrameState.imeInfo) {
        [self drawCellRenderer:_imeCursorRenderer
                     frameData:frameData
                 renderEncoder:renderEncoder
                          stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawCursor]];
    }
}

- (void)drawContentBehindTextWithFrameData:(iTermMetalFrameData *)frameData renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder {
    [self drawCellRenderer:_marginRenderer
                 frameData:frameData
             renderEncoder:renderEncoder
                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawMargin]];

    [self drawRenderer:_backgroundImageRenderer
             frameData:frameData
         renderEncoder:renderEncoder
                  stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawBackgroundImage]];

    [self drawCellRenderer:_backgroundColorRenderer
                 frameData:frameData
             renderEncoder:renderEncoder
                      stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueDrawBackgroundColor]];

    [self drawRenderer:_broadcastStripesRenderer
             frameData:frameData
         renderEncoder:renderEncoder
                  stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueBroadcastStripes]];

    [self drawRenderer:_badgeRenderer
             frameData:frameData
         renderEncoder:renderEncoder
                  stat:&frameData.stats[iTermMetalFrameDataStatPqEnqueueBadge]];

    [self drawCursorBeforeTextWithFrameData:frameData
                              renderEncoder:renderEncoder];

    if (frameData.intermediateRenderPassDescriptor) {
        [frameData measureTimeForStat:iTermMetalFrameDataStatPqEnqueueDrawEndEncodingToIntermediateTexture ofBlock:^{
            [renderEncoder endEncoding];
        }];
    }
}

- (void)finishDrawingWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                             frameData:(iTermMetalFrameData *)frameData
                         renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder {
    [frameData measureTimeForStat:iTermMetalFrameDataStatPqEnqueueDrawEndEncodingToDrawable ofBlock:^{
        [renderEncoder endEncoding];
    }];
    [frameData measureTimeForStat:iTermMetalFrameDataStatPqEnqueueDrawPresentAndCommit ofBlock:^{
#if !ENABLE_SYNCHRONOUS_PRESENTATION
        [commandBuffer presentDrawable:frameData.drawable];
#endif
        __block BOOL completed = NO;

        iTermPreciseTimerStatsStartTimer(&frameData.stats[iTermMetalFrameDataStatGpuScheduleWait]);
        [commandBuffer addScheduledHandler:^(id<MTLCommandBuffer> _Nonnull commandBuffer) {
            iTermPreciseTimerStatsMeasureAndRecordTimer(&frameData.stats[iTermMetalFrameDataStatGpuScheduleWait]);
        }];

        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull buffer) {
            void (^block)(void) = ^{
                if (!completed) {
                    completed = YES;
                    [self complete:frameData];
                    [self scheduleDrawIfNeededInView:frameData.view];

                    __weak __typeof(self) weakSelf = self;
                    [weakSelf dispatchAsyncToMainQueue:^{
                        if (!_imageRenderer.rendererDisabled) {
                            iTermImageRendererTransientState *tState = [frameData transientStateForRenderer:_imageRenderer];
                            [weakSelf.dataSource metalDidFindImages:tState.missingImageUniqueIdentifiers
                                                      missingImages:tState.foundImageUniqueIdentifiers
                                                      animatedLines:tState.animatedLines];
                        }
                        [weakSelf.dataSource metalDriverDidDrawFrame:frameData.perFrameState];
                    }];
                }
            };
#if ENABLE_PRIVATE_QUEUE
            [frameData dispatchToQueue:_queue forCompletion:block];
#else
            [frameData dispatchToQueue:dispatch_get_main_queue() forCompletion:block];
#endif
        }];

        [commandBuffer commit];
#if ENABLE_SYNCHRONOUS_PRESENTATION
        dispatch_async(dispatch_get_main_queue(), ^{
            [commandBuffer waitUntilScheduled];
            [frameData.drawable present];
        });
#endif
    }];
}

#pragma mark - Drawing Helpers

- (id<MTLRenderCommandEncoder>)newRenderEncoderFromCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                            renderPassDescriptor:(MTLRenderPassDescriptor *)renderPassDescriptor
                                                           label:(NSString *)label
                                                       frameData:(iTermMetalFrameData *)frameData
                                                            stat:(iTermMetalFrameDataStat)stat {
    __block id<MTLRenderCommandEncoder> renderEncoder;
    [frameData measureTimeForStat:stat ofBlock:^{
        renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        renderEncoder.label = label;

        // Set the region of the drawable to which we'll draw.
        MTLViewport viewport = {
            -(double)frameData.viewportSize.x,
            0.0,
            frameData.viewportSize.x * 2,
            frameData.viewportSize.y * 2,
            -1.0,
            1.0
        };
        [renderEncoder setViewport:viewport];
    }];

    return renderEncoder;
}

- (id<MTLRenderCommandEncoder>)newRenderEncoderFromCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                                       frameData:(iTermMetalFrameData *)frameData
                                                            pass:(int)pass {
    assert(pass >= 0 && pass <= 1);

    NSArray<MTLRenderPassDescriptor *> *descriptors =
        @[ frameData.intermediateRenderPassDescriptor ?: frameData.renderPassDescriptor,
           frameData.renderPassDescriptor ];
    NSArray<NSString *> *labels =
        @[ frameData.intermediateRenderPassDescriptor ? @"Render background to intermediate" : @"Render All Layers of Terminal",
           @"Copy bg and render text" ];
    iTermMetalFrameDataStat stats[2] = {
        iTermMetalFrameDataStatPqEnqueueDrawCreateFirstRenderEncoder,
        iTermMetalFrameDataStatPqEnqueueDrawCreateSecondRenderEncoder
    };

    id<MTLRenderCommandEncoder> renderEncoder = [self newRenderEncoderFromCommandBuffer:commandBuffer
                                                                   renderPassDescriptor:descriptors[pass]
                                                                                  label:labels[pass]
                                                                              frameData:frameData
                                                                                   stat:stats[pass]];
    return renderEncoder;
}

- (void)complete:(iTermMetalFrameData *)frameData {
    DLog(@"  Completed");

    if (!_textRenderer.rendererDisabled) {
        // Unlock indices and free up the stage texture.
        iTermTextRendererTransientState *textState = [frameData transientStateForRenderer:_textRenderer];
        [textState didComplete];
    }

    DLog(@"  Recording final stats");
    [frameData didCompleteWithAggregateStats:_stats owner:_identifier];

    @synchronized(self) {
        _framesInFlight--;
        @synchronized(self) {
            frameData.status = @"retired";
            [_currentFrames removeObject:frameData];
        }
    }
    [self dispatchAsyncToPrivateQueue:^{
        [self scheduleDrawIfNeededInView:frameData.view];
    }];
}

#pragma mark - Miscellaneous Utility Methods

- (NSArray<id<iTermMetalCellRenderer>> *)cellRenderers {
    return @[ _marginRenderer,
              _textRenderer,
              _backgroundColorRenderer,
              _markRenderer,
              _cursorGuideRenderer,
              _highlightRowRenderer,
              _imageRenderer,
              _underlineCursorRenderer,
              _barCursorRenderer,
              _imeCursorRenderer,
              _blockCursorRenderer,
              _frameCursorRenderer,
              _copyModeCursorRenderer,
              _timestampsRenderer ];
}

- (NSArray<id<iTermMetalRenderer>> *)nonCellRenderers {
    return @[ _backgroundImageRenderer,
              _badgeRenderer,
              _broadcastStripesRenderer,
              _copyBackgroundRenderer,
              _indicatorRenderer,
              _flashRenderer ];
}

- (void)scheduleDrawIfNeededInView:(MTKView *)view {
    if (self.needsDraw) {
        void (^block)(void) = ^{
            if (self.needsDraw) {
                self.needsDraw = NO;
                [view setNeedsDisplay:YES];
            }
        };
#if ENABLE_PRIVATE_QUEUE
        dispatch_async(dispatch_get_main_queue(), block);
#else
        block();
#endif
    }
}

- (void)dispatchAsyncToPrivateQueue:(void (^)(void))block {
#if ENABLE_PRIVATE_QUEUE
    dispatch_async(_queue, block);
#else
    block();
#endif
}

- (void)dispatchAsyncToMainQueue:(void (^)(void))block {
#if ENABLE_PRIVATE_QUEUE
    dispatch_async(dispatch_get_main_queue(), block);
#else
    block();
#endif
}

@end


