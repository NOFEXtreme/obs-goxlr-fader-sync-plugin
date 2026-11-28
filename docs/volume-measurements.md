# GoXLR volume measurements

This fork uses 256 gain coefficients measured on a GoXLR Full with firmware `1.5.1.901`, GoXLR Utility `1.2.4` and TC-Helicon TUSB driver `5.57.0` on Windows. The digital path ran from the channel's WASAPI playback endpoint to Broadcast Stream Mix at 48 kHz. The Sample channel used the sampler. A/B were set separately and confirmed by Utility readback.

[Measured Game, Submix A](game-submix-a.csv) contains the left-channel tone RMS in full-scale units for a descending sweep. The test played a 1 kHz sine with a normalized peak of 0.25. At each integer fader level, it waited 250 ms and recorded 300 ms of stereo audio. Project the captured samples onto sine and cosine at the stimulus frequency, then divide the resulting tone RMS by the RMS at level 255 in the same pass. For a nonzero ratio, gain in dB is `20 × log10(ratio)`.

The lookup table represents that ratio as an integer divided by 7,844. Rounding the measured ratios after multiplying by 7,844 recovers the same table for both Submixes and every tested stimulus. Levels 0–8 had zero-valued PCM windows. The plugin sets exactly zero at those levels, including when a volume offset is applied. At level 255 and an offset of 0 dB, it sets unity gain.

| Recorded conditions | Fader levels | Largest gain residual |
| --- | --- | ---: |
| Game, A/B, rising and falling 1 kHz sweeps, peak 0.25 | All 256 | 0.001701 dB |
| Game, A, 1 kHz and 1.01 kHz precision passes, peaks 0.50 and 0.90 | Selected levels | 0.001700 dB |
| Game, System, Music and Sample, A/B, peak 0.90 | Full sweeps for System, Music and Sample, selected Game levels | 0.001000 dB |
| Chat, A/B, peak 0.90 | Full sweep and selected repeat levels | 0.002294 dB |

These are residuals relative to each pass's own level 255. The recorded PCM has eight zero low bits in its 32-bit container. Residuals vary with the stimulus amplitude and frequency, including in the same channel. Float32 adds at most 0.000000462 dB at an offset of 0 dB. The digital tests cover this unit, firmware and routing. The fork shares the table across supported channels and GoXLR models, including unmeasured analog routes.

The chart compares gain with mute off and an offset of 0 dB. Its original 1.4.0 curve comes from the target formula with the default mute behavior. That version writes a new volume only when the difference exceeds 0.0001 in linear gain or its mute state changes. The chart shows the formula at each level and has no history of earlier settings. [Original 1.4.0 source](https://github.com/parzival-space/obs-goxlr-fader-sync-plugin/blob/8ec2c5bb548ea3340f516235e6d279cb1d7e8300/FaderSyncPlugin/OBS/GoXlrChannelSyncFilter.cs)

To repeat the comparison, route only Game to Broadcast Stream Mix, turn off additional processing in the measurement path, and hold the playback level fixed. Sweep through 0–255 with Utility, checking readback and keeping the inactive Submix constant. Repeat after swapping Submixes. Normalize each pass to its own level 255 and compare with [the supplied sweep](game-submix-a.csv).

## Chat channel dynamics

At fader level 255, separate steady-tone tests with shared and exclusive WASAPI playback showed about +11.66 dB gain for quiet input. Above a fitted knee near −30.1 dBFS in sine peak units, the measured output changed by about 1 dB per 4 dB of input change. The fits gave ratios of 3.97:1 in both modes, with deviations of up to 0.052 dB from the fitted line at higher levels. Music was approximately linear under the same test.

These values describe the measured digital path. The results do not locate the processing in the device or driver, establish manufacturer settings or cover a real voice-call stream. Fader Sync applies the fader's gain in OBS. Capture audio before GoXLR fader gain to prevent applying that gain twice.
