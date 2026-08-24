package me.aroxu.dawnshell;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

public class HardwareCodecProtocolTest {

    @Test
    public void wireHeaderAndLimitsAreBounded() {
        assertEquals(0x44534342, HardwareCodecProtocol.MAGIC);
        assertEquals(1, HardwareCodecProtocol.VERSION);
        assertEquals(32, HardwareCodecProtocol.HEADER_BYTES);
        assertTrue(HardwareCodecProtocol.MAX_CONTROL_PAYLOAD
                < HardwareCodecProtocol.MAX_MEDIA_PAYLOAD);
        assertTrue(HardwareCodecProtocol.MAX_MEDIA_PAYLOAD <= 8 * 1024 * 1024);
        assertTrue(HardwareCodecProtocol.MAX_SESSIONS_PER_PEER
                <= HardwareCodecProtocol.MAX_SESSIONS);
    }

    @Test
    public void everyRequestTypeFitsBelowResponseBit() {
        int[] types = {
                HardwareCodecProtocol.HELLO,
                HardwareCodecProtocol.CAPABILITIES,
                HardwareCodecProtocol.CREATE,
                HardwareCodecProtocol.INPUT,
                HardwareCodecProtocol.OUTPUT,
                HardwareCodecProtocol.FLUSH,
                HardwareCodecProtocol.EOS,
                HardwareCodecProtocol.CLOSE,
                HardwareCodecProtocol.INPUT_SHARED_MEMORY,
                HardwareCodecProtocol.OUTPUT_SHARED_MEMORY,
                HardwareCodecProtocol.CREATE_TRANSCODER
        };
        for (int type : types) {
            assertEquals(0, type & HardwareCodecProtocol.RESPONSE_BIT);
            assertTrue(type > 0);
        }
    }
}
