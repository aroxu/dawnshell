package me.aroxu.dawnshell;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import org.junit.Test;

public class BfuPreferencesTest {

    @Test
    public void normalizesUsbDeviceIdsAndRemovesDuplicates() {
        assertEquals("18d1:4ee7,0403:6001",
                BfuPreferences.normalizeUsbExclusiveDeviceIds(
                        " 18D1:4EE7, 0403:6001\n18d1:4ee7 "));
    }

    @Test
    public void acceptsEmptyUsbDeviceIdList() {
        assertEquals("", BfuPreferences.normalizeUsbExclusiveDeviceIds(" \n "));
        assertEquals("", BfuPreferences.normalizeUsbExclusiveDeviceIds(null));
    }

    @Test
    public void rejectsMalformedUsbDeviceId() {
        assertThrows(IllegalArgumentException.class,
                () -> BfuPreferences.normalizeUsbExclusiveDeviceIds("18d1:xyz1"));
        assertThrows(IllegalArgumentException.class,
                () -> BfuPreferences.normalizeUsbExclusiveDeviceIds("18d1:4ee7:0001"));
    }

    @Test
    public void rejectsMoreThanThirtyTwoUsbDeviceIds() {
        StringBuilder input = new StringBuilder();
        for (int index = 0; index < 33; index++) {
            if (input.length() > 0) input.append(',');
            input.append(String.format("%04x:%04x", index, index));
        }
        assertThrows(IllegalArgumentException.class,
                () -> BfuPreferences.normalizeUsbExclusiveDeviceIds(
                        input.toString()));
    }
}
