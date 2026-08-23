package me.aroxu.dawnshell;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import org.junit.Test;

public class BfuArchitectureTest {

    @Test
    public void mapsSupportedAndroidAbisToDebian() {
        assertMapping("armeabi-v7a", "armhf");
        assertMapping("arm64-v8a", "arm64");
        assertMapping("x86_64", "amd64");
    }

    @Test
    public void rejectsUnsupportedAbi() {
        assertNull(BfuArchitecture.fromAndroidAbi("x86"));
    }

    private static void assertMapping(String androidAbi, String debianArchitecture) {
        BfuArchitecture result = BfuArchitecture.fromAndroidAbi(androidAbi);
        assertEquals(androidAbi, result.androidAbi);
        assertEquals(debianArchitecture, result.debianArchitecture);
        assertEquals("bfu/bin/" + androidAbi, result.assetDirectory());
    }
}
