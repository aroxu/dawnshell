#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
layout="$repo_dir/app/src/main/res/layout/activity_boot.xml"
navigation="$repo_dir/app/src/main/res/menu/menu_dashboard_navigation.xml"
activity="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BootActivity.java"
service="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuBootService.java"
guide="$repo_dir/docs/user-guide.md"

for page in dashboard_page_home dashboard_page_access dashboard_page_advanced; do
    grep -Fq "android:id=\"@+id/$page\"" "$layout"
done
advanced_line="$(grep -nF 'android:id="@+id/dashboard_page_advanced"' "$layout" | cut -d: -f1)"
diagnostics_line="$(grep -nF 'android:text="@string/dawnshell_section_diagnostics"' "$layout" | cut -d: -f1)"
(( diagnostics_line > advanced_line ))
[[ "$(grep -Fc '<item' "$navigation")" -eq 3 ]]
grep -Fq 'android:id="@+id/settings_apply_bar"' "$layout"
[[ "$(grep -Fc 'android:id="@+id/save_provision_button"' "$layout")" -eq 1 ]]

if grep -Eq 'android:id="@\+id/apply_(host_usb|docker)_policy_button"' "$layout"; then
    echo "settings must not expose feature-specific apply buttons" >&2
    exit 1
fi

grep -Fq 'SettingsSnapshot.fromPreferences(this)' "$activity"
grep -Fq 'requested.requiresRuntimeApply(previous)' "$activity"
grep -Fq 'requestRuntimeSettingsApply(this' "$activity"
[[ "$(grep -Fc 'savePreferences(requested)' "$activity")" -eq 1 ]]
if grep -Fq 'savePreferences();' "$activity"; then
    echo "immediate command buttons must not silently apply pending settings" >&2
    exit 1
fi
grep -Fq 'ACTION_APPLY_RUNTIME_SETTINGS' "$service"
grep -Fq 'HostUsbProvisioner.apply(this, layout)' "$service"
grep -Fq 'DockerNetworkProvisioner.apply(' "$service"
[[ "$(grep -Fc '"AFU_settings_apply"' "$service")" -eq 1 ]]
[[ "$(grep -Fc '"AFU_settings_applied"' "$service")" -eq 1 ]]

grep -Fq '| **Home** |' "$guide"
grep -Fq 'global **Apply** bar' "$guide"

echo "PASS: dashboard navigation and the single settings apply workflow are pinned."
