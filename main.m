// Thermal Camera Viewer for macOS
// Build: make
// Usage: ./thermal

#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#define W 256
#define H 192
#define SCALE 3
#define BAR_W 20
#define BAR_GAP 10
#define BAR_MARGIN 50


typedef struct {
  int x;
  int y;
  float val;
} point_t;

// Global state
static uint16_t g_frame[W * H];
static uint8_t g_rgb[W * H * 4];
static point_t g_min, g_max, g_center;
static float g_render_min, g_render_max;
static volatile int g_ready = 0;
static volatile int g_connected = 0;
static volatile int g_frozen = 0;
static int g_flipV = 0;

static int g_fixed_scale = 0;

#define MAX_PTS 16
static point_t g_pts[MAX_PTS];
static int g_pts_n = 0;

static void palette(float t, uint8_t *r, uint8_t *g, uint8_t *b) {
  if (t < 0)
    t = 0;
  else if (t > 1)
    t = 1;
  if (t < 0.2f) {
    *r = 0;
    *g = 0;
    *b = (uint8_t)(t / 0.2f * 128);
  } else if (t < 0.4f) {
    float s = (t - 0.2f) / 0.2f;
    *r = (uint8_t)(s * 128);
    *g = 0;
    *b = 128;
  } else if (t < 0.6f) {
    float s = (t - 0.4f) / 0.2f;
    *r = 128 + (uint8_t)(s * 127);
    *g = 0;
    *b = (uint8_t)(128 * (1 - s));
  } else if (t < 0.8f) {
    float s = (t - 0.6f) / 0.2f;
    *r = 255;
    *g = (uint8_t)(s * 200);
    *b = 0;
  } else {
    float s = (t - 0.8f) / 0.2f;
    *r = 255;
    *g = 200 + (uint8_t)(s * 55);
    *b = (uint8_t)(s * 255);
  }
}

static inline float raw_to_temp(uint16_t raw) {
  return (raw / 64.0f) - 273.15f;
}

static void process(const uint8_t *frame, size_t stride, size_t rows) {
  size_t th_row_start = (rows >= 386) ? 194 : 0;
  const uint8_t *thdata = frame + th_row_start * stride;
  g_min = (point_t){.val = 1000.0f};
  g_max = (point_t){.val = -1000.0f};

  for (int y = 0; y < H; y++) {
    const uint8_t *row = thdata + y * stride;
    for (int x = 0; x < W; x++) {
      uint16_t raw = row[x * 2] | (row[x * 2 + 1] << 8);
      g_frame[y * W + x] = raw;
      
      float t = raw_to_temp(raw);
      if (t < g_min.val) {
          g_min = (point_t){.x = x, .y = y, .val = t};
      }
      if (t > g_max.val) {
          g_max = (point_t){.x = x, .y = y, .val = t};
      }
    }
  }

  g_center = (point_t){
      .x = W / 2,
      .y = H / 2,
      .val = raw_to_temp(g_frame[(H / 2) * W + (W / 2)])};

  for (int i = 0; i < g_pts_n; i++) {
    g_pts[i].val = raw_to_temp(g_frame[g_pts[i].y * W + g_pts[i].x]);
  }

  if (!g_fixed_scale) {
    g_render_min = g_min.val;
    g_render_max = g_max.val;
  }
  for (int i = 0; i < W * H; i++) {
    float t = (raw_to_temp(g_frame[i]) - g_render_min) / (g_render_max - g_render_min);
    palette(t, &g_rgb[i * 4], &g_rgb[i * 4 + 1], &g_rgb[i * 4 + 2]);
    g_rgb[i * 4 + 3] = 255;
  }
  g_ready = 1;
}

@interface View : NSView <NSToolbarDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, NSApplicationDelegate, NSWindowDelegate>
@property(strong) AVCaptureSession *session;
- (void)connect;
- (void)disconnect;
- (void)reconnect;
- (void)saveAction:(id)sender;
- (void)freezeAction:(id)sender;
- (void)flipAction:(id)sender;
- (void)reconnectAction:(id)sender;
- (void)clearAction:(id)sender;
- (void)toggleScaleAction:(id)sender;
@end
@implementation View
- (instancetype)initWithFrame:(NSRect)frameRect {
  if (self = [super initWithFrame:frameRect]) {
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(reconnect)
               name:AVCaptureDeviceWasConnectedNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(disconnect)
               name:AVCaptureDeviceWasDisconnectedNotification
             object:nil];
  }
  return self;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  return YES;
}
- (void)captureOutput:(AVCaptureOutput *)o
    didOutputSampleBuffer:(CMSampleBufferRef)b
           fromConnection:(AVCaptureConnection *)c {
  CVImageBufferRef img = CMSampleBufferGetImageBuffer(b);
  if (!img)
    return;
  CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
  uint8_t *p = CVPixelBufferGetBaseAddress(img);
  size_t s = CVPixelBufferGetBytesPerRow(img);
  size_t r = CVPixelBufferGetHeight(img);
  if (p && !g_frozen) {
    process(p, s, r);
    dispatch_async(dispatch_get_main_queue(), ^{
      [self setNeedsDisplay:YES];
    });
  }
  CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
}
- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstResponder {
  return YES;
}
- (void)saveAction:(id)sender {
  if (!g_ready)
    return;
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(g_rgb, W, H, 8, W * 4, cs, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
  CGImageRef img = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
  if (!img)
    return;

  NSSavePanel *panel = [NSSavePanel savePanel];
  panel.nameFieldStringValue = [NSString stringWithFormat:@"thermal_%ld.png",
                       (long)[[NSDate date] timeIntervalSince1970]];
  [panel beginSheetModalForWindow:self.window
                completionHandler:^(NSModalResponse result) {
                  if (result == NSModalResponseOK) {
                    NSBitmapImageRep *rep =
                        [[NSBitmapImageRep alloc] initWithCGImage:img];
                    NSData *data =
                        [rep representationUsingType:NSBitmapImageFileTypePNG
                                          properties:@{}];
                    [data writeToURL:panel.URL atomically:YES];
                  }
                  CGImageRelease(img);
                }];
}
- (void)freezeAction:(id)sender {
  g_frozen = !g_frozen;
}

- (void)flipAction:(id)sender {
  g_flipV = !g_flipV;
}
- (void)reconnectAction:(id)sender {
  [self reconnect];
}
- (void)clearAction:(id)sender {
  g_pts_n = 0;
}
- (void)toggleScaleAction:(id)sender {
  g_fixed_scale = !g_fixed_scale;
  if (g_fixed_scale) {
    g_render_min = 16;
    g_render_max = 40;
  }
}
- (void)keyDown:(NSEvent *)e {
  if (e.keyCode == 53)
    [NSApp terminate:nil];
  else if (e.keyCode == 49) {
    g_frozen = !g_frozen;
  }
}
- (NSImage *)getSymbol:(NSString *)name fallback:(NSImageName)fallback {
  if (@available(macOS 11.0, *)) {
    NSImage *img = [NSImage imageWithSystemSymbolName:name
                             accessibilityDescription:nil];
    if (img)
      return img;
  }
  return [NSImage imageNamed:fallback];
}
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
             itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
         willBeInsertedIntoToolbar:(BOOL)flag {
  NSToolbarItem *item =
      [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
  if ([itemIdentifier isEqualToString:@"freeze"]) {
    item.label = @"Freeze";
    item.paletteLabel = @"Freeze/Unfreeze";
    item.image = [self getSymbol:@"pause.circle" fallback:NSImageNameStopProgressTemplate];
    item.target = self;
    item.action = @selector(freezeAction:);
  } else if ([itemIdentifier isEqualToString:@"flip"]) {
    item.label = @"Vertical Flip";
    item.paletteLabel = @"Flip Vertical";
    item.image = [self getSymbol:@"arrow.up.and.down" fallback:NSImageNameActionTemplate];
    item.target = self;
    item.action = @selector(flipAction:);
  } else if ([itemIdentifier isEqualToString:@"reconnect"]) {
    item.label = @"Reconnect";
    item.paletteLabel = @"Reconnect Camera";
    item.image = [self getSymbol:@"arrow.clockwise" fallback:NSImageNameRefreshTemplate];
    item.target = self;
    item.action = @selector(reconnectAction:);
  } else if ([itemIdentifier isEqualToString:@"clear"]) {
    item.label = @"Clear Markers";
    item.paletteLabel = @"Clear Markers";
    item.image = [self getSymbol:@"trash" fallback:NSImageNameTrashEmpty];
    item.target = self;
    item.action = @selector(clearAction:);
  } else if ([itemIdentifier isEqualToString:@"save"]) {
    item.label = @"Save";
    item.paletteLabel = @"Save PNG";
    item.image = [self getSymbol:@"square.and.arrow.down"
                         fallback:NSImageNameFolder];
    item.target = self;
    item.action = @selector(saveAction:);
  } else if ([itemIdentifier isEqualToString:@"scale"]) {
    item.label = @"16-40°C";
    item.paletteLabel = @"Toggle Fixed Scale";
    item.image = [self getSymbol:@"thermometer"
                         fallback:NSImageNameTouchBarCommunicationVideoTemplate];
    item.target = self;
    item.action = @selector(toggleScaleAction:);
  }
  return item;
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:
    (NSToolbar *)toolbar {
  return @[
    @"save", @"freeze", @"flip", @"reconnect", @"clear", @"scale"
  ];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:
    (NSToolbar *)toolbar {
  return @[
    @"save", @"freeze", @"flip", @"reconnect", @"clear", @"scale"
  ];
}
- (void)updateWindowSize {
  int winW = W * SCALE + BAR_GAP + BAR_W + BAR_MARGIN;
  int winH = H * SCALE;
  NSRect wr =
      [self.window frameRectForContentRect:NSMakeRect(0, 0, winW, winH)];
  NSPoint tl =
      NSMakePoint(self.window.frame.origin.x,
                  (self.window.frame.origin.y + self.window.frame.size.height));
  wr.origin = NSMakePoint(tl.x, tl.y - wr.size.height);
  [self.window setFrame:wr display:YES animate:YES];
}

// Map from Thermal coord (0..W-1, 0..H-1) to View coord
- (NSPoint)mapToView:(int)tx ty:(int)ty {
  int x = tx, y = ty;
  if (g_flipV)
    y = H - 1 - y;
  int vx = x;
  int vy = y;
  return NSMakePoint(vx * SCALE, vy * SCALE);
}

- (void)mouseDown:(NSEvent *)e {
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  float fx = p.x / SCALE, fy = p.y / SCALE;
  int tx = (int)fx;
  int ty = (int)fy;
  if (g_flipV)
    ty = H - 1 - ty;
  if (tx < 0 || tx >= W || ty < 0 || ty >= H)
    return;
  for (int i = 0; i < g_pts_n; i++) {
    if (abs(g_pts[i].x - tx) < 8 && abs(g_pts[i].y - ty) < 8) {
      for (int j = i; j < g_pts_n - 1; j++) {
        g_pts[j] = g_pts[j + 1];
      }
      g_pts_n--;
      return;
    }
  }
  if (g_pts_n < MAX_PTS) {
    g_pts[g_pts_n] = (point_t){
        .x = tx, .y = ty, .val = raw_to_temp(g_frame[ty * W + tx])};
    g_pts_n++;
  }
}

- (void)drawRect:(NSRect)rect {
  NSRect b = self.bounds;
  [[NSColor blackColor] setFill];
  NSRectFill(b);
  NSShadow *shadow = [[NSShadow alloc] init];
  shadow.shadowColor = [NSColor blackColor];
  shadow.shadowBlurRadius = 2.0;
  shadow.shadowOffset = NSMakeSize(1, -1);

  NSDictionary *sa = @{
    NSFontAttributeName : [NSFont systemFontOfSize:18],
    NSForegroundColorAttributeName : [NSColor grayColor],
    NSShadowAttributeName : shadow
  };
  if (!g_connected || !g_ready) {
    NSString *msg =
        !g_connected ? @"Camera not connected" : @"Waiting for frame...";
    NSSize sz = [msg sizeWithAttributes:sa];
    [msg drawAtPoint:NSMakePoint((b.size.width - sz.width) / 2,
                                 (b.size.height - sz.height) / 2)
        withAttributes:sa];
    return;
  }
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(g_rgb, W, H, 8, W * 4, cs,
                                           kCGImageAlphaNoneSkipLast |
                                               kCGBitmapByteOrder32Big);
  CGImageRef img = CGBitmapContextCreateImage(ctx);
  CGContextRef dc = [[NSGraphicsContext currentContext] CGContext];

  // Draw Image with transform
  CGContextSaveGState(dc);
  // Quartz expects row 0 at the bottom. Our view is isFlipped=YES (row 0 at
  // top). So we must flip specifically for CGContextDrawImage.
  int imgW = W * SCALE;
  int imgH = H * SCALE;
  CGContextTranslateCTM(dc, 0, imgH);
  CGContextScaleCTM(dc, 1, -1);

  // Now apply user rotation/flip in the coordinate space of DRAWING the image
  // Since we flipped above, we must adjust.
  if (g_flipV) {
    CGContextTranslateCTM(dc, 0, H * SCALE);
    CGContextScaleCTM(dc, 1, -1);
  }

  CGContextSetInterpolationQuality(dc, kCGInterpolationNone);
  CGContextDrawImage(dc, CGRectMake(0, 0, W * SCALE, H * SCALE), img);
  CGContextRestoreGState(dc);

  // Draw Overlays in View Space (Text is upright here)
  NSPoint pMin = [self mapToView:g_min.x ty:g_min.y];
  NSPoint pMax = [self mapToView:g_max.x ty:g_max.y];
  NSPoint pCenter = [self mapToView:g_center.x ty:g_center.y];

  CGContextSetLineWidth(dc, 2);
  CGContextSetRGBStrokeColor(dc, 0, 1, 1, 1);
  CGContextStrokeEllipseInRect(dc,
                               CGRectMake(pMin.x - 10, pMin.y - 10, 20, 20));
  CGContextSetRGBStrokeColor(dc, 1, 0, 0, 1);
  CGContextStrokeEllipseInRect(dc,
                               CGRectMake(pMax.x - 10, pMax.y - 10, 20, 20));
  CGContextSetRGBStrokeColor(dc, 1, 1, 1, 1);
  CGContextStrokeEllipseInRect(
      dc, CGRectMake(pCenter.x - 8, pCenter.y - 8, 16, 16));

  NSDictionary *ya = @{
    NSFontAttributeName : [NSFont monospacedSystemFontOfSize:14
                                                      weight:NSFontWeightBold],
    NSForegroundColorAttributeName : [NSColor yellowColor],
    NSShadowAttributeName : shadow
  };
  NSDictionary *wa = @{
    NSFontAttributeName :
        [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName : [NSColor whiteColor],
    NSShadowAttributeName : shadow
  };
  [[NSString stringWithFormat:@"▲%.1f°C", g_max.val]
         drawAtPoint:NSMakePoint(pMax.x + 12, pMax.y - 7)
      withAttributes:ya];
  [[NSString stringWithFormat:@"▼%.1f°C", g_min.val]
         drawAtPoint:NSMakePoint(pMin.x + 12, pMin.y - 7)
      withAttributes:ya];
  [[NSString stringWithFormat:@"⊕%.1f°C", g_center.val]
         drawAtPoint:NSMakePoint(pCenter.x + 14, pCenter.y - 7)
      withAttributes:wa];

  for (int i = 0; i < g_pts_n; i++) {
    NSPoint dp = [self mapToView:g_pts[i].x ty:g_pts[i].y];
    CGContextSetRGBStrokeColor(dc, 0, 1, 0, 1);
    CGContextStrokeEllipseInRect(dc, CGRectMake(dp.x - 8, dp.y - 8, 16, 16));
    [[NSString stringWithFormat:@"●%.1f°C", g_pts[i].val]
           drawAtPoint:NSMakePoint(dp.x + 10, dp.y - 7)
        withAttributes:wa];
  }

  int sx = W * SCALE + BAR_GAP,
      sh = H * SCALE - 40;
  for (int y = 0; y < sh; y++) {
    uint8_t r, g, b;
    palette(1.0f - y / (float)sh, &r, &g, &b);
    CGContextSetRGBFillColor(dc, r / 255.0, g / 255.0, b / 255.0, 1);
    CGContextFillRect(dc, CGRectMake(sx, 20 + y, BAR_W, 1));
  }
  [[NSString stringWithFormat:@"%.1f°C", g_render_max]
         drawAtPoint:NSMakePoint(sx - 5, 2)
      withAttributes:wa];
  [[NSString stringWithFormat:@"%.1f°C", g_render_min]
         drawAtPoint:NSMakePoint(sx - 5,
                                 H * SCALE - 18)
      withAttributes:wa];
  CGImageRelease(img);
  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
}
- (void)reconnect {
  [self disconnect];
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self connect];
      });
}
- (void)disconnect {
  [self.session stopRunning];
  self.session = nil;
  g_connected = 0;
  g_ready = 0;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self setNeedsDisplay:YES];
  });
}
- (void)connect {
  if (g_connected)
    return;
  AVCaptureDeviceDiscoverySession *ds = [AVCaptureDeviceDiscoverySession
      discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeExternal ]
                            mediaType:AVMediaTypeVideo
                             position:AVCaptureDevicePositionUnspecified];
  AVCaptureDevice *dev = nil;
  for (AVCaptureDevice *d in ds.devices) {
    for (AVCaptureDeviceFormat *f in d.formats) {
      CMVideoDimensions dim =
          CMVideoFormatDescriptionGetDimensions(f.formatDescription);
      if (dim.width == 256 && dim.height == 386) {
        dev = d;
        break;
      }
    }
    if (dev)
      break;
  }
  if (!dev)
    return;
  NSError *err;
  if (![dev lockForConfiguration:&err])
    return;
  for (AVCaptureDeviceFormat *f in dev.formats) {
    CMVideoDimensions dim =
        CMVideoFormatDescriptionGetDimensions(f.formatDescription);
    if (dim.width == 256 && dim.height == 386) {
      [dev setActiveFormat:f];
      break;
    }
  }
  [dev unlockForConfiguration];
  self.session = [AVCaptureSession new];
  [self.session beginConfiguration];
  AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:dev
                                                                   error:&err];
  if (in && [self.session canAddInput:in])
    [self.session addInput:in];
  AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
  out.videoSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_422YpCbCr8_yuvs)
  };
  [out setSampleBufferDelegate:self
                         queue:dispatch_queue_create("th",
                                                     DISPATCH_QUEUE_SERIAL)];
  if ([self.session canAddOutput:out])
    [self.session addOutput:out];
  [self.session commitConfiguration];
  [self.session startRunning];
  g_connected = 1;
}
@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    View *v = [[View alloc]
        initWithFrame:NSMakeRect(0, 0, W * SCALE + BAR_GAP + BAR_W + BAR_MARGIN, H * SCALE)];
    [v connect];
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(100, 100, W * SCALE + BAR_GAP + BAR_W + BAR_MARGIN, H * SCALE)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.title = @"Thermal";
    win.contentView = v;
    NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"ThermalToolbar"];
    tb.delegate = v;
    tb.displayMode = NSToolbarDisplayModeIconAndLabel;
    win.toolbar = tb;
    [win makeKeyAndOrderFront:nil];
    [v updateWindowSize];
    [NSApp setDelegate:v];
    [NSApp run];
  }
  return 0;
}
