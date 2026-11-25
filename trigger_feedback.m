#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <GameController/GameController.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>

#include "fire_gate.h"
#include "hd_haptics.h"
#include "native_profiles.h"

typedef NS_ENUM(NSInteger, FeedbackSource) {
    FeedbackSourceNone,
    FeedbackSourceDirect,
    FeedbackSourceNative,
};

static BOOL directFeedbackEnabled;
static GCDualSenseGamepad *drivenGamepad;
static FeedbackSource drivenSource;
static BOOL fireFeedbackEnabled;
static uint64_t nativeGeneration;

static void stopFeedback(void) {
    if (drivenGamepad) {
        [drivenGamepad.leftTrigger setModeOff];
        [drivenGamepad.rightTrigger setModeOff];
    }
    fireGateSet(nil, 0);
    drivenGamepad = nil;
    drivenSource = FeedbackSourceNone;
    fireFeedbackEnabled = NO;
    nativeGeneration = 0;
}

static GCDualSenseGamepad *connectedDualSense(void) {
    GCDualSenseGamepad *result = nil;
    for (GCController *controller in GCController.controllers) {
        GCExtendedGamepad *profile = controller.extendedGamepad;
        if ([profile isKindOfClass:GCDualSenseGamepad.class]) {
            if (result) {
                return nil;
            }
            result = (GCDualSenseGamepad *)profile;
        }
    }
    return result;
}

static void applyNativeEffect(GCDualSenseAdaptiveTrigger *trigger, const NativeTriggerEffect *effect) {
    const float *v = effect->values;
    switch (effect->kind) {
    case NativeTriggerOff:
        [trigger setModeOff];
        break;
    case NativeTriggerFeedback:
        [trigger setModeFeedbackWithStartPosition:v[0] resistiveStrength:v[1]];
        break;
    case NativeTriggerWeapon:
        [trigger setModeWeaponWithStartPosition:v[0] endPosition:v[1] resistiveStrength:v[2]];
        break;
    case NativeTriggerVibration:
        [trigger setModeVibrationWithStartPosition:v[0] amplitude:v[1] frequency:v[2]];
        break;
    }
    hdHapticsOutputTouched();
}

static void updateDirectFeedback(GCDualSenseGamepad *gamepad, BOOL started) {
    if (started) {
        [gamepad.leftTrigger setModeFeedbackWithStartPosition:0.10f resistiveStrength:0.38f];
    }
    float aim = gamepad.leftTrigger.value;
    BOOL aiming = aim >= (fireFeedbackEnabled ? 0.15f : 0.25f);
    if (aiming == fireFeedbackEnabled && !started) {
        return;
    }
    if (aiming) {
        [gamepad.rightTrigger setModeWeaponWithStartPosition:0.25f endPosition:0.60f
                                          resistiveStrength:0.63f];
        fireGateSet(gamepad.rightTrigger, 0.60f);
    } else {
        [gamepad.rightTrigger setModeOff];
        fireGateSet(nil, 0);
    }
    hdHapticsOutputTouched();
    fireFeedbackEnabled = aiming;
}

static void updateNativeFeedback(GCDualSenseGamepad *gamepad) {
    NativeTriggerEffect effects[2];
    if (nativeTriggersSnapshot(&nativeGeneration, effects)) {
        applyNativeEffect(gamepad.leftTrigger, &effects[0]);
        applyNativeEffect(gamepad.rightTrigger, &effects[1]);
        // A weapon effect clicks at its end position; fire there, not before.
        BOOL clicks = effects[1].kind == NativeTriggerWeapon;
        fireGateSet(gamepad.rightTrigger, clicks ? effects[1].values[1] : 0);
    }
}

static void updateFeedback(void) {
    FeedbackSource source = FeedbackSourceNone;
    if (directFeedbackEnabled) {
        source = FeedbackSourceDirect;
    } else if (nativeTriggersEnabled()) {
        source = FeedbackSourceNative;
    }
    GCDualSenseGamepad *gamepad = NSApp.isActive ? connectedDualSense() : nil;
    nativeTriggersSetPull(gamepad ? gamepad.leftTrigger.value : 0,
                          gamepad ? fireGateRawValue(gamepad.rightTrigger) : 0);
    if (!gamepad || source == FeedbackSourceNone) {
        stopFeedback();
        return;
    }

    BOOL started = gamepad != drivenGamepad || source != drivenSource;
    if (started) {
        stopFeedback();
        drivenGamepad = gamepad;
        drivenSource = source;
    }
    if (source == FeedbackSourceDirect) {
        updateDirectFeedback(gamepad, started);
    } else {
        updateNativeFeedback(gamepad);
    }
}

static void installFeedback(void) {
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserverForName:NSApplicationWillResignActiveNotification
                               object:nil queue:NSOperationQueue.mainQueue
                           usingBlock:^(__unused NSNotification *event) { stopFeedback(); }];
    [notifications addObserverForName:NSApplicationWillTerminateNotification
                               object:nil queue:NSOperationQueue.mainQueue
                           usingBlock:^(__unused NSNotification *event) { stopFeedback(); }];

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *event) {
        if (event.keyCode != kVK_F8 || (event.modifierFlags &
            (NSEventModifierFlagCommand | NSEventModifierFlagControl |
             NSEventModifierFlagOption | NSEventModifierFlagShift))) {
            return event;
        }
        if (!event.isARepeat) {
            directFeedbackEnabled = !directFeedbackEnabled;
            updateFeedback();
            fprintf(stderr, "RE4 DualSense: direct feedback %s.\n",
                    directFeedbackEnabled ? "on" : "off");
        }
        return nil;
    }];

    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 60.0 repeats:YES
                                             block:^(__unused NSTimer *tick) { updateFeedback(); }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    fprintf(stderr, "RE4 DualSense: press F8 in gameplay to toggle direct trigger feedback.\n");
}

__attribute__((constructor))
static void registerFeedback(void) {
    if (getenv("RE4_DUALSENSE_OVERLAY")) {
        dispatch_async(dispatch_get_main_queue(), ^{ installFeedback(); });
    }
}
