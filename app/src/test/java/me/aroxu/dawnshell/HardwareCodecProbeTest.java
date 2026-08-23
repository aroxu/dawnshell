package me.aroxu.dawnshell;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class HardwareCodecProbeTest {

    @Test
    public void recognizesLegacyExynosHardwareNames() {
        assertTrue(HardwareCodecProbe.isConservativeHardwareCodecName(
                "OMX.Exynos.AVC.Decoder"));
        assertTrue(HardwareCodecProbe.isConservativeHardwareCodecName(
                "OMX.SEC.avc.enc"));
        assertTrue(HardwareCodecProbe.isConservativeHardwareCodecName(
                "c2.exynos.hevc.decoder"));
    }

    @Test
    public void recognizesKnownSoftwareNames() {
        assertTrue(HardwareCodecProbe.isConservativeSoftwareCodecName(
                "OMX.google.h264.decoder"));
        assertTrue(HardwareCodecProbe.isConservativeSoftwareCodecName(
                "c2.android.avc.encoder"));
        assertTrue(HardwareCodecProbe.isConservativeSoftwareCodecName(
                "OMX.ffmpeg.video.decoder"));
    }

    @Test
    public void unknownCodecIsNotPromotedToHardware() {
        assertFalse(HardwareCodecProbe.isConservativeHardwareCodecName(
                "OMX.unknown.avc.decoder"));
        assertFalse(HardwareCodecProbe.isConservativeSoftwareCodecName(
                "OMX.unknown.avc.decoder"));
    }
}
