#include "native_profiles.h"

#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Offsets are for the arm64 App Store build 26011300.13.1, relative to its
// Mach header. launch.command verifies the complete executable hash first.
//
// Each frame the gameplay trigger updater reads the equipped weapon's
// adaptive-feedback profile and stores (power, frequency, range start,
// range end) for L2 and R2. On PS5 a later step sends those values to
// via.hid.DualSenseDevice. On Mac the pad is a generic GamePadDevice, so that
// step never runs. We take the stored values and drive GameController instead.
enum {
    PlatformFunction = 0x827a1c4,
    PlatformCheck = 0x2c2b278,  // inside TriggerUpdater: cmp w9, #5 (PS5)
    PullCheck = 0x2c2b4b4,      // inside TriggerUpdater: keep frequency only past range start
    TriggerUpdater = 0x2c2b238,
    ProfileStore = 0x6271448,   // (context, pad, trigger, power, frequency, start, end)
};

// Each hook overwrites four instructions with `ldr x16, #8; br x16; .quad hook`.
// The copied prologue instructions are position independent.
#define TRAMPOLINE(name, w0, w1, w2, w3)                                              \
    __attribute__((visibility("hidden"))) void *name##Resume;                         \
    extern void name##Original(void);                                                 \
    __asm__(".text\n.p2align 2\n.private_extern _" #name "Original\n_" #name          \
            "Original:\n.long " #w0 "\n.long " #w1 "\n.long " #w2 "\n.long " #w3      \
            "\nadrp x16, _" #name "Resume@PAGE\nldr x16, [x16, _" #name               \
            "Resume@PAGEOFF]\nbr x16\n")

#define UPDATER_PROLOGUE 0xd10183ff, 0x6d0123e9, 0xa9025ff8, 0xa90357f6
#define STORE_PROLOGUE 0xd10203ff, 0x6d012beb, 0x6d0223e9, 0xa90367fa
TRAMPOLINE(updater, 0xd10183ff, 0x6d0123e9, 0xa9025ff8, 0xa90357f6);
TRAMPOLINE(store, 0xd10203ff, 0x6d012beb, 0x6d0223e9, 0xa90367fa);

typedef uint64_t (*UpdaterFunction)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t,
                                    uint64_t, uint64_t, uint64_t);
typedef uint64_t (*StoreFunction)(void *, void *, uint64_t, float, float, float, float);

static uint8_t *image;
static bool enabled;
static os_unfair_lock effectLock = OS_UNFAIR_LOCK_INIT;
static NativeTriggerEffect currentEffects[2];
static uint64_t currentGeneration = 1;
static _Thread_local unsigned storedTriggers;
static _Atomic float pulls[2];

static void stop(const char *message, kern_return_t result) {
    fprintf(stderr, "RE4 DualSense: %s (%s).\n", message, mach_error_string(result));
    _exit(EXIT_FAILURE);
}

static void writeCode(uintptr_t offset, const uint32_t *words, size_t count) {
    uint32_t *target = (uint32_t *)(image + offset);
    mach_vm_address_t mask = ~((mach_vm_address_t)vm_page_size - 1);
    mach_vm_address_t first = (mach_vm_address_t)target & mask;
    mach_vm_address_t last = ((mach_vm_address_t)(target + count) - 1) & mask;
    mach_vm_size_t size = last - first + vm_page_size;
    kern_return_t result = mach_vm_protect(mach_task_self(), first, size, FALSE,
                                          VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (result != KERN_SUCCESS) {
        stop("couldn't make a private copy of game code", result);
    }
    memcpy(target, words, count * sizeof(*words));
    sys_icache_invalidate(target, count * sizeof(*words));
    result = mach_vm_protect(mach_task_self(), first, size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (result != KERN_SUCCESS) {
        stop("couldn't restore executable protection to game code", result);
    }
}

static void requireCode(uintptr_t offset, const uint32_t *words, size_t count) {
    if (memcmp(image + offset, words, count * sizeof(*words)) != 0) {
        stop("game code does not match the tested build", KERN_INVALID_ARGUMENT);
    }
}

static void hook(uintptr_t offset, const uint32_t original[4], void *replacement, void **resume) {
    requireCode(offset, original, 4);
    *resume = image + offset + 16;
    uint64_t address = (uint64_t)replacement;
    const uint32_t jump[4] = {0x58000050, 0xd61f0200, (uint32_t)address, (uint32_t)(address >> 32)};
    writeCode(offset, jump, 4);
}

static float unit(float value) {
    // Matches the engine's clamp, which maps negative values to zero.
    return value < 0 ? 0 : fminf(value, 1);
}

static int clampInt(int value, int low, int high) {
    return value < low ? low : value > high ? high : value;
}

// Mirrors the engine's conversion to Sony trigger commands, with 10 position
// zones and 8 strength steps, then normalizes back to GameController's 0–1.
static NativeTriggerEffect convertEffect(float power, float frequency, float start, float end) {
    int force = (int)(unit(power) * 8);
    int startZone = (int)(unit(start) * 9);
    int pulse = (int)ceilf(unit(frequency) * 255);
    if (!force) {
        return (NativeTriggerEffect){NativeTriggerOff, {0}};
    }
    if (pulse) {
        return (NativeTriggerEffect){NativeTriggerVibration,
                                     {startZone / 9.0f, force / 8.0f, pulse / 255.0f}};
    }
    int endZone = (int)(unit(end) * 9);
    if (endZone == 9) {
        return (NativeTriggerEffect){NativeTriggerFeedback, {startZone / 9.0f, force / 8.0f}};
    }
    int first = clampInt(startZone, 2, 7);
    int last = first < endZone ? clampInt(endZone, 0, 8) : first + 1;
    return (NativeTriggerEffect){NativeTriggerWeapon, {first / 9.0f, last / 9.0f, force / 8.0f}};
}

static void publish(unsigned trigger, NativeTriggerEffect effect, const float raw[5]) {
    os_unfair_lock_lock(&effectLock);
    bool changed = memcmp(&currentEffects[trigger], &effect, sizeof(effect)) != 0;
    if (changed) {
        currentEffects[trigger] = effect;
        ++currentGeneration;
    }
    os_unfair_lock_unlock(&effectLock);

    if (changed && getenv("RE4_DUALSENSE_TRACE")) {
        static const char *kinds[] = {"off", "feedback", "weapon", "vibration"};
        fprintf(stderr, "[trigger] %s %s %.2f %.2f %.2f (power %.2f freq %.2f range %.2f-%.2f pull %.2f)\n",
                trigger ? "R2" : "L2", kinds[effect.kind], effect.values[0], effect.values[1],
                effect.values[2], raw[0], raw[1], raw[2], raw[3], raw[4]);
    }
}

static uint64_t storeHook(void *context, void *pad, uint64_t trigger, float power,
                          float frequency, float start, float end) {
    uint64_t result = ((StoreFunction)storeOriginal)(context, pad, trigger, power, frequency,
                                                     start, end);
    if (trigger < 2) {
        storedTriggers |= 1u << trigger;
        // The game vibrates a trigger only once it's pulled past the range start.
        // Its own pull value stays low on Mac, so use the controller's.
        float pull = atomic_load_explicit(&pulls[trigger], memory_order_relaxed);
        float active = pull >= start ? frequency : 0;
        const float raw[5] = {power, frequency, start, end, pull};
        publish((unsigned)trigger, convertEffect(power, active, start, end), raw);
    }
    return result;
}

// The updater stores a profile only while a weapon with one is active.
// Any trigger it skips this frame goes back to no resistance.
static uint64_t updaterHook(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4,
                            uint64_t a5, uint64_t a6, uint64_t a7) {
    storedTriggers = 0;
    uint64_t result = ((UpdaterFunction)updaterOriginal)(a0, a1, a2, a3, a4, a5, a6, a7);
    static const float none[5] = {0};
    for (unsigned trigger = 0; trigger < 2; ++trigger) {
        if (!(storedTriggers & (1u << trigger))) {
            publish(trigger, (NativeTriggerEffect){NativeTriggerOff, {0}}, none);
        }
    }
    return result;
}

void nativeTriggersSetPull(float left, float right) {
    atomic_store_explicit(&pulls[0], left, memory_order_relaxed);
    atomic_store_explicit(&pulls[1], right, memory_order_relaxed);
}

bool nativeTriggersEnabled(void) {
    return enabled;
}

bool nativeTriggersSnapshot(uint64_t *generation, NativeTriggerEffect effects[2]) {
    os_unfair_lock_lock(&effectLock);
    bool changed = *generation != currentGeneration;
    if (changed) {
        memcpy(effects, currentEffects, sizeof(currentEffects));
        *generation = currentGeneration;
    }
    os_unfair_lock_unlock(&effectLock);
    return changed;
}

__attribute__((constructor))
static void enableNativeProfiles(void) {
    const char *setting = getenv("RE4_DUALSENSE_NATIVE_PROFILES");
    if (!getenv("RE4_DUALSENSE_OVERLAY") || (setting && strcmp(setting, "0") == 0)) {
        return;
    }

    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const struct mach_header *candidate = _dyld_get_image_header(index);
        if (candidate && candidate->filetype == MH_EXECUTE) {
            image = (uint8_t *)candidate;
            break;
        }
    }
    const struct mach_header *header = (const struct mach_header *)image;
    if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) {
        stop("unexpected main executable", KERN_INVALID_ARGUMENT);
    }
    const uint32_t platformCall = 0x52832140;
    const uint32_t platformCheck = 0x7100153f;
    const uint32_t pullCheck = 0x54000045;
    requireCode(PlatformFunction, &platformCall, 1);
    requireCode(PlatformCheck, &platformCheck, 1);
    requireCode(PullCheck, &pullCheck, 1);

    // The Mac platform value is 0x190a; the updater otherwise stops unless it is 5.
    // cmp w9, #5 -> cmp w9, #10. The in-game adaptive trigger option still applies.
    const uint32_t macCheck = 0x7100293f;
    writeCode(PlatformCheck, &macCheck, 1);
    // b.pl -> b: always pass the profile's frequency; storeHook applies the pull check.
    const uint32_t keepFrequency = 0x14000002;
    writeCode(PullCheck, &keepFrequency, 1);
    hook(TriggerUpdater, (const uint32_t[]){UPDATER_PROLOGUE}, (void *)updaterHook, &updaterResume);
    hook(ProfileStore, (const uint32_t[]){STORE_PROLOGUE}, (void *)storeHook, &storeResume);

    enabled = true;
    fprintf(stderr, "RE4 DualSense: weapon trigger profiles enabled.\n");
}
