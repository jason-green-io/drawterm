#define Rect RectC
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdint.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <limits.h>
#include <stdarg.h>
#include <objc/runtime.h>
#undef Rect

#undef nil
#define Point Point9
#include "u.h"
#include "lib.h"
#include "kern/dat.h"
#include "kern/fns.h"
#include "error.h"
#include "user.h"
#include <draw.h>
#include <memdraw.h>
#include "screen.h"
#include "keyboard.h"

#ifndef DEBUG
#define DEBUG 0
#endif
#define LOG(fmt, ...) if(DEBUG)NSLog((@"%s:%d %s " fmt), __FILE__, __LINE__, __PRETTY_FUNCTION__, ##__VA_ARGS__)

Memimage *gscreen;

@interface DrawLayer : CAMetalLayer
@property id<MTLTexture> texture;
@end

@interface DrawtermView : NSView<NSTextInputClient>
- (void)reshape;
- (void)clearMods;
- (void)clearInput;
- (void)mouseevent:(NSEvent *)e;
- (void)resetLastInputRect;
- (void)enlargeLastInputRect:(NSRect)r;
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

static AppDelegate *myApp;
static DrawtermView *myview;
static NSCursor *currentCursor;
static NSString *ScaleDefaultsKey = @"DrawtermUIScale";
static NSString *CpuHostDefaultsKey = @"DrawtermCpuHost";
static NSString *CpuPortDefaultsKey = @"DrawtermCpuPort";
static NSString *AuthHostDefaultsKey = @"DrawtermAuthHost";
static NSString *AuthPortDefaultsKey = @"DrawtermAuthPort";
static NSString *UserDefaultsKey = @"DrawtermUser";
static NSString *PassDefaultsKey = @"DrawtermPass";
static NSString *SavePassDefaultsKey = @"DrawtermSavePass";
static NSString *ServersDefaultsKey = @"DrawtermServers";
static NSString *LastServerDefaultsKey = @"DrawtermLastServer";

static inline NSString*
trim(NSString *s)
{
	if(s == nil)
		return @"";
	return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static ulong pal[256];

static int readybit;
static Rendez rend;
static double uiscale = 1.0;     // user-selected UI scale (0 means raw pixels)
static CGFloat devscale = 1.0;   // device backing scale
static uchar *scalebuf;
static size_t scalebufsz;
static int forcefullredraw;

static inline int
effscale(void)
{
	// Effective pixel scale for upscaling to the Metal texture.
	if(uiscale <= 0.0)
		return 1; // raw pixels; gscreen is sized to device pixels
	int es = (int)ceil(devscale * uiscale);
	return es < 1 ? 1 : es;
}

static inline double
logicalscale(void)
{
	// Logical pixels per view point. If uiscale==0 => raw device pixels.
	if(uiscale <= 0.0)
		return devscale > 0 ? 1.0 / devscale : 1.0;
	return uiscale;
}

static inline int
effscale_for(double ui, double dev)
{
	if(ui <= 0.0)
		return 1;
	int es = (int)ceil(dev * ui);
	return es < 1 ? 1 : es;
}

static inline double
logicalscale_for(double ui, double dev)
{
	if(ui <= 0.0)
		return dev > 0 ? 1.0 / dev : 1.0;
	return ui;
}

static char*
hostgetenv(const char *name)
{
	extern char **environ;
	size_t n;
	char **p;

	if(name == nil || *name == '\0' || environ == nil)
		return nil;
	n = strlen(name);
	for(p = environ; *p != nil; p++){
		if(strncmp(*p, name, n) == 0 && (*p)[n] == '=')
			return strdup((*p) + n + 1);
	}
	return nil;
}

static double
detectscale(CGFloat fallback)
{
	CGFloat s;

	s = fallback;
	if(s < 1.0 && [NSScreen mainScreen] != nil)
		s = [NSScreen mainScreen].backingScaleFactor;
	if(s < 1.0)
		s = 1.0;
	return (double)s;
}

static double
preferredscale(CGFloat fallback)
{
	char *env;
	double s;
	NSUserDefaults *def;
	double stored;
	id obj;

	env = hostgetenv("DRAWTERM_SCALE");
	if(env != nil){
		s = strtod(env, NULL);
		free(env);
		if(s >= 0.0)
			return s;
	}
	def = [NSUserDefaults standardUserDefaults];
	obj = [def objectForKey:ScaleDefaultsKey];
	if(obj != nil){
		stored = [def doubleForKey:ScaleDefaultsKey];
		if(stored >= 0.0)
			return stored;
	}
	s = 1.0; // default user scale 1x; device scale handled separately
	return s;
}

static uchar*
scalebufensure(NSUInteger w, NSUInteger h)
{
	size_t need;

	need = (size_t)w * (size_t)h * 4;
	if(need > scalebufsz){
		scalebuf = realloc(scalebuf, need);
		if(scalebuf == nil){
			scalebufsz = 0;
			return nil;
		}
		scalebufsz = need;
	}
	return scalebuf;
}

static int
isready(void*a)
{
	return readybit;
}

void
guimain(void)
{
	LOG();
	@autoreleasepool{
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
		myApp = [AppDelegate new];
		[NSApp setDelegate:myApp];
		[NSApp run];
	}
}

void
screeninit(void)
{
	memimageinit();
	NSSize s = myview.frame.size;
	devscale = myview.window.backingScaleFactor > 0 ? myview.window.backingScaleFactor : 1.0;
	uiscale = preferredscale(devscale);
	double lscale = logicalscale();
	screensize(Rect(0, 0, s.width/lscale, s.height/lscale), ARGB32);
	gscreen->clipr = Rect(0, 0, s.width/lscale, s.height/lscale);
	forcefullredraw = 1;
	LOG(@"%g %g", s.width, s.height);
	terminit();
	readybit = 1;
	wakeup(&rend);
}

void
screensize(Rectangle r, ulong chan)
{
	Memimage *i;
	Memimage *old;
	int tw, th;
	double ui;
	double dev;
	if(Dx(r) <= 0 || Dy(r) <= 0)
		return;

	if((i = allocmemimage(r, chan)) == nil)
		return;
@autoreleasepool{
	ui = uiscale;
	dev = devscale;
	int es = effscale_for(ui, dev);
	tw = Dx(r) * es;
	th = Dy(r) * es;
	if(tw <= 0 || th <= 0){
		freememimage(i);
		return;
	}
	DrawLayer *layer = (DrawLayer *)myview.layer;
	id<MTLTexture> newtex;
	MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		width:tw
		height:th
		mipmapped:NO];
	/*
	 * We update this texture from the CPU via replaceRegion, so keep it in a
	 * CPU-addressable storage mode. GPU-optimized/private textures may crash or
	 * fail updates when the texture gets large.
	 */
	textureDesc.allowGPUOptimizedContents = NO;
	textureDesc.storageMode = MTLStorageModeShared;
	textureDesc.usage = MTLTextureUsageShaderRead;
	textureDesc.cpuCacheMode = MTLCPUCacheModeWriteCombined;
	newtex = [layer.device newTextureWithDescriptor:textureDesc];
	if(newtex == nil){
		freememimage(i);
		return;
	}
	layer.texture = newtex;

	[layer setDrawableSize:NSMakeSize(tw, th)];
	[layer setContentsScale:dev];
}
	old = gscreen;
	gscreen = i;
	gscreen->clipr = ZR;
	if(old != nil)
		freememimage(old);
}

Memdata*
attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen)
{
	LOG();
	*r = gscreen->clipr;
	*chan = gscreen->chan;
	*depth = gscreen->depth;
	*width = gscreen->width;
	*softscreen = 1;

	gscreen->data->ref++;
	return gscreen->data;
}

char *
clipread(void)
{
	@autoreleasepool{
		NSPasteboard *pb = [NSPasteboard generalPasteboard];
		NSString *s = [pb stringForType:NSPasteboardTypeString];
		if(s)
			return strdup([s UTF8String]);
	}
	return nil;
}

int
clipwrite(char *buf)
{
	@autoreleasepool{
		NSString *s = [[NSString alloc] initWithUTF8String:buf];
		NSPasteboard *pb = [NSPasteboard generalPasteboard];
		[pb clearContents];
		[pb writeObjects:@[s]];
	}
	return strlen(buf);
}

void
flushmemscreen(Rectangle r)
{
	LOG(@"<- %d %d %d %d", r.min.x, r.min.y, Dx(r), Dy(r));
	/*
	 * After resize/rescale we create a new texture. If we only upload the
	 * incremental update rect, newly exposed areas will contain garbage.
	 */
	if(forcefullredraw)
		r = gscreen->clipr;
	if(rectclip(&r, gscreen->clipr) == 0)
		return;
	if(Dx(r) <= 0 || Dy(r) <= 0)
		return;
	LOG(@"-> %d %d %d %d", r.min.x, r.min.y, Dx(r), Dy(r));
	@autoreleasepool{
		double ui = uiscale;
		double dev = devscale;
		int es = effscale_for(ui, dev);
		if((ui == 1.0 || ui <= 0.0) && es == 1){
			[((DrawLayer *)myview.layer).texture
				replaceRegion:MTLRegionMake2D(r.min.x, r.min.y, Dx(r), Dy(r))
				mipmapLevel:0
				withBytes:byteaddr(gscreen, Pt(r.min.x, r.min.y))
				bytesPerRow:gscreen->width * 4];
		}else{
			int sw, sh, x, y, sx, sy;
			uchar *dst, *src;
			size_t stride;

			sw = Dx(r) * es;
			sh = Dy(r) * es;
			dst = scalebufensure(sw, sh);
			if(dst == nil)
				return;
			stride = gscreen->width * 4;
			src = byteaddr(gscreen, Pt(r.min.x, r.min.y));
			for(y = 0; y < Dy(r); y++){
				uint32_t *s = (uint32_t *)(src + y * stride);
				for(sy = 0; sy < es; sy++){
					uint32_t *d = (uint32_t *)(dst + (y * es + sy) * sw * 4);
					for(x = 0; x < Dx(r); x++){
						uint32_t p = s[x];
						for(sx = 0; sx < es; sx++)
							d[x * es + sx] = p;
					}
				}
			}
			[((DrawLayer *)myview.layer).texture
				replaceRegion:MTLRegionMake2D(r.min.x * es, r.min.y * es, sw, sh)
				mipmapLevel:0
				withBytes:dst
				bytesPerRow:sw * 4];
		}
		double lscale = logicalscale_for(ui, dev);
		NSRect sr = NSMakeRect(r.min.x * lscale, r.min.y * lscale, Dx(r) * lscale, Dy(r) * lscale);
		int full = forcefullredraw;
		if(full)
			forcefullredraw = 0;
		dispatch_async(dispatch_get_main_queue(), ^(void){@autoreleasepool{
			LOG(@"setNeedsDisplayInRect %g %g %g %g", sr.origin.x, sr.origin.y, sr.size.width, sr.size.height);
			if(full)
				[myview setNeedsDisplay:YES];
			else
				[myview setNeedsDisplayInRect:sr];
			[myview enlargeLastInputRect:sr];
		}});
		// ReplaceRegion is somehow asynchronous since 10.14.5.  We wait sometime to request a update again.
		dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_MSEC);
		dispatch_after(time, dispatch_get_main_queue(), ^(void){@autoreleasepool{
			LOG(@"setNeedsDisplayInRect %g %g %g %g again", sr.origin.x, sr.origin.y, sr.size.width, sr.size.height);
			if(full)
				[myview setNeedsDisplay:YES];
			else
				[myview setNeedsDisplayInRect:sr];
		}});
		time = dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC);
		dispatch_after(time, dispatch_get_main_queue(), ^(void){@autoreleasepool{
			LOG(@"setNeedsDisplayInRect %g %g %g %g again", sr.origin.x, sr.origin.y, sr.size.width, sr.size.height);
			if(full)
				[myview setNeedsDisplay:YES];
			else
				[myview setNeedsDisplayInRect:sr];
		}});
	}
}

void
getcolor(ulong i, ulong *r, ulong *g, ulong *b)
{
	ulong v;

	v = pal[i];
	*r = (v>>16)&0xFF;
	*g = (v>>8)&0xFF;
	*b = v&0xFF;
}

void
setcolor(ulong i, ulong r, ulong g, ulong b)
{
	pal[i] = ((r&0xFF)<<16) & ((g&0xFF)<<8) & (b&0xFF);
}

void
setcursor(void)
{
	static unsigned char data[64], data2[256];
	unsigned char *planes[2] = {&data[0], &data[32]};
	unsigned char *planes2[2] = {&data2[0], &data2[128]};
	unsigned int i, x, y, a;
	unsigned char pu, pb, pl, pr, pc;  // upper, bottom, left, right, center
	unsigned char pul, pur, pbl, pbr;
	unsigned char ful, fur, fbl, fbr;

	lock(&cursor.lk);
	for(i = 0; i < 32; i++){
		data[i] = ~cursor.set[i] & cursor.clr[i];
		data[i+32] = cursor.set[i] | cursor.clr[i];
	}
	for(a=0; a<2; a++){
		for(y=0; y<16; y++){
			for(x=0; x<2; x++){
				pc = planes[a][x+2*y];
				pu = y==0 ? pc : planes[a][x+2*(y-1)];
				pb = y==15 ? pc : planes[a][x+2*(y+1)];
				pl = (pc>>1) | (x==0 ? pc&0x80 : (planes[a][x-1+2*y]&1)<<7);
				pr = (pc<<1) | (x==1 ? pc&1 : (planes[a][x+1+2*y]&0x80)>>7);
				ful = ~(pl^pu) & (pl^pb) & (pu^pr);
				pul = (ful & pu) | (~ful & pc);
				fur = ~(pu^pr) & (pu^pl) & (pr^pb);
				pur = (fur & pr) | (~fur & pc);
				fbl = ~(pb^pl) & (pb^pr) & (pl^pu);
				pbl = (fbl & pl) | (~fbl & pc);
				fbr = ~(pr^pb) & (pr^pu) & (pb^pl);
				pbr = (fbr & pb) | (~fbr & pc);
				planes2[a][2*x+4*2*y] = (pul&0x80) | ((pul&0x40)>>1)  | ((pul&0x20)>>2) | ((pul&0x10)>>3)
					| ((pur&0x80)>>1) | ((pur&0x40)>>2)  | ((pur&0x20)>>3) | ((pur&0x10)>>4);
				planes2[a][2*x+1+4*2*y] = ((pul&0x8)<<4) | ((pul&0x4)<<3)  | ((pul&0x2)<<2) | ((pul&0x1)<<1)
					| ((pur&0x8)<<3) | ((pur&0x4)<<2)  | ((pur&0x2)<<1) | (pur&0x1);
				planes2[a][2*x+4*(2*y+1)] =  (pbl&0x80) | ((pbl&0x40)>>1)  | ((pbl&0x20)>>2) | ((pbl&0x10)>>3)
					| ((pbr&0x80)>>1) | ((pbr&0x40)>>2)  | ((pbr&0x20)>>3) | ((pbr&0x10)>>4);
				planes2[a][2*x+1+4*(2*y+1)] = ((pbl&0x8)<<4) | ((pbl&0x4)<<3)  | ((pbl&0x2)<<2) | ((pbl&0x1)<<1)
					| ((pbr&0x8)<<3) | ((pbr&0x4)<<2)  | ((pbr&0x2)<<1) | (pbr&0x1);
			}
		}
	}
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
		initWithBitmapDataPlanes:planes
		pixelsWide:16
		pixelsHigh:16
		bitsPerSample:1
		samplesPerPixel:2
		hasAlpha:YES
		isPlanar:YES
		colorSpaceName:NSDeviceWhiteColorSpace
		bitmapFormat:0
		bytesPerRow:2
		bitsPerPixel:0];
	NSBitmapImageRep *rep2 = [[NSBitmapImageRep alloc]
		initWithBitmapDataPlanes:planes2
		pixelsWide:32
		pixelsHigh:32
		bitsPerSample:1
		samplesPerPixel:2
		hasAlpha:YES
		isPlanar:YES
		colorSpaceName:NSDeviceWhiteColorSpace
		bitmapFormat:0
		bytesPerRow:4
		bitsPerPixel:0];
	NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
	[img addRepresentation:rep2];
	[img addRepresentation:rep];
	currentCursor = [[NSCursor alloc] initWithImage:img hotSpot:NSMakePoint(-cursor.offset.x, -cursor.offset.y)];
	unlock(&cursor.lk);

	dispatch_async(dispatch_get_main_queue(), ^(void){
		[[myview window] invalidateCursorRectsForView:myview];
	});
}

void
mouseset(Point p)
{
	dispatch_async(dispatch_get_main_queue(), ^(void){@autoreleasepool{
		NSPoint s;

		if([[myview window] isKeyWindow]){
			double lscale = logicalscale();
			s = NSMakePoint(p.x * lscale, p.y * lscale);
			LOG(@"-> pixel  %g %g", s.x, s.y);
			s = [myview convertPoint:s toView:nil];
			LOG(@"-> window %g %g", s.x, s.y);
			s = [[myview window] convertPointToScreen: s];
			LOG(@"(%g, %g) <- toScreen", s.x, s.y);
			s.y = NSScreen.screens[0].frame.size.height - s.y;
			LOG(@"(%g, %g) <- setmouse", s.x, s.y);
			CGWarpMouseCursorPosition(s);
			CGAssociateMouseAndMouseCursorPosition(true);
		}
	}});
}

/* ---- static helpers ---- */

static BOOL
alreadyConnected(void)
{
	NSArray *args = [[NSProcessInfo processInfo] arguments];
	for(NSString *a in args)
		if([a isEqualToString:@"-h"])
			return YES;
	return NO;
}

static NSMutableArray *
loadServers(void)
{
	NSArray *raw = [[NSUserDefaults standardUserDefaults] arrayForKey:ServersDefaultsKey];
	if(raw == nil)
		return [NSMutableArray array];
	NSMutableArray *out = [NSMutableArray arrayWithCapacity:raw.count];
	for(id item in raw)
		[out addObject:[NSMutableDictionary dictionaryWithDictionary:item]];
	return out;
}

static void
saveServers(NSArray *servers)
{
	NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
	[def setObject:servers forKey:ServersDefaultsKey];
	[def synchronize];
}

static void
migrateIfNeeded(void)
{
	NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
	if([def objectForKey:ServersDefaultsKey] != nil)
		return;
	NSString *cpuHost = [def stringForKey:CpuHostDefaultsKey];
	if(cpuHost == nil)
		return;
	NSMutableDictionary *d = [NSMutableDictionary dictionary];
	d[@"name"]        = @"Default";
	d[@"cpuHost"]     = cpuHost;
	d[@"cpuPort"]     = [def stringForKey:CpuPortDefaultsKey] ?: @"17019";
	d[@"authHost"]    = [def stringForKey:AuthHostDefaultsKey] ?: @"";
	d[@"authPort"]    = [def stringForKey:AuthPortDefaultsKey] ?: @"";
	d[@"user"]        = [def stringForKey:UserDefaultsKey] ?: @"glenda";
	d[@"pass"]        = [def stringForKey:PassDefaultsKey] ?: @"";
	d[@"savePass"]    = @([def boolForKey:SavePassDefaultsKey]);
	d[@"autoConnect"] = @NO;
	saveServers(@[d]);
}

static void
execConnect(NSDictionary *server)
{
	NSString *cpuHost  = trim(server[@"cpuHost"]);
	NSString *cpuPort  = trim(server[@"cpuPort"]);
	NSString *authHost = trim(server[@"authHost"]);
	NSString *authPort = trim(server[@"authPort"]);
	NSString *user     = trim(server[@"user"]);
	NSString *pass     = server[@"pass"] ?: @"";
	BOOL savePass      = [server[@"savePass"] boolValue];

	if(cpuHost.length == 0)  cpuHost  = @"localhost";
	if(cpuPort.length == 0)  cpuPort  = @"17019";
	if(user.length == 0)     user     = @"glenda";
	if(!savePass)            pass     = @"";

	NSString *exe = [[NSBundle mainBundle] executablePath];
	if(exe == nil || exe.length == 0)
		exe = [[NSProcessInfo processInfo] arguments][0];
	char resolved[PATH_MAX];
	if(realpath([exe UTF8String], resolved) != NULL)
		exe = [NSString stringWithUTF8String:resolved];

	NSString *cpustr  = [NSString stringWithFormat:@"tcp!%@!%@", cpuHost, cpuPort];
	NSString *authTarget = authHost.length ? authHost : cpuHost;
	NSString *authstr;
	if(authPort.length)
		authstr = [NSString stringWithFormat:@"tcp!%@!%@", authTarget, authPort];
	else
		authstr = [NSString stringWithFormat:@"tcp!%@", authTarget];

	NSArray *argv = @[exe, @"-a", authstr, @"-h", cpustr, @"-u", user];
	int argc = (int)argv.count;
	char **cargv = calloc(argc + 1, sizeof(char *));
	for(int i = 0; i < argc; i++)
		cargv[i] = strdup([[argv objectAtIndex:i] UTF8String]);

	if(pass.length)
		setenv("PASS", [pass UTF8String], 1);
	else
		unsetenv("PASS");

	execv(cargv[0], cargv);
	for(int i = 0; i < argc; i++)
		free(cargv[i]);
	free(cargv);
	_exit(1);
}

/* ---- ServerListController ---- */

@interface ServerListController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
- (instancetype)init;
- (void)showPanel;
@end

@implementation ServerListController
{
	NSPanel            *_panel;
	NSTableView        *_tableView;
	NSScrollView       *_scroll;
	NSButton           *_addButton;
	NSButton           *_editButton;
	NSButton           *_deleteButton;
	NSButton           *_connectButton;
	NSButton           *_cancelButton;
	NSMutableArray     *_servers;
	NSInteger           _editingIndex;
	id                  _keyMonitor;

	NSPanel            *_editPanel;
	NSTextField        *_nameField;
	NSTextField        *_cpuHostField;
	NSTextField        *_cpuPortField;
	NSTextField        *_authHostField;
	NSTextField        *_authPortField;
	NSTextField        *_userField;
	NSSecureTextField  *_passField;
	NSButton           *_savePassCheck;
}

- (NSButton *)makeButtonTitle:(NSString *)title action:(SEL)sel
{
	NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
	[b setTitle:title];
	[b setTarget:self];
	[b setAction:sel];
	[b setBezelStyle:NSBezelStyleRounded];
	[b sizeToFit];
	return b;
}

- (NSTextField *)makeLabelText:(NSString *)text
{
	NSTextField *f = [NSTextField labelWithString:text];
	[f setAlignment:NSTextAlignmentRight];
	return f;
}

- (NSTextField *)makeEditFieldWidth:(CGFloat)w
{
	NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, w, 22)];
	return f;
}

- (void)buildServerListPanel
{
	_panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 500, 300)
		styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered defer:NO];
	[_panel setTitle:@"Drawterm Servers"];
	[_panel setReleasedWhenClosed:NO];
	[[_panel standardWindowButton:NSWindowCloseButton] setTarget:self];
	[[_panel standardWindowButton:NSWindowCloseButton] setAction:@selector(cancelPanel:)];

	/* replace default content view so Auto Layout works cleanly */
	NSView *cv = [[NSView alloc] init];
	[_panel setContentView:cv];

	_scroll = [NSScrollView new];
	[_scroll setHasVerticalScroller:YES];
	[_scroll setAutohidesScrollers:YES];
	[_scroll setBorderType:NSBezelBorder];

	_tableView = [NSTableView new];
	[_tableView setUsesAlternatingRowBackgroundColors:YES];
	[_tableView setAllowsMultipleSelection:NO];
	[_tableView setAllowsEmptySelection:YES];
	[_tableView setDataSource:self];
	[_tableView setDelegate:self];
	[_tableView setDoubleAction:@selector(tableDoubleClick:)];
	[_tableView setTarget:self];
	[_tableView setColumnAutoresizingStyle:NSTableViewNoColumnAutoresizing];

	for(NSArray *def in @[
		@[@"name", @"Name",  @150],
		@[@"host", @"Host",  @150],
		@[@"user", @"User",  @90],
		@[@"auto", @"Auto",  @44],
	]){
		NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:def[0]];
		col.title = def[1];
		col.width = [def[2] floatValue];
		if([def[0] isEqualToString:@"auto"])
			col.resizingMask = NSTableColumnNoResizing;
		[_tableView addTableColumn:col];
	}
	[_scroll setDocumentView:_tableView];

	_addButton     = [self makeButtonTitle:@"Add"     action:@selector(addServer:)];
	_editButton    = [self makeButtonTitle:@"Edit"    action:@selector(editServer:)];
	_deleteButton  = [self makeButtonTitle:@"Delete"  action:@selector(deleteServer:)];
	_cancelButton  = [self makeButtonTitle:@"Cancel"  action:@selector(cancelPanel:)];
	_connectButton = [self makeButtonTitle:@"Connect" action:@selector(connectServer:)];
	[_connectButton setKeyEquivalent:@"\r"];

	for(NSView *v in @[_scroll, _addButton, _editButton, _deleteButton, _cancelButton, _connectButton]){
		[v setTranslatesAutoresizingMaskIntoConstraints:NO];
		[cv addSubview:v];
	}

	NSDictionary *views = NSDictionaryOfVariableBindings(
		_scroll, _addButton, _editButton, _deleteButton, _cancelButton, _connectButton);
	NSDictionary *m = @{@"p":@12, @"g":@8, @"bh":@44};

	NSMutableArray *cs = [NSMutableArray array];
	[cs addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:
		@"H:|-(p)-[_scroll]-(p)-|" options:0 metrics:m views:views]];
	[cs addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:
		@"V:|-(p)-[_scroll]-(bh)-|" options:0 metrics:m views:views]];
	[cs addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:
		@"H:|-(p)-[_addButton]-(g)-[_editButton]-(g)-[_deleteButton]" options:NSLayoutFormatAlignAllCenterY metrics:m views:views]];
	[cs addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:
		@"H:[_cancelButton]-(g)-[_connectButton]-(p)-|" options:NSLayoutFormatAlignAllCenterY metrics:m views:views]];
	[cs addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:
		@"V:[_addButton]-(p)-|" options:0 metrics:m views:views]];
	[cs addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:
		@"V:[_connectButton]-(p)-|" options:0 metrics:m views:views]];
	[NSLayoutConstraint activateConstraints:cs];

	[_editButton   setEnabled:NO];
	[_deleteButton setEnabled:NO];
	[_connectButton setEnabled:NO];
}

- (NSTextField *)addLabelText:(NSString *)text y:(CGFloat)y lx:(CGFloat)lx labelW:(CGFloat)w toView:(NSView *)cv
{
	NSTextField *lbl = [NSTextField labelWithString:text];
	[lbl setFrame:NSMakeRect(lx, y, w, 22)];
	[lbl setAlignment:NSTextAlignmentRight];
	[cv addSubview:lbl];
	return lbl;
}

- (void)buildEditPanel
{
	CGFloat pw = 420, ph = 360;
	_editPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, pw, ph)
		styleMask:NSWindowStyleMaskTitled
		backing:NSBackingStoreBuffered defer:NO];
	[_editPanel setReleasedWhenClosed:NO];

	CGFloat labelW = 100, fieldW = 240, lx = 10, fx = 120;
	CGFloat rowH = 28, gapY = 6;
	NSView *cv = [_editPanel contentView];

	/* checkboxes at the bottom of the field area */
	CGFloat checkboxY = 10 + 2*(rowH + gapY);

	_savePassCheck = [[NSButton alloc] initWithFrame:NSMakeRect(fx, checkboxY, fieldW, 22)];
	[_savePassCheck setButtonType:NSButtonTypeSwitch];
	[_savePassCheck setTitle:@"Save password"];
	[cv addSubview:_savePassCheck];

	/* text fields, top to bottom */
	CGFloat y0 = checkboxY + 1*(rowH + gapY);
	int idx = 0;
	CGFloat y;

#define NEXTROW(i) (y0 + (6 - (i)) * (rowH + gapY))

	y = NEXTROW(idx); idx++;
	[self addLabelText:@"Name:"      y:y lx:lx labelW:labelW toView:cv];
	_nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(fx, y, fieldW, 22)];
	[cv addSubview:_nameField];

	y = NEXTROW(idx); idx++;
	[self addLabelText:@"CPU host:"  y:y lx:lx labelW:labelW toView:cv];
	_cpuHostField = [[NSTextField alloc] initWithFrame:NSMakeRect(fx, y, fieldW, 22)];
	[cv addSubview:_cpuHostField];

	y = NEXTROW(idx); idx++;
	[self addLabelText:@"CPU port:"  y:y lx:lx labelW:labelW toView:cv];
	_cpuPortField = [[NSTextField alloc] initWithFrame:NSMakeRect(fx, y, 90, 22)];
	[cv addSubview:_cpuPortField];

	y = NEXTROW(idx); idx++;
	[self addLabelText:@"Auth host:" y:y lx:lx labelW:labelW toView:cv];
	_authHostField = [[NSTextField alloc] initWithFrame:NSMakeRect(fx, y, fieldW, 22)];
	[cv addSubview:_authHostField];

	y = NEXTROW(idx); idx++;
	[self addLabelText:@"Auth port:" y:y lx:lx labelW:labelW toView:cv];
	_authPortField = [[NSTextField alloc] initWithFrame:NSMakeRect(fx, y, 90, 22)];
	[cv addSubview:_authPortField];

	y = NEXTROW(idx); idx++;
	[self addLabelText:@"User:"      y:y lx:lx labelW:labelW toView:cv];
	_userField = [[NSTextField alloc] initWithFrame:NSMakeRect(fx, y, fieldW, 22)];
	[cv addSubview:_userField];

	y = NEXTROW(idx);
	[self addLabelText:@"Password:"  y:y lx:lx labelW:labelW toView:cv];
	_passField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fx, y, fieldW, 22)];
	[cv addSubview:_passField];

#undef NEXTROW

	NSButton *saveBtn   = [self makeButtonTitle:@"Save"   action:@selector(saveEditAndClose:)];
	NSButton *cancelBtn = [self makeButtonTitle:@"Cancel" action:@selector(cancelEdit:)];
	[saveBtn setKeyEquivalent:@"\r"];

	CGFloat bx = pw - 10;
	bx -= saveBtn.frame.size.width;
	[saveBtn setFrameOrigin:NSMakePoint(bx, 10)];
	bx -= 8 + cancelBtn.frame.size.width;
	[cancelBtn setFrameOrigin:NSMakePoint(bx, 10)];
	[cv addSubview:saveBtn];
	[cv addSubview:cancelBtn];
	[_editPanel setDefaultButtonCell:saveBtn.cell];
}

- (instancetype)init
{
	self = [super init];
	if(self == nil)
		return nil;
	migrateIfNeeded();
	_servers = loadServers();
	_editingIndex = -1;
	[self buildServerListPanel];
	[self buildEditPanel];
	return self;
}

- (void)showPanel
{
	_servers = loadServers();
	[_tableView reloadData];

	/* pre-select last connected server, fall back to row 0 */
	NSInteger selRow = 0;
	NSString *lastName = [[NSUserDefaults standardUserDefaults] stringForKey:LastServerDefaultsKey];
	if(lastName){
		for(NSInteger i = 0; i < (NSInteger)_servers.count; i++){
			if([_servers[i][@"name"] isEqualToString:lastName]){
				selRow = i;
				break;
			}
		}
	}
	if(_servers.count > 0)
		[_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:selRow] byExtendingSelection:NO];

	BOOL hasSel = ([_tableView selectedRow] >= 0);
	[_editButton   setEnabled:hasSel];
	[_deleteButton setEnabled:hasSel];
	[_connectButton setEnabled:hasSel];

	if(_keyMonitor == nil){
		__weak ServerListController *weakSelf = self;
		_keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e){
			ServerListController *s = weakSelf;
			if(s == nil || e.window != s->_panel) return e;
			NSUInteger mods = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
			/* Delete — remove selected server */
			if(e.keyCode == 51){
				[s deleteServer:nil];
				return nil;
			}
			/* Return / Enter — connect */
			if(e.keyCode == 36 || e.keyCode == 76){
				[s connectServer:nil];
				return nil;
			}
			/* Cmd+N — add new server */
			if(mods == NSEventModifierFlagCommand && [e.charactersIgnoringModifiers isEqualToString:@"n"]){
				[s addServer:nil];
				return nil;
			}
			return e;
		}];
	}

	[_panel center];
	[_panel makeKeyAndOrderFront:nil];
}

- (void)addServer:(id)sender
{
	[_panel makeKeyAndOrderFront:nil];
	_editingIndex = -1;
	[_editPanel setTitle:@"Add Server"];
	[_nameField     setStringValue:@""];
	[_cpuHostField  setStringValue:@""];
	[_cpuPortField  setStringValue:@"17019"];
	[_authHostField setStringValue:@""];
	[_authPortField setStringValue:@""];
	[_userField     setStringValue:@"glenda"];
	[_passField     setStringValue:@""];
	[_savePassCheck     setState:NSControlStateValueOff];
	[_panel beginSheet:_editPanel completionHandler:^(NSModalResponse r){(void)r;}];
	[_editPanel makeFirstResponder:_nameField];
}

- (void)editServer:(id)sender
{
	NSInteger row = [_tableView selectedRow];
	if(row < 0 || row >= (NSInteger)_servers.count)
		return;
	_editingIndex = row;
	NSDictionary *s = _servers[row];
	[_editPanel setTitle:@"Edit Server"];
	[_nameField     setStringValue:s[@"name"]     ?: @""];
	[_cpuHostField  setStringValue:s[@"cpuHost"]  ?: @""];
	[_cpuPortField  setStringValue:s[@"cpuPort"]  ?: @"17019"];
	[_authHostField setStringValue:s[@"authHost"] ?: @""];
	[_authPortField setStringValue:s[@"authPort"] ?: @""];
	[_userField     setStringValue:s[@"user"]     ?: @"glenda"];
	BOOL sp = [s[@"savePass"] boolValue];
	[_savePassCheck setState:sp ? NSControlStateValueOn : NSControlStateValueOff];
	[_passField setStringValue:(sp ? (s[@"pass"] ?: @"") : @"")];
	[_panel beginSheet:_editPanel completionHandler:^(NSModalResponse r){(void)r;}];
	[_editPanel makeFirstResponder:_cpuHostField];
}

- (void)deleteServer:(id)sender
{
	NSInteger row = [_tableView selectedRow];
	if(row < 0 || row >= (NSInteger)_servers.count)
		return;
	NSString *name = _servers[row][@"name"] ?: @"this server";
	NSAlert *alert = [NSAlert new];
	[alert setMessageText:[NSString stringWithFormat:@"Delete \"%@\"?", name]];
	[alert addButtonWithTitle:@"Delete"];
	[alert addButtonWithTitle:@"Cancel"];
	[alert setAlertStyle:NSAlertStyleWarning];
	if([alert runModal] != NSAlertFirstButtonReturn)
		return;
	[_servers removeObjectAtIndex:row];
	saveServers(_servers);
	[_tableView reloadData];
	BOOL hasSel = ([_tableView selectedRow] >= 0);
	[_editButton  setEnabled:hasSel];
	[_deleteButton setEnabled:hasSel];
	[_connectButton setEnabled:hasSel];
}

- (void)connectServer:(id)sender
{
	NSInteger row = [_tableView selectedRow];
	if(row < 0 || row >= (NSInteger)_servers.count)
		return;
	NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
	[def setObject:_servers[row][@"name"] forKey:LastServerDefaultsKey];
	[def synchronize];
	execConnect(_servers[row]);
}

- (void)tableDoubleClick:(id)sender
{
	[self connectServer:nil];
}

- (void)cancelPanel:(id)sender
{
	if(_keyMonitor){
		[NSEvent removeMonitor:_keyMonitor];
		_keyMonitor = nil;
	}
	[_panel orderOut:nil];
}

- (void)saveEditAndClose:(id)sender
{
	NSString *name    = trim([_nameField stringValue]);
	NSString *cpuHost = trim([_cpuHostField stringValue]);
	if(name.length == 0 || cpuHost.length == 0){
		NSAlert *alert = [NSAlert new];
		[alert setMessageText:@"Name and CPU host are required."];
		[alert runModal];
		return;
	}
	BOOL savePass = (_savePassCheck.state == NSControlStateValueOn);
	NSString *pass = savePass ? [_passField stringValue] : @"";

	NSMutableDictionary *entry = [NSMutableDictionary dictionary];
	entry[@"name"]        = name;
	entry[@"cpuHost"]     = cpuHost;
	entry[@"cpuPort"]     = trim([_cpuPortField stringValue]) ?: @"17019";
	entry[@"authHost"]    = trim([_authHostField stringValue]) ?: @"";
	entry[@"authPort"]    = trim([_authPortField stringValue]) ?: @"";
	entry[@"user"]        = (trim([_userField stringValue]).length ? trim([_userField stringValue]) : @"glenda");
	entry[@"pass"]        = pass;
	entry[@"savePass"]    = @(savePass);
	/* preserve autoConnect flag when editing; new servers default to NO */
	entry[@"autoConnect"] = (_editingIndex >= 0 && _editingIndex < (NSInteger)_servers.count)
		? _servers[_editingIndex][@"autoConnect"] : @NO;

	if(_editingIndex >= 0 && _editingIndex < (NSInteger)_servers.count)
		[_servers replaceObjectAtIndex:_editingIndex withObject:entry];
	else
		[_servers addObject:entry];
	saveServers(_servers);
	[_panel endSheet:_editPanel];
	[_editPanel orderOut:nil];
	[_tableView reloadData];
	NSInteger selRow = (_editingIndex >= 0) ? _editingIndex : (NSInteger)_servers.count - 1;
	[_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:selRow] byExtendingSelection:NO];
	[_editButton  setEnabled:YES];
	[_deleteButton setEnabled:YES];
	[_connectButton setEnabled:YES];
}

- (void)cancelEdit:(id)sender
{
	[_panel endSheet:_editPanel];
	[_editPanel orderOut:nil];
}

/* NSTableViewDataSource */

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
	return (NSInteger)_servers.count;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row
{
	if(row < 0 || row >= (NSInteger)_servers.count)
		return nil;
	NSDictionary *s = _servers[row];
	NSString *ident = col.identifier;

	if([ident isEqualToString:@"auto"]){
		NSButton *btn = [tv makeViewWithIdentifier:@"autoCheck" owner:self];
		if(btn == nil){
			btn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 22, 22)];
			[btn setButtonType:NSButtonTypeSwitch];
			[btn setTitle:@""];
			[btn setIdentifier:@"autoCheck"];
			[btn setTarget:self];
			[btn setAction:@selector(autoCheckClicked:)];
		}
		[btn setState:[s[@"autoConnect"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff];
		[btn setTag:row];
		return btn;
	}

	NSTextField *tf = [tv makeViewWithIdentifier:ident owner:self];
	if(tf == nil){
		tf = [NSTextField labelWithString:@""];
		[tf setFrame:NSMakeRect(0, 0, col.width, 17)];
		[tf setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];
		[tf setIdentifier:ident];
	}
	NSString *text = @"";
	if([ident isEqualToString:@"name"]) text = s[@"name"] ?: @"";
	if([ident isEqualToString:@"host"]) text = s[@"cpuHost"] ?: @"";
	if([ident isEqualToString:@"user"]) text = s[@"user"] ?: @"";
	[tf setStringValue:text];
	return tf;
}

- (void)autoCheckClicked:(NSButton *)btn
{
	NSInteger row = btn.tag;
	if(row < 0 || row >= (NSInteger)_servers.count)
		return;
	BOOL newVal = (btn.state == NSControlStateValueOn);
	if(newVal){
		for(NSMutableDictionary *d in _servers)
			d[@"autoConnect"] = @NO;
		_servers[row][@"autoConnect"] = @YES;
	} else {
		_servers[row][@"autoConnect"] = @NO;
	}
	saveServers(_servers);
	[_tableView reloadData];
}

/* NSTableViewDelegate */

- (void)tableViewSelectionDidChange:(NSNotification *)n
{
	BOOL hasSel = ([_tableView selectedRow] >= 0);
	[_editButton  setEnabled:hasSel];
	[_deleteButton setEnabled:hasSel];
	[_connectButton setEnabled:hasSel];
}

@end

/* ---- AppDelegate ---- */

@implementation AppDelegate
{
	NSWindow  *_window;
	ServerListController *_serverList;
	NSPanel   *_prefsPanel;
	NSSlider  *_prefsSlider;
	NSTextField *_prefsValueLabel;
}

- (void)scaleSliderChanged:(NSSlider *)sender
{
	double step = 0.25;
	double v = sender.doubleValue;
	if(v < step/2)
		v = 0.0; // raw pixels
	else
		v = round(v/step)*step;
	[sender setDoubleValue:v];
	if(_prefsValueLabel)
		[_prefsValueLabel setStringValue:(v == 0.0 ? @"raw" : [NSString stringWithFormat:@"%.2f", v])];
}

- (NSWindow *)window
{
	return _window;
}

- (void)applyScaleAndResize:(double)scale
{
	uiscale = scale;
	/*
	 * Force a resize even if the logical size is unchanged so the new scale
	 * rebuilds the Metal texture. Do a bump-then-restore pass to defeat the
	 * eqrect short circuit in resizeproc.
	 */
	double lscale = logicalscale();
	int w = (int)(myview.frame.size.width/lscale);
	int h = (int)(myview.frame.size.height/lscale);
	if(w < 1) w = 1;
	if(h < 1) h = 1;
	screenresize(Rect(0, 0, w+1, h+1));
	screenresize(Rect(0, 0, w, h));
	forcefullredraw = 1;
}

- (void)openAbout:(id)sender
{
	NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
	NSMutableAttributedString *credits = [[NSMutableAttributedString alloc] init];
	NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11]};
	[[credits mutableString] setString:
		@"drawterm connects to Plan 9 CPU servers.\n\n"
		 "Original drawterm by Russ Cox and the Bell Labs Plan 9 team.\n"
		 "macOS Cocoa backend, HiDPI scaling, and connection UI by Rui Carmo.\n"
		 "OpenGL → Metal port by Jacob Moody (thanks jxy & Keegan).\n"
		 "CoreAudio backend and server management UI by Jason Green,\n"
		 "assisted by Claude (Anthropic).\n"
		 "Upstream kernel and library work by the 9front contributors.\n\n"
		 "Copyright © 2018–2026 respective authors.\n"
		 "All cats reserved."];
	[credits setAttributes:attrs range:NSMakeRange(0, credits.length)];
	[NSApp orderFrontStandardAboutPanelWithOptions:@{
		@"ApplicationName":    @"drawterm",
		@"ApplicationVersion": version,
		@"Credits":            credits,
	}];
}

- (void)buildPrefsPanel
{
	double detected = detectscale(self.window.backingScaleFactor);

	_prefsPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 340, 140)
		styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable
		backing:NSBackingStoreBuffered defer:NO];
	[_prefsPanel setTitle:@"Settings"];
	[_prefsPanel setReleasedWhenClosed:NO];

	NSView *cv = [[NSView alloc] init];
	[_prefsPanel setContentView:cv];

	NSTextField *heading = [NSTextField labelWithString:@"Interface Scale"];
	[heading setFont:[NSFont boldSystemFontOfSize:13]];

	NSString *infoStr = [NSString stringWithFormat:@"HiDPI scale for Retina displays. Detected: %.2f", detected];
	NSTextField *info = [NSTextField wrappingLabelWithString:infoStr];
	[info setTextColor:[NSColor secondaryLabelColor]];
	[info setFont:[NSFont systemFontOfSize:11]];

	_prefsSlider = [NSSlider sliderWithValue:uiscale minValue:0.0 maxValue:4.0
		target:self action:@selector(scaleSliderChanged:)];
	[_prefsSlider setAllowsTickMarkValuesOnly:YES];
	[_prefsSlider setNumberOfTickMarks:17];
	[_prefsSlider setContinuous:YES];

	NSString *valStr = (uiscale == 0.0) ? @"raw" : [NSString stringWithFormat:@"%.2f", uiscale];
	_prefsValueLabel = [NSTextField labelWithString:valStr];
	[_prefsValueLabel setAlignment:NSTextAlignmentRight];

	NSButton *okBtn     = [NSButton buttonWithTitle:@"OK" target:self action:@selector(prefsOK:)];
	NSButton *cancelBtn = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(prefsCancel:)];
	[okBtn setKeyEquivalent:@"\r"];

	for(NSView *v in @[heading, info, _prefsSlider, _prefsValueLabel, okBtn, cancelBtn]){
		[v setTranslatesAutoresizingMaskIntoConstraints:NO];
		[cv addSubview:v];
	}

	NSDictionary *views = NSDictionaryOfVariableBindings(
		heading, info, _prefsSlider, _prefsValueLabel, okBtn, cancelBtn);
	NSDictionary *m = @{@"p":@12, @"g":@6, @"s":@48};

	NSMutableArray *cs = [NSMutableArray array];
	[cs addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:
		@"H:|-(p)-[heading]-(p)-|" options:0 metrics:m views:views]];
	[cs addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:
		@"H:|-(p)-[info]-(p)-|" options:0 metrics:m views:views]];
	[cs addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:
		@"H:|-(p)-[_prefsSlider]-[_prefsValueLabel(==40)]-(p)-|" options:NSLayoutFormatAlignAllCenterY metrics:m views:views]];
	[cs addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:
		@"H:[cancelBtn]-(g)-[okBtn]-(p)-|" options:NSLayoutFormatAlignAllCenterY metrics:m views:views]];
	[cs addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:
		@"V:|-(p)-[heading]-(g)-[info]-(g)-[_prefsSlider]-(g)-[okBtn]-(p)-|" options:0 metrics:m views:views]];
	[cs addObject:[cancelBtn.bottomAnchor constraintEqualToAnchor:okBtn.bottomAnchor]];
	[NSLayoutConstraint activateConstraints:cs];
}

- (void)prefsOK:(id)sender
{
	double newScale = _prefsSlider.doubleValue;
	if(newScale < 0.125)
		newScale = 0.0;
	else
		newScale = round(newScale/0.25)*0.25;
	[_prefsPanel orderOut:nil];
	if(newScale != uiscale){
		NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
		[def setDouble:newScale forKey:ScaleDefaultsKey];
		[def synchronize];
		[self applyScaleAndResize:newScale];
	}
}

- (void)prefsCancel:(id)sender
{
	[_prefsSlider setDoubleValue:uiscale];
	NSString *v = (uiscale == 0.0) ? @"raw" : [NSString stringWithFormat:@"%.2f", uiscale];
	[_prefsValueLabel setStringValue:v];
	[_prefsPanel orderOut:nil];
}

- (void)openPreferences:(id)sender
{
	if(_prefsPanel == nil)
		[self buildPrefsPanel];
	[_prefsSlider setDoubleValue:uiscale];
	NSString *v = (uiscale == 0.0) ? @"raw" : [NSString stringWithFormat:@"%.2f", uiscale];
	[_prefsValueLabel setStringValue:v];
	[_prefsPanel center];
	[_prefsPanel makeKeyAndOrderFront:nil];
}

- (void)openConnect:(id)sender
{
	if(_serverList == nil)
		_serverList = [ServerListController new];
	[_serverList showPanel];
}

static void
mainproc(void *aux)
{
	cpubody();
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
	if([sender mainWindow] == nil)
		return NSTerminateNow;

	NSAlert *alert = [[NSAlert alloc] init];
	[alert setMessageText:@"Really quit drawterm?"];
	[alert addButtonWithTitle:@"Yes"];
	[alert addButtonWithTitle:@"Cancel"];
	[alert setAlertStyle:NSAlertStyleCritical];
	int choice = [alert runModal];
	if(choice == NSAlertFirstButtonReturn)
		return NSTerminateNow;
	return NSTerminateCancel;
}

- (void) applicationDidFinishLaunching:(NSNotification *)aNotification
{
	LOG(@"BEGIN");

	NSMenu *sm = [NSMenu new];
	[sm addItemWithTitle:@"About drawterm" action:@selector(openAbout:) keyEquivalent:@""];
	[sm addItem:[NSMenuItem separatorItem]];
	[sm addItemWithTitle:@"Toggle Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"F"];
	[sm addItemWithTitle:@"Hide" action:@selector(hide:) keyEquivalent:@"H"];
	[sm addItemWithTitle:@"Connect…" action:@selector(openConnect:) keyEquivalent:@"o"];
	[sm addItemWithTitle:@"Settings…" action:@selector(openPreferences:) keyEquivalent:@","];
	[sm addItemWithTitle:@"Quit drawterm" action:@selector(terminate:) keyEquivalent:@"q"];
	NSMenu *m = [NSMenu new];
	[m addItemWithTitle:@"drawterm" action:NULL keyEquivalent:@""];
	[m setSubmenu:sm forItem:[m itemWithTitle:@"drawterm"]];
	[NSApp setMainMenu:m];

	const NSWindowStyleMask Winstyle = NSWindowStyleMaskTitled
		| NSWindowStyleMaskClosable
		| NSWindowStyleMaskMiniaturizable
		| NSWindowStyleMaskResizable;

	NSRect r = [[NSScreen mainScreen] visibleFrame];

	r.size.width = r.size.width*3/4;
	r.size.height = r.size.height*3/4;
	r = [NSWindow contentRectForFrameRect:r styleMask:Winstyle];

	_window = [[NSWindow alloc] initWithContentRect:r styleMask:Winstyle
		backing:NSBackingStoreBuffered defer:NO];
	NSString *windowTitle = @"drawterm";
	NSArray *pargs = [[NSProcessInfo processInfo] arguments];
	for(NSUInteger i = 0; i + 1 < pargs.count; i++){
		if([pargs[i] isEqualToString:@"-h"]){
			/* extract host from "tcp!host!port" */
			NSArray *parts = [pargs[i+1] componentsSeparatedByString:@"!"];
			NSString *host = parts.count > 1 ? parts[1] : pargs[i+1];
			windowTitle = [NSString stringWithFormat:@"drawterm — %@", host];
			break;
		}
	}
	[_window setTitle:windowTitle];
	[_window center];
	[_window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
	[_window setContentMinSize:NSMakeSize(64,64)];
	[_window setOpaque:YES];
	[_window setRestorable:NO];
	[_window setAcceptsMouseMovedEvents:YES];
	[_window setDelegate:self];

	myview = [DrawtermView new];
	[_window setContentView:myview];

	[NSEvent setMouseCoalescingEnabled:NO];
	setcursor();

	[_window makeKeyAndOrderFront:self];
	[NSApp activateIgnoringOtherApps:YES];

	migrateIfNeeded();
	if(!alreadyConnected()){
		NSArray *svrs = loadServers();
		for(NSDictionary *s in svrs){
			if([s[@"autoConnect"] boolValue]){
				execConnect(s);
				break;
			}
		}
	}

	LOG(@"launch mainproc");
	kproc("mainproc", mainproc, 0);
	ksleep(&rend, isready, 0);
}

- (NSApplicationPresentationOptions) window:(NSWindow *)window
		willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions
{
	NSApplicationPresentationOptions o;
	o = proposedOptions;
	o &= ~(NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar);
	o |= NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
	return o;
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication
{
	return YES;
}

- (void) windowDidBecomeKey:(id)arg
{
	NSPoint p;
	p = [myview convertPoint:[_window mouseLocationOutsideOfEventStream] fromView:nil];
	double lscale = logicalscale();
	absmousetrack(p.x/lscale, (self.window.contentView.frame.size.height - p.y)/lscale, 0, ticks());
}

- (void) windowDidResize:(NSNotification *)notification
{
	/*
	 * Live resize notifications are delivered to the NSWindow's delegate
	 * (AppDelegate), not the content view. Trigger a reshape so the draw thread
	 * can coalesce and rebuild the backing store/texture.
	 */
	[myview reshape];
}

- (void) windowDidResignKey:(id)arg
{
	[myview clearMods];
}

@end

@implementation DrawtermView
{
	NSMutableString *_tmpText;
	NSRange _markedRange;
	NSRange _selectedRange;
	NSRect _lastInputRect;	// The view is flipped, this is not.
	BOOL _tapping;
	NSUInteger _tapFingers;
	NSUInteger _tapTime;
	BOOL _breakcompose;
	NSEventModifierFlags _mods;
}

- (id) initWithFrame:(NSRect)fr
{
	LOG(@"BEGIN");
	self = [super initWithFrame:fr];
	[self setWantsLayer:YES];
	[self setLayerContentsRedrawPolicy:NSViewLayerContentsRedrawOnSetNeedsDisplay];
	[self setAllowedTouchTypes:NSTouchTypeMaskDirect|NSTouchTypeMaskIndirect];
	_tmpText = [[NSMutableString alloc] initWithCapacity:2];
	_markedRange = NSMakeRange(NSNotFound, 0);
	_selectedRange = NSMakeRange(0, 0);
	_breakcompose = NO;
	_mods = 0;
	LOG(@"END");
	return self;
}

- (CALayer *) makeBackingLayer
{
	return [DrawLayer layer];
}

- (BOOL)wantsUpdateLayer
{
	return YES;
}

- (BOOL)isOpaque
{
	return YES;
}

- (BOOL)isFlipped
{
	return YES;
}

static uint
evkey(uint v)
{
	switch(v){
	case '\r': return '\n';
	case 127: return '\b';
	case NSUpArrowFunctionKey: return Kup;
	case NSDownArrowFunctionKey: return Kdown;
	case NSLeftArrowFunctionKey: return Kleft;
	case NSRightArrowFunctionKey: return Kright;
	case NSF1FunctionKey: return KF|1;
	case NSF2FunctionKey: return KF|2;
	case NSF3FunctionKey: return KF|3;
	case NSF4FunctionKey: return KF|4;
	case NSF5FunctionKey: return KF|5;
	case NSF6FunctionKey: return KF|6;
	case NSF7FunctionKey: return KF|7;
	case NSF8FunctionKey: return KF|8;
	case NSF9FunctionKey: return KF|9;
	case NSF10FunctionKey: return KF|10;
	case NSF11FunctionKey: return KF|11;
	case NSF12FunctionKey: return KF|12;
	case NSInsertFunctionKey: return Kins;
	case NSDeleteFunctionKey: return Kdel;
	case NSHomeFunctionKey: return Khome;
	case NSEndFunctionKey: return Kend;
	case NSPageUpFunctionKey: return Kpgup;
	case NSPageDownFunctionKey: return Kpgdown;
	case NSScrollLockFunctionKey: return Kscroll;
	case NSBeginFunctionKey:
	case NSF13FunctionKey:
	case NSF14FunctionKey:
	case NSF15FunctionKey:
	case NSF16FunctionKey:
	case NSF17FunctionKey:
	case NSF18FunctionKey:
	case NSF19FunctionKey:
	case NSF20FunctionKey:
	case NSF21FunctionKey:
	case NSF22FunctionKey:
	case NSF23FunctionKey:
	case NSF24FunctionKey:
	case NSF25FunctionKey:
	case NSF26FunctionKey:
	case NSF27FunctionKey:
	case NSF28FunctionKey:
	case NSF29FunctionKey:
	case NSF30FunctionKey:
	case NSF31FunctionKey:
	case NSF32FunctionKey:
	case NSF33FunctionKey:
	case NSF34FunctionKey:
	case NSF35FunctionKey:
	case NSPrintScreenFunctionKey:
	case NSPauseFunctionKey:
	case NSSysReqFunctionKey:
	case NSBreakFunctionKey:
	case NSResetFunctionKey:
	case NSStopFunctionKey:
	case NSMenuFunctionKey:
	case NSUserFunctionKey:
	case NSSystemFunctionKey:
	case NSPrintFunctionKey:
	case NSClearLineFunctionKey:
	case NSClearDisplayFunctionKey:
	case NSInsertLineFunctionKey:
	case NSDeleteLineFunctionKey:
	case NSInsertCharFunctionKey:
	case NSDeleteCharFunctionKey:
	case NSPrevFunctionKey:
	case NSNextFunctionKey:
	case NSSelectFunctionKey:
	case NSExecuteFunctionKey:
	case NSUndoFunctionKey:
	case NSRedoFunctionKey:
	case NSFindFunctionKey:
	case NSHelpFunctionKey:
	case NSModeSwitchFunctionKey: return 0;
	default: return v;
	}
}

- (void)keyDown:(NSEvent*)event {
	[self interpretKeyEvents:[NSArray arrayWithObject:event]];
	[self resetLastInputRect];
}

- (void)flagsChanged:(NSEvent*)event {
	NSEventModifierFlags x;
	NSUInteger u;

	x = [event modifierFlags];
	u = [NSEvent pressedMouseButtons];
	u = (u&~6) | (u&4)>>1 | (u&2)<<1;
	if((x & ~_mods & NSEventModifierFlagShift) != 0)
		kbdkey(Kshift, 1);
	if((x & ~_mods & NSEventModifierFlagControl) != 0){
		if(u){
			u |= 1;
			[self sendmouse:u];
			return;
		}else
			kbdkey(Kctl, 1);
	}
	if((x & ~_mods & NSEventModifierFlagOption) != 0){
		if(u){
			u |= 2;
			[self sendmouse:u];
			return;
		}else
			kbdkey(Kalt, 1);
	}
	if((x & NSEventModifierFlagCommand) != 0){
		if(u){
			u |= 4;
			[self sendmouse:u];
		}else
			kbdkey(Kmod4, 1);
	}
	if((x & ~_mods & NSEventModifierFlagCapsLock) != 0)
		kbdkey(Kcaps, 1);
	if((~x & _mods & NSEventModifierFlagShift) != 0)
		kbdkey(Kshift, 0);
	if((~x & _mods & NSEventModifierFlagControl) != 0)
		kbdkey(Kctl, 0);
	if((~x & _mods & NSEventModifierFlagOption) != 0){
		kbdkey(Kalt, 0);
		if(_breakcompose){
			kbdkey(Kalt, 1);
			kbdkey(Kalt, 0);
			_breakcompose = NO;
		}
	}
	if((~x & NSEventModifierFlagCommand) != 0)
		kbdkey(Kmod4, 0);
	if((~x & _mods & NSEventModifierFlagCapsLock) != 0)
		kbdkey(Kcaps, 0);
	_mods = x;
}

- (void) clearMods {
	if((_mods & NSEventModifierFlagShift) != 0){
		kbdkey(Kshift, 0);
		_mods ^= NSEventModifierFlagShift;
	}
	if((_mods & NSEventModifierFlagControl) != 0){
		kbdkey(Kctl, 0);
		_mods ^= NSEventModifierFlagControl;
	}
	if((_mods & NSEventModifierFlagOption) != 0){
		kbdkey(Kalt, 0);
		_mods ^= NSEventModifierFlagOption;
	}
	if((_mods & NSEventModifierFlagCommand) != 0){
		kbdkey(Kmod4, 0);
		_mods ^= NSEventModifierFlagCommand;
	}
}

- (void) mouseevent:(NSEvent*)event
{
	NSPoint p;
	Point q;
	NSUInteger u;
	NSEventModifierFlags m;

	p = [self convertPoint:[event locationInWindow] fromView:nil];
	u = [NSEvent pressedMouseButtons];
	double lscale = logicalscale();
	q.x = p.x/lscale;
	q.y = p.y/lscale;
	if(!ptinrect(q, gscreen->clipr)) return;
	u = (u&~6) | (u&4)>>1 | (u&2)<<1;
	if(u == 1){
		m = [event modifierFlags];
		if(m & NSEventModifierFlagOption){
			_breakcompose = 1;
			u = 2;
		}else if(m & NSEventModifierFlagCommand)
			u = 4;
	}
	absmousetrack(q.x, q.y, u, ticks());
	if(u && _lastInputRect.size.width && _lastInputRect.size.height)
		[self resetLastInputRect];
}

- (void) sendmouse:(NSUInteger)u
{
	mousetrack(0, 0, u, ticks());
	if(u && _lastInputRect.size.width && _lastInputRect.size.height)
		[self resetLastInputRect];
}

- (void) mouseDown:(NSEvent*)event { [self mouseevent:event]; }
- (void) mouseDragged:(NSEvent*)event { [self mouseevent:event]; }
- (void) mouseUp:(NSEvent*)event { [self mouseevent:event]; }
- (void) mouseMoved:(NSEvent*)event { [self mouseevent:event]; }
- (void) rightMouseDown:(NSEvent*)event { [self mouseevent:event]; }
- (void) rightMouseDragged:(NSEvent*)event { [self mouseevent:event]; }
- (void) rightMouseUp:(NSEvent*)event { [self mouseevent:event]; }
- (void) otherMouseDown:(NSEvent*)event { [self mouseevent:event]; }
- (void) otherMouseDragged:(NSEvent*)event { [self mouseevent:event]; }
- (void) otherMouseUp:(NSEvent*)event { [self mouseevent:event]; }

- (void) scrollWheel:(NSEvent*)event{
	NSInteger s = [event scrollingDeltaY];
	if(s > 0)
		[self sendmouse:8];
	else if(s < 0)
		[self sendmouse:16];
}

- (void)magnifyWithEvent:(NSEvent*)e{
	if(fabs([e magnification]) > 0.02)
		[[self window] toggleFullScreen:nil];
}

- (void)touchesBeganWithEvent:(NSEvent*)e
{
	_tapping = YES;
	_tapFingers = [e touchesMatchingPhase:NSTouchPhaseTouching inView:nil].count;
	_tapTime = ticks();
}

- (void)touchesMovedWithEvent:(NSEvent*)e
{
	_tapping = NO;
}

- (void)touchesEndedWithEvent:(NSEvent*)e
{
	if(_tapping
		&& [e touchesMatchingPhase:NSTouchPhaseTouching inView:nil].count == 0
		&& ticks() - _tapTime < 250){
		switch(_tapFingers){
		case 3:
			[self sendmouse:2];
			[self sendmouse:0];
			break;
		case 4:
			[self sendmouse:2];
			[self sendmouse:1];
			[self sendmouse:0];
			break;
		}
		_tapping = NO;
	}
}

- (void)touchesCancelledWithEvent:(NSEvent*)e
{
	_tapping = NO;
}

- (BOOL) acceptsFirstResponder
{
	return TRUE;
}

- (void) resetCursorRects
{
	[super resetCursorRects];
	lock(&cursor.lk);
	[self addCursorRect:self.bounds cursor:currentCursor];
	unlock(&cursor.lk);
}

- (void) reshape
{
	NSSize s = self.frame.size;
	uiscale = preferredscale(self.window.backingScaleFactor);
	devscale = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 1.0;
	LOG(@"%g %g", s.width, s.height);
	if(gscreen != nil){
		double lscale = logicalscale();
		int w = (int)(s.width/lscale);
		int h = (int)(s.height/lscale);
		if(w < 1) w = 1;
		if(h < 1) h = 1;
		screenresize(Rect(0, 0, w, h));
		forcefullredraw = 1;
	}
}

- (void)windowDidResize:(NSNotification *)notification
{
	/*
	 * Some window managers resize the window interactively but we only
	 * reshaped at the end of live-resize, causing stale/blank contents.
	 * Always reshape; screenresize is coalesced by the resize proc.
	 */
	[self reshape];
	/* Keep the layer presenting even if the draw thread lags. */
	[self setNeedsDisplay:YES];
}

- (void)viewDidEndLiveResize
{
	LOG();
	[super viewDidEndLiveResize];
	[self reshape];
}

- (void)viewDidChangeBackingProperties
{
	LOG();
	[super viewDidChangeBackingProperties];
	[self reshape];
}

static void
keystroke(Rune r)
{
	kbdkey(r, 1);
	kbdkey(r, 0);
}

// conforms to protocol NSTextInputClient
- (BOOL)hasMarkedText
{
	return _markedRange.location != NSNotFound;
}
- (NSRange)markedRange
{
	return _markedRange;
}
- (NSRange)selectedRange
{
	return _selectedRange;
}
- (void)setMarkedText:(id)string
	selectedRange:(NSRange)sRange
	replacementRange:(NSRange)rRange
{
	NSString *str;

	[self clearInput];

	if([string isKindOfClass:[NSAttributedString class]])
		str = [string string];
	else
		str = string;

	if(rRange.location == NSNotFound){
		if(_markedRange.location != NSNotFound){
			rRange = _markedRange;
		}else{
			rRange = _selectedRange;
		}
	}

	if(str.length == 0){
		[_tmpText deleteCharactersInRange:rRange];
		[self unmarkText];
	}else{
		_markedRange = NSMakeRange(rRange.location, str.length);
		[_tmpText replaceCharactersInRange:rRange withString:str];
	}
	_selectedRange.location = rRange.location + sRange.location;
	_selectedRange.length = sRange.length;

	if(_tmpText.length){
		for(uint i = 0; i <= _tmpText.length; ++i){
			if(i == _markedRange.location)
				keystroke('[');
			if(_selectedRange.length){
				if(i == _selectedRange.location)
					keystroke('{');
				if(i == NSMaxRange(_selectedRange))
					keystroke('}');
				}
			if(i == NSMaxRange(_markedRange))
				keystroke(']');
			if(i < _tmpText.length)
				keystroke([_tmpText characterAtIndex:i]);
		}
		uint l = 1 + _tmpText.length - NSMaxRange(_selectedRange)
			+ (_selectedRange.length > 0);
		for(uint i = 0; i < l; ++i)
			keystroke(Kleft);
	}
}
- (void)unmarkText
{
	[_tmpText deleteCharactersInRange:NSMakeRange(0, [_tmpText length])];
	_markedRange = NSMakeRange(NSNotFound, 0);
	_selectedRange = NSMakeRange(0, 0);
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText
{
	return @[];
}
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)r
	actualRange:(NSRangePointer)actualRange
{
	NSRange sr;
	NSAttributedString *s;

	sr = NSMakeRange(0, [_tmpText length]);
	sr = NSIntersectionRange(sr, r);
	if(actualRange)
		*actualRange = sr;
	if(sr.length)
		s = [[NSAttributedString alloc]
			initWithString:[_tmpText substringWithRange:sr]];
	return s;
}
- (void)insertText:(id)s
	replacementRange:(NSRange)r
{
	NSUInteger i;
	NSUInteger len;

	[self clearInput];

	len = [s length];
	for(i = 0; i < len; ++i)
		keystroke([s characterAtIndex:i]);
	[_tmpText deleteCharactersInRange:NSMakeRange(0, _tmpText.length)];
	_markedRange = NSMakeRange(NSNotFound, 0);
	_selectedRange = NSMakeRange(0, 0);
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
	return 0;
}
- (NSRect)firstRectForCharacterRange:(NSRange)r
	actualRange:(NSRangePointer)actualRange
{
	if(actualRange)
		*actualRange = r;
	return [[self window] convertRectToScreen:_lastInputRect];
}
- (void)doCommandBySelector:(SEL)s
{
	NSEvent *e;
	uint c, k;

	e = [NSApp currentEvent];
	c = [[e charactersIgnoringModifiers] characterAtIndex:0];
	k = evkey(c);
	if(k>0)
		keystroke(k);
}

// Helper for managing input rect approximately
- (void)resetLastInputRect
{
	_lastInputRect.origin.x = 0.0;
	_lastInputRect.origin.y = 0.0;
	_lastInputRect.size.width = 0.0;
	_lastInputRect.size.height = 0.0;
}

- (void)enlargeLastInputRect:(NSRect)r
{
	r.origin.y = [self bounds].size.height - r.origin.y - r.size.height;
	_lastInputRect = NSUnionRect(_lastInputRect, r);
}

- (void)clearInput
{
	if(_tmpText.length){
		uint l = 1 + _tmpText.length - NSMaxRange(_selectedRange)
			+ (_selectedRange.length > 0);
		for(uint i = 0; i < l; ++i)
			keystroke(Kright);
		l = _tmpText.length+2+2*(_selectedRange.length > 0);
		for(uint i = 0; i < l; ++i)
			keystroke(Kbs);
	}
}
@end

@implementation DrawLayer
{
	id<MTLCommandQueue> _commandQueue;
}

- (id) init {
	LOG();
	self = [super init];
	self.device = MTLCreateSystemDefaultDevice();
	self.pixelFormat = MTLPixelFormatBGRA8Unorm;
	self.framebufferOnly = YES;
	self.opaque = YES;

	// We use a default transparent layer on top of the CAMetalLayer.
	// This seems to make fullscreen applications behave.
	{
		CALayer *stub = [CALayer layer];
		stub.frame = CGRectMake(0, 0, 1, 1);
		[stub setNeedsDisplay];
		[self addSublayer:stub];
	}

	_commandQueue = [self.device newCommandQueue];

	return self;
}

- (void) display
{
	id<MTLCommandBuffer> cbuf;
	id<MTLBlitCommandEncoder> blit;
	if(_texture == nil || _texture.width == 0 || _texture.height == 0)
		return;

	cbuf = [_commandQueue commandBuffer];

@autoreleasepool{
	id<CAMetalDrawable> drawable = [self nextDrawable];
	if(!drawable){
		LOG(@"display couldn't get drawable");
		[self setNeedsDisplay];
		return;
	}
	if(drawable.texture == nil || drawable.texture.width == 0 || drawable.texture.height == 0)
		return;

	blit = [cbuf blitCommandEncoder];
	[blit copyFromTexture:_texture
		sourceSlice:0
		sourceLevel:0
		sourceOrigin:MTLOriginMake(0, 0, 0)
		sourceSize:MTLSizeMake(_texture.width, _texture.height, _texture.depth)
		toTexture:drawable.texture
		destinationSlice:0
		destinationLevel:0
		destinationOrigin:MTLOriginMake(0, 0, 0)];
	[blit endEncoding];

	[cbuf presentDrawable:drawable];
	drawable = nil;
}
	[cbuf addCompletedHandler:^(id<MTLCommandBuffer> cmdBuff){
		if(cmdBuff.error){
			NSLog(@"command buffer finished with error: %@",
				cmdBuff.error.localizedDescription);
		}else{
			LOG(@"command buffer finished");
		}
	}];
	[cbuf commit];
}

@end
