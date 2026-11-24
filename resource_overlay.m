#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *overlayPath;
static NSString *(*originalResourcePath)(NSBundle *, SEL);
static NSString *const patchName = @"re_chunk_000.pak.patch_001.pak";

static NSString *resourcePathWithPatch(NSBundle *bundle, SEL selector) {
    if (bundle == NSBundle.mainBundle) {
        return overlayPath;
    }
    return originalResourcePath(bundle, selector);
}

static void removeOverlay(void) {
    @autoreleasepool {
        if (overlayPath) {
            [NSFileManager.defaultManager removeItemAtPath:overlayPath error:nil];
        }
    }
}

static void fail(NSString *message) {
    fprintf(stderr, "RE4 DualSense: %s\n", message.UTF8String);
    removeOverlay();
    _exit(EXIT_FAILURE);
}

__attribute__((constructor))
static void prepareResources(void) {
    // The launcher opens the patch for reading before the game enters its sandbox.
    if (!getenv("RE4_DUALSENSE_OVERLAY")) {
        return;
    }

    @autoreleasepool {
        NSBundle *game = NSBundle.mainBundle;
        NSString *build = [game objectForInfoDictionaryKey:@"CFBundleVersion"];
        if (![game.bundleIdentifier isEqualToString:@"jp.co.capcom.RE4US"] ||
            ![build isEqualToString:@"26011300.13.1"]) {
            fail(@"Expected the Mac App Store build of RE4 1.0.7.");
        }

        int patchDescriptor = 3;
        struct stat patchInfo;
        if (fstat(patchDescriptor, &patchInfo) != 0 || !S_ISREG(patchInfo.st_mode) ||
            patchInfo.st_size < 16 || patchInfo.st_size > 1024 * 1024) {
            fail(@"The patch file is missing or has an invalid size.");
        }
        NSFileHandle *patchFile = [[NSFileHandle alloc] initWithFileDescriptor:patchDescriptor
                                                               closeOnDealloc:YES];
        NSError *error = nil;
        NSData *patch = [patchFile readDataToEndOfFileAndReturnError:&error];
        if (patch.length != (NSUInteger)patchInfo.st_size ||
            memcmp(patch.bytes, "KPKA", 4) != 0) {
            fail(error.localizedDescription ?: @"The patch file is not a RE Engine PAK.");
        }
        [patchFile closeFile];

        NSFileManager *files = NSFileManager.defaultManager;
        NSString *resources = game.resourcePath;
        NSArray<NSString *> *names = [files contentsOfDirectoryAtPath:resources error:&error];
        if (!names) {
            fail(error.localizedDescription);
        }
        if ([names containsObject:patchName]) {
            fail(@"The game already has a patch in slot 001.");
        }

        NSString *folder = [@"re4-dualsense-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:folder];
        if (![files createDirectoryAtPath:path withIntermediateDirectories:NO
                               attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
            fail(error.localizedDescription);
        }
        overlayPath = path;

        for (NSString *name in names) {
            if (![files createSymbolicLinkAtPath:[path stringByAppendingPathComponent:name]
                             withDestinationPath:[resources stringByAppendingPathComponent:name]
                                           error:&error]) {
                fail(error.localizedDescription);
            }
        }
        NSString *patchPath = [path stringByAppendingPathComponent:patchName];
        if (![patch writeToFile:patchPath options:NSDataWritingWithoutOverwriting error:&error]) {
            fail(error.localizedDescription);
        }

        Method method = class_getInstanceMethod(NSBundle.class, @selector(resourcePath));
        if (!method || atexit(removeOverlay) != 0) {
            fail(@"Couldn't register the temporary resource directory.");
        }
        originalResourcePath = (void *)method_getImplementation(method);
        method_setImplementation(method, (IMP)resourcePathWithPatch);
        fprintf(stderr, "RE4 DualSense: temporary patch ready.\n");
    }
}
