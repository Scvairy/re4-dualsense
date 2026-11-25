#import <CoreHaptics/CoreHaptics.h>
#import <GameController/GameController.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "hd_haptics.h"

// HD haptics: every game vibration goes through the script method
// soundlib.SoundVibrationManager.triggerVibration with a 32-bit trigger hash.
// On PS5 the hash selects a waveform track for the controller's voice coils.
// The Mac build plays an approximation through Core Haptics instead.
//
// When launch.command starts the haptics helper, it passes a pipe on fd 4.
// Each trigger is forwarded to the helper, which looks up the track and streams
// it to the DualSense over Bluetooth. The game's own Core Haptics rumble is
// muted meanwhile, because ordinary rumble takes the controller out of
// waveform mode.

enum {
    HelperFD = 4,
    TriggerVibration = 0x12165a0,  // offset in the tested arm64 build 26011300.13.1
    MessageTrigger = 4,
    MessageOutputTouched = 5,
};

static uint8_t *image;
static bool connected;
static bool tracing;

__attribute__((visibility("hidden"))) void *triggerResume;
extern void triggerEntry(void);

// Saves the argument registers, reports the trigger, then runs the four
// prologue instructions it replaced and continues in the original function.
__asm__(".text\n.p2align 3\n.private_extern _triggerEntry\n_triggerEntry:\n"
        "sub sp, sp, #0x90\n"
        "stp x0, x1, [sp]\nstp x2, x3, [sp, #16]\nstp x4, x5, [sp, #32]\nstp x6, x7, [sp, #48]\n"
        "stp x8, x30, [sp, #64]\nstp d0, d1, [sp, #80]\nstp d2, d3, [sp, #96]\n"
        "stp x29, x30, [sp, #112]\nadd x29, sp, #112\n"
        "mov x0, x2\nmov x1, x3\nbl _hdHapticsTrigger\n"
        "ldp x0, x1, [sp]\nldp x2, x3, [sp, #16]\nldp x4, x5, [sp, #32]\nldp x6, x7, [sp, #48]\n"
        "ldp x8, x30, [sp, #64]\nldp d0, d1, [sp, #80]\nldp d2, d3, [sp, #96]\n"
        "ldr x29, [sp, #112]\nadd sp, sp, #0x90\n"
        ".long 0xd103c3ff\n.long 0x6d053bef\n.long 0x6d0633ed\n.long 0x6d072beb\n"
        "adrp x16, _triggerResume@PAGE\nldr x16, [x16, _triggerResume@PAGEOFF]\nbr x16\n");

static const uint32_t triggerPrologue[4] = {0xd103c3ff, 0x6d053bef, 0x6d0633ed, 0x6d072beb};

// Called with the trigger hash and pad index. The default power arrives in s0,
// which the stub leaves untouched for this call.
__attribute__((used, visibility("hidden"))) void hdHapticsTrigger(uint64_t hash, uint64_t pad, float power) {
    struct __attribute__((packed)) {
        uint32_t type, length, hash;
        float power;
        int32_t pad;
    } message = {MessageTrigger, 12, (uint32_t)hash, power, (int32_t)pad};
    // A full pipe drops the trigger rather than stalling the game.
    ssize_t written = write(HelperFD, &message, sizeof message);
    if (tracing) {
        fprintf(stderr, "[haptics] trigger %#010x power %.2f pad %d%s\n", (uint32_t)hash, power, (int32_t)pad,
                written == sizeof message ? "" : " (dropped)");
    }
}

void hdHapticsOutputTouched(void) {
    if (connected) {
        const uint32_t message[2] = {MessageOutputTouched, 0};
        (void)write(HelperFD, message, sizeof message);
    }
}

static bool writeCode(uintptr_t offset, const uint32_t *words, size_t count) {
    uint32_t *target = (uint32_t *)(image + offset);
    mach_vm_address_t mask = ~((mach_vm_address_t)vm_page_size - 1);
    mach_vm_address_t first = (mach_vm_address_t)target & mask;
    mach_vm_address_t last = ((mach_vm_address_t)(target + count) - 1) & mask;
    mach_vm_size_t size = last - first + vm_page_size;
    if (mach_vm_protect(mach_task_self(), first, size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)) {
        return false;
    }
    memcpy(target, words, count * sizeof(*words));
    sys_icache_invalidate(target, count * sizeof(*words));
    return mach_vm_protect(mach_task_self(), first, size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS;
}

// While the helper runs, the game gets no Core Haptics engines for the
// controller. An active engine makes gamecontrollerd send rumble reports at a
// fixed rate, which floods the Bluetooth link and keeps the controller out of
// waveform mode. The game handles a missing engine as a controller without
// haptics.
static id noEngine(id haptics, SEL selector, GCHapticsLocality locality) {
    (void)haptics, (void)selector, (void)locality;
    return nil;
}

// Fallback in case the game gets an engine some other way: the game creates a
// new player for every rumble change, and those players are never started.
static BOOL (*originalStart)(id, SEL, NSTimeInterval, NSError **);
static id (*originalCreatePlayer)(id, SEL, CHHapticPattern *, NSError **);

static BOOL mutedStart(id player, SEL selector, NSTimeInterval time, NSError **error) {
    (void)player, (void)selector, (void)time, (void)error;
    return YES;
}

static id createPlayer(id engine, SEL selector, CHHapticPattern *pattern, NSError **error) {
    id player = originalCreatePlayer(engine, selector, pattern, error);
    static dispatch_once_t once;
    if (player) {
        dispatch_once(&once, ^{
            Method start = class_getInstanceMethod(object_getClass(player), @selector(startAtTime:error:));
            if (start) {
                originalStart = (void *)method_setImplementation(start, (IMP)mutedStart);
            }
        });
    }
    return player;
}

static void muteRumble(void) {
    Method engine = class_getInstanceMethod([GCDeviceHaptics class], @selector(createEngineWithLocality:));
    if (engine) {
        method_setImplementation(engine, (IMP)noEngine);
    }
    Method create = class_getInstanceMethod([CHHapticEngine class], @selector(createPlayerWithPattern:error:));
    if (create) {
        originalCreatePlayer = (void *)method_setImplementation(create, (IMP)createPlayer);
    }
}

__attribute__((constructor))
static void enableHDHaptics(void) {
    const char *setting = getenv("RE4_DUALSENSE_HD_HAPTICS");
    if (!getenv("RE4_DUALSENSE_OVERLAY") || !setting || strcmp(setting, "1") != 0) {
        return;
    }
    if (fcntl(HelperFD, F_GETFD) < 0) {
        fprintf(stderr, "RE4 DualSense: HD haptics helper isn't connected; using standard rumble.\n");
        return;
    }
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const struct mach_header *candidate = _dyld_get_image_header(index);
        if (candidate && candidate->filetype == MH_EXECUTE) {
            image = (uint8_t *)candidate;
            break;
        }
    }
    if (!image || memcmp(image + TriggerVibration, triggerPrologue, sizeof triggerPrologue) != 0) {
        fprintf(stderr, "RE4 DualSense: HD haptics need the tested game build; using standard rumble.\n");
        return;
    }

    // Writes must never block the game or kill it if the helper exits.
    fcntl(HelperFD, F_SETFL, fcntl(HelperFD, F_GETFL) | O_NONBLOCK);
    fcntl(HelperFD, F_SETNOSIGPIPE, 1);
    fcntl(HelperFD, F_SETFD, FD_CLOEXEC);
    tracing = getenv("RE4_DUALSENSE_TRACE") != NULL;

    triggerResume = image + TriggerVibration + 16;
    uint64_t address = (uint64_t)triggerEntry;
    const uint32_t jump[4] = {0x58000050, 0xd61f0200, (uint32_t)address, (uint32_t)(address >> 32)};
    if (!writeCode(TriggerVibration, jump, 4)) {
        fprintf(stderr, "RE4 DualSense: couldn't hook vibration triggers; using standard rumble.\n");
        return;
    }
    muteRumble();
    connected = true;
    fprintf(stderr, "RE4 DualSense: HD haptics enabled.\n");
}
