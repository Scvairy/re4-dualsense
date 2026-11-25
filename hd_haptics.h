#ifndef RE4_DUALSENSE_HD_HAPTICS_H
#define RE4_DUALSENSE_HD_HAPTICS_H

// Call after changing an adaptive trigger effect. macOS sends the change in an
// output report that switches the controller back to ordinary rumble, so the
// HD haptics helper re-enables waveform playback shortly afterwards.
void hdHapticsOutputTouched(void);

#endif
